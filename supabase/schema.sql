-- Chami Market backend for Supabase.
--
-- Paste this whole file into the Supabase SQL editor and run it. It is safe to
-- run again after an update: tables are created if missing and functions are
-- replaced.
--
-- Security model: the browser can read public data (usernames, markets,
-- results, the activity feed, the leaderboard) and its own portfolio, but it
-- cannot write any table. Every change to money goes through the functions
-- below, which run on the server, price trades from the server's own data,
-- roll game outcomes with a cryptographic RNG and lock the account row, so
-- balances can't be edited from devtools.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;
-- Optional: lets trades read live Polymarket prices. Without it, trades use
-- the prices the sync job stores every few minutes.
do $$ begin
  create extension if not exists http with schema extensions;
exception when others then raise notice 'http extension not available; trades will use synced prices';
end $$;

create schema if not exists private;
revoke all on schema private from public;
-- Older versions returned text.
drop function if exists public.reset_password_with_code(text, text, text);

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  username extensions.citext not null unique check (username ~ '^[A-Za-z0-9_.+-]{1,20}$'),
  created_at timestamptz not null default now()
);
-- Guests' profiles are hidden from other players (see the "profiles are public" policy).
alter table public.profiles add column if not exists is_guest boolean not null default false;
update public.profiles p set is_guest = u.is_anonymous from auth.users u where u.id = p.id and p.is_guest is distinct from u.is_anonymous;

create table if not exists public.portfolios (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  cash numeric(16, 2) not null check (cash >= 0),
  realized_pnl numeric(16, 2) not null default 0,
  run int not null default 1,
  run_start_cash numeric(16, 2) not null,
  resets_used int not null default 0,
  trade_count int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.positions (
  user_id uuid not null references public.portfolios (user_id) on delete cascade,
  market_id text not null,
  side text not null check (side in ('yes', 'no')),
  market_title text not null default '',
  shares numeric(18, 4) not null check (shares > 0),
  cost_basis numeric(16, 2) not null check (cost_basis >= 0),
  opened_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, market_id, side)
);
create index if not exists positions_market_idx on public.positions (market_id);

create table if not exists public.history (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.portfolios (user_id) on delete cascade,
  run int not null,
  type text not null check (type in ('buy', 'sell', 'settlement', 'reset')),
  market_id text,
  market_title text,
  side text,
  shares numeric(18, 4),
  price numeric(10, 4),
  amount numeric(16, 2),
  realized_pnl numeric(16, 2),
  note text,
  created_at timestamptz not null default now()
);
create index if not exists history_user_idx on public.history (user_id, created_at desc);

create table if not exists public.game_rounds (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.portfolios (user_id) on delete cascade,
  run int not null,
  game text not null check (game in ('roulette', 'blackjack', 'plinko')),
  staked numeric(16, 2) not null,
  returned numeric(16, 2) not null,
  net numeric(16, 2) not null,
  detail text not null default '',
  created_at timestamptz not null default now()
);
-- Only rebuilt when the game list changes, so a re-run doesn't lock and recheck the whole table.
do $$ begin
  if coalesce((select pg_get_constraintdef(oid) from pg_constraint
      where conrelid = 'public.game_rounds'::regclass and conname = 'game_rounds_game_check'), '') not like '%poker%' then
    alter table public.game_rounds drop constraint if exists game_rounds_game_check;
    alter table public.game_rounds add constraint game_rounds_game_check
      check (game in ('roulette', 'blackjack', 'plinko', 'dice', 'mines', 'chicken', 'limbo', 'crash', 'boneyard', 'slots', 'poker'));
  end if;
end $$;
create index if not exists game_rounds_user_idx on public.game_rounds (user_id, created_at desc);

create table if not exists public.equity_snapshots (
  user_id uuid not null references public.portfolios (user_id) on delete cascade,
  t timestamptz not null default now(),
  equity numeric(16, 2) not null
);
create index if not exists equity_snapshots_user_idx on public.equity_snapshots (user_id, t desc);

-- Blackjack hands in progress, including the shoe. Never readable by clients.
create table if not exists public.blackjack_tables (
  user_id uuid primary key references public.portfolios (user_id) on delete cascade,
  state jsonb not null,
  updated_at timestamptz not null default now()
);

-- Provably fair seeds per player. The active server seed is secret until rotated.
create table if not exists public.fair_seeds (
  user_id uuid primary key references public.portfolios (user_id) on delete cascade,
  server_seed text not null,
  client_seed text not null,
  nonce int not null default 0,
  prev_server_seed text,
  prev_client_seed text,
  prev_nonce int,
  updated_at timestamptz not null default now()
);

-- Mines and Chicken Cross rounds in progress (mine positions and the crash lane stay here).
create table if not exists public.game_states (
  user_id uuid not null references public.portfolios (user_id) on delete cascade,
  game text not null check (game in ('mines', 'chicken', 'crash')),
  state jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, game)
);
do $$ begin
  if coalesce((select pg_get_constraintdef(oid) from pg_constraint
      where conrelid = 'public.game_states'::regclass and conname = 'game_states_game_check'), '') not like '%crash%' then
    alter table public.game_states drop constraint if exists game_states_game_check;
    alter table public.game_states add constraint game_states_game_check check (game in ('mines', 'chicken', 'crash'));
  end if;
end $$;

create table if not exists public.recovery_codes (
  user_id uuid primary key references auth.users (id) on delete cascade,
  code_hash text not null,
  failed_attempts int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);

-- Prices and closing times, written by the sync job (and by live price checks).
create table if not exists public.markets (
  id text primary key,
  title text not null,
  category text not null,
  league text,
  labels jsonb not null default '{"yes":"Yes","no":"No"}',
  yes_price numeric(10, 4) not null check (yes_price between 0 and 1),
  no_price numeric(10, 4) not null check (no_price between 0 and 1),
  end_date timestamptz,
  game_start timestamptz,
  closed boolean not null default false,
  data jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
create index if not exists markets_category_idx on public.markets (category, end_date);

create table if not exists public.resolutions (
  market_id text primary key,
  outcome text not null check (outcome in ('yes', 'no', 'void')),
  source text not null default 'sync',
  title text not null default '',
  resolved_at timestamptz not null default now()
);

-- The public activity feed: trades and game results from every player.
create table if not exists public.activity (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles (id) on delete cascade,
  username text not null,
  kind text not null check (kind in ('buy', 'sell', 'game')),
  market_id text,
  market_title text,
  side text,
  side_label text,
  shares numeric(18, 4),
  price numeric(10, 4),
  amount numeric(16, 2),
  game text,
  net numeric(16, 2),
  detail text,
  created_at timestamptz not null default now()
);
create index if not exists activity_created_idx on public.activity (created_at desc);
create index if not exists activity_kind_idx on public.activity (kind, created_at desc);

-- Feedback and suggestions from the Feedback tab. Private: only the owner reads
-- it (Supabase Table Editor, or the "Admin - feedback report" workflow).
create table if not exists public.feedback (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users (id) on delete cascade,
  username text,
  category text not null check (category in ('suggestion', 'bug', 'other')),
  message text not null check (length(message) between 3 and 1000),
  page text check (length(page) <= 200),
  status text not null default 'new' check (status in ('new', 'reviewed')),
  created_at timestamptz not null default now()
);
create index if not exists feedback_created_idx on public.feedback (created_at desc);
create index if not exists feedback_user_idx on public.feedback (user_id);
create index if not exists feedback_new_idx on public.feedback (created_at) where status = 'new';

-- Tables (multiplayer poker; see the poker section further down). One public row
-- per table holds the state every player and spectator may see. Seats, hole
-- cards and the deck live in the private schema, which the API doesn't expose,
-- so no select, filter or Realtime message can ever return a hidden card.
create table if not exists public.poker_tables (
  id bigint generated always as identity primary key,
  stake text not null,
  small_blind bigint not null check (small_blind > 0),
  big_blind bigint not null check (big_blind >= small_blind),
  min_buy bigint not null,
  max_buy bigint not null,
  max_seats int not null default 6 check (max_seats between 2 and 6),
  seated int not null default 0,
  -- Goes up with every change, so clients can drop anything older than what they have.
  version bigint not null default 0,
  hand_no bigint not null default 0,
  -- When the table next needs a push: the end of a player's turn, the next deal, or an idle seat's removal.
  deadline timestamptz,
  state jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists poker_tables_deadline_idx on public.poker_tables (deadline) where deadline is not null;
create index if not exists poker_tables_stake_idx on public.poker_tables (stake);

create table if not exists private.poker_seats (
  table_id bigint not null references public.poker_tables (id) on delete cascade,
  seat int not null check (seat between 0 and 5),
  -- Null once the account is deleted: the seat is folded and cleared when the hand ends.
  user_id uuid references public.portfolios (user_id) on delete set null,
  username text not null,
  -- The portfolio run the chips were bought in. Chips never cross a balance reset.
  run int not null,
  stack bigint not null check (stack >= 0),
  sitting_out boolean not null default false,
  away_since timestamptz,
  leaving boolean not null default false,
  timeouts int not null default 0,
  in_hand boolean not null default false,
  folded boolean not null default false,
  all_in boolean not null default false,
  -- Chips put in on this betting round, and over the whole hand.
  bet bigint not null default 0 check (bet >= 0),
  committed bigint not null default 0 check (committed >= 0),
  -- Whether the player has acted since the last full raise, and the bet they faced or made then.
  acted boolean not null default false,
  acted_level bigint not null default 0,
  hole text[],
  hole_idx int[],
  hand_rank int[],
  shown boolean not null default false,
  won bigint not null default 0,
  last_action text,
  joined_at timestamptz not null default now(),
  -- The last time this player's browser asked about the table. A seat nobody is behind is freed between hands.
  seen_at timestamptz not null default now(),
  primary key (table_id, seat)
);
-- One seat per player across every table.
create unique index if not exists poker_seats_user_idx on private.poker_seats (user_id) where user_id is not null;

create table if not exists private.poker_hands (
  table_id bigint primary key references public.poker_tables (id) on delete cascade,
  hand_no bigint not null,
  street text not null check (street in ('preflop', 'flop', 'turn', 'river', 'done', 'idle')),
  deck text[] not null,
  salts text[] not null,
  commits text[] not null,
  deck_hash text not null,
  -- Index of the last card dealt (hole cards first, then burn and board cards).
  next_card int not null,
  board text[] not null default '{}',
  board_idx int[] not null default '{}',
  button int not null,
  sb_seat int,
  bb_seat int,
  to_act int,
  turn int not null default 0,
  current_bet bigint not null default 0,
  last_raise bigint not null,
  aggressor int,
  runout int not null default 0,
  result jsonb,
  started_at timestamptz not null default now()
);

-- The last finished hand at each table, for the fairness check (see poker_proof).
create table if not exists private.poker_proofs (
  table_id bigint primary key references public.poker_tables (id) on delete cascade,
  hand_no bigint not null,
  deck_hash text not null,
  commits text[] not null,
  reveals jsonb not null,
  holes jsonb not null
);

create table if not exists private.rate_limits (
  user_id uuid not null,
  bucket text not null,
  window_start timestamptz not null,
  hits int not null,
  primary key (user_id, bucket)
);

-- Running game totals per player, run and game, kept by private.game_round, so
-- portfolio and leaderboard reads don't add up every round ever played.
create table if not exists private.game_totals (
  user_id uuid not null references public.portfolios (user_id) on delete cascade,
  run int not null,
  game text not null,
  rounds bigint not null default 0,
  wagered numeric not null default 0,
  net numeric not null default 0,
  best numeric not null default 0,
  primary key (user_id, run, game)
);
-- Fills in players from before the table existed. Anyone with a row is already kept up to date.
insert into private.game_totals (user_id, run, game, rounds, wagered, net, best)
select g.user_id, g.run, g.game, count(*), sum(g.staked), sum(g.net), max(g.net)
from public.game_rounds g
where not exists (select 1 from private.game_totals t where t.user_id = g.user_id)
group by g.user_id, g.run, g.game;

-- The last leaderboard, reused for a few seconds so a burst of visitors runs it once.
create table if not exists private.leaderboard_cache (
  id int primary key check (id = 1),
  data jsonb not null,
  at timestamptz not null
);

-- ---------------------------------------------------------------------------
-- Row level security: read-only access for clients, no client writes at all
-- ---------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.portfolios enable row level security;
alter table public.positions enable row level security;
alter table public.history enable row level security;
alter table public.game_rounds enable row level security;
alter table public.equity_snapshots enable row level security;
alter table public.blackjack_tables enable row level security;
alter table public.fair_seeds enable row level security;
alter table public.game_states enable row level security;
alter table public.recovery_codes enable row level security;
alter table public.markets enable row level security;
alter table public.resolutions enable row level security;
alter table public.activity enable row level security;

revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;
revoke all on public.blackjack_tables, public.recovery_codes, public.fair_seeds, public.game_states from anon, authenticated;
alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;
do $$ begin
  grant select, update on public.feedback to service_role;
exception when undefined_object then null;
end $$;

drop policy if exists "profiles are public" on public.profiles;
-- Everyone's but guests': a name a guest picks while signing up stays private until the sign-up finishes.
create policy "profiles are public" on public.profiles for select using (not is_guest or id = auth.uid());
drop policy if exists "own portfolio" on public.portfolios;
create policy "own portfolio" on public.portfolios for select to authenticated using (user_id = auth.uid());
drop policy if exists "own positions" on public.positions;
create policy "own positions" on public.positions for select to authenticated using (user_id = auth.uid());
drop policy if exists "own history" on public.history;
create policy "own history" on public.history for select to authenticated using (user_id = auth.uid());
drop policy if exists "own game rounds" on public.game_rounds;
create policy "own game rounds" on public.game_rounds for select to authenticated using (user_id = auth.uid());
drop policy if exists "own snapshots" on public.equity_snapshots;
create policy "own snapshots" on public.equity_snapshots for select to authenticated using (user_id = auth.uid());
drop policy if exists "markets are public" on public.markets;
create policy "markets are public" on public.markets for select using (true);
drop policy if exists "results are public" on public.resolutions;
create policy "results are public" on public.resolutions for select using (true);
drop policy if exists "activity is public" on public.activity;
create policy "activity is public" on public.activity for select using (true);
-- The feeds show a username, never which account a row belongs to: a guest's rows would otherwise
-- link to the name they pick later, and ids plus exact times would trace one player across the feed.
-- Profiles likewise show only a name, not when the account was made. (Realtime sends only these columns too.)
revoke select on public.activity from anon, authenticated;
grant select (id, username, kind, market_id, market_title, side, side_label, shares, price, amount, game, net, detail, created_at)
  on public.activity to anon, authenticated;
revoke select on public.profiles from anon, authenticated;
grant select (id, username, is_guest) on public.profiles to anon, authenticated;

-- Tables: anyone may read the public state of a table; nothing else about a hand is reachable.
alter table public.poker_tables enable row level security;
drop policy if exists "tables are public" on public.poker_tables;
create policy "tables are public" on public.poker_tables for select using (true);
revoke all on public.poker_tables from anon, authenticated;
grant select (id, stake, small_blind, big_blind, min_buy, max_buy, max_seats, seated, version, hand_no, deadline, state, updated_at)
  on public.poker_tables to anon, authenticated;
revoke all on all tables in schema private from public, anon, authenticated;

-- Live feed over Supabase Realtime.
do $$ begin
  alter publication supabase_realtime add table public.activity;
exception when others then null;
end $$;
-- Table state changes, so players see each other act without polling.
do $$ begin
  alter publication supabase_realtime add table public.poker_tables;
exception when others then null;
end $$;

-- ---------------------------------------------------------------------------
-- Helpers (private schema, not callable from the browser)
-- ---------------------------------------------------------------------------

create or replace function private.uid() returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'Log in first.'; end if;
  return v;
end $$;

create or replace function private.ms(t timestamptz) returns bigint
language sql immutable set search_path = '' as $$ select (extract(epoch from t) * 1000)::bigint $$;

/** Fails when a user calls a bucket more than `max_hits` times per minute. */
create or replace function private.rate_limit(p_user uuid, p_bucket text, p_max int) returns void
language plpgsql set search_path = '' as $$
declare r private.rate_limits;
begin
  insert into private.rate_limits as rl (user_id, bucket, window_start, hits) values (p_user, p_bucket, now(), 1)
  on conflict (user_id, bucket) do update set
    hits = case when rl.window_start < now() - interval '1 minute' then 1 else rl.hits + 1 end,
    window_start = case when rl.window_start < now() - interval '1 minute' then now() else rl.window_start end
  returning * into r;
  if r.hits > p_max then raise exception 'Slow down a little and try again in a minute.'; end if;
end $$;

/** Uniform integer in [0, n) from a cryptographic RNG, without modulo bias. */
create or replace function private.rand_int(n int) returns int
language plpgsql volatile set search_path = '' as $$
declare x bigint; lim bigint;
begin
  if n < 1 then raise exception 'rand_int needs n >= 1'; end if;
  lim := (4294967296 / n) * n;
  loop
    x := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;
    if x < 0 then x := x + 4294967296; end if;
    exit when x < lim;
  end loop;
  return (x % n)::int;
end $$;

create or replace function private.username_of(p_user uuid) returns text
language sql stable set search_path = '' as $$ select username::text from public.profiles where id = p_user $$;

/** Guests play on an anonymous Supabase account until they sign up (which keeps everything). */
create or replace function private.is_guest(p_user uuid) returns boolean
language sql stable set search_path = '' as $$ select coalesce((select is_anonymous from auth.users where id = p_user), false) $$;

/** The name shown in the public feeds: "Guest" for guests. */
create or replace function private.feed_name(p_user uuid) returns text
language sql stable set search_path = '' as $$
  select case when private.is_guest(p_user) then 'Guest' else private.username_of(p_user) end
$$;

-- ---------------------------------------------------------------------------
-- Market prices
-- ---------------------------------------------------------------------------

/** Live Polymarket price via the http extension; null when unavailable. */
create or replace function private.live_gamma(p_id text) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare v_status int; v_body text; j jsonb; prices jsonb; y numeric; n numeric; v_closed boolean; v_accepting boolean;
  v_end timestamptz; v_final boolean;
begin
  if p_id !~ '^\d{1,15}$' then return null; end if;
  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '4000');
    select status, content into v_status, v_body from extensions.http_get('https://gamma-api.polymarket.com/markets/' || p_id);
  exception when others then
    return null;
  end;
  if v_status is distinct from 200 then return null; end if;
  begin
    j := v_body::jsonb;
    prices := (j ->> 'outcomePrices')::jsonb;
    y := (prices ->> 0)::numeric;
    n := (prices ->> 1)::numeric;
    v_closed := coalesce((j ->> 'closed')::boolean, false);
    v_accepting := coalesce((j ->> 'acceptingOrders')::boolean, true);
    v_end := (j ->> 'endDate')::timestamptz;
  exception when others then
    return null;
  end;
  if y is null or n is null or y < 0 or y > 1 or n < 0 or n > 1 then return null; end if;
  -- A closed market can still be under an UMA proposal or dispute; only a final result settles.
  v_final := v_closed and coalesce(nullif(j ->> 'umaResolutionStatus', ''), 'resolved') = 'resolved';
  return jsonb_build_object(
    'yes', round(y, 4), 'no', round(n, 4),
    'closed', v_closed,
    'accepting', v_accepting,
    'end_date', v_end,
    'title', left(coalesce(j ->> 'question', ''), 300),
    'outcome', case
      when v_final and y >= 0.99 and n <= 0.01 then 'yes'
      when v_final and n >= 0.99 and y <= 0.01 then 'no'
      -- Canceled events settle 50-50 on Polymarket; here they refund at cost.
      when v_final and y = 0.5 and n = 0.5 then 'void'
    end
  );
end $$;

/** Live Coinbase spot price via the http extension; null when unavailable. */
create or replace function private.live_coinbase(p_product text) returns numeric
language plpgsql volatile set search_path = '' as $$
declare v_status int; v_body text; v numeric;
begin
  if p_product not in ('BTC-USD', 'ETH-USD') then return null; end if;
  begin
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '3000');
    select status, content into v_status, v_body from extensions.http_get('https://api.exchange.coinbase.com/products/' || p_product || '/ticker');
    if v_status is distinct from 200 then return null; end if;
    v := (v_body::jsonb ->> 'price')::numeric;
  exception when others then
    return null;
  end;
  return case when v > 0 then v end;
end $$;

/** Standard normal CDF (Abramowitz and Stegun 7.1.26, error under 2e-7). */
create or replace function private.norm_cdf(x float8) returns float8
language plpgsql immutable set search_path = '' as $$
declare z float8 := abs(x) / sqrt(2.0); t float8 := 1 / (1 + 0.3275911 * z); e float8;
begin
  e := 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-z * z);
  return case when x >= 0 then (1 + e) / 2 else (1 - e) / 2 end;
end $$;

/**
 * Chance an hourly crypto market finishes above its strike: lognormal with no
 * drift, the same formula as probAbove() in src/services/quick/crypto.js,
 * kept between 2% and 98% like the listed odds.
 */
create or replace function private.above_prob(p_spot numeric, p_strike numeric, p_sigma float8, p_minutes float8) returns numeric
language plpgsql immutable set search_path = '' as $$
declare sd float8;
begin
  if p_minutes <= 0 then return case when p_spot > p_strike then 0.98 else 0.02 end; end if;
  sd := p_sigma * sqrt(p_minutes);
  return round(least(greatest(private.norm_cdf((ln(p_spot / p_strike)::float8 - sd * sd / 2) / sd)::numeric, 0.02), 0.98), 4);
end $$;

drop function if exists private.quote(text, text);

/**
 * The server's price for one outcome, with the market's title and closing
 * time. Problems come back in `err` rather than as exceptions: a raise would
 * roll back the price cache and rate limit along with the trade, letting
 * failed trades hit the price APIs without limit.
 */
create or replace function private.quote(p_market text, p_side text, out price numeric, out title text, out closes timestamptz, out err text)
language plpgsql volatile set search_path = '' as $$
declare m public.markets; live jsonb; legs text[]; leg text; leg_id text; leg_side text; lq record; lc timestamptz;
  spot numeric; strike numeric; v_end timestamptz; sigma float8; p numeric;
begin
  if p_side not in ('yes', 'no') then err := 'Pick Yes or No.'; return; end if;
  if exists (select 1 from public.resolutions where market_id = p_market) then
    err := 'This market is resolved. Trading is closed.'; return;
  end if;

  -- Parlays (retired, still sellable) are priced from their legs ("q-parlay-<id>_y~<id>_n").
  if p_market like 'q-parlay-%' then
    legs := string_to_array(substr(p_market, 10), '~');
    if coalesce(array_length(legs, 1), 0) < 2 then err := 'This market is not available for trading right now.'; return; end if;
    price := 1;
    closes := null;
    foreach leg in array legs loop
      leg_id := regexp_replace(leg, '_[yn]$', '');
      leg_side := case when leg ~ '_y$' then 'yes' else 'no' end;
      select * into lq from private.quote(leg_id, leg_side);
      if lq.err is not null then err := lq.err; return; end if;
      price := price * lq.price;
      select least(coalesce(mm.game_start, mm.end_date), lq.closes) into lc from public.markets mm where mm.id = leg_id;
      closes := least(closes, lc, lq.closes);
    end loop;
    if p_side = 'no' then price := 1 - price; end if;
    price := round(price, 4);
    select coalesce(mm.title, 'Parlay') into title from public.markets mm where mm.id = p_market;
    title := coalesce(title, 'Parlay');
  else
    select * into m from public.markets where id = p_market;
    if m.id is null then err := 'This market is not available for trading right now.'; return; end if;
    if m.closed then err := 'This market is closed.'; return; end if;
    title := m.title;
    closes := m.end_date;

    if p_market ~ '^\d+$' then
      -- Polymarket: a live price, at most every 5 seconds per market.
      if m.updated_at < now() - interval '5 seconds' then live := private.live_gamma(p_market); end if;
      if live is not null then
        update public.markets set yes_price = (live ->> 'yes')::numeric, no_price = (live ->> 'no')::numeric, updated_at = now()
        where id = p_market;
        -- Closed, or paused once a game ends but before it resolves: the winner is already known.
        if (live ->> 'closed')::boolean or not (live ->> 'accepting')::boolean then err := 'This market is closed.'; return; end if;
        m.yes_price := (live ->> 'yes')::numeric;
        m.no_price := (live ->> 'no')::numeric;
        m.updated_at := now();
        title := coalesce(nullif(live ->> 'title', ''), m.title, '');
        closes := coalesce(m.end_date, (live ->> 'end_date')::timestamptz);
      end if;
      if m.updated_at < now() - interval '3 hours' then err := 'This market''s price is refreshing. Try again in a few minutes.'; return; end if;
      -- Once a game is under way, an old price would let players buy the leading side cheap.
      if m.game_start <= now() and m.updated_at < now() - interval '2 minutes' then
        err := 'This market''s price is refreshing. Try again in a minute.'; return;
      end if;
    elsif p_market ~ '^q-(btc|eth)-above-\d+(\.\d+)?-\d+$' then
      -- Hourly crypto markets move fast: price them from live Coinbase spot,
      -- at most every 10 seconds per market, the same way the browser does.
      strike := substring(p_market from '^q-[a-z]+-above-(\d+(?:\.\d+)?)-')::numeric;
      v_end := to_timestamp(substring(p_market from '-(\d+)$')::bigint);
      sigma := (m.data -> 'quote' ->> 'sigma')::float8;
      if m.updated_at < now() - interval '10 seconds' and sigma > 0 then
        spot := private.live_coinbase(m.data -> 'quote' ->> 'product');
        if spot is not null then
          p := private.above_prob(spot, strike, sigma, extract(epoch from v_end - now()) / 60);
          update public.markets set yes_price = p, no_price = 1 - p, updated_at = now() where id = p_market;
          m.yes_price := p;
          m.no_price := 1 - p;
          m.updated_at := now();
        end if;
      end if;
      -- Without a live price, only a very fresh synced one will do.
      if m.updated_at < now() - interval '4 minutes' then err := 'This market''s price is refreshing. Try again in a minute.'; return; end if;
    else
      if m.updated_at < now() - interval '3 hours' then err := 'This market''s price is refreshing. Try again in a few minutes.'; return; end if;
    end if;
    price := case when p_side = 'yes' then m.yes_price else m.no_price end;
  end if;

  if closes is not null and closes <= now() then
    err := 'This event has ended. Trading is closed until it settles.'; return;
  end if;
  if price is null or price <= 0 or price >= 1 then
    err := 'This outcome has no tradable price right now.'; return;
  end if;
end $$;

/** Rejects a trade when the price the player saw is more than 3 cents off the server's. */
drop function if exists private.check_price(numeric, numeric);
create or replace function private.price_moved(p_seen numeric, p_server numeric) returns text
language sql immutable set search_path = '' as $$
  select case when p_seen is not null and abs(p_seen - p_server) > 0.03
    then format('The price moved to %s¢. Check the new price and try again.', round(p_server * 100, 1)) end
$$;

/** A position's value: resolved markets pay $1 or $0 (void refunds cost), else the stored price. */
create or replace function private.position_value(p public.positions) returns numeric
language sql stable set search_path = '' as $$
  select round(case
    when r.outcome = 'void' then p.cost_basis
    when r.outcome is not null then case when r.outcome = p.side then p.shares else 0 end
    when m.id is not null then p.shares * case when p.side = 'yes' then m.yes_price else m.no_price end
    else p.cost_basis
  end, 2)
  from (select 1) one
  left join public.resolutions r on r.market_id = p.market_id
  left join public.markets m on m.id = p.market_id
$$;

create or replace function private.equity(p_user uuid) returns numeric
language sql stable set search_path = '' as $$
  select pf.cash + coalesce((select sum(private.position_value(p)) from public.positions p where p.user_id = p_user), 0)
    -- Chips at a table (the stack plus anything in the pot this hand) are still the player's until a hand is lost.
    + coalesce((select s.stack + s.committed from private.poker_seats s where s.user_id = p_user and s.run = pf.run), 0)
  from public.portfolios pf where pf.user_id = p_user
$$;

create or replace function private.snapshot(p_user uuid, p_force boolean default false) returns void
language plpgsql set search_path = '' as $$
declare last timestamptz;
begin
  select max(t) into last from public.equity_snapshots where user_id = p_user;
  if p_force or last is null or last < now() - interval '5 minutes' then
    insert into public.equity_snapshots (user_id, equity) values (p_user, private.equity(p_user));
    delete from public.equity_snapshots s where s.user_id = p_user and s.t < (
      select t from public.equity_snapshots where user_id = p_user order by t desc offset 399 limit 1
    );
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Portfolio view returned to the browser (same shape as the local app uses)
-- ---------------------------------------------------------------------------

create or replace function private.portfolio_json(p_user uuid) returns jsonb
language sql stable set search_path = '' as $$
  with pf as (select * from public.portfolios where user_id = p_user),
  stats as (
    select game, sum(rounds) as rounds, sum(wagered) as wagered, sum(net) as net, greatest(max(best), 0) as best
    from private.game_totals where user_id = p_user group by game
  ),
  run_games as (
    select coalesce(sum(rounds), 0) as rounds, coalesce(sum(net), 0) as net, coalesce(sum(wagered), 0) as wagered, greatest(coalesce(max(best), 0), 0) as best
    from private.game_totals g, pf where g.user_id = p_user and g.run = pf.run
  )
  select jsonb_build_object(
    'cash', pf.cash,
    'realizedPnl', pf.realized_pnl,
    'run', pf.run,
    'runStartCash', pf.run_start_cash,
    'resetsUsed', pf.resets_used,
    'tradeCount', pf.trade_count,
    'tableChips', coalesce((select s.stack + s.committed from private.poker_seats s where s.user_id = p_user and s.run = pf.run), 0),
    'createdAt', private.ms(pf.created_at),
    'positions', coalesce((
      select jsonb_object_agg(p.market_id || ':' || p.side, jsonb_build_object(
        'marketId', p.market_id, 'side', p.side, 'marketTitle', p.market_title,
        'shares', p.shares, 'costBasis', p.cost_basis,
        'openedAt', private.ms(p.opened_at), 'updatedAt', private.ms(p.updated_at)))
      from public.positions p where p.user_id = p_user), '{}'),
    'history', coalesce((
      select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id', 'h' || h.id, 'ts', private.ms(h.created_at), 'run', h.run, 'type', h.type,
        'marketId', h.market_id, 'marketTitle', h.market_title, 'side', h.side, 'shares', h.shares,
        'price', h.price, 'amount', h.amount, 'realizedPnl', h.realized_pnl, 'note', h.note)) order by h.created_at desc, h.id desc)
      from (select * from public.history where user_id = p_user order by created_at desc, id desc limit 1000) h), '[]'),
    'snapshots', coalesce((
      select jsonb_agg(jsonb_build_object('t', private.ms(s.t), 'equity', s.equity) order by s.t)
      from public.equity_snapshots s where s.user_id = p_user), '[]'),
    'games', jsonb_build_object(
      'history', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', 'g' || g.id, 'ts', private.ms(g.created_at), 'run', g.run, 'game', g.game,
          'staked', g.staked, 'returned', g.returned, 'net', g.net, 'detail', g.detail) order by g.created_at desc, g.id desc)
        from (select * from public.game_rounds where user_id = p_user order by created_at desc, id desc limit 200) g), '[]'),
      'stats', coalesce((select jsonb_object_agg(game, jsonb_build_object('rounds', rounds, 'wagered', wagered, 'net', net, 'best', best)) from stats), '{}'),
      'pending', '[]'::jsonb,
      'run', pf.run,
      'runNet', rg.net, 'runRounds', rg.rounds, 'runWagered', rg.wagered, 'runBest', rg.best)
  )
  from pf, run_games rg
$$;

-- ---------------------------------------------------------------------------
-- Accounts
-- ---------------------------------------------------------------------------

/**
 * Names players can't take: the simulated players' names (so nobody can pass
 * as one, or have one pass as them) and anything that looks official.
 * Keep the list in step with src/services/mockTraders.js (a unit test checks).
 */
/** A name folded for look-alike checks: lowercase, no _ . + -, and 0 1 3 4 5 7 8 i read as o l e a s t b l. */
create or replace function private.name_key(p_name text) returns text
language sql immutable set search_path = '' as $$
  select translate(lower(regexp_replace(coalesce(p_name, ''), '[_.+-]', '', 'g')), '0134578i', 'oleastbl')
$$;

create or replace function private.is_reserved_name(p_name text) returns boolean
language sql immutable set search_path = '' as $$
  select private.name_key(p_name) in (select private.name_key(x) from unnest(array[
    'ballotmaster',
    'benchwarmer',
    'bullpenbets',
    'coinflipcarl',
    'contrarian_cat',
    'cryptooracle',
    'datadan',
    'electoraledge',
    'filibusterfred',
    'forecastfiona',
    'fourthandlong',
    'gamedaygabe',
    'gridironguru',
    'hoopshedger',
    'longshotlou',
    'lucky_lena',
    'mapleleaf_mo',
    'marginmaya',
    'midtermmaven',
    'nightowl88',
    'nottoday_nia',
    'oddsonollie',
    'parlayprincess',
    'pivotpete',
    'pollpundit',
    'quietkelly',
    'redzonerita',
    'sixfigurespreads',
    'statsgeek',
    'swingstatesam',
    'tipofftom',
    'whaletrader99',
    'yesman_jay',
    'mod',
    'support',
    'staff',
    'system',
    'sim',
    'root',
    'owner',
    'help',
    'null',
    'undefined'
  ]) x)
    or exists (select 1 from unnest(array['admin', 'moderator', 'official', 'chaminade', 'chamimarket']) w
      where position(private.name_key(w) in private.name_key(p_name)) > 0)
    -- "sim" on its own or as a tag (sim_1, bot-sim) would pass as a simulated player.
    or lower(coalesce(p_name, '')) ~ '(^|[^a-z])sim([^a-z]|$)'
    -- Names starting with guest would look like the Guest accounts in the feeds.
    or private.name_key(p_name) like 'guest%'
    -- Slurs and crude words (look-alikes included), and names that pass as school staff.
    or exists (select 1 from unnest(array['fuck', 'shit', 'bitch', 'cunt', 'nigg', 'niga', 'fag', 'retard', 'whore', 'slut', 'porn', 'nazi', 'hitler', 'kkk', 'dick', 'pussy', 'penis', 'vagina', 'boob']) w
      where position(private.name_key(w) in private.name_key(p_name)) > 0)
    or coalesce(p_name, '') ~ '^(Mr|Mrs|Ms|Dr|Fr|Br|Bro|Coach|Principal|Teacher|Prof|Dean)_?[A-Z]'
    or lower(coalesce(p_name, '')) ~ '^(mrs?|ms|dr|fr|br|bro|coach|principal|teacher|prof|dean)_'
    or lower(coalesce(p_name, '')) ~ '(principal|teacher|faculty)'
$$;

/** The username rules for a new player, or a guest picking a name: raises when the name can't be used. */
create or replace function private.check_username(p_name text, p_self uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  -- Same rule as the sign-up form, so direct API sign-ups can't make look-alikes such as a.lex or alex-.
  if coalesce(p_name, '') !~ '^[A-Za-z0-9_]{3,20}$' then
    raise exception 'Pick a username of 3 to 20 letters, numbers or underscores.';
  end if;
  if private.is_reserved_name(p_name) then raise exception 'That username is reserved. Pick another.'; end if;
  -- No look-alikes of an existing player either (aIice next to alice).
  if exists (select 1 from public.profiles where id is distinct from p_self and private.name_key(username::text) = private.name_key(p_name)) then
    raise exception 'That username is taken.';
  end if;
end $$;

/**
 * Creates the profile and a $100,000 portfolio for every new sign-up. Guests
 * (Supabase anonymous sign-ins) get a placeholder name until they sign up.
 */
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_name text := trim(coalesce(new.raw_user_meta_data ->> 'username', ''));
begin
  if coalesce(new.is_anonymous, false) then
    -- The hyphen keeps it apart from real usernames, which can't have one.
    v_name := 'guest-' || left(replace(new.id::text, '-', ''), 12);
  else
    perform private.check_username(v_name, null);
    -- A username's login address (<name>@users.chamimarket.app, see VITE_USERNAME_EMAIL_DOMAIN) belongs to that
    -- username only, so nobody can claim someone else's login name under a different profile name.
    if lower(new.email) like '%@users.chamimarket.app' and lower(split_part(new.email, '@', 1)) <> lower(v_name) then
      raise exception 'That username is not available.';
    end if;
  end if;
  insert into public.profiles (id, username, is_guest) values (new.id, v_name, coalesce(new.is_anonymous, false));
  insert into public.portfolios (user_id, cash, run_start_cash) values (new.id, 100000, 100000);
  insert into public.equity_snapshots (user_id, equity) values (new.id, 100000);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function private.handle_new_user();

/** Keeps the same rule when an account changes its email later. */
create or replace function private.check_login_email() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if lower(new.email) like '%@users.chamimarket.app'
    and lower(split_part(new.email, '@', 1)) <> lower(coalesce((select username::text from public.profiles where id = new.id), '')) then
    raise exception 'That email address is not available.';
  end if;
  return new;
end $$;

/** A guest who finishes signing up becomes a regular, visible profile. */
create or replace function private.sync_guest_flag() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles set is_guest = coalesce(new.is_anonymous, false) where id = new.id;
  return new;
end $$;

drop trigger if exists on_auth_user_guest on auth.users;
create trigger on_auth_user_guest after update of is_anonymous on auth.users for each row
  when (old.is_anonymous is distinct from new.is_anonymous) execute function private.sync_guest_flag();

drop trigger if exists on_auth_user_email on auth.users;
create trigger on_auth_user_email before update of email on auth.users for each row
  when (old.email is distinct from new.email) execute function private.check_login_email();

create or replace function public.username_available(p_username text) returns boolean
language sql stable security definer set search_path = '' as $$
  select not private.is_reserved_name(p_username)
    and not exists (select 1 from public.profiles where private.name_key(username::text) = private.name_key(trim(p_username)))
$$;

create index if not exists profiles_name_key_idx on public.profiles (private.name_key(username::text));

/**
 * A guest picks their username just before signing up, so the account (and
 * its balance, trades and games) carries over: the browser then sets the
 * login email and password on this same account. Only guests can call it.
 */
create or replace function public.claim_guest(p_username text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); v_name text := trim(coalesce(p_username, ''));
begin
  perform private.rate_limit(v_user, 'claim', 10);
  if not private.is_guest(v_user) then return jsonb_build_object('error', 'This account already has a username.'); end if;
  begin
    perform private.check_username(v_name, v_user);
  exception when others then
    return jsonb_build_object('error', sqlerrm);
  end;
  update public.profiles set username = v_name where id = v_user;
  return jsonb_build_object('username', v_name);
exception when unique_violation then
  return jsonb_build_object('error', 'That username is taken.');
end $$;

create or replace function public.get_portfolio() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid();
begin
  -- A Crash round that ended while the player was away pays out (or loses) now.
  perform 1 from public.portfolios where user_id = v_user for update;
  perform private.crash_settle(v_user);
  perform private.snapshot(v_user);
  return private.portfolio_json(v_user) || jsonb_build_object('username', private.username_of(v_user));
end $$;

/** A new one-time recovery code for the signed-in player. Shown once; only a hash is stored. */
create or replace function public.create_recovery_code() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; code text := ''; i int;
begin
  perform private.rate_limit(v_user, 'recovery', 5);
  if private.is_guest(v_user) then raise exception 'Sign up first, then make a recovery code.'; end if;
  for i in 1..12 loop
    code := code || substr(alphabet, private.rand_int(length(alphabet)) + 1, 1);
    if i in (4, 8) then code := code || '-'; end if;
  end loop;
  insert into public.recovery_codes (user_id, code_hash) values (v_user, extensions.crypt(code, extensions.gen_salt('bf', 10)))
  on conflict (user_id) do update set code_hash = excluded.code_hash, failed_attempts = 0, locked_until = null, created_at = now();
  return code;
end $$;

/**
 * Sets a new password with a recovery code (no email involved). Five wrong
 * codes lock the account's recovery for 15 minutes. Returns { "code": "<new
 * code>" } on success (the used code stops working) or { "error": "..." }.
 * Failures are returned rather than raised so the attempt counter is saved.
 */
create or replace function public.reset_password_with_code(p_email text, p_code text, p_new_password text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid; rc public.recovery_codes; v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; fresh text := ''; i int;
  -- One answer for every failure, so nobody can tell whether an account (or a locked one) exists.
  no_match constant text := 'That username and recovery code don''t match. After 5 wrong codes, wait 15 minutes.';
begin
  if length(coalesce(p_new_password, '')) < 8 or length(p_new_password) > 72 then
    return jsonb_build_object('error', 'Passwords need 8 to 72 characters.');
  end if;
  -- Every attempt hashes, so all of them together are capped too.
  perform private.rate_limit('00000000-0000-0000-0000-000000000000', 'recovery-all', 300);
  -- Login emails are stored in lowercase, so this uses the email index.
  select id into v_user from auth.users where email = lower(trim(p_email));
  if v_user is not null then
    select * into rc from public.recovery_codes where user_id = v_user for update;
  end if;
  if rc.user_id is null then
    perform extensions.crypt('timing', extensions.gen_salt('bf', 10));
    return jsonb_build_object('error', no_match);
  end if;
  if rc.locked_until is not null and rc.locked_until > now() then
    perform extensions.crypt('timing', extensions.gen_salt('bf', 10));
    return jsonb_build_object('error', no_match);
  end if;
  -- An expired lock starts the count over, so one guess every 15 minutes can't keep it locked forever.
  if rc.locked_until is not null then
    update public.recovery_codes set failed_attempts = 0, locked_until = null where user_id = v_user;
    rc.failed_attempts := 0;
  end if;
  v_code := substr(v_code, 1, 4) || '-' || substr(v_code, 5, 4) || '-' || substr(v_code, 9, 4);
  if extensions.crypt(v_code, rc.code_hash) <> rc.code_hash then
    update public.recovery_codes set failed_attempts = rc.failed_attempts + 1,
      locked_until = case when rc.failed_attempts + 1 >= 5 then now() + interval '15 minutes' end
    where user_id = v_user;
    return jsonb_build_object('error', no_match);
  end if;

  update auth.users set encrypted_password = extensions.crypt(p_new_password, extensions.gen_salt('bf', 10)), updated_at = now()
  where id = v_user;
  -- Sign out every existing session.
  begin
    delete from auth.sessions where user_id = v_user;
  exception when others then null;
  end;
  begin
    execute 'update auth.refresh_tokens set revoked = true where user_id = $1' using v_user::text;
  exception when others then null;
  end;

  for i in 1..12 loop
    fresh := fresh || substr(alphabet, private.rand_int(length(alphabet)) + 1, 1);
    if i in (4, 8) then fresh := fresh || '-'; end if;
  end loop;
  update public.recovery_codes set code_hash = extensions.crypt(fresh, extensions.gen_salt('bf', 10)), failed_attempts = 0, locked_until = null, created_at = now()
  where user_id = v_user;
  return jsonb_build_object('code', fresh);
end $$;

-- ---------------------------------------------------------------------------
-- Trading
-- ---------------------------------------------------------------------------

create or replace function public.buy(p_market_id text, p_side text, p_amount numeric, p_seen_price numeric default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; q record; spend numeric; v_shares numeric; label text;
begin
  perform private.rate_limit(v_user, 'trade', 30);
  if p_amount is null or not (p_amount >= 0.01 and p_amount < 1e12) then raise exception 'Enter an amount of at least $0.01.'; end if;
  -- Parlays are no longer offered. Positions opened earlier can still be sold and settle as before.
  if p_market_id like 'q-parlay-%' then raise exception 'Parlays are no longer offered.'; end if;
  -- One trade or settlement per market at a time, so a buy can't slip in while it settles.
  -- Market first, then the portfolio, the same order as sell and resolve, so they can't deadlock.
  perform pg_advisory_xact_lock(hashtext('market:' || p_market_id));
  select * into pf from public.portfolios where user_id = v_user for update;
  spend := round(p_amount, 2);
  if spend > pf.cash then raise exception 'Amount exceeds your available cash ($%).', to_char(pf.cash, 'FM999,999,999,990.00'); end if;
  -- From here on, problems are returned rather than raised so the price check and rate limit stick.
  select * into q from private.quote(p_market_id, p_side);
  if q.err is not null then return jsonb_build_object('error', q.err); end if;
  if private.price_moved(p_seen_price, q.price) is not null then return jsonb_build_object('error', private.price_moved(p_seen_price, q.price)); end if;
  v_shares := round(spend / q.price, 4);
  if v_shares < 0.0001 then return jsonb_build_object('error', 'Order is too small to buy any shares.'); end if;

  insert into public.positions as p (user_id, market_id, side, market_title, shares, cost_basis)
  values (v_user, p_market_id, p_side, q.title, v_shares, spend)
  on conflict (user_id, market_id, side) do update set
    shares = p.shares + excluded.shares, cost_basis = p.cost_basis + excluded.cost_basis,
    market_title = excluded.market_title, updated_at = now();
  update public.portfolios set cash = cash - spend, trade_count = trade_count + 1, updated_at = now() where user_id = v_user;
  insert into public.history (user_id, run, type, market_id, market_title, side, shares, price, amount)
  values (v_user, pf.run, 'buy', p_market_id, q.title, p_side, v_shares, q.price, spend);
  select labels ->> p_side into label from public.markets where id = p_market_id;
  insert into public.activity (user_id, username, kind, market_id, market_title, side, side_label, shares, price, amount)
  values (v_user, private.feed_name(v_user), 'buy', p_market_id, q.title, p_side, coalesce(label, initcap(p_side)), v_shares, q.price, spend);
  perform private.snapshot(v_user, true);
  return jsonb_build_object('price', q.price, 'shares', v_shares, 'amount', spend, 'portfolio', private.portfolio_json(v_user));
end $$;

create or replace function public.sell(p_market_id text, p_side text, p_shares numeric, p_seen_price numeric default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; pos public.positions; q record; qty numeric; sold numeric;
  proceeds numeric; cost_part numeric; pnl numeric; full_sale boolean; label text;
begin
  perform private.rate_limit(v_user, 'trade', 30);
  if p_shares is null or not (p_shares > 0 and p_shares < 1e12) then raise exception 'Enter a number of shares greater than 0.'; end if;
  perform pg_advisory_xact_lock(hashtext('market:' || p_market_id));
  select * into pf from public.portfolios where user_id = v_user for update;
  select * into pos from public.positions where user_id = v_user and market_id = p_market_id and side = p_side for update;
  if pos.user_id is null then raise exception 'You have no shares to sell.'; end if;
  if exists (select 1 from public.resolutions where market_id = p_market_id) then
    raise exception 'This market is resolved. Positions settle automatically.';
  end if;
  qty := round(p_shares, 4);
  if qty > pos.shares then raise exception 'You only own % shares.', pos.shares; end if;
  select * into q from private.quote(p_market_id, p_side);
  if q.err is not null then return jsonb_build_object('error', q.err); end if;
  if private.price_moved(p_seen_price, q.price) is not null then return jsonb_build_object('error', private.price_moved(p_seen_price, q.price)); end if;
  full_sale := pos.shares - qty < 0.0001;
  sold := case when full_sale then pos.shares else qty end;
  -- Proceeds round down, so selling dust can never create money.
  proceeds := trunc(sold * q.price, 2);
  cost_part := case when full_sale then pos.cost_basis else round(sold * pos.cost_basis / pos.shares, 2) end;
  pnl := proceeds - cost_part;
  if not full_sale and proceeds < 0.01 then return jsonb_build_object('error', 'Sale is too small to produce any proceeds.'); end if;

  if full_sale then
    delete from public.positions where user_id = v_user and market_id = p_market_id and side = p_side;
  else
    update public.positions set shares = shares - sold, cost_basis = cost_basis - cost_part, updated_at = now()
    where user_id = v_user and market_id = p_market_id and side = p_side;
  end if;
  update public.portfolios set cash = cash + proceeds, realized_pnl = realized_pnl + pnl, trade_count = trade_count + 1, updated_at = now()
  where user_id = v_user;
  insert into public.history (user_id, run, type, market_id, market_title, side, shares, price, amount, realized_pnl)
  values (v_user, pf.run, 'sell', p_market_id, pos.market_title, p_side, sold, q.price, proceeds, pnl);
  select labels ->> p_side into label from public.markets where id = p_market_id;
  insert into public.activity (user_id, username, kind, market_id, market_title, side, side_label, shares, price, amount)
  values (v_user, private.feed_name(v_user), 'sell', p_market_id, pos.market_title, p_side, coalesce(label, initcap(p_side)), sold, q.price, proceeds);
  perform private.snapshot(v_user, true);
  return jsonb_build_object('price', q.price, 'shares', sold, 'proceeds', proceeds, 'realizedPnl', pnl, 'isFull', full_sale,
    'portfolio', private.portfolio_json(v_user));
end $$;

/** Starts a new run at $50,000: open positions, any blackjack hand and a seat at a table (with its chips) are cleared. */
create or replace function public.reset_balance() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; cleared int; last_reset timestamptz;
begin
  -- Before the portfolio lock: table first, then portfolio, the same order every Tables call uses.
  perform private.poker_evict(v_user);
  select * into pf from public.portfolios where user_id = v_user for update;
  -- A short wait between resets (5 minutes), so resetting can't be hammered in a loop.
  select max(created_at) into last_reset from public.history where user_id = v_user and type = 'reset';
  if last_reset > now() - interval '5 minutes' then
    raise exception 'You can reset again in % minute%.', ceil(extract(epoch from last_reset + interval '5 minutes' - now()) / 60),
      case when ceil(extract(epoch from last_reset + interval '5 minutes' - now()) / 60) = 1 then '' else 's' end;
  end if;
  select count(*) into cleared from public.positions where user_id = v_user;
  delete from public.positions where user_id = v_user;
  delete from public.blackjack_tables where user_id = v_user;
  delete from public.game_states where user_id = v_user;
  insert into public.history (user_id, run, type, amount, note) values (v_user, pf.run, 'reset', 50000,
    format('Balance reset to $50,000.00. %s open position%s cleared.', cleared, case when cleared = 1 then '' else 's' end));
  update public.portfolios set cash = 50000, realized_pnl = 0, run = run + 1, run_start_cash = 50000,
    resets_used = resets_used + 1, updated_at = now() where user_id = v_user;
  delete from public.equity_snapshots where user_id = v_user;
  insert into public.equity_snapshots (user_id, equity) values (v_user, 50000);
  return private.portfolio_json(v_user);
end $$;

/**
 * Deletes the caller's account for good: profile, portfolio, positions,
 * history, game rounds and state, seeds, recovery codes, snapshots and feed
 * entries all go with it (they cascade from auth.users). The player must be
 * signed in and send the word they typed to confirm ("DELETE"), so nothing
 * deletes an account by accident.
 */
drop function if exists public.delete_account(text);
create or replace function public.delete_account(p_confirm text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid();
begin
  perform private.rate_limit(v_user, 'delete', 5);
  if upper(trim(coalesce(p_confirm, ''))) <> 'DELETE' then return jsonb_build_object('error', 'Type DELETE to confirm.'); end if;
  -- Folds any hand in progress, so the table carries on without them.
  perform private.poker_evict(v_user);
  delete from private.rate_limits where user_id = v_user;
  delete from auth.users where id = v_user;
  delete from private.leaderboard_cache;
  return jsonb_build_object('deleted', true);
end $$;

/** Pays out every holder of a resolved market. Returns how many positions settled. */
create or replace function private.settle_market(p_market text, p_outcome text) returns int
language plpgsql volatile set search_path = '' as $$
declare u uuid; pos public.positions; pf public.portfolios; payout numeric; pnl numeric; n int := 0;
begin
  for u in select distinct user_id from public.positions where market_id = p_market order by user_id loop
    select * into pf from public.portfolios where user_id = u for update;
    for pos in select * from public.positions where user_id = u and market_id = p_market for update loop
      payout := case when p_outcome = 'void' then pos.cost_basis when pos.side = p_outcome then trunc(pos.shares, 2) else 0 end;
      pnl := case when p_outcome = 'void' then 0 else payout - pos.cost_basis end;
      -- Capped at the column limit, so one huge balance can't make a settlement fail.
      update public.portfolios set cash = least(cash + payout, 99999999999999.99),
        realized_pnl = greatest(least(realized_pnl + pnl, 99999999999999.99), -99999999999999.99), updated_at = now() where user_id = u;
      insert into public.history (user_id, run, type, market_id, market_title, side, shares, price, amount, realized_pnl, note)
      values (u, pf.run, 'settlement', p_market, pos.market_title, pos.side, pos.shares,
        case when p_outcome = 'void' then round(pos.cost_basis / pos.shares, 4) when pos.side = p_outcome then 1 else 0 end,
        payout, pnl,
        case when p_outcome = 'void' then 'Voided, refunded at cost' when p_outcome = 'yes' then 'Resolved Yes' else 'Resolved No' end);
      delete from public.positions where user_id = u and market_id = pos.market_id and side = pos.side;
      n := n + 1;
    end loop;
    perform private.snapshot(u, true);
  end loop;
  return n;
end $$;

create or replace function private.resolve(p_market text, p_outcome text, p_source text, p_title text) returns int
language plpgsql volatile set search_path = '' as $$
begin
  if p_outcome not in ('yes', 'no', 'void') then return 0; end if;
  -- Waits for any trade in flight on this market (see buy and sell).
  perform pg_advisory_xact_lock(hashtext('market:' || p_market));
  insert into public.resolutions (market_id, outcome, source, title) values (p_market, p_outcome, p_source, coalesce(p_title, ''))
  on conflict (market_id) do nothing;
  if not found then return 0; end if;
  return private.settle_market(p_market, p_outcome);
end $$;

/**
 * Stores one message from the Feedback tab. Guests can send too. Limits keep
 * it from being flooded: 5 an hour per player, 20 an hour from all guests
 * together, 200 an hour and 1,000 a day overall, and no more than 2,000
 * waiting for review. Problems come back as { error }.
 */
create or replace function public.submit_feedback(p_category text, p_message text, p_page text default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := auth.uid(); msg text; pg text;
begin
  if coalesce(p_category, '') not in ('suggestion', 'bug', 'other') then return jsonb_build_object('error', 'Pick a type of feedback.'); end if;
  -- Control, zero-width and text-direction characters out, whitespace tidied.
  msg := regexp_replace(coalesce(p_message, ''), '[\x01-\x09\x0b-\x1f\x7f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]', '', 'g');
  msg := btrim(regexp_replace(msg, '[ \t]+', ' ', 'g'), E' \n');
  if length(msg) < 3 then return jsonb_build_object('error', 'Write a little more first.'); end if;
  if length(msg) > 1000 then return jsonb_build_object('error', 'Keep it under 1,000 characters.'); end if;
  pg := left(regexp_replace(coalesce(p_page, ''), '[^A-Za-z0-9/_.?=&%#-]', '', 'g'), 200);
  -- One submission checks the limits at a time, so a burst of parallel calls can't slip past them.
  perform pg_advisory_xact_lock(hashtext('submit_feedback'));
  if (select count(*) from public.feedback where status = 'new') >= 2000
    or (select count(*) from public.feedback where created_at > now() - interval '1 day') >= 1000
    or (select count(*) from public.feedback where created_at > now() - interval '1 hour') >= 200
    or (v_user is not null and (select count(*) from public.feedback where user_id = v_user and created_at > now() - interval '1 hour') >= 5)
    or (v_user is null and (select count(*) from public.feedback where user_id is null and created_at > now() - interval '1 hour') >= 20) then
    return jsonb_build_object('error', 'Thanks! That''s a lot of feedback for now. Try again in an hour.');
  end if;
  insert into public.feedback (user_id, username, category, message, page)
  values (v_user, case when private.is_guest(v_user) then null else private.username_of(v_user) end, p_category, msg, nullif(pg, ''));
  return jsonb_build_object('ok', true);
end $$;

/** Lets a player trigger an immediate check of a Polymarket market they hold (settles it if closed). */
create or replace function public.check_market(p_market_id text) returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); live jsonb;
begin
  if exists (select 1 from public.resolutions where market_id = p_market_id) then return true; end if;
  if p_market_id !~ '^\d+$' or not exists (select 1 from public.positions where market_id = p_market_id) then return false; end if;
  perform private.rate_limit(v_user, 'check', 20);
  live := private.live_gamma(p_market_id);
  if live is null or live ->> 'outcome' is null then return false; end if;
  perform private.resolve(p_market_id, live ->> 'outcome', 'api', live ->> 'title');
  return true;
end $$;

-- ---------------------------------------------------------------------------
-- Games: shared money handling
-- ---------------------------------------------------------------------------

/**
 * Logs a finished round and keeps the running totals, without moving money.
 * Tables calls it directly: a hand's winnings stay in the player's stack at
 * the table and only reach cash when they leave.
 */
create or replace function private.game_record(p_user uuid, p_run int, p_game text, p_staked numeric, p_returned numeric, p_detail text) returns void
language plpgsql volatile set search_path = '' as $$
begin
  insert into public.game_rounds (user_id, run, game, staked, returned, net, detail)
  values (p_user, p_run, p_game, p_staked, p_returned, p_returned - p_staked, p_detail);
  insert into private.game_totals as t (user_id, run, game, rounds, wagered, net, best)
  values (p_user, p_run, p_game, 1, p_staked, p_returned - p_staked, p_returned - p_staked)
  on conflict (user_id, run, game) do update set
    rounds = t.rounds + 1, wagered = t.wagered + excluded.wagered, net = t.net + excluded.net, best = greatest(t.best, excluded.best);
end $$;

/** Pays a finished round into cash and logs it. */
create or replace function private.game_round(p_user uuid, p_run int, p_game text, p_staked numeric, p_returned numeric, p_detail text) returns void
language plpgsql volatile set search_path = '' as $$
begin
  update public.portfolios set cash = cash + p_returned, updated_at = now() where user_id = p_user;
  perform private.game_record(p_user, p_run, p_game, p_staked, p_returned, p_detail);
end $$;

create or replace function private.game_activity(p_user uuid, p_game text, p_staked numeric, p_net numeric, p_detail text) returns void
language sql volatile set search_path = '' as $$
  insert into public.activity (user_id, username, kind, game, amount, net, detail)
  values (p_user, private.feed_name(p_user), 'game', p_game, p_staked, p_net, p_detail)
$$;

-- ---------------------------------------------------------------------------
-- Roulette (European, single zero)
-- ---------------------------------------------------------------------------

create or replace function private.roulette_color(n int) returns text
language sql immutable set search_path = '' as $$
  select case when n = 0 then 'Green' when n = any (array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]) then 'Red' else 'Black' end
$$;

/** Numbers covered by a bet key ("split:17-20", "red:1-3-...") after checking it is a real bet. */
create or replace function private.roulette_bet(p_key text, out bet_type text, out nums int[], out odds int)
language plpgsql immutable set search_path = '' as $$
declare parts text[]; n int; c int; k int;
begin
  parts := string_to_array(p_key, ':');
  if array_length(parts, 1) <> 2 or parts[2] !~ '^\d{1,2}(-\d{1,2})*$' then raise exception 'Invalid bet.'; end if;
  bet_type := parts[1];
  nums := string_to_array(parts[2], '-')::int[];
  if exists (select 1 from unnest(nums) x where x < 0 or x > 36) then raise exception 'Invalid bet.'; end if;
  if nums <> (select array_agg(x order by x) from (select distinct unnest(nums) x) d) then raise exception 'Invalid bet.'; end if;
  n := array_length(nums, 1);
  c := nums[1];
  if bet_type = 'straight' and n = 1 then odds := 35;
  elsif bet_type = 'split' and n = 2 and (
      (c = 0 and nums[2] between 1 and 3) or
      (c >= 1 and nums[2] = c + 3) or
      (c >= 1 and nums[2] = c + 1 and c % 3 <> 0)) then odds := 17;
  elsif bet_type = 'street' and n = 3 and c % 3 = 1 and nums = array[c, c + 1, c + 2] then odds := 11;
  elsif bet_type = 'corner' and n = 4 and c >= 1 and c % 3 <> 0 and c <= 32 and nums = array[c, c + 1, c + 3, c + 4] then odds := 8;
  elsif bet_type = 'sixline' and n = 6 and c % 3 = 1 and c <= 31 and nums = (select array_agg(x) from generate_series(c, c + 5) x) then odds := 5;
  elsif bet_type = 'dozen' and n = 12 and c in (1, 13, 25) and nums = (select array_agg(x) from generate_series(c, c + 11) x) then odds := 2;
  elsif bet_type = 'column' and n = 12 and c between 1 and 3 and nums = (select array_agg(x) from generate_series(c, 36, 3) x) then odds := 2;
  elsif bet_type in ('red', 'black') and n = 18 and nums = (select array_agg(x order by x) from generate_series(1, 36) x where private.roulette_color(x) = initcap(bet_type)) then odds := 1;
  elsif bet_type = 'odd' and n = 18 and nums = (select array_agg(x) from generate_series(1, 35, 2) x) then odds := 1;
  elsif bet_type = 'even' and n = 18 and nums = (select array_agg(x) from generate_series(2, 36, 2) x) then odds := 1;
  elsif bet_type = 'low' and n = 18 and nums = (select array_agg(x) from generate_series(1, 18) x) then odds := 1;
  elsif bet_type = 'high' and n = 18 and nums = (select array_agg(x) from generate_series(19, 36) x) then odds := 1;
  else raise exception 'Invalid bet.';
  end if;
end $$;

/** p_bets: [{ "key": "straight:17", "amount": 25 }, ...]. */
create or replace function public.play_roulette(p_bets jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; b jsonb; amt numeric; staked numeric := 0; returned numeric := 0;
  v_result int; bet record; nbets int;
begin
  perform private.rate_limit(v_user, 'game', 40);
  if jsonb_typeof(p_bets) <> 'array' then raise exception 'Invalid bets.'; end if;
  nbets := jsonb_array_length(p_bets);
  if nbets < 1 or nbets > 200 then raise exception 'Place between 1 and 200 bets.'; end if;
  select * into pf from public.portfolios where user_id = v_user for update;
  v_result := private.rand_int(37);
  for b in select * from jsonb_array_elements(p_bets) loop
    amt := round((b ->> 'amount')::numeric, 2);
    if amt is null or not (amt >= 1 and amt <= 1e9) then raise exception 'Each bet must be at least $1.'; end if;
    select * into bet from private.roulette_bet(b ->> 'key');
    staked := staked + amt;
    if v_result = any (bet.nums) then returned := returned + amt * (bet.odds + 1); end if;
  end loop;
  if staked > pf.cash then raise exception 'Not enough cash for these bets.'; end if;
  update public.portfolios set cash = cash - staked where user_id = v_user;
  perform private.game_round(v_user, pf.run, 'roulette', staked, returned,
    format('%s %s · %s bet%s', v_result, private.roulette_color(v_result), nbets, case when nbets = 1 then '' else 's' end));
  perform private.game_activity(v_user, 'roulette', staked, returned - staked, format('landed %s %s', v_result, private.roulette_color(v_result)));
  return jsonb_build_object('result', v_result, 'staked', staked, 'returned', returned, 'portfolio', private.portfolio_json(v_user));
end $$;

-- ---------------------------------------------------------------------------
-- Plinko
-- ---------------------------------------------------------------------------

create or replace function private.plinko_table(p_rows int, p_risk text) returns numeric[]
language sql immutable set search_path = '' as $$
  select array_agg(x::numeric order by ord)
  from jsonb_array_elements_text('{
    "8":  {"low": [5.6,2.1,1.1,1,0.5,1,1.1,2.1,5.6], "medium": [13,3,1.3,0.7,0.4,0.7,1.3,3,13], "high": [29,4,1.5,0.3,0.2,0.3,1.5,4,29]},
    "12": {"low": [10,3,1.6,1.4,1.1,1,0.5,1,1.1,1.4,1.6,3,10], "medium": [33,11,4,2,1.1,0.6,0.3,0.6,1.1,2,4,11,33], "high": [170,24,8.1,2,0.7,0.2,0.2,0.2,0.7,2,8.1,24,170]},
    "16": {"low": [16,9,2,1.4,1.4,1.2,1.1,1,0.5,1,1.1,1.2,1.4,1.4,2,9,16], "medium": [110,41,10,5,3,1.5,1,0.5,0.3,0.5,1,1.5,3,5,10,41,110], "high": [1000,130,26,9,4,2,0.2,0.2,0.2,0.2,0.2,2,4,9,26,130,1000]}
  }'::jsonb -> p_rows::text -> p_risk) with ordinality as t(x, ord)
$$;

create or replace function public.play_plinko(p_amount numeric, p_rows int, p_risk text, p_balls int) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; amt numeric; mults numeric[]; total numeric; returned numeric := 0;
  i int; r int; k int; path int[]; m numeric; ret numeric; balls jsonb := '[]';
begin
  perform private.rate_limit(v_user, 'game', 40);
  if p_rows not in (8, 12, 16) or p_risk not in ('low', 'medium', 'high') then raise exception 'Pick 8, 12 or 16 rows and a risk level.'; end if;
  if p_balls is null or p_balls < 1 or p_balls > 25 then raise exception 'Drop between 1 and 25 balls.'; end if;
  amt := round(p_amount, 2);
  if amt is null or not (amt >= 0.1 and amt <= 1e9) then raise exception 'Enter a bet of at least $0.10.'; end if;
  select * into pf from public.portfolios where user_id = v_user for update;
  total := amt * p_balls;
  if total > pf.cash then raise exception 'Not enough cash for % balls at $% each.', p_balls, amt; end if;
  update public.portfolios set cash = cash - total where user_id = v_user;
  mults := private.plinko_table(p_rows, p_risk);
  for i in 1..p_balls loop
    path := '{}';
    for r in 1..p_rows loop path := path || private.rand_int(2); end loop;
    k := (select sum(x) from unnest(path) x);
    m := mults[k + 1];
    ret := trunc(amt * m, 2);
    returned := returned + ret;
    perform private.game_round(v_user, pf.run, 'plinko', amt, ret, format('%s× · %s rows, %s risk', m, p_rows, p_risk));
    balls := balls || jsonb_build_object('path', to_jsonb(path), 'bucket', k, 'multiplier', m, 'returned', ret);
  end loop;
  perform private.game_activity(v_user, 'plinko', total, returned - total,
    format('dropped %s ball%s (%s rows, %s risk)', p_balls, case when p_balls = 1 then '' else 's' end, p_rows, p_risk));
  return jsonb_build_object('balls', balls, 'staked', total, 'returned', returned, 'portfolio', private.portfolio_json(v_user));
end $$;

-- ---------------------------------------------------------------------------
-- Blackjack: six decks, dealer stands on soft 17, peeks under an ace or ten,
-- blackjack pays 3:2, insurance 2:1, double on any two, split up to 4 hands.
-- The state (shoe included) stays on the server; players only see bj_view.
-- ---------------------------------------------------------------------------

create or replace function private.bj_rank_value(p_rank text) returns int
language sql immutable set search_path = '' as $$
  select case when p_rank = 'A' then 11 when p_rank in ('J', 'Q', 'K', '10') then 10 else p_rank::int end
$$;

create or replace function private.bj_value(p_cards jsonb, out total int, out soft boolean)
language plpgsql immutable set search_path = '' as $$
declare c jsonb; aces int := 0;
begin
  total := 0;
  for c in select * from jsonb_array_elements(coalesce(p_cards, '[]')) loop
    total := total + private.bj_rank_value(c ->> 'rank');
    if c ->> 'rank' = 'A' then aces := aces + 1; end if;
  end loop;
  while total > 21 and aces > 0 loop
    total := total - 10;
    aces := aces - 1;
  end loop;
  soft := aces > 0;
end $$;

create or replace function private.bj_is_blackjack(p_cards jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_array_length(coalesce(p_cards, '[]')) = 2 and (private.bj_value(p_cards)).total = 21
$$;

create or replace function private.bj_new_shoe() returns jsonb
language plpgsql volatile set search_path = '' as $$
declare cards text[] := '{}'; d int; su text; r text; i int; j int; tmp text;
begin
  for d in 0..5 loop
    foreach su in array array['♠', '♥', '♦', '♣'] loop
      foreach r in array array['A', '2', '3', '4', '5', '6', '7', '8', '9', '10', 'J', 'Q', 'K'] loop
        cards := cards || (d || '|' || r || '|' || su);
      end loop;
    end loop;
  end loop;
  for i in reverse array_length(cards, 1)..2 loop
    j := private.rand_int(i) + 1;
    tmp := cards[i];
    cards[i] := cards[j];
    cards[j] := tmp;
  end loop;
  return (
    select jsonb_agg(jsonb_build_object('rank', split_part(c, '|', 2), 'suit', split_part(c, '|', 3),
      'id', split_part(c, '|', 1) || split_part(c, '|', 2) || split_part(c, '|', 3)) order by ord)
    from unnest(cards) with ordinality as u(c, ord)
  );
end $$;

/** Moves the top card of the shoe to the dealer (p_target = -1) or a hand. */
create or replace function private.bj_draw(s jsonb, p_target int) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare shoe jsonb := s -> 'shoe'; card jsonb;
begin
  if shoe is null or jsonb_array_length(shoe) = 0 then shoe := private.bj_new_shoe(); end if;
  card := shoe -> 0;
  s := jsonb_set(s, '{shoe}', shoe - 0);
  if p_target < 0 then
    return jsonb_set(s, '{dealer}', (s -> 'dealer') || jsonb_build_array(card));
  end if;
  return jsonb_set(s, array['hands', p_target::text, 'cards'], (s -> 'hands' -> p_target -> 'cards') || jsonb_build_array(card));
end $$;

create or replace function private.bj_hand(p_cards jsonb, p_bet numeric, p_from_split boolean, p_split_aces boolean) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('cards', p_cards, 'bet', p_bet, 'fromSplit', p_from_split, 'splitAces', p_split_aces, 'doubled', false, 'done', false)
$$;

create or replace function private.bj_set_done(s jsonb, p_index int) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_set(s, array['hands', p_index::text, 'done'], 'true')
$$;

create or replace function private.bj_settle(s jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare dealer_total int := (private.bj_value(s -> 'dealer')).total; dealer_bj boolean := private.bj_is_blackjack(s -> 'dealer');
  h jsonb; hands jsonb := '[]'; v int; is_natural boolean; outcome text; back numeric; returned numeric := 0; staked numeric := 0;
  ins numeric := coalesce((s ->> 'insurance')::numeric, 0); ins_back numeric;
begin
  for h in select * from jsonb_array_elements(s -> 'hands') loop
    v := (private.bj_value(h -> 'cards')).total;
    is_natural := private.bj_is_blackjack(h -> 'cards') and not (h ->> 'fromSplit')::boolean;
    outcome := case
      when is_natural and not dealer_bj then 'blackjack'
      when is_natural and dealer_bj then 'push'
      when dealer_bj then 'lose'
      when v > 21 then 'bust'
      when dealer_total > 21 or v > dealer_total then 'win'
      when v = dealer_total then 'push'
      else 'lose' end;
    back := trunc(case outcome when 'blackjack' then (h ->> 'bet')::numeric * 2.5 when 'win' then (h ->> 'bet')::numeric * 2
      when 'push' then (h ->> 'bet')::numeric else 0 end, 2);
    returned := returned + back;
    staked := staked + (h ->> 'bet')::numeric;
    hands := hands || jsonb_build_array(h || jsonb_build_object('outcome', outcome, 'returned', back));
  end loop;
  ins_back := case when dealer_bj and ins > 0 then ins * 3 else 0 end;
  return s || jsonb_build_object('phase', 'done', 'hands', hands, 'result', jsonb_build_object(
    'returned', returned + ins_back, 'staked', staked + ins, 'insuranceBack', ins_back, 'dealerBlackjack', dealer_bj));
end $$;

create or replace function private.bj_after_peek(s jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare up text := s -> 'dealer' -> 0 ->> 'rank';
begin
  if (up = 'A' or private.bj_rank_value(up) = 10) and private.bj_is_blackjack(s -> 'dealer') then return private.bj_settle(s); end if;
  if private.bj_is_blackjack(s -> 'hands' -> 0 -> 'cards') then return private.bj_settle(s); end if;
  return jsonb_set(s, '{phase}', '"player"');
end $$;

create or replace function private.bj_dealer_play(s jsonb) returns jsonb
language plpgsql volatile set search_path = '' as $$
begin
  if exists (select 1 from jsonb_array_elements(s -> 'hands') h where (private.bj_value(h -> 'cards')).total <= 21) then
    while (private.bj_value(s -> 'dealer')).total < 17 loop
      s := private.bj_draw(s, -1);
    end loop;
  end if;
  return private.bj_settle(s);
end $$;

/** Moves to the next unfinished hand (dealing split hands their second card), or plays the dealer. */
create or replace function private.bj_advance(s jsonb) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare i int := (s ->> 'active')::int; n int := jsonb_array_length(s -> 'hands');
begin
  loop
    while i < n and (s -> 'hands' -> i ->> 'done')::boolean loop i := i + 1; end loop;
    if i >= n then
      return private.bj_dealer_play(jsonb_set(s, '{active}', to_jsonb(n - 1)));
    end if;
    if jsonb_array_length(s -> 'hands' -> i -> 'cards') = 1 then
      s := private.bj_draw(jsonb_set(s, '{active}', to_jsonb(i)), i);
      if (s -> 'hands' -> i ->> 'splitAces')::boolean or (private.bj_value(s -> 'hands' -> i -> 'cards')).total = 21 then
        s := private.bj_set_done(s, i);
        continue;
      end if;
    end if;
    return jsonb_set(jsonb_set(s, '{active}', to_jsonb(i)), '{phase}', '"player"');
  end loop;
end $$;

create or replace function private.bj_can_double(s jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select s ->> 'phase' = 'player'
    and jsonb_array_length(s -> 'hands' -> (s ->> 'active')::int -> 'cards') = 2
    and not (s -> 'hands' -> (s ->> 'active')::int ->> 'splitAces')::boolean
$$;

create or replace function private.bj_can_split(s jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select s ->> 'phase' = 'player'
    and jsonb_array_length(s -> 'hands' -> (s ->> 'active')::int -> 'cards') = 2
    and private.bj_rank_value(s -> 'hands' -> (s ->> 'active')::int -> 'cards' -> 0 ->> 'rank')
      = private.bj_rank_value(s -> 'hands' -> (s ->> 'active')::int -> 'cards' -> 1 ->> 'rank')
    and jsonb_array_length(s -> 'hands') < 4
$$;

/** What the player may see: no shoe, and the dealer's hole card stays face down until the hand ends. */
create or replace function private.bj_view(s jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object(
    'phase', s ->> 'phase',
    'dealer', case when s ->> 'phase' in ('insurance', 'player')
      then jsonb_build_array(s -> 'dealer' -> 0, jsonb_build_object('rank', '', 'suit', '', 'id', 'hole', 'hidden', true))
      else coalesce(s -> 'dealer', '[]') end,
    'hands', coalesce(s -> 'hands', '[]'),
    'active', coalesce((s ->> 'active')::int, 0),
    'insurance', coalesce((s ->> 'insurance')::numeric, 0),
    'result', s -> 'result',
    'reshuffled', coalesce((s ->> 'reshuffled')::boolean, false),
    'shoeLeft', round(jsonb_array_length(coalesce(s -> 'shoe', '[]')) / 312.0, 3),
    'canDouble', coalesce(private.bj_can_double(s), false),
    'canSplit', coalesce(private.bj_can_split(s), false))
$$;

create or replace function private.bj_finish(p_user uuid, p_run int, s jsonb) returns void
language plpgsql volatile set search_path = '' as $$
declare detail text; dealer text;
begin
  if s ->> 'phase' <> 'done' then return; end if;
  -- The game goes by "21" on the site, so a blackjack reads as a natural 21.
  dealer := case when (s -> 'result' ->> 'dealerBlackjack')::boolean then 'natural 21' else (private.bj_value(s -> 'dealer')).total::text end;
  select string_agg(case h ->> 'outcome' when 'blackjack' then 'Natural 21' when 'win' then 'Win' when 'push' then 'Push'
      when 'bust' then 'Bust' else 'Lose' end, ', ' order by ord)
    into detail from jsonb_array_elements(s -> 'hands') with ordinality as t(h, ord);
  detail := detail || ' vs dealer ' || dealer;
  perform private.game_round(p_user, p_run, 'blackjack', (s -> 'result' ->> 'staked')::numeric, (s -> 'result' ->> 'returned')::numeric, detail);
  perform private.game_activity(p_user, 'blackjack', (s -> 'result' ->> 'staked')::numeric,
    (s -> 'result' ->> 'returned')::numeric - (s -> 'result' ->> 'staked')::numeric, lower(detail));
end $$;

create or replace function private.bj_load(p_user uuid) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare s jsonb; shoe jsonb;
begin
  select state into s from public.blackjack_tables where user_id = p_user for update;
  if s is null then
    shoe := private.bj_new_shoe();
    s := jsonb_build_object('phase', 'betting', 'shoe', shoe, 'cut', 156, 'dealer', '[]'::jsonb, 'hands', '[]'::jsonb,
      'active', 0, 'insurance', 0, 'result', null);
    insert into public.blackjack_tables (user_id, state) values (p_user, s);
  end if;
  return s;
end $$;

create or replace function private.bj_save(p_user uuid, s jsonb) returns void
language sql volatile set search_path = '' as $$
  update public.blackjack_tables set state = s, updated_at = now() where user_id = p_user
$$;

create or replace function public.blackjack_state() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid();
begin
  return private.bj_view(private.bj_load(v_user));
end $$;

create or replace function public.blackjack_deal(p_bet numeric) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; s jsonb; bet numeric := round(p_bet, 2); shoe jsonb;
begin
  perform private.rate_limit(v_user, 'game', 40);
  if bet is null or not (bet >= 1 and bet <= 1e9) then raise exception 'Bets start at $1.'; end if;
  select * into pf from public.portfolios where user_id = v_user for update;
  s := private.bj_load(v_user);
  if s ->> 'phase' in ('insurance', 'player') then raise exception 'Finish the current hand first.'; end if;
  if bet > pf.cash then raise exception 'Not enough cash for this bet.'; end if;
  update public.portfolios set cash = cash - bet where user_id = v_user;
  s := s || jsonb_build_object('dealer', '[]'::jsonb, 'hands', jsonb_build_array(private.bj_hand('[]', bet, false, false)),
    'active', 0, 'insurance', 0, 'result', null, 'reshuffled', false, 'run', pf.run);
  if jsonb_array_length(s -> 'shoe') <= (s ->> 'cut')::int then
    shoe := private.bj_new_shoe();
    s := s || jsonb_build_object('shoe', shoe, 'cut', 156, 'reshuffled', true);
  end if;
  s := private.bj_draw(s, 0);
  s := private.bj_draw(s, -1);
  s := private.bj_draw(s, 0);
  s := private.bj_draw(s, -1);
  if s -> 'dealer' -> 0 ->> 'rank' = 'A' then
    s := jsonb_set(s, '{phase}', '"insurance"');
  else
    s := private.bj_after_peek(s);
  end if;
  perform private.bj_finish(v_user, pf.run, s);
  perform private.bj_save(v_user, s);
  return jsonb_build_object('table', private.bj_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

/** p_action: hit, stand, double, split, insurance or no_insurance. */
create or replace function public.blackjack_act(p_action text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; s jsonb; i int; h jsonb; cost numeric := 0; aces boolean; hands jsonb; k int;
begin
  perform private.rate_limit(v_user, 'game', 120);
  select * into pf from public.portfolios where user_id = v_user for update;
  s := private.bj_load(v_user);
  i := (s ->> 'active')::int;
  h := s -> 'hands' -> i;

  if p_action in ('insurance', 'no_insurance') then
    if s ->> 'phase' <> 'insurance' then raise exception 'Insurance is not on offer right now.'; end if;
    if p_action = 'insurance' then cost := round((s -> 'hands' -> 0 ->> 'bet')::numeric / 2, 2); end if;
    if cost > pf.cash then raise exception 'Not enough cash for insurance.'; end if;
    s := private.bj_after_peek(jsonb_set(s, '{insurance}', to_jsonb(cost)));
  elsif s ->> 'phase' <> 'player' then
    raise exception 'There is no hand to play. Deal first.';
  elsif p_action = 'hit' then
    s := private.bj_draw(s, i);
    if (private.bj_value(s -> 'hands' -> i -> 'cards')).total >= 21 then s := private.bj_set_done(s, i); end if;
    s := private.bj_advance(s);
  elsif p_action = 'stand' then
    s := private.bj_advance(private.bj_set_done(s, i));
  elsif p_action = 'double' then
    if not private.bj_can_double(s) then raise exception 'You can only double on your first two cards.'; end if;
    cost := (h ->> 'bet')::numeric;
    if cost > pf.cash then raise exception 'Not enough cash to double.'; end if;
    s := jsonb_set(s, array['hands', i::text], h || jsonb_build_object('bet', cost * 2, 'doubled', true));
    s := private.bj_draw(s, i);
    s := private.bj_advance(private.bj_set_done(s, i));
  elsif p_action = 'split' then
    if not private.bj_can_split(s) then raise exception 'Only pairs can be split, up to four hands.'; end if;
    cost := (h ->> 'bet')::numeric;
    if cost > pf.cash then raise exception 'Not enough cash to split.'; end if;
    aces := h -> 'cards' -> 0 ->> 'rank' = 'A';
    hands := '[]';
    for k in 0..jsonb_array_length(s -> 'hands') - 1 loop
      if k = i then
        hands := hands || jsonb_build_array(
          private.bj_hand(jsonb_build_array(h -> 'cards' -> 0), cost, true, aces),
          private.bj_hand(jsonb_build_array(h -> 'cards' -> 1), cost, true, aces));
      else
        hands := hands || jsonb_build_array(s -> 'hands' -> k);
      end if;
    end loop;
    s := private.bj_draw(jsonb_set(s, '{hands}', hands), i);
    if aces or (private.bj_value(s -> 'hands' -> i -> 'cards')).total = 21 then s := private.bj_set_done(s, i); end if;
    s := private.bj_advance(s);
  else
    raise exception 'Unknown move.';
  end if;

  if cost > 0 then update public.portfolios set cash = cash - cost where user_id = v_user; end if;
  perform private.bj_finish(v_user, coalesce((s ->> 'run')::int, pf.run), s);
  perform private.bj_save(v_user, s);
  return jsonb_build_object('table', private.bj_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

-- ---------------------------------------------------------------------------
-- Leaderboard
-- ---------------------------------------------------------------------------

/** Every player with overall, market and game figures for their current run. */
create or replace function private.leaderboard_rows() returns jsonb
language sql stable set search_path = '' as $$
  with pf as (
    -- Guests play but don't rank.
    select p.*, pr.username::text as username from public.portfolios p join public.profiles pr on pr.id = p.user_id
    where not private.is_guest(p.user_id)
  ),
  pos as (
    select user_id, sum(private.position_value(p)) as value, sum(p.cost_basis) as cost, count(*) as open
    from public.positions p group by user_id
  ),
  closed as (
    select h.user_id, count(*) filter (where h.realized_pnl > 0) as wins, count(*) as total
    from public.history h join public.portfolios p on p.user_id = h.user_id and h.run = p.run
    where h.type in ('sell', 'settlement') group by h.user_id
  ),
  games as (
    select g.user_id, sum(g.rounds) as rounds, sum(g.net) as net, sum(g.wagered) as wagered, greatest(max(g.best), 0) as best
    from private.game_totals g join public.portfolios p on p.user_id = g.user_id and g.run = p.run group by g.user_id
  ),
  fav as (
    select distinct on (g.user_id) g.user_id, g.game
    from private.game_totals g join public.portfolios p on p.user_id = g.user_id and g.run = p.run
    where g.rounds > 0 order by g.user_id, g.rounds desc
  ),
  -- Chips sitting at a table count toward net worth, like cash.
  chips as (
    select s.user_id, s.stack + s.committed as chips from private.poker_seats s join public.portfolios p on p.user_id = s.user_id and p.run = s.run
  ),
  rows as (
    select pf.*, coalesce(pos.value, 0) as value, coalesce(pos.cost, 0) as cost, coalesce(pos.open, 0) as open,
      pf.cash + coalesce(pos.value, 0) + coalesce(chips.chips, 0) as net_worth, closed.wins, closed.total,
      coalesce(games.rounds, 0) as g_rounds, coalesce(games.net, 0) as g_net, coalesce(games.wagered, 0) as g_wagered,
      coalesce(games.best, 0) as g_best, fav.game as fav
    from pf left join pos using (user_id) left join closed using (user_id) left join games using (user_id) left join fav using (user_id)
      left join chips using (user_id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', user_id, 'name', username, 'sim', false,
    'netWorth', net_worth,
    'pnl', net_worth - run_start_cash,
    'pnlPct', case when run_start_cash > 0 then round((net_worth - run_start_cash) * 100 / run_start_cash, 4) else 0 end,
    'marketPnl', net_worth - run_start_cash - g_net,
    'realized', realized_pnl,
    'unrealized', value - cost,
    'trades', trade_count,
    'winRate', case when total > 0 then round(wins * 100.0 / total, 2) end,
    'openPositions', open,
    'games', jsonb_build_object('net', g_net, 'rounds', g_rounds, 'wagered', g_wagered, 'best', g_best, 'favorite', fav)
  ) order by net_worth desc), '[]')
  from (select * from rows order by net_worth desc limit 500) r
$$;

/** Every player's standings. Anyone can call it, so the answer is reused for 10 seconds. */
create or replace function public.leaderboard() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare c private.leaderboard_cache;
begin
  select * into c from private.leaderboard_cache where id = 1;
  if c.at > clock_timestamp() - interval '10 seconds' then return c.data; end if;
  -- One caller rebuilds it; the rest get the last copy meanwhile.
  if c.data is not null and not pg_try_advisory_xact_lock(hashtext('leaderboard')) then return c.data; end if;
  c.data := private.leaderboard_rows();
  insert into private.leaderboard_cache (id, data, at) values (1, c.data, clock_timestamp())
  on conflict (id) do update set data = excluded.data, at = excluded.at;
  return c.data;
end $$;

-- ---------------------------------------------------------------------------
-- Sync job entry points (service role only)
-- ---------------------------------------------------------------------------

/** Upserts markets ({ id, title, category, league, labels, yesPrice, noPrice, endDate, gameStart, closed }). */
create or replace function public.sync_markets(p_markets jsonb) returns int
language plpgsql volatile security definer set search_path = '' as $$
declare m jsonb; n int := 0; y numeric; no_ numeric;
begin
  for m in select * from jsonb_array_elements(p_markets) loop
    continue when coalesce(m ->> 'id', '') !~ '^[A-Za-z0-9_.~:-]+$' or length(m ->> 'id') > 400 or coalesce(m ->> 'title', '') = '';
    -- A sane market is a few KB; anything far bigger is a bad feed, not a market.
    continue when length(m::text) > 20000 or length(coalesce(m -> 'labels' ->> 'yes', '')) > 100 or length(coalesce(m -> 'labels' ->> 'no', '')) > 100;
    y := (m ->> 'yesPrice')::numeric;
    no_ := (m ->> 'noPrice')::numeric;
    continue when y is null or no_ is null or y < 0 or y > 1 or no_ < 0 or no_ > 1;
    insert into public.markets (id, title, category, league, labels, yes_price, no_price, end_date, game_start, closed, data, updated_at)
    values (m ->> 'id', left(m ->> 'title', 300), coalesce(m ->> 'category', 'sports'), m ->> 'league',
      coalesce(m -> 'labels', '{"yes":"Yes","no":"No"}'), round(y, 4), round(no_, 4),
      (m ->> 'endDate')::timestamptz, (m ->> 'gameStart')::timestamptz, coalesce((m ->> 'closed')::boolean, false), m, now())
    on conflict (id) do update set title = excluded.title, category = excluded.category, league = excluded.league,
      labels = excluded.labels, yes_price = excluded.yes_price, no_price = excluded.no_price, end_date = excluded.end_date,
      game_start = excluded.game_start, closed = excluded.closed, data = excluded.data, updated_at = now();
    n := n + 1;
  end loop;
  delete from public.markets mk where mk.end_date < now() - interval '7 days'
    and not exists (select 1 from public.positions p where p.market_id = mk.id);
  delete from public.activity where created_at < now() - interval '30 days';
  -- Every game round posts to the feed, so game rows are kept for two days only.
  delete from public.activity where kind = 'game' and created_at < now() - interval '2 days';
  return n;
end $$;

/** p_results: { "<market id>": { "outcome": "yes" | "no" | "void", "source": "...", "title": "..." } }. */
create or replace function public.sync_resolutions(p_results jsonb) returns int
language plpgsql volatile security definer set search_path = '' as $$
declare k text; v jsonb; n int := 0;
begin
  for k, v in select * from jsonb_each(p_results) loop
    -- One bad market must not roll back every other settlement in the run.
    begin
      n := n + private.resolve(k, coalesce(v ->> 'outcome', v #>> '{}'), coalesce(v ->> 'source', 'sync'), v ->> 'title');
    exception when others then
      raise warning 'settling % failed: %', k, sqlerrm;
    end;
  end loop;
  return n;
end $$;

/** Market ids someone holds and that have no result yet, so the sync job knows what to settle. */
create or replace function public.held_markets() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(distinct p.market_id), '[]') from public.positions p
  where not exists (select 1 from public.resolutions r where r.market_id = p.market_id)
$$;

create or replace function public.sync_snapshots() returns int
language plpgsql volatile security definer set search_path = '' as $$
declare u uuid; n int := 0;
begin
  -- Crash rounds left running by players who went away.
  for u in select user_id from public.game_states
      where game = 'crash' and state ->> 'phase' = 'playing' and (state ->> 'ends')::bigint <= private.now_ms() loop
    perform 1 from public.portfolios where user_id = u for update;
    perform private.crash_settle(u);
  end loop;
  -- Guests nobody has played as for 30 days (a day, if they never played) go, with all their data.
  delete from auth.users u using public.portfolios p
  where p.user_id = u.id and u.is_anonymous and u.created_at < now() - interval '1 day'
    and p.updated_at < now() - case when p.trade_count = 0 and not exists (select 1 from public.game_rounds g where g.user_id = u.id)
      then interval '1 day' else interval '30 days' end;
  for u in select user_id from public.portfolios loop
    perform private.snapshot(u);
    n := n + 1;
  end loop;
  delete from private.rate_limits where window_start < now() - interval '1 hour';
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Provably fair games: Dice, Mines, Chicken Cross
--
-- Every result comes from HMAC_SHA256(server seed, "<client seed>:<nonce>:<cursor>"),
-- 4 bytes per float, exactly like src/games/fair.js. Players see the SHA-256
-- of the server seed before betting. Both seeds are set by the server and
-- can't be changed by players; every 100 bets the pair is retired, its server
-- seed revealed, and a fresh pair starts.
-- ---------------------------------------------------------------------------

create or replace function private.fair_floats(p_server text, p_client text, p_nonce int, p_count int) returns float8[]
language plpgsql immutable set search_path = '' as $$
declare res float8[] := '{}'; cur int := 0; b bytea; i int;
begin
  while coalesce(array_length(res, 1), 0) < p_count loop
    b := extensions.hmac(convert_to(p_client || ':' || p_nonce || ':' || cur, 'UTF8'), convert_to(p_server, 'UTF8'), 'sha256');
    i := 0;
    while i < 32 and coalesce(array_length(res, 1), 0) < p_count loop
      res := res || (get_byte(b, i) / 256::float8 + get_byte(b, i + 1) / 65536::float8
        + get_byte(b, i + 2) / 16777216::float8 + get_byte(b, i + 3) / 4294967296::float8);
      i := i + 4;
    end loop;
    cur := cur + 1;
  end loop;
  return res;
end $$;

create or replace function private.fair_load(p_user uuid) returns public.fair_seeds
language plpgsql volatile set search_path = '' as $$
declare r public.fair_seeds;
begin
  select * into r from public.fair_seeds where user_id = p_user for update;
  if r.user_id is null then
    insert into public.fair_seeds (user_id, server_seed, client_seed)
    values (p_user, encode(extensions.gen_random_bytes(32), 'hex'), encode(extensions.gen_random_bytes(8), 'hex'))
    returning * into r;
  end if;
  return r;
end $$;

/**
 * Seeds for the next bet; the nonce then moves on. After 100 bets the pair is
 * retired first, but never while a Mines or Chicken Cross round is open: its
 * outcome comes from the current server seed, so revealing it would give the
 * round away. Callers hold the player's portfolio lock.
 */
create or replace function private.fair_next(p_user uuid, out server_seed text, out client_seed text, out nonce int)
language plpgsql volatile set search_path = '' as $$
declare r public.fair_seeds := private.fair_load(p_user);
begin
  if r.nonce >= 100 and not private.round_active(p_user) then
    update public.fair_seeds set prev_server_seed = r.server_seed, prev_client_seed = r.client_seed, prev_nonce = r.nonce,
      server_seed = encode(extensions.gen_random_bytes(32), 'hex'), client_seed = encode(extensions.gen_random_bytes(8), 'hex'),
      nonce = 0, updated_at = now()
    where user_id = p_user
    returning * into r;
  end if;
  server_seed := r.server_seed;
  client_seed := r.client_seed;
  nonce := r.nonce;
  update public.fair_seeds set nonce = r.nonce + 1, updated_at = now() where user_id = p_user;
end $$;

/**
 * True while a Mines, Chicken Cross or Crash round is open. A Crash round that
 * has already crashed (or hit its auto cash-out) is settled here first, so it
 * never blocks the next game. Callers hold the player's portfolio lock.
 */
create or replace function private.round_active(p_user uuid) returns boolean
language plpgsql volatile set search_path = '' as $$
begin
  perform private.crash_settle(p_user);
  return exists (select 1 from public.game_states where user_id = p_user and state ->> 'phase' = 'playing');
end $$;

create or replace function private.fair_json(p_user uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'serverSeedHash', encode(extensions.digest(server_seed, 'sha256'), 'hex'),
    'clientSeed', client_seed,
    'nonce', nonce,
    'previous', case when prev_server_seed is null then null else jsonb_build_object(
      'serverSeed', prev_server_seed,
      'serverSeedHash', encode(extensions.digest(prev_server_seed, 'sha256'), 'hex'),
      'clientSeed', prev_client_seed,
      'nonce', prev_nonce) end)
  from public.fair_seeds where user_id = p_user
$$;

create or replace function public.fair_state() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid();
begin
  perform private.fair_load(v_user);
  return private.fair_json(v_user);
end $$;

-- Players used to pick their own client seed and change seeds. Seeds are now set by the server only.
drop function if exists public.fair_rotate(text);

create or replace function private.bet_amount(p_amount numeric) returns numeric
language plpgsql immutable set search_path = '' as $$
declare amt numeric := round(p_amount, 2);
begin
  if amt is null or not (amt >= 0.1 and amt <= 1e9) then raise exception 'Enter a bet of at least $0.10.'; end if;
  return amt;
end $$;

create or replace function private.fmt_mult(m numeric) returns text
language sql immutable set search_path = '' as $$ select trim(trailing '.' from trim(trailing '0' from m::text)) || '×' $$;

-- Dice ------------------------------------------------------------------------

create or replace function public.play_dice(p_amount numeric, p_target numeric, p_over boolean) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; amt numeric := private.bet_amount(p_amount); t int; fs record;
  v_roll int; chance int; mult numeric; win boolean; ret numeric;
begin
  perform private.rate_limit(v_user, 'dice', 150);
  if p_target is null or round(p_target, 2) < 2 or round(p_target, 2) > 98 then raise exception 'Pick a target between 2 and 98.'; end if;
  t := (round(p_target, 2) * 100)::int;
  select * into pf from public.portfolios where user_id = v_user for update;
  if amt > pf.cash then raise exception 'Not enough cash for this bet.'; end if;
  select * into fs from private.fair_next(v_user);
  v_roll := floor((private.fair_floats(fs.server_seed, fs.client_seed, fs.nonce, 1))[1] * 10001)::int;
  chance := case when p_over then 10000 - t else t end;
  mult := floor(99000000::numeric / chance) / 10000;
  win := case when p_over then v_roll > t else v_roll < t end;
  ret := case when win then trunc(amt * mult, 2) else 0 end;
  update public.portfolios set cash = cash - amt where user_id = v_user;
  perform private.game_round(v_user, pf.run, 'dice', amt, ret, format('Rolled %s · %s %s (%s)',
    to_char(v_roll / 100.0, 'FM990.00'), case when p_over then 'over' else 'under' end, to_char(t / 100.0, 'FM990.00'), private.fmt_mult(mult)));
  perform private.game_activity(v_user, 'dice', amt, ret - amt, format('rolled %s, %s %s (%s)', to_char(v_roll / 100.0, 'FM990.00'),
    case when p_over then 'over' else 'under' end, to_char(t / 100.0, 'FM990.00'), private.fmt_mult(mult)));
  return jsonb_build_object('roll', v_roll, 'win', win, 'multiplier', mult, 'payout', ret, 'nonce', fs.nonce,
    'portfolio', private.portfolio_json(v_user));
end $$;

-- Mines -----------------------------------------------------------------------

create or replace function private.mines_mult(p_mines int, p_gems int) returns numeric
language plpgsql immutable set search_path = '' as $$
declare num numeric := 99; den numeric := 100; i int;
begin
  if p_gems <= 0 then return 1; end if;
  for i in 0..p_gems - 1 loop
    num := num * (25 - i);
    den := den * (25 - p_mines - i);
  end loop;
  return floor(num * 100 / den) / 100;
end $$;

create or replace function private.mines_place(p_floats float8[], p_mines int) returns int[]
language plpgsql immutable set search_path = '' as $$
declare tiles int[] := (select array_agg(x order by x) from generate_series(0, 24) x); ord int[] := '{}'; i int; j int;
begin
  for i in 0..23 loop
    j := floor(p_floats[i + 1] * (25 - i))::int;
    ord := ord || tiles[j + 1];
    tiles := tiles[1:j] || tiles[j + 2:];
  end loop;
  ord := ord || tiles[1];
  return (select array_agg(x order by x) from unnest(ord[1:p_mines]) x);
end $$;

/** What the player sees: mine positions only once the round is over. */
create or replace function private.mines_view(s jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare gems int; m int;
begin
  if s is null then return jsonb_build_object('phase', 'idle'); end if;
  gems := jsonb_array_length(s -> 'revealed');
  m := (s ->> 'mines')::int;
  return jsonb_build_object(
    'phase', s ->> 'phase', 'bet', (s ->> 'bet')::numeric, 'mines', m, 'revealed', s -> 'revealed', 'gems', gems,
    'multiplier', private.mines_mult(m, gems),
    'nextMultiplier', case when gems < 25 - m then private.mines_mult(m, gems + 1) end,
    'payout', least(trunc((s ->> 'bet')::numeric * private.mines_mult(m, gems), 2), 1e12),
    'nonce', (s ->> 'nonce')::int,
    'result', case when s ->> 'phase' = 'done' then (s -> 'result') || jsonb_build_object('positions', s -> 'positions') end);
end $$;

create or replace function private.mines_finish(p_user uuid, s jsonb, p_win boolean, p_hit int) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare gems int := jsonb_array_length(s -> 'revealed'); m int := (s ->> 'mines')::int; bet numeric := (s ->> 'bet')::numeric;
  mult numeric := case when p_win then private.mines_mult(m, gems) else 0 end;
  -- Payouts round down to the cent (rounding up gave tiny bets an edge) and stop at $1 trillion.
  ret numeric := least(trunc(bet * mult, 2), 1e12);
begin
  perform private.game_round(p_user, (s ->> 'run')::int, 'mines', bet, ret,
    case when p_win then format('%s gem%s · %s mine%s (%s)', gems, case when gems = 1 then '' else 's' end, m, case when m = 1 then '' else 's' end, private.fmt_mult(mult))
    else format('Mine on pick %s · %s mine%s', gems + 1, m, case when m = 1 then '' else 's' end) end);
  perform private.game_activity(p_user, 'mines', bet, ret - bet, case when p_win
    then format('cashed out %s with %s mine%s', private.fmt_mult(mult), m, case when m = 1 then '' else 's' end)
    else format('hit a mine on pick %s with %s mine%s', gems + 1, m, case when m = 1 then '' else 's' end) end);
  return s || jsonb_build_object('phase', 'done', 'result', jsonb_build_object('win', p_win, 'hit', p_hit, 'multiplier', mult, 'payout', ret));
end $$;

create or replace function private.mines_begin(p_user uuid, p_amount numeric, p_mines int) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare pf public.portfolios; amt numeric := private.bet_amount(p_amount); fs record;
begin
  if p_mines is null or p_mines < 1 or p_mines > 24 then raise exception 'Pick 1 to 24 mines.'; end if;
  -- Lock before checking, so two starts (or a start and a seed change) can't race.
  select * into pf from public.portfolios where user_id = p_user for update;
  if private.round_active(p_user) then raise exception 'Finish the current round first.'; end if;
  if amt > pf.cash then raise exception 'Not enough cash for this bet.'; end if;
  update public.portfolios set cash = cash - amt where user_id = p_user;
  select * into fs from private.fair_next(p_user);
  return jsonb_build_object('phase', 'playing', 'bet', amt, 'mines', p_mines, 'revealed', '[]'::jsonb, 'run', pf.run, 'nonce', fs.nonce,
    'positions', to_jsonb(private.mines_place(private.fair_floats(fs.server_seed, fs.client_seed, fs.nonce, 24), p_mines)));
end $$;

create or replace function private.mines_pick(p_user uuid, s jsonb, p_tile int) returns jsonb
language plpgsql volatile set search_path = '' as $$
begin
  if p_tile is null or p_tile < 0 or p_tile > 24 then raise exception 'Pick a tile from 0 to 24.'; end if;
  if s -> 'revealed' @> to_jsonb(p_tile) then raise exception 'That tile is already open.'; end if;
  if s -> 'positions' @> to_jsonb(p_tile) then return private.mines_finish(p_user, s, false, p_tile); end if;
  s := jsonb_set(s, '{revealed}', (s -> 'revealed') || to_jsonb(p_tile));
  if jsonb_array_length(s -> 'revealed') = 25 - (s ->> 'mines')::int then return private.mines_finish(p_user, s, true, null); end if;
  return s;
end $$;

create or replace function private.state_save(p_user uuid, p_game text, s jsonb) returns void
language sql volatile set search_path = '' as $$
  insert into public.game_states (user_id, game, state) values (p_user, p_game, s)
  on conflict (user_id, game) do update set state = excluded.state, updated_at = now()
$$;

create or replace function private.state_load(p_user uuid, p_game text) returns jsonb
language sql volatile set search_path = '' as $$
  select state from public.game_states where user_id = p_user and game = p_game for update
$$;

create or replace function public.mines_state() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  return private.mines_view(private.state_load(private.uid(), 'mines'));
end $$;

create or replace function public.mines_start(p_amount numeric, p_mines int) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb;
begin
  perform private.rate_limit(v_user, 'mines', 120);
  s := private.mines_begin(v_user, p_amount, p_mines);
  perform private.state_save(v_user, 'mines', s);
  return jsonb_build_object('round', private.mines_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

create or replace function public.mines_reveal(p_tile int) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb;
begin
  perform private.rate_limit(v_user, 'step', 300);
  perform 1 from public.portfolios where user_id = v_user for update;
  s := private.state_load(v_user, 'mines');
  if s is null or s ->> 'phase' <> 'playing' then raise exception 'Start a round first.'; end if;
  s := private.mines_pick(v_user, s, p_tile);
  perform private.state_save(v_user, 'mines', s);
  return jsonb_build_object('round', private.mines_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

create or replace function public.mines_cashout() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb;
begin
  perform 1 from public.portfolios where user_id = v_user for update;
  s := private.state_load(v_user, 'mines');
  if s is null or s ->> 'phase' <> 'playing' then raise exception 'There is no round to cash out.'; end if;
  if jsonb_array_length(s -> 'revealed') = 0 then raise exception 'Open at least one tile first.'; end if;
  s := private.mines_finish(v_user, s, true, null);
  perform private.state_save(v_user, 'mines', s);
  return jsonb_build_object('round', private.mines_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

/** Auto play: opens the given tiles in order and cashes out if they are all safe. */
create or replace function public.mines_auto(p_amount numeric, p_mines int, p_tiles int[]) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb; t int;
begin
  perform private.rate_limit(v_user, 'mines', 120);
  -- Every check happens before the mines are placed: an error after that would undo a losing
  -- round and give the bet back, which would let players test tiles for free.
  if coalesce(array_length(p_tiles, 1), 0) < 1 or array_length(p_tiles, 1) > 25 - coalesce(p_mines, 1)
    or exists (select 1 from unnest(p_tiles) x where x is null or x < 0 or x > 24)
    or (select count(distinct x) from unnest(p_tiles) x) <> array_length(p_tiles, 1) then
    raise exception 'Pick between 1 and % different tiles from 0 to 24.', 25 - coalesce(p_mines, 1);
  end if;
  s := private.mines_begin(v_user, p_amount, p_mines);
  foreach t in array p_tiles loop
    s := private.mines_pick(v_user, s, t);
    exit when s ->> 'phase' = 'done';
  end loop;
  if s ->> 'phase' = 'playing' then s := private.mines_finish(v_user, s, true, null); end if;
  perform private.state_save(v_user, 'mines', s);
  return jsonb_build_object('round', private.mines_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

-- Chicken Cross ------------------------------------------------------------------

create or replace function private.chicken_cfg(p_difficulty text, out lanes int, out num int, out den int)
language plpgsql immutable set search_path = '' as $$
begin
  case p_difficulty
    when 'easy' then lanes := 30; num := 24; den := 25;
    when 'medium' then lanes := 25; num := 22; den := 25;
    when 'hard' then lanes := 22; num := 4; den := 5;
    when 'daredevil' then lanes := 18; num := 3; den := 5;
    else raise exception 'Pick Easy, Medium, Hard or Daredevil.';
  end case;
end $$;

create or replace function private.chicken_mult(p_difficulty text, p_lane int) returns numeric
language plpgsql immutable set search_path = '' as $$
declare c record; a numeric := 98; b numeric := 1; i int;
begin
  if p_lane <= 0 then return 1; end if;
  select * into c from private.chicken_cfg(p_difficulty);
  for i in 1..p_lane loop
    a := a * c.den;
    b := b * c.num;
  end loop;
  return floor(a / b) / 100;
end $$;

create or replace function private.chicken_view(s jsonb) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare lane int; d text; c record;
begin
  if s is null then return jsonb_build_object('phase', 'idle'); end if;
  lane := (s ->> 'lane')::int;
  d := s ->> 'difficulty';
  select * into c from private.chicken_cfg(d);
  return jsonb_build_object(
    'phase', s ->> 'phase', 'bet', (s ->> 'bet')::numeric, 'difficulty', d, 'lane', lane, 'lanes', c.lanes,
    'multiplier', private.chicken_mult(d, lane),
    'nextMultiplier', case when lane < c.lanes then private.chicken_mult(d, lane + 1) end,
    'payout', least(trunc((s ->> 'bet')::numeric * private.chicken_mult(d, lane), 2), 1e12),
    'nonce', (s ->> 'nonce')::int,
    'result', case when s ->> 'phase' = 'done' then s -> 'result' end);
end $$;

create or replace function private.chicken_finish(p_user uuid, s jsonb, p_win boolean) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare lane int := (s ->> 'lane')::int; d text := s ->> 'difficulty'; bet numeric := (s ->> 'bet')::numeric;
  mult numeric := case when p_win then private.chicken_mult(d, lane) else 0 end;
  ret numeric := least(trunc(bet * mult, 2), 1e12);
  label text := initcap(d);
begin
  perform private.game_round(p_user, (s ->> 'run')::int, 'chicken', bet, ret,
    case when p_win then format('Lane %s · %s (%s)', lane, label, private.fmt_mult(mult))
    else format('Hit on lane %s · %s', lane + 1, label) end);
  perform private.game_activity(p_user, 'chicken', bet, ret - bet, case when p_win
    then format('crossed %s lane%s on %s (%s)', lane, case when lane = 1 then '' else 's' end, lower(label), private.fmt_mult(mult))
    else format('got hit on lane %s on %s', lane + 1, lower(label)) end);
  return s || jsonb_build_object('phase', 'done', 'result', jsonb_build_object('win', p_win, 'lane', lane,
    'hitLane', case when p_win then null else lane + 1 end, 'multiplier', mult, 'payout', ret, 'crashLane', s -> 'crash'));
end $$;

create or replace function private.chicken_begin(p_user uuid, p_amount numeric, p_difficulty text) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare pf public.portfolios; amt numeric := private.bet_amount(p_amount); c record; fs record; f float8[]; crash int; i int;
begin
  select * into c from private.chicken_cfg(p_difficulty);
  select * into pf from public.portfolios where user_id = p_user for update;
  if private.round_active(p_user) then raise exception 'Finish the current round first.'; end if;
  if amt > pf.cash then raise exception 'Not enough cash for this bet.'; end if;
  update public.portfolios set cash = cash - amt where user_id = p_user;
  select * into fs from private.fair_next(p_user);
  f := private.fair_floats(fs.server_seed, fs.client_seed, fs.nonce, c.lanes);
  for i in 1..c.lanes loop
    if f[i] * c.den >= c.num then crash := i; exit; end if;
  end loop;
  return jsonb_build_object('phase', 'playing', 'bet', amt, 'difficulty', p_difficulty, 'lane', 0, 'run', pf.run,
    'nonce', fs.nonce, 'crash', crash);
end $$;

create or replace function private.chicken_hop(p_user uuid, s jsonb) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare nxt int := (s ->> 'lane')::int + 1; c record;
begin
  select * into c from private.chicken_cfg(s ->> 'difficulty');
  if (s ->> 'crash')::int = nxt then return private.chicken_finish(p_user, s, false); end if;
  s := jsonb_set(s, '{lane}', to_jsonb(nxt));
  if nxt >= c.lanes then return private.chicken_finish(p_user, s, true); end if;
  return s;
end $$;

create or replace function public.chicken_state() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
begin
  return private.chicken_view(private.state_load(private.uid(), 'chicken'));
end $$;

create or replace function public.chicken_start(p_amount numeric, p_difficulty text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb;
begin
  perform private.rate_limit(v_user, 'chicken', 120);
  s := private.chicken_begin(v_user, p_amount, p_difficulty);
  perform private.state_save(v_user, 'chicken', s);
  return jsonb_build_object('round', private.chicken_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

create or replace function public.chicken_step() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb;
begin
  perform private.rate_limit(v_user, 'step', 300);
  perform 1 from public.portfolios where user_id = v_user for update;
  s := private.state_load(v_user, 'chicken');
  if s is null or s ->> 'phase' <> 'playing' then raise exception 'Start a round first.'; end if;
  s := private.chicken_hop(v_user, s);
  perform private.state_save(v_user, 'chicken', s);
  return jsonb_build_object('round', private.chicken_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

create or replace function public.chicken_cashout() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb;
begin
  perform 1 from public.portfolios where user_id = v_user for update;
  s := private.state_load(v_user, 'chicken');
  if s is null or s ->> 'phase' <> 'playing' then raise exception 'There is no round to cash out.'; end if;
  if (s ->> 'lane')::int = 0 then raise exception 'Cross at least one lane first.'; end if;
  s := private.chicken_finish(v_user, s, true);
  perform private.state_save(v_user, 'chicken', s);
  return jsonb_build_object('round', private.chicken_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

/** Auto play: hops until the target lane (cashing out there) or until hit. */
create or replace function public.chicken_auto(p_amount numeric, p_difficulty text, p_target int) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb; c record;
begin
  perform private.rate_limit(v_user, 'chicken', 120);
  select * into c from private.chicken_cfg(p_difficulty);
  if p_target is null or p_target < 1 or p_target > c.lanes then raise exception 'Pick a lane from 1 to %.', c.lanes; end if;
  s := private.chicken_begin(v_user, p_amount, p_difficulty);
  while s ->> 'phase' = 'playing' and (s ->> 'lane')::int < p_target loop
    s := private.chicken_hop(v_user, s);
  end loop;
  if s ->> 'phase' = 'playing' then s := private.chicken_finish(v_user, s, true); end if;
  perform private.state_save(v_user, 'chicken', s);
  return jsonb_build_object('round', private.chicken_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

-- Limbo and Crash -----------------------------------------------------------------
-- One provably fair result per round, exactly as src/games/limbo.js computes it:
--   n = floor(float × 2^24), result = floor(2^24 × 99 / (n + 1)) hundredths,
-- clamped to 1.00× to 1,000,000×. Reaching x has a chance of about 0.99 / x.

create or replace function private.limbo_cents(f float8) returns bigint
language sql immutable set search_path = '' as $$
  select least(100000000, greatest(100, 1660944384::bigint / (floor(f * 16777216)::bigint + 1)))
$$;

create or replace function private.cents_mult(c bigint) returns text
language sql immutable set search_path = '' as $$ select to_char(c / 100.0, 'FM9999990.00') || '×' $$;

/** Limbo: pick a target from 1.01× to 1,000,000×; a result at or above it pays target × bet. */
create or replace function public.play_limbo(p_amount numeric, p_target numeric) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; amt numeric := private.bet_amount(p_amount); t bigint; fs record;
  res bigint; win boolean; ret numeric;
begin
  perform private.rate_limit(v_user, 'limbo', 150);
  if p_target is null or round(p_target, 2) < 1.01 or round(p_target, 2) > 1000000 then
    raise exception 'Pick a target from 1.01× to 1,000,000×.';
  end if;
  t := (round(p_target, 2) * 100)::bigint;
  select * into pf from public.portfolios where user_id = v_user for update;
  if amt > pf.cash then raise exception 'Not enough cash for this bet.'; end if;
  select * into fs from private.fair_next(v_user);
  res := private.limbo_cents((private.fair_floats(fs.server_seed, fs.client_seed, fs.nonce, 1))[1]);
  win := res >= t;
  ret := case when win then least(trunc(amt * t / 100, 2), 1e12) else 0 end;
  update public.portfolios set cash = cash - amt where user_id = v_user;
  perform private.game_round(v_user, pf.run, 'limbo', amt, ret, format('Result %s · target %s', private.cents_mult(res), private.cents_mult(t)));
  perform private.game_activity(v_user, 'limbo', amt, ret - amt, format('hit %s with a %s target', private.cents_mult(res), private.cents_mult(t)));
  return jsonb_build_object('result', res / 100.0, 'win', win, 'target', t / 100.0, 'payout', ret, 'nonce', fs.nonce,
    'portfolio', private.portfolio_json(v_user));
end $$;

-- Crash: the multiplier climbs as e^(0.00006 × ms) from the start and crashes at
-- the round's result. The crash point and the moment the round ends stay on
-- the server; players only learn them once the round is over.

create or replace function private.now_ms() returns bigint
language sql volatile set search_path = '' as $$ select floor(extract(epoch from clock_timestamp()) * 1000)::bigint $$;

create or replace function private.crash_view(s jsonb) returns jsonb
language sql volatile set search_path = '' as $$
  select case when s is null then jsonb_build_object('phase', 'idle') else jsonb_build_object(
    'phase', s ->> 'phase',
    'bet', (s ->> 'bet')::numeric,
    'auto', (s ->> 'auto')::numeric / 100,
    'elapsed', private.now_ms() - (s ->> 'started')::bigint,
    'nonce', (s ->> 'nonce')::int,
    'result', s -> 'result') end
$$;

create or replace function private.crash_finish(p_user uuid, s jsonb, p_win boolean, p_cents bigint) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare bet numeric := (s ->> 'bet')::numeric; c bigint := (s ->> 'crash')::bigint;
  ret numeric := case when p_win then least(trunc(bet * p_cents / 100, 2), 1e12) else 0 end;
begin
  perform private.game_round(p_user, (s ->> 'run')::int, 'crash', bet, ret,
    case when p_win then format('Cashed out %s · crashed at %s', private.cents_mult(p_cents), private.cents_mult(c))
    else format('Crashed at %s', private.cents_mult(c)) end);
  perform private.game_activity(p_user, 'crash', bet, ret - bet,
    case when p_win then format('cashed out at %s (crashed at %s)', private.cents_mult(p_cents), private.cents_mult(c))
    else format('rode it to the crash at %s', private.cents_mult(c)) end);
  return s || jsonb_build_object('phase', 'done', 'result', jsonb_build_object(
    'win', p_win, 'cashout', case when p_win then p_cents / 100.0 end, 'crash', c / 100.0, 'payout', ret));
end $$;

/** Settles a Crash round once it has crashed or reached its auto cash-out, or on a cash-out request. */
create or replace function private.crash_check(p_user uuid, s jsonb, p_cashout boolean) returns jsonb
language plpgsql volatile set search_path = '' as $$
declare c bigint; a bigint; x float8; m bigint;
begin
  if s is null or s ->> 'phase' <> 'playing' then return s; end if;
  c := (s ->> 'crash')::bigint;
  a := (s ->> 'auto')::bigint;
  x := exp(0.00006 * greatest(0, private.now_ms() - (s ->> 'started')::bigint)) * 100;
  if a is not null and a <= c and x >= a then return private.crash_finish(p_user, s, true, a); end if;
  if x >= c then return private.crash_finish(p_user, s, false, c); end if;
  if p_cashout then
    m := floor(x)::bigint;
    return private.crash_finish(p_user, s, true, m);
  end if;
  return s;
end $$;

/** Settles a finished Crash round for the player, if there is one. Callers hold the portfolio lock. */
create or replace function private.crash_settle(p_user uuid) returns void
language plpgsql volatile set search_path = '' as $$
declare s jsonb;
begin
  select state into s from public.game_states where user_id = p_user and game = 'crash' and state ->> 'phase' = 'playing' for update;
  if s is null then return; end if;
  if (s ->> 'ends')::bigint > private.now_ms() then return; end if;
  perform private.state_save(p_user, 'crash', private.crash_check(p_user, s, false));
end $$;

create or replace function public.crash_start(p_amount numeric, p_auto numeric default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; amt numeric := private.bet_amount(p_amount); fs record;
  c bigint; a bigint; s jsonb; started bigint;
begin
  perform private.rate_limit(v_user, 'crash', 120);
  if p_auto is not null and (round(p_auto, 2) < 1.01 or round(p_auto, 2) > 1000000) then
    raise exception 'Auto cash-out goes from 1.01× to 1,000,000×.';
  end if;
  a := (round(p_auto, 2) * 100)::bigint;
  select * into pf from public.portfolios where user_id = v_user for update;
  if private.round_active(v_user) then raise exception 'Finish the current round first.'; end if;
  if amt > pf.cash then raise exception 'Not enough cash for this bet.'; end if;
  update public.portfolios set cash = cash - amt where user_id = v_user;
  select * into fs from private.fair_next(v_user);
  c := private.limbo_cents((private.fair_floats(fs.server_seed, fs.client_seed, fs.nonce, 1))[1]);
  started := private.now_ms();
  s := jsonb_build_object('phase', 'playing', 'bet', amt, 'run', pf.run, 'nonce', fs.nonce, 'crash', c, 'auto', a, 'started', started,
    -- When the round is over for sure: the auto cash-out if it comes first, else the crash.
    'ends', started + ceil(ln(least(c, coalesce(a, c)) / 100.0) / 0.00006)::bigint);
  perform private.state_save(v_user, 'crash', s);
  return jsonb_build_object('round', private.crash_view(s), 'portfolio', private.portfolio_json(v_user));
end $$;

/** Polled while a round runs: settles it if it has crashed or hit the auto cash-out. */
create or replace function public.crash_state() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb; n jsonb;
begin
  perform private.rate_limit(v_user, 'crash-poll', 600);
  perform 1 from public.portfolios where user_id = v_user for update;
  s := private.state_load(v_user, 'crash');
  n := private.crash_check(v_user, s, false);
  if n is distinct from s then perform private.state_save(v_user, 'crash', n); end if;
  return jsonb_build_object('round', private.crash_view(n),
    'portfolio', case when n is distinct from s then private.portfolio_json(v_user) end);
end $$;

create or replace function public.crash_cashout() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s jsonb; n jsonb;
begin
  perform private.rate_limit(v_user, 'step', 300);
  perform 1 from public.portfolios where user_id = v_user for update;
  s := private.state_load(v_user, 'crash');
  if s is null then raise exception 'There is no round to cash out.'; end if;
  n := private.crash_check(v_user, s, true);
  if n is distinct from s then perform private.state_save(v_user, 'crash', n); end if;
  return jsonb_build_object('round', private.crash_view(n), 'portfolio', private.portfolio_json(v_user));
end $$;

-- Golden Sevens (slots) -----------------------------------------------------------
-- The same engine as src/games/slots.js, step for step: 24 provably fair
-- floats per spin, integer "units" of a hundredth of the bet (a line bet is
-- 5 units). See that file for the rules. Tests check both give the same rounds.
-- Boneyard, the slot this replaced, is retired; its past rounds stay in history.

drop function if exists public.play_boneyard(numeric);
drop function if exists private.by_round(float8[]);
drop function if exists private.by_spin(float8[], int, text, int);
drop function if exists private.by_pay(text, int);
drop function if exists private.by_pick(float8, text[], int[]);

create or replace function private.weighted_pick(f float8, syms text[], w int[]) returns text
language plpgsql immutable set search_path = '' as $$
declare total int := 0; r int; i int;
begin
  for i in 1..array_length(w, 1) loop total := total + w[i]; end loop;
  r := floor(f * total)::int;
  for i in 1..array_length(w, 1) loop
    r := r - w[i];
    if r < 0 then return syms[i]; end if;
  end loop;
  return syms[array_length(syms, 1)];
end $$;

/** Pay for 3, 4 or 5 of a kind on a line, in line bets. */
create or replace function private.slot_pay(p_sym text, p_count int) returns int
language sql immutable set search_path = '' as $$
  select (case p_sym
    when 'cherry' then array[2, 6, 20] when 'lemon' then array[2, 6, 20] when 'orange' then array[3, 10, 35] when 'plum' then array[3, 10, 35]
    when 'bell' then array[6, 20, 90] when 'bar' then array[10, 35, 175] when 'seven' then array[18, 90, 500]
    when 'diamond' then array[40, 250, 3000] end)[p_count - 2]
$$;

create or replace function private.slot_spin(fl float8[], p_at int, p_free boolean) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  outer_s text[] := array['cherry', 'lemon', 'orange', 'plum', 'bell', 'bar', 'seven', 'diamond', 'scatter'];
  outer_w int[] := array[20, 18, 16, 14, 10, 7, 4, 2, 3];
  mid_s text[] := array['cherry', 'lemon', 'orange', 'plum', 'bell', 'bar', 'seven', 'diamond', 'wild', 'scatter'];
  mid_w int[] := array[20, 18, 16, 14, 10, 7, 4, 2, 5, 3];
  wm_s text[] := array['2', '3', '5', '10'];
  wm_w int[] := array[56, 27, 13, 4];
  lines int[] := array[
    [1, 1, 1, 1, 1], [0, 0, 0, 0, 0], [2, 2, 2, 2, 2], [0, 1, 2, 1, 0], [2, 1, 0, 1, 2],
    [0, 0, 1, 2, 2], [2, 2, 1, 0, 0], [1, 0, 0, 0, 1], [1, 2, 2, 2, 1], [0, 1, 0, 1, 0],
    [2, 1, 2, 1, 2], [1, 0, 1, 0, 1], [1, 2, 1, 2, 1], [0, 1, 1, 1, 0], [2, 1, 1, 1, 2],
    [1, 1, 0, 1, 1], [1, 1, 2, 1, 1], [0, 2, 0, 2, 0], [2, 0, 2, 0, 2], [0, 2, 2, 2, 0]];
  cells text[] := array_fill(null::text, array[15]);
  mults int[] := array_fill(1, array[15]);
  r int; rw int; li int; idx int; first text; sym text; cnt int; mult bigint; win bigint; units bigint := 0;
  wins jsonb := '[]'; grid jsonb := '[]'; mgrid jsonb := '[]'; col jsonb; mcol jsonb; scat int := 0; scat_units bigint := 0; spins int := 0;
begin
  for r in 0..4 loop
    for rw in 0..2 loop
      idx := r * 3 + rw + 1;
      if r = 0 or r = 4 then cells[idx] := private.weighted_pick(fl[p_at + idx], outer_s, outer_w);
      else cells[idx] := private.weighted_pick(fl[p_at + idx], mid_s, mid_w);
      end if;
      if cells[idx] = 'wild' then
        mults[idx] := private.weighted_pick(fl[p_at + 16 + (r - 1) * 3 + rw], wm_s, wm_w)::int;
      end if;
      if cells[idx] = 'scatter' then scat := scat + 1; end if;
    end loop;
  end loop;

  for li in 1..20 loop
    first := cells[lines[li][1] + 1];
    continue when first = 'scatter';
    cnt := 1; mult := 1;
    for r in 1..4 loop
      idx := r * 3 + lines[li][r + 1] + 1;
      sym := cells[idx];
      exit when sym <> first and sym <> 'wild';
      if sym = 'wild' then mult := mult * mults[idx]; end if;
      cnt := cnt + 1;
    end loop;
    continue when cnt < 3;
    win := private.slot_pay(first, cnt) * 5 * mult;
    wins := wins || jsonb_build_object('line', li - 1, 'symbol', first, 'count', cnt, 'mult', mult, 'units', win);
    units := units + win;
  end loop;

  if scat >= 3 then
    scat_units := (array[2, 10, 50])[least(scat, 5) - 2] * 100;
    spins := (array[10, 15, 20])[least(scat, 5) - 2];
  end if;
  units := units + scat_units;
  if p_free then units := units * 3; scat_units := scat_units * 3; end if;

  for r in 0..4 loop
    col := '[]'; mcol := '[]';
    for rw in 0..2 loop
      col := col || to_jsonb(cells[r * 3 + rw + 1]);
      mcol := mcol || to_jsonb(mults[r * 3 + rw + 1]);
    end loop;
    grid := grid || jsonb_build_array(col);
    mgrid := mgrid || jsonb_build_array(mcol);
  end loop;
  return jsonb_build_object('grid', grid, 'mults', mgrid, 'wins', wins, 'scatters', scat, 'scatterUnits', scat_units,
    'freeSpins', spins, 'units', units);
end $$;

/** A whole round: the base spin, then free spins with retriggers (30 at most), stopping at the 50,000x cap. */
create or replace function private.slot_round(fl float8[]) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare sp jsonb; spins jsonb; total bigint; left_ int; awarded int; extra int; i int := 1;
begin
  sp := private.slot_spin(fl, 0, false);
  spins := jsonb_build_array(sp);
  total := least(5000000, (sp ->> 'units')::bigint);
  left_ := least(30, (sp ->> 'freeSpins')::int);
  awarded := left_;
  while left_ > 0 and total < 5000000 loop
    sp := private.slot_spin(fl, i * 24, true);
    spins := spins || jsonb_build_array(sp);
    total := least(5000000, total + (sp ->> 'units')::bigint);
    left_ := left_ - 1;
    extra := least((sp ->> 'freeSpins')::int, 30 - awarded);
    left_ := left_ + extra;
    awarded := awarded + extra;
    i := i + 1;
  end loop;
  return jsonb_build_object('spins', spins, 'freeSpins', awarded, 'units', total, 'capped', total >= 5000000);
end $$;

create or replace function public.play_slots(p_amount numeric) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); pf public.portfolios; amt numeric := private.bet_amount(p_amount); fs record; rd jsonb;
  units bigint; ret numeric; fsp int;
begin
  perform private.rate_limit(v_user, 'slot', 120);
  select * into pf from public.portfolios where user_id = v_user for update;
  if amt > pf.cash then raise exception 'Not enough cash for this bet.'; end if;
  select * into fs from private.fair_next(v_user);
  rd := private.slot_round(private.fair_floats(fs.server_seed, fs.client_seed, fs.nonce, 744));
  units := (rd ->> 'units')::bigint;
  fsp := (rd ->> 'freeSpins')::int;
  ret := least(trunc(amt * units / 100, 2), 1e12);
  update public.portfolios set cash = cash - amt where user_id = v_user;
  perform private.game_round(v_user, pf.run, 'slots', amt, ret,
    concat_ws(' · ', case when fsp > 0 then fsp || ' free spins' end,
      case when units > 0 then private.cents_mult(units) || case when (rd ->> 'capped')::boolean then ' (max win)' else '' end else 'No win' end));
  perform private.game_activity(v_user, 'slots', amt, ret - amt,
    case when units > 0 then 'hit ' || private.cents_mult(units) || case when fsp > 0 then ' with ' || fsp || ' free spins' else '' end
    else 'spun' end);
  return jsonb_build_object('round', rd, 'payout', ret, 'nonce', fs.nonce, 'portfolio', private.portfolio_json(v_user));
end $$;

-- ---------------------------------------------------------------------------
-- Tables: live No-Limit Texas Hold'em between players
--
-- Shown on the site as "Tables" (src/games/names.js). Rounds are recorded
-- under the game id 'poker'. Play money only, no rake.
--
-- THE RULE SET
--
-- Seats and stakes
--   * Cash tables with 2 to 6 seats at fixed stakes (private.poker_stakes).
--     Chips are whole dollars. A buy-in is 20 to 100 big blinds and moves
--     from cash to the table stack; leaving moves the stack back.
--   * One seat per player across all tables. Guests can watch but not sit:
--     a guest account is free and unlimited, so a seat for guests would let
--     anyone pour fresh $100,000 balances into one real account.
--   * A hand is dealt when at least two seated players have chips and are
--     not sitting out. A player who sits down, comes back or adds chips
--     during a hand joins the next one. Nobody posts a dead blind.
--
-- Button and blinds
--   * Moving button: each hand the button goes to the next player being dealt
--     in, clockwise from where it was (the first hand's button is random).
--     The small blind is the next player after the button and the big blind
--     the next after that.
--   * Heads-up, the button posts the small blind, acts first before the flop
--     and last on every later round.
--   * A player with fewer chips than their blind posts what they have and is
--     all-in. The bet to call is still the full big blind.
--
-- Betting
--   * Before the flop the first player after the big blind acts first, and
--     the big blind may raise when everyone only called. After the flop the
--     first player after the button who is still in and not all-in acts first.
--   * Fold, check (nothing to call), call (all-in for less is allowed), bet
--     or raise. Amounts are the total a player has in on this round.
--   * The smallest bet is the big blind. The smallest raise adds at least the
--     size of the last full bet or raise on this round. A player may always
--     go all-in for less.
--   * An all-in raise smaller than a full raise does not reopen the betting:
--     a player who already acted may raise again only when the bet has gone
--     up by at least a full raise since they acted (so several short all-ins
--     that add up to a full raise do reopen it). Players who have not acted
--     yet can still raise, by at least the last full raise on top of the bet.
--   * A raise is not offered when every other player still in is all-in.
--   * A round ends when everyone still in and not all-in has acted and
--     matched the bet. A bet nobody called is returned to the bettor.
--   * When all but one player has folded, the last one wins the pot without
--     showing. When at most one player still has chips to bet, the rest of
--     the board is dealt at once and every hand still in is turned face up.
--
-- Pots and showdown
--   * Side pots: each all-in amount caps a pot. A pot goes to the best hand
--     among the players who put the full amount for it in. Folded players'
--     chips stay in the pots they paid into.
--   * Best five cards from seven. Ties split the pot; an odd chip goes to the
--     first winner clockwise from the button.
--   * Showing order: the last player to bet or raise on the river shows
--     first, or the first player after the button when the river was checked.
--     Going clockwise, a player shows a hand that wins or ties any pot, or
--     that is at least as good as the best one shown so far; otherwise it is
--     mucked and nobody ever sees it.
--
-- Clock
--   * Every turn has a deadline (private.poker_k). A player who runs out of
--     time checks if that is free and folds otherwise. Two timeouts in a row
--     sit the player out; from then on they are folded at once until they
--     come back. A player who stays out for three minutes, or stays at zero
--     chips that long, is removed and their stack returned to cash. So is a
--     player whose browser has not asked about the table for three minutes
--     (checked between hands), so nobody holds a seat they have walked away from.
--   * There is no server process. Every call that touches a table first
--     plays out any turn whose deadline has passed (private.poker_advance),
--     each one timed from the deadline before it, exactly as a clock running
--     on time would have. Clients call poker_tick when a deadline they can
--     see passes, and a once-a-minute pg_cron job (private.poker_sweep)
--     does the same for tables nobody is looking at.
--
-- Fairness
--   * The deck is shuffled with a cryptographic RNG (private.rand_int).
--     Before any card is dealt each of the 52 cards is sealed as
--     sha256("<salt>:<card>") with its own random salt, and the hash of all 52
--     seals is published with the hand. After the hand, poker_proof gives the
--     seals plus the salt of every card that was shown (and, to each player,
--     of their own two), so anyone can check the cards were fixed before the
--     betting started. Mucked hands, burn cards and the rest of the deck stay
--     sealed for good.
--
-- What a client can see: public.poker_tables.state (built by poker_publish
-- from an explicit list of fields) and, from poker_state, their own two
-- cards. Other players' cards appear only once shown at a showdown.
-- ---------------------------------------------------------------------------

/** Table timings in seconds, and how many timeouts in a row sit a player out. */
create or replace function private.poker_k(p_key text) returns int
language sql immutable set search_path = '' as $$
  select case p_key
    when 'turn' then 25       -- time to act
    when 'pause' then 6       -- a finished hand stays up this long before the next deal
    when 'runout' then 4      -- extra time when the board was dealt out after an all-in
    when 'start' then 3       -- countdown once a second player is ready
    when 'away' then 180      -- sitting out (or out of chips) this long frees the seat
    when 'timeouts' then 2    -- timeouts in a row before a player is sat out
    when 'grace' then 1       -- a move arriving this late still counts
  end
$$;

create or replace function private.poker_stakes() returns table (stake text, small_blind bigint, big_blind bigint, min_buy bigint, max_buy bigint)
language sql immutable set search_path = '' as $$
  values ('micro', 1::bigint, 2::bigint, 40::bigint, 200::bigint), ('low', 5, 10, 200, 1000), ('mid', 25, 50, 1000, 5000), ('high', 100, 200, 4000, 20000)
$$;

-- Hand evaluation ---------------------------------------------------------------
-- Cards are two characters: a rank from 23456789TJQKA and a suit from shdc.
-- A hand's strength is an array that compares the way hands do: the category
-- (8 straight flush ... 0 high card), then the ranks that break ties, highest
-- first. src/games/poker.js computes the same array for the labels on screen.

/** The top card of the best straight among the ranks present (p[2..14] > 0), or 0. The ace also plays low. */
create or replace function private.poker_straight(p int[]) returns int
language plpgsql immutable set search_path = '' as $$
declare h int;
begin
  for h in reverse 14..6 loop
    if p[h] > 0 and p[h - 1] > 0 and p[h - 2] > 0 and p[h - 3] > 0 and p[h - 4] > 0 then return h; end if;
  end loop;
  if p[14] > 0 and p[2] > 0 and p[3] > 0 and p[4] > 0 and p[5] > 0 then return 5; end if;
  return 0;
end $$;

/** The strength of the best five-card hand among 5 to 7 cards. */
create or replace function private.poker_rank(p_cards text[]) returns int[]
language plpgsql immutable set search_path = '' as $$
declare cnt int[] := array_fill(0, array[14]); suits int[] := array_fill(0, array[4]); fl int[] := array_fill(0, array[14]);
  c text; r int; s int; fs int := 0; sh int; quad int := 0; trips int[] := '{}'; pairs int[] := '{}'; singles int[] := '{}'; top int[] := '{}';
begin
  if coalesce(array_length(p_cards, 1), 0) not between 5 and 7 then raise exception 'A hand is 5 to 7 cards.'; end if;
  foreach c in array p_cards loop
    if c is null or c !~ '^[2-9TJQKA][shdc]$' then raise exception 'Bad card %.', c; end if;
    r := position(substr(c, 1, 1) in '23456789TJQKA') + 1;
    s := position(substr(c, 2, 1) in 'shdc');
    cnt[r] := cnt[r] + 1;
    suits[s] := suits[s] + 1;
  end loop;
  for s in 1..4 loop
    if suits[s] >= 5 then fs := s; end if;
  end loop;
  if fs > 0 then
    foreach c in array p_cards loop
      if position(substr(c, 2, 1) in 'shdc') = fs then fl[position(substr(c, 1, 1) in '23456789TJQKA') + 1] := 1; end if;
    end loop;
    sh := private.poker_straight(fl);
    if sh > 0 then return array[8, sh, 0, 0, 0, 0]; end if;
  end if;
  for r in reverse 14..2 loop
    if cnt[r] = 4 then quad := r;
    elsif cnt[r] = 3 then trips := trips || r;
    elsif cnt[r] = 2 then pairs := pairs || r;
    elsif cnt[r] = 1 then singles := singles || r;
    end if;
  end loop;
  if quad > 0 then
    return array[7, quad, (select max(x) from generate_series(2, 14) x where x <> quad and cnt[x] > 0), 0, 0, 0];
  end if;
  if coalesce(array_length(trips, 1), 0) > 0 and (array_length(trips, 1) > 1 or coalesce(array_length(pairs, 1), 0) > 0) then
    return array[6, trips[1], greatest(coalesce(trips[2], 0), coalesce(pairs[1], 0)), 0, 0, 0];
  end if;
  if fs > 0 then
    for r in reverse 14..2 loop
      if fl[r] > 0 and coalesce(array_length(top, 1), 0) < 5 then top := top || r; end if;
    end loop;
    return array[5] || top;
  end if;
  sh := private.poker_straight(cnt);
  if sh > 0 then return array[4, sh, 0, 0, 0, 0]; end if;
  if coalesce(array_length(trips, 1), 0) > 0 then return array[3, trips[1], singles[1], singles[2], 0, 0]; end if;
  if coalesce(array_length(pairs, 1), 0) >= 2 then
    return array[2, pairs[1], pairs[2], greatest(coalesce(pairs[3], 0), coalesce(singles[1], 0)), 0, 0];
  end if;
  if coalesce(array_length(pairs, 1), 0) = 1 then return array[1, pairs[1], singles[1], singles[2], singles[3], 0]; end if;
  return array[0, singles[1], singles[2], singles[3], singles[4], singles[5]];
end $$;

create or replace function private.poker_rank_name(p int[]) returns text
language sql immutable set search_path = '' as $$
  select case p[1]
    when 8 then case when p[2] = 14 then 'a royal flush' else 'a straight flush' end
    when 7 then 'four of a kind' when 6 then 'a full house' when 5 then 'a flush' when 4 then 'a straight'
    when 3 then 'three of a kind' when 2 then 'two pair' when 1 then 'a pair' else 'high card' end
$$;

/** A freshly shuffled deck: Fisher-Yates driven by the cryptographic, unbiased private.rand_int. */
create or replace function private.poker_shuffle() returns text[]
language plpgsql volatile set search_path = '' as $$
declare cards text[] := '{}'; r text; s text; i int; j int; tmp text;
begin
  foreach s in array array['s', 'h', 'd', 'c'] loop
    foreach r in array array['2', '3', '4', '5', '6', '7', '8', '9', 'T', 'J', 'Q', 'K', 'A'] loop
      cards := cards || (r || s);
    end loop;
  end loop;
  for i in reverse 52..2 loop
    j := private.rand_int(i) + 1;
    tmp := cards[i];
    cards[i] := cards[j];
    cards[j] := tmp;
  end loop;
  return cards;
end $$;

-- The engine. Every function here expects the caller to hold the table's row
-- lock (select ... for update on public.poker_tables), which is what makes two
-- moves, two tabs or a move and a timeout take turns instead of racing.
-- `p_base` is the moment an event happened: now() for a player's own move, or
-- the deadline that ran out, so late pushes replay the table on schedule.

/** What the player to act may do: chips to call, whether a raise is open, and the smallest and largest total bet. */
create or replace function private.poker_options(p_table bigint, p_seat int, out to_call bigint, out can_raise boolean, out min_to bigint, out max_to bigint)
language plpgsql stable set search_path = '' as $$
declare h private.poker_hands; s private.poker_seats; v_others int; v_bet bigint;
begin
  select * into h from private.poker_hands where table_id = p_table;
  select * into s from private.poker_seats where table_id = p_table and seat = p_seat;
  select count(*) filter (where not all_in), coalesce(max(bet), 0) into v_others, v_bet
    from private.poker_seats where table_id = p_table and in_hand and not folded and seat <> p_seat;
  -- Against players who are all all-in, there is only their largest bet to match (a short big blind, say), not the nominal one.
  v_bet := case when v_others = 0 then least(h.current_bet, v_bet) else h.current_bet end;
  to_call := least(greatest(v_bet - s.bet, 0), s.stack);
  max_to := s.bet + s.stack;
  min_to := least(h.current_bet + h.last_raise, max_to);
  can_raise := max_to > h.current_bet and v_others > 0 and (not s.acted or h.current_bet - s.acted_level >= h.last_raise);
end $$;

/**
 * Applies one move for a seat. Returns null when it was applied, or the
 * reason it can't be (nothing is changed then). Whose turn it is and what
 * happens next are the caller's business (see poker_progress).
 */
create or replace function private.poker_apply(p_table bigint, p_seat int, p_action text, p_amount numeric) returns text
language plpgsql volatile set search_path = '' as $$
declare h private.poker_hands; s private.poker_seats; o record; v_target bigint; v_pay bigint;
begin
  select * into h from private.poker_hands where table_id = p_table;
  select * into s from private.poker_seats where table_id = p_table and seat = p_seat;
  select * into o from private.poker_options(p_table, p_seat);
  if p_action = 'fold' then
    update private.poker_seats set folded = true, acted = true, last_action = 'fold' where table_id = p_table and seat = p_seat;
  elsif p_action = 'check' then
    if o.to_call > 0 then return 'You can''t check: there is a bet to call.'; end if;
    update private.poker_seats set acted = true, acted_level = h.current_bet, last_action = 'check' where table_id = p_table and seat = p_seat;
  elsif p_action = 'call' then
    if o.to_call <= 0 then return 'There is nothing to call.'; end if;
    update private.poker_seats set stack = stack - o.to_call, bet = bet + o.to_call, committed = committed + o.to_call, all_in = (stack = o.to_call),
      acted = true, acted_level = h.current_bet, last_action = case when stack = o.to_call then 'allin' else 'call' end
    where table_id = p_table and seat = p_seat;
  elsif p_action in ('bet', 'raise') then
    if p_action = 'bet' and h.current_bet > 0 then return 'There is already a bet. Call, raise or fold.'; end if;
    if p_action = 'raise' and h.current_bet = 0 then return 'Nobody has bet yet. Check or bet.'; end if;
    if not o.can_raise then return 'You can only call or fold here.'; end if;
    if p_amount is null or p_amount <> trunc(p_amount) or not (p_amount > 0 and p_amount < 1e15) then return 'Enter a whole number of chips.'; end if;
    v_target := p_amount::bigint;
    if v_target > o.max_to then return 'You don''t have that many chips.'; end if;
    if v_target < o.min_to then return format('The smallest %s here is %s.', p_action, o.min_to); end if;
    v_pay := v_target - s.bet;
    update private.poker_seats set stack = stack - v_pay, bet = v_target, committed = committed + v_pay, all_in = (stack = v_pay),
      acted = true, acted_level = v_target, last_action = case when stack = v_pay then 'allin' else p_action end
    where table_id = p_table and seat = p_seat;
    if v_target - h.current_bet >= h.last_raise then
      -- A full bet or raise: everyone else gets to act again.
      update private.poker_hands set last_raise = v_target - h.current_bet, current_bet = v_target, aggressor = p_seat where table_id = p_table;
      update private.poker_seats set acted = false where table_id = p_table and in_hand and not folded and not all_in and seat <> p_seat;
    else
      -- An all-in for less than a full raise: the bet goes up but the betting is not reopened.
      update private.poker_hands set current_bet = v_target, aggressor = p_seat where table_id = p_table;
    end if;
  else
    return 'Unknown move.';
  end if;
  return null;
end $$;

/** Returns the part of the highest bet on this round that nobody matched. */
create or replace function private.poker_refund(p_table bigint) returns void
language plpgsql volatile set search_path = '' as $$
declare v_seat int; v_top bigint; v_second bigint;
begin
  select seat, bet into v_seat, v_top from private.poker_seats where table_id = p_table and in_hand order by bet desc, seat limit 1;
  select coalesce(max(bet), 0) into v_second from private.poker_seats where table_id = p_table and in_hand and seat <> v_seat;
  if v_top > v_second then
    update private.poker_seats set bet = v_second, committed = committed - (v_top - v_second), stack = stack + (v_top - v_second), all_in = false
    where table_id = p_table and seat = v_seat;
  end if;
end $$;

/** Moves a seat's stack back to cash. Chips bought in an earlier run (before a balance reset) are dropped. */
create or replace function private.poker_cashout(p_table bigint, p_seat int) returns void
language plpgsql volatile set search_path = '' as $$
declare s private.poker_seats;
begin
  select * into s from private.poker_seats where table_id = p_table and seat = p_seat;
  if s.stack > 0 and s.user_id is not null then
    update public.portfolios set cash = cash + s.stack, updated_at = now() where user_id = s.user_id and run = s.run;
  end if;
  update private.poker_seats set stack = 0 where table_id = p_table and seat = p_seat;
end $$;

/** Between hands: frees the seats of players who left, were deleted, stayed out too long, or whose browser has gone quiet. */
create or replace function private.poker_cleanup(p_table bigint, p_base timestamptz) returns void
language plpgsql volatile set search_path = '' as $$
declare s private.poker_seats;
begin
  for s in select * from private.poker_seats where table_id = p_table and (user_id is null or leaving
      or (sitting_out and away_since + make_interval(secs => private.poker_k('away')) <= p_base)
      or seen_at + make_interval(secs => private.poker_k('away')) <= p_base) loop
    perform private.poker_cashout(p_table, s.seat);
    delete from private.poker_seats where table_id = p_table and seat = s.seat;
  end loop;
end $$;

/** Ends the hand: awards every pot, records each player's result and starts the pause before the next deal. */
create or replace function private.poker_finish(p_table bigint, p_base timestamptz) returns void
language plpgsql volatile set search_path = '' as $$
declare t public.poker_tables; h private.poker_hands; s private.poker_seats; v_live int; v_total bigint; v_prev bigint := 0; v_lvl bigint; v_max bigint;
  v_amt bigint; v_best int[]; v_winners int[]; v_n int; v_share bigint; v_rem bigint; i int; v_pots jsonb := '[]'; v_first int; v_shown_best int[];
  v_showdown boolean; v_detail text; v_feed text;
begin
  select * into t from public.poker_tables where id = p_table;
  perform private.poker_refund(p_table);
  select * into h from private.poker_hands where table_id = p_table;
  select count(*) filter (where not folded), coalesce(sum(committed), 0) into v_live, v_total from private.poker_seats where table_id = p_table and in_hand;
  v_showdown := v_live > 1;
  if not v_showdown then
    -- Everyone else folded: the pot goes to the last player, cards unseen.
    update private.poker_seats set won = v_total where table_id = p_table and in_hand and not folded returning seat into i;
    v_pots := jsonb_build_array(jsonb_build_object('amount', v_total, 'seats', jsonb_build_array(i),
      'winners', jsonb_build_array(jsonb_build_object('seat', i, 'amount', v_total))));
  else
    update private.poker_seats set hand_rank = private.poker_rank(hole || h.board) where table_id = p_table and in_hand and not folded;
    select max(committed) into v_max from private.poker_seats where table_id = p_table and in_hand and not folded;
    -- One pot per all-in level, smallest first. The last also takes anything a folded player put in above it.
    for v_lvl in select distinct committed from private.poker_seats where table_id = p_table and in_hand and not folded order by committed loop
      select coalesce(sum(least(committed, v_lvl) - least(committed, v_prev)), 0)
          + case when v_lvl = v_max then coalesce(sum(greatest(committed - v_lvl, 0)), 0) else 0 end
        into v_amt from private.poker_seats where table_id = p_table and in_hand;
      v_prev := v_lvl;
      continue when v_amt <= 0;
      select max(hand_rank) into v_best from private.poker_seats where table_id = p_table and in_hand and not folded and committed >= v_lvl;
      -- Winners in order from the button's left, which is also who gets an odd chip first.
      select array_agg(seat order by (seat - h.button + 5) % 6) into v_winners from private.poker_seats
        where table_id = p_table and in_hand and not folded and committed >= v_lvl and hand_rank = v_best;
      v_n := array_length(v_winners, 1);
      v_share := v_amt / v_n;
      v_rem := v_amt % v_n;
      for i in 1..v_n loop
        update private.poker_seats set won = won + v_share + case when i <= v_rem then 1 else 0 end where table_id = p_table and seat = v_winners[i];
      end loop;
      v_pots := v_pots || jsonb_build_object('amount', v_amt,
        'seats', (select jsonb_agg(seat order by seat) from private.poker_seats where table_id = p_table and in_hand and not folded and committed >= v_lvl),
        'winners', (select jsonb_agg(jsonb_build_object('seat', v_winners[x], 'amount', v_share + case when x <= v_rem then 1 else 0 end) order by x)
          from generate_series(1, v_n) x));
    end loop;
    -- Who shows: from the last river bettor (or the button's left), a hand that wins or is the best so far is shown, the rest are mucked.
    select seat into v_first from private.poker_seats where table_id = p_table and in_hand and not folded
      order by (seat = h.aggressor) desc nulls last, (seat - h.button + 5) % 6 limit 1;
    for s in select * from private.poker_seats where table_id = p_table and in_hand and not folded order by (seat - v_first + 6) % 6 loop
      if h.runout > 0 or s.won > 0 or v_shown_best is null or s.hand_rank >= v_shown_best then
        update private.poker_seats set shown = true where table_id = p_table and seat = s.seat;
        if v_shown_best is null or s.hand_rank > v_shown_best then v_shown_best := s.hand_rank; end if;
      end if;
    end loop;
  end if;

  -- Each player's result for the hand goes to their history and the leaderboard totals; wins also go to the feed.
  -- (A player can win without having put a chip in, when the blinds both leave before the first move.)
  for s in select * from private.poker_seats where table_id = p_table and in_hand and (committed > 0 or won > 0) and user_id is not null and run >= 0 loop
    v_detail := case
      when s.won > 0 and v_showdown then 'Won with ' || private.poker_rank_name(s.hand_rank)
      when s.won > 0 then 'Won, everyone else folded'
      when s.folded then 'Folded'
      else 'Lost with ' || private.poker_rank_name(s.hand_rank) end;
    perform private.game_record(s.user_id, s.run, 'poker', s.committed, s.won, format('%s · $%s/$%s', v_detail, t.small_blind, t.big_blind));
    if s.won > s.committed then
      v_feed := case when v_showdown then 'with ' || private.poker_rank_name(s.hand_rank) else 'when everyone else folded' end;
      perform private.game_activity(s.user_id, 'poker', s.committed, s.won - s.committed, format('%s ($%s/$%s)', v_feed, t.small_blind, t.big_blind));
    end if;
  end loop;

  update private.poker_hands set street = 'done', to_act = null, result = jsonb_build_object('showdown', v_showdown, 'pots', v_pots,
    'players', (select jsonb_agg(jsonb_build_object('seat', seat, 'won', won, 'net', won - committed) order by seat)
      from private.poker_seats where table_id = p_table and in_hand))
  where table_id = p_table;

  -- The fairness record: the seals for the whole deck, and the salts of the cards that were shown.
  insert into private.poker_proofs (table_id, hand_no, deck_hash, commits, reveals, holes) values (p_table, h.hand_no, h.deck_hash, h.commits,
    coalesce((select jsonb_agg(jsonb_build_object('i', x, 'card', h.deck[x], 'salt', h.salts[x]) order by x) from (
      select unnest(h.board_idx) as x
      union select unnest(hole_idx) from private.poker_seats where table_id = p_table and in_hand and shown) q), '[]'),
    coalesce((select jsonb_object_agg(user_id::text, (select jsonb_agg(jsonb_build_object('i', x, 'card', h.deck[x], 'salt', h.salts[x]) order by x) from unnest(hole_idx) x))
      from private.poker_seats where table_id = p_table and in_hand and user_id is not null), '{}'))
  on conflict (table_id) do update set hand_no = excluded.hand_no, deck_hash = excluded.deck_hash, commits = excluded.commits,
    reveals = excluded.reveals, holes = excluded.holes;

  update private.poker_seats set stack = stack + won, bet = 0, committed = 0 where table_id = p_table and in_hand;
  -- Out of chips: sat out until they add more (or the seat is freed).
  update private.poker_seats set sitting_out = true, away_since = coalesce(away_since, p_base)
  where table_id = p_table and stack = 0 and not leaving and user_id is not null;
  update public.poker_tables set deadline = p_base + make_interval(secs => private.poker_k('pause') + case when h.runout > 0 then private.poker_k('runout') else 0 end)
  where id = p_table;
end $$;

/**
 * After a move or a deal: gives the turn to the next player who has something
 * to decide, or closes the betting round (dealing the next cards), or ends the
 * hand. Players who are gone or sat out are checked or folded on the spot.
 */
create or replace function private.poker_progress(p_table bigint, p_from int, p_base timestamptz) returns void
language plpgsql volatile set search_path = '' as $$
declare t public.poker_tables; h private.poker_hands; s private.poker_seats; v_live int; v_active int; v_owing int; v_from int := p_from; v_n int;
  v_runout boolean; guard int := 0;
begin
  select * into t from public.poker_tables where id = p_table;
  loop
    guard := guard + 1;
    if guard > 80 then raise exception 'The hand did not settle.'; end if;
    select * into h from private.poker_hands where table_id = p_table;
    select count(*) filter (where not folded), count(*) filter (where not folded and not all_in)
      into v_live, v_active from private.poker_seats where table_id = p_table and in_hand;
    if v_live <= 1 then
      perform private.poker_finish(p_table, p_base);
      return;
    end if;
    -- Whether the one player who can still bet has an all-in bet above their own to answer.
    select count(*) into v_owing from private.poker_seats a where a.table_id = p_table and a.in_hand and not a.folded and not a.all_in
      and a.bet < (select coalesce(max(b.bet), 0) from private.poker_seats b where b.table_id = p_table and b.in_hand and not b.folded and b.seat <> a.seat);
    s := null;
    -- With one player left who can bet and nothing for them to call, there is no betting to do.
    if v_active > 1 or v_owing > 0 then
      select * into s from private.poker_seats where table_id = p_table and in_hand and not folded and not all_in
        and (not acted or bet < h.current_bet) order by (seat - v_from + 5) % 6 limit 1;
    end if;
    if s.seat is not null then
      if s.user_id is null or s.leaving or s.timeouts >= private.poker_k('timeouts') then
        perform private.poker_apply(p_table, s.seat, case when s.bet >= h.current_bet then 'check' else 'fold' end, null);
        v_from := s.seat;
        continue;
      end if;
      update private.poker_hands set to_act = s.seat, turn = turn + 1 where table_id = p_table;
      update public.poker_tables set deadline = p_base + make_interval(secs => private.poker_k('turn')) where id = p_table;
      return;
    end if;

    -- The betting round is over.
    perform private.poker_refund(p_table);
    if h.street = 'river' then
      perform private.poker_finish(p_table, p_base);
      return;
    end if;
    select count(*) filter (where not folded and not all_in) <= 1 into v_runout from private.poker_seats where table_id = p_table and in_hand;
    -- Burn one, then deal three for the flop or one for the turn and river.
    v_n := case when h.street = 'preflop' then 3 else 1 end;
    update private.poker_hands set
      street = case h.street when 'preflop' then 'flop' when 'flop' then 'turn' else 'river' end,
      board = board || deck[next_card + 2 : next_card + 1 + v_n],
      board_idx = board_idx || (select array_agg(x) from generate_series(h.next_card + 2, h.next_card + 1 + v_n) x),
      next_card = next_card + 1 + v_n,
      current_bet = 0, last_raise = t.big_blind, aggressor = null, to_act = null,
      runout = runout + case when v_runout then v_n else 0 end
    where table_id = p_table;
    update private.poker_seats set bet = 0, acted = false, acted_level = 0, last_action = case when folded or all_in then last_action end
    where table_id = p_table and in_hand;
    v_from := h.button;
  end loop;
end $$;

/** Deals a new hand if at least two players are ready. Returns false (and deals nothing) otherwise. */
create or replace function private.poker_start(p_table bigint, p_base timestamptz) returns boolean
language plpgsql volatile set search_path = '' as $$
declare t public.poker_tables; h private.poker_hands; n int; v_button int; v_sb int; v_bb int; v_deck text[]; v_salts text[] := '{}';
  v_commits text[] := '{}'; i int; k int := 0; r record;
begin
  select * into t from public.poker_tables where id = p_table;
  select * into h from private.poker_hands where table_id = p_table;
  update private.poker_seats set in_hand = user_id is not null and not sitting_out and not leaving and stack > 0,
    folded = false, all_in = false, bet = 0, committed = 0, acted = false, acted_level = 0,
    hole = null, hole_idx = null, hand_rank = null, shown = false, won = 0, last_action = null
  where table_id = p_table;
  select count(*) into n from private.poker_seats where table_id = p_table and in_hand;
  if n < 2 then
    update private.poker_seats set in_hand = false where table_id = p_table and in_hand;
    return false;
  end if;
  if h.table_id is null then
    select seat into v_button from private.poker_seats where table_id = p_table and in_hand order by seat offset private.rand_int(n) limit 1;
  else
    select seat into v_button from private.poker_seats where table_id = p_table and in_hand order by (seat - h.button + 5) % 6 limit 1;
  end if;
  if n = 2 then
    v_sb := v_button;
  else
    select seat into v_sb from private.poker_seats where table_id = p_table and in_hand order by (seat - v_button + 5) % 6 limit 1;
  end if;
  select seat into v_bb from private.poker_seats where table_id = p_table and in_hand order by (seat - v_sb + 5) % 6 limit 1;

  v_deck := private.poker_shuffle();
  for i in 1..52 loop
    v_salts := v_salts || encode(extensions.gen_random_bytes(16), 'hex');
    v_commits := v_commits || encode(extensions.digest(v_salts[i] || ':' || v_deck[i], 'sha256'), 'hex');
  end loop;
  -- One card each from the button's left, twice round.
  for r in select seat from private.poker_seats where table_id = p_table and in_hand order by (seat - v_button + 5) % 6 loop
    update private.poker_seats set hole = array[v_deck[k + 1], v_deck[n + k + 1]], hole_idx = array[k + 1, n + k + 1]
    where table_id = p_table and seat = r.seat;
    k := k + 1;
  end loop;
  update private.poker_seats set bet = least(stack, t.small_blind), committed = least(stack, t.small_blind), all_in = stack <= t.small_blind,
    stack = stack - least(stack, t.small_blind), last_action = 'sb' where table_id = p_table and seat = v_sb;
  update private.poker_seats set bet = least(stack, t.big_blind), committed = least(stack, t.big_blind), all_in = stack <= t.big_blind,
    stack = stack - least(stack, t.big_blind), last_action = 'bb' where table_id = p_table and seat = v_bb;

  delete from private.poker_hands where table_id = p_table;
  insert into private.poker_hands (table_id, hand_no, street, deck, salts, commits, deck_hash, next_card, button, sb_seat, bb_seat,
    current_bet, last_raise, turn, started_at)
  values (p_table, t.hand_no + 1, 'preflop', v_deck, v_salts, v_commits, encode(extensions.digest(array_to_string(v_commits, ','), 'sha256'), 'hex'),
    2 * n, v_button, v_sb, v_bb, t.big_blind, t.big_blind, coalesce(h.turn, 0), p_base);
  update public.poker_tables set hand_no = hand_no + 1 where id = p_table;
  perform private.poker_progress(p_table, v_bb, p_base);
  return true;
end $$;

/**
 * When a table with no hand to deal should next be looked at: as soon as a
 * player who is sitting out has been gone long enough to lose the seat, and
 * otherwise every few minutes while anyone is seated, to free the seats of
 * players whose browsers have gone. Null for an empty table.
 */
create or replace function private.poker_idle_check(p_table bigint, p_base timestamptz) returns timestamptz
language sql stable set search_path = '' as $$
  select case when count(*) > 0 then least(
    min(away_since + make_interval(secs => private.poker_k('away'))) filter (where sitting_out),
    p_base + make_interval(secs => private.poker_k('away'))) end
  from private.poker_seats where table_id = p_table
$$;

/** No hand to deal: clears the felt and sets the next look at the table, if anyone is seated. */
create or replace function private.poker_idle(p_table bigint, p_base timestamptz) returns void
language plpgsql volatile set search_path = '' as $$
begin
  update private.poker_hands set street = 'idle', to_act = null, result = null where table_id = p_table;
  update public.poker_tables set deadline = private.poker_idle_check(p_table, p_base) where id = p_table;
end $$;

/** Notes that a seated player's browser is still there (written at most every 30 seconds). */
create or replace function private.poker_seen(p_table bigint, p_user uuid) returns void
language sql volatile set search_path = '' as $$
  update private.poker_seats set seen_at = now() where table_id = p_table and user_id = p_user and seen_at < now() - interval '30 seconds'
$$;

/** A player sat down, came back or added chips: starts the countdown to a deal once two are ready. */
create or replace function private.poker_wake(p_table bigint) returns void
language plpgsql volatile set search_path = '' as $$
declare h private.poker_hands; v_ready int;
begin
  select * into h from private.poker_hands where table_id = p_table;
  -- A hand in play or just finished already has its own deadline.
  if h.table_id is not null and h.street <> 'idle' then return; end if;
  select count(*) into v_ready from private.poker_seats where table_id = p_table and user_id is not null and not sitting_out and not leaving and stack > 0;
  if v_ready >= 2 then
    update public.poker_tables set deadline = now() + make_interval(secs => private.poker_k('start'))
    where id = p_table and (deadline is null or deadline > now() + make_interval(secs => private.poker_k('start')));
  else
    update public.poker_tables set deadline = private.poker_idle_check(p_table, now()) where id = p_table;
  end if;
end $$;

/** Chips collected on earlier betting rounds, split into the main pot and side pots (amounts only). */
create or replace function private.poker_pots(p_table bigint) returns jsonb
language plpgsql stable set search_path = '' as $$
declare v_lvl bigint; v_prev bigint := 0; v_max bigint; v_amt bigint; v_out jsonb := '[]';
begin
  select max(committed - bet) into v_max from private.poker_seats where table_id = p_table and in_hand and not folded;
  for v_lvl in select distinct committed - bet from private.poker_seats where table_id = p_table and in_hand and not folded and committed > bet order by 1 loop
    select coalesce(sum(least(committed - bet, v_lvl) - least(committed - bet, v_prev)), 0)
        + case when v_lvl = v_max then coalesce(sum(greatest(committed - bet - v_lvl, 0)), 0) else 0 end
      into v_amt from private.poker_seats where table_id = p_table and in_hand;
    v_prev := v_lvl;
    if v_amt > 0 then v_out := v_out || to_jsonb(v_amt); end if;
  end loop;
  return v_out;
end $$;

/**
 * Rebuilds the public state of a table from an explicit list of fields and
 * bumps its version. A player's cards are included only when the hand is
 * over and they were shown; the deck, burn cards and mucked hands never are.
 */
create or replace function private.poker_publish(p_table bigint) returns void
language plpgsql volatile set search_path = '' as $$
declare t public.poker_tables; h private.poker_hands; o record; v_phase text; v_live boolean; v_seats jsonb; v_act jsonb;
begin
  select * into t from public.poker_tables where id = p_table;
  select * into h from private.poker_hands where table_id = p_table;
  v_phase := case when h.table_id is null or h.street = 'idle' then 'waiting' when h.street = 'done' then 'showdown' else h.street end;
  v_live := v_phase not in ('waiting', 'showdown');
  select jsonb_agg(case when s.seat is null then null else jsonb_build_object(
      'name', s.username, 'stack', s.stack, 'bet', s.bet, 'inHand', s.in_hand and v_phase <> 'waiting', 'folded', s.folded, 'allIn', s.all_in,
      'away', s.sitting_out, 'left', s.leaving or s.user_id is null, 'last', s.last_action,
      'cards', case when v_phase = 'showdown' and s.shown then to_jsonb(s.hole) end,
      'rank', case when v_phase = 'showdown' and s.shown then to_jsonb(s.hand_rank) end,
      'won', case when v_phase = 'showdown' then s.won else 0 end) end order by g.n)
    into v_seats from generate_series(0, t.max_seats - 1) g(n) left join private.poker_seats s on s.table_id = p_table and s.seat = g.n;
  if v_live and h.to_act is not null then
    select * into o from private.poker_options(p_table, h.to_act);
    v_act := jsonb_build_object('seat', h.to_act, 'toCall', o.to_call, 'canRaise', o.can_raise, 'minRaise', o.min_to, 'maxRaise', o.max_to);
  end if;
  update public.poker_tables set version = version + 1, updated_at = now(),
    seated = (select count(*) from private.poker_seats where table_id = p_table and user_id is not null and not leaving),
    state = jsonb_build_object(
      'phase', v_phase,
      'hand', t.hand_no,
      'button', case when v_phase <> 'waiting' then h.button end,
      'sb', case when v_phase <> 'waiting' then h.sb_seat end,
      'bb', case when v_phase <> 'waiting' then h.bb_seat end,
      'board', case when v_phase <> 'waiting' then to_jsonb(h.board) else '[]'::jsonb end,
      'pot', case when v_live then (select coalesce(sum(committed), 0) from private.poker_seats where table_id = p_table and in_hand) else 0 end,
      'pots', case when v_live then private.poker_pots(p_table) else '[]'::jsonb end,
      'bet', case when v_live then h.current_bet else 0 end,
      'act', v_act,
      'turn', coalesce(h.turn, 0),
      'runout', case when v_phase = 'showdown' then h.runout else 0 end,
      'deadline', private.ms(t.deadline),
      'deckHash', case when v_phase <> 'waiting' then h.deck_hash end,
      'result', case when v_phase = 'showdown' then h.result end,
      'seats', v_seats)
  where id = p_table;
end $$;

/**
 * Plays out everything whose time has come: turns that ran out (check if
 * free, else fold; two in a row sit the player out), the deal after a
 * finished hand, and idle seats to free. Returns true when anything changed.
 */
create or replace function private.poker_advance(p_table bigint) returns boolean
language plpgsql volatile set search_path = '' as $$
declare t public.poker_tables; h private.poker_hands; s private.poker_seats; v_due timestamptz; v_changed boolean := false; guard int := 0;
begin
  loop
    select * into t from public.poker_tables where id = p_table;
    exit when t.deadline is null or t.deadline + make_interval(secs => private.poker_k('grace')) > now();
    -- A table left for a very long time catches up over a few calls rather than in one.
    guard := guard + 1;
    exit when guard > 400;
    v_due := t.deadline;
    v_changed := true;
    select * into h from private.poker_hands where table_id = p_table;
    if h.table_id is not null and h.street not in ('done', 'idle') then
      if h.to_act is null then
        perform private.poker_progress(p_table, h.button, v_due);
        continue;
      end if;
      select * into s from private.poker_seats where table_id = p_table and seat = h.to_act;
      perform private.poker_apply(p_table, h.to_act, case when s.bet >= h.current_bet then 'check' else 'fold' end, null);
      update private.poker_seats set timeouts = timeouts + 1,
        sitting_out = sitting_out or timeouts + 1 >= private.poker_k('timeouts'),
        away_since = case when timeouts + 1 >= private.poker_k('timeouts') then coalesce(away_since, v_due) else away_since end
      where table_id = p_table and seat = h.to_act;
      perform private.poker_progress(p_table, h.to_act, v_due);
    else
      perform private.poker_cleanup(p_table, v_due);
      if not private.poker_start(p_table, v_due) then perform private.poker_idle(p_table, v_due); end if;
    end if;
  end loop;
  if v_changed then perform private.poker_publish(p_table); end if;
  return v_changed;
end $$;

/**
 * Takes a player off the table. Mid-hand they fold first (an all-in player
 * stays in for the pots they can win); the seat itself is freed when the hand
 * is over. With p_refund the stack goes back to cash, otherwise it is dropped
 * (a balance reset or a deleted account).
 */
create or replace function private.poker_remove(p_table bigint, p_seat int, p_refund boolean) returns void
language plpgsql volatile set search_path = '' as $$
declare h private.poker_hands; s private.poker_seats; v_active boolean;
begin
  select * into h from private.poker_hands where table_id = p_table;
  select * into s from private.poker_seats where table_id = p_table and seat = p_seat;
  if s.seat is null then return; end if;
  v_active := h.table_id is not null and h.street not in ('done', 'idle');
  if not p_refund then
    update private.poker_seats set stack = 0, run = -1 where table_id = p_table and seat = p_seat;
  end if;
  if h.table_id is null or h.street = 'idle' or not s.in_hand then
    perform private.poker_cashout(p_table, p_seat);
    delete from private.poker_seats where table_id = p_table and seat = p_seat;
    return;
  end if;
  update private.poker_seats set leaving = true where table_id = p_table and seat = p_seat;
  if v_active and not s.folded and not s.all_in then
    perform private.poker_apply(p_table, p_seat, 'fold', null);
    if h.to_act = p_seat then
      perform private.poker_progress(p_table, p_seat, now());
    elsif (select count(*) from private.poker_seats where table_id = p_table and in_hand and not folded) <= 1 then
      -- Folding out of turn left one player standing.
      perform private.poker_finish(p_table, now());
    end if;
  end if;
  -- Chips no longer at risk go back now. An all-in player's winnings follow when the seat is freed.
  select * into h from private.poker_hands where table_id = p_table;
  if h.street = 'done' or (select folded from private.poker_seats where table_id = p_table and seat = p_seat) then
    perform private.poker_cashout(p_table, p_seat);
  end if;
end $$;

/** Takes a player off whatever table they are at, dropping their chips (see reset_balance and delete_account). */
create or replace function private.poker_evict(p_user uuid) returns void
language plpgsql volatile set search_path = '' as $$
declare v_table bigint; s private.poker_seats;
begin
  select table_id into v_table from private.poker_seats where user_id = p_user;
  if v_table is null then return; end if;
  perform 1 from public.poker_tables where id = v_table for update;
  select * into s from private.poker_seats where table_id = v_table and user_id = p_user;
  if s.seat is null then return; end if;
  perform private.poker_remove(v_table, s.seat, false);
  perform private.poker_wake(v_table);
  perform private.poker_publish(v_table);
end $$;

/** Keeps a table with a free seat open at every stake, adding one when they are all full. */
create or replace function private.poker_ensure_tables() returns void
language plpgsql volatile set search_path = '' as $$
declare st record; v_id bigint;
begin
  -- One caller at a time, so a burst of visitors can't open a row of empty tables.
  if not pg_try_advisory_xact_lock(hashtext('poker-tables')) then return; end if;
  for st in select * from private.poker_stakes() loop
    if not exists (select 1 from public.poker_tables where stake = st.stake and seated < max_seats) then
      insert into public.poker_tables (stake, small_blind, big_blind, min_buy, max_buy)
      values (st.stake, st.small_blind, st.big_blind, st.min_buy, st.max_buy) returning id into v_id;
      perform private.poker_publish(v_id);
    end if;
  end loop;
end $$;

/**
 * The backstop for tables nobody is watching: plays out overdue turns, and
 * closes spare empty tables (one with a free seat always stays open per
 * stake). Cheap when there is nothing to do: one indexed lookup.
 */
create or replace function private.poker_sweep() returns int
language plpgsql volatile set search_path = '' as $$
declare r record; n int := 0;
begin
  for r in select id from public.poker_tables where deadline is not null and deadline < now() - interval '3 seconds'
      order by deadline limit 50 for update skip locked loop
    if private.poker_advance(r.id) then n := n + 1; end if;
  end loop;
  delete from public.poker_tables where id in (
    select t.id from public.poker_tables t
    where t.seated = 0 and t.updated_at < now() - interval '10 minutes'
      and not exists (select 1 from private.poker_seats s where s.table_id = t.id)
      and (t.stake not in (select stake from private.poker_stakes())
        or exists (select 1 from public.poker_tables o where o.stake = t.stake and o.id < t.id and o.seated < o.max_seats))
    for update of t skip locked);
  perform private.poker_ensure_tables();
  return n;
end $$;

/** A table as one player sees it: the public state plus their own seat and cards. */
create or replace function private.poker_view(p_table bigint, p_user uuid) returns jsonb
language sql volatile set search_path = '' as $$
  select jsonb_build_object(
    'table', jsonb_build_object('id', t.id, 'stake', t.stake, 'smallBlind', t.small_blind, 'bigBlind', t.big_blind,
      'minBuy', t.min_buy, 'maxBuy', t.max_buy, 'seats', t.max_seats, 'version', t.version, 'state', t.state),
    'me', (select jsonb_build_object('seat', s.seat, 'stack', s.stack, 'cards', case when s.in_hand then to_jsonb(s.hole) end,
        'away', s.sitting_out, 'left', s.leaving)
      from private.poker_seats s where s.table_id = p_table and s.user_id = p_user),
    'now', private.now_ms())
  from public.poker_tables t where t.id = p_table
$$;

-- What the browser calls. Refusals come back as { "error": "..." } rather than
-- being raised, so the turns played out on the way in (and the rate limit) are kept.

/** The lobby: every open table with its stakes and seats filled, and where the caller is seated. */
create or replace function public.poker_lobby() returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid();
begin
  perform private.rate_limit(v_user, 'poker-lobby', 40);
  perform private.poker_sweep();
  return jsonb_build_object(
    'tables', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'stake', t.stake, 'smallBlind', t.small_blind, 'bigBlind', t.big_blind,
        'minBuy', t.min_buy, 'maxBuy', t.max_buy, 'seats', t.max_seats, 'seated', t.seated,
        'players', (select coalesce(jsonb_agg(x -> 'name'), '[]') from jsonb_array_elements(t.state -> 'seats') x where x <> 'null' and not (x ->> 'left')::boolean))
      order by t.big_blind, t.id) from public.poker_tables t), '[]'),
    'seat', (select jsonb_build_object('table', s.table_id, 'stack', s.stack) from private.poker_seats s where s.user_id = v_user and not s.leaving),
    'canSit', not private.is_guest(v_user));
end $$;

/** The caller's view of a table. Also plays out any turn whose time is up. */
create or replace function public.poker_state(p_table bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); t public.poker_tables;
begin
  perform private.rate_limit(v_user, 'poker-state', 150);
  select * into t from public.poker_tables where id = p_table;
  if t.id is null then return jsonb_build_object('error', 'That table has closed.', 'closed', true); end if;
  if t.deadline is not null and t.deadline + make_interval(secs => private.poker_k('grace')) <= now() then
    perform 1 from public.poker_tables where id = p_table for update;
    perform private.poker_advance(p_table);
  end if;
  perform private.poker_seen(p_table, v_user);
  return private.poker_view(p_table, v_user);
end $$;

/**
 * The clock push. Browsers call it when a deadline they can see has passed;
 * it plays out the turn (or deals the next hand) and returns the new version.
 * The new state itself reaches everyone over Realtime.
 */
create or replace function public.poker_tick(p_table bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); t public.poker_tables;
begin
  perform private.rate_limit(v_user, 'poker-tick', 60);
  select * into t from public.poker_tables where id = p_table;
  if t.id is null then return jsonb_build_object('error', 'That table has closed.', 'closed', true); end if;
  if t.deadline is not null and t.deadline + make_interval(secs => private.poker_k('grace')) <= now() then
    perform 1 from public.poker_tables where id = p_table for update;
    perform private.poker_advance(p_table);
  end if;
  perform private.poker_seen(p_table, v_user);
  return (select jsonb_build_object('version', version) from public.poker_tables where id = p_table);
end $$;

/** Takes a seat with a buy-in from cash. p_seat picks a seat (0 to 5); null takes the first free one. */
create or replace function public.poker_sit(p_table bigint, p_buy_in numeric, p_seat int default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); t public.poker_tables; pf public.portfolios; v_seat int; v_amt bigint; v_err text;
begin
  perform private.rate_limit(v_user, 'poker-seat', 30);
  select * into t from public.poker_tables where id = p_table for update;
  if t.id is null then return jsonb_build_object('error', 'That table has closed.', 'closed', true); end if;
  perform private.poker_advance(p_table);
  select * into pf from public.portfolios where user_id = v_user for update;
  if private.is_guest(v_user) then v_err := 'Sign up to take a seat. Guests can watch.';
  elsif exists (select 1 from private.poker_seats where user_id = v_user and leaving) then v_err := 'Your last hand is still finishing. Try again in a moment.';
  elsif exists (select 1 from private.poker_seats where user_id = v_user) then v_err := 'You already have a seat. Leave that table first.';
  elsif p_buy_in is null or p_buy_in <> trunc(p_buy_in) or not (p_buy_in >= t.min_buy and p_buy_in <= t.max_buy) then
    v_err := format('Buy in for $%s to $%s, in whole dollars.', t.min_buy, t.max_buy);
  elsif p_buy_in > pf.cash then v_err := 'Not enough cash for that buy-in.';
  elsif p_seat is not null and (p_seat < 0 or p_seat >= t.max_seats) then v_err := 'Pick a seat at this table.';
  elsif p_seat is not null and exists (select 1 from private.poker_seats where table_id = p_table and seat = p_seat) then v_err := 'That seat was just taken.';
  end if;
  if v_err is null then
    v_seat := coalesce(p_seat, (select g from generate_series(0, t.max_seats - 1) g
      where not exists (select 1 from private.poker_seats where table_id = p_table and seat = g) order by g limit 1));
    if v_seat is null then v_err := 'This table is full.'; end if;
  end if;
  if v_err is not null then return private.poker_view(p_table, v_user) || jsonb_build_object('error', v_err); end if;
  v_amt := p_buy_in::bigint;
  update public.portfolios set cash = cash - v_amt, updated_at = now() where user_id = v_user;
  insert into private.poker_seats (table_id, seat, user_id, username, run, stack) values (p_table, v_seat, v_user, private.username_of(v_user), pf.run, v_amt);
  perform private.poker_wake(p_table);
  perform private.poker_publish(p_table);
  -- That may have filled the last open table at this stake.
  perform private.poker_ensure_tables();
  return private.poker_view(p_table, v_user) || jsonb_build_object('portfolio', private.portfolio_json(v_user));
end $$;

/** Leaves the table: folds any live hand and moves the stack back to cash. */
create or replace function public.poker_leave(p_table bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s private.poker_seats;
begin
  perform private.rate_limit(v_user, 'poker-seat', 30);
  perform 1 from public.poker_tables where id = p_table for update;
  if not found then return jsonb_build_object('error', 'That table has closed.', 'closed', true); end if;
  perform private.poker_advance(p_table);
  select * into s from private.poker_seats where table_id = p_table and user_id = v_user and not leaving;
  if s.seat is null then return private.poker_view(p_table, v_user) || jsonb_build_object('error', 'You are not seated at this table.'); end if;
  perform private.poker_remove(p_table, s.seat, true);
  perform private.poker_wake(p_table);
  perform private.poker_publish(p_table);
  return private.poker_view(p_table, v_user) || jsonb_build_object('portfolio', private.portfolio_json(v_user));
end $$;

/**
 * A move: fold, check, call, bet or raise. p_amount is the total to have in on
 * this betting round (for bet and raise). p_turn, when sent, is the turn the
 * player was looking at: a late or repeated click for an earlier turn is
 * ignored instead of being played as the next decision.
 */
create or replace function public.poker_act(p_table bigint, p_action text, p_amount numeric default null, p_turn int default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); h private.poker_hands; s private.poker_seats; v_err text;
begin
  perform private.rate_limit(v_user, 'poker-act', 90);
  perform 1 from public.poker_tables where id = p_table for update;
  if not found then return jsonb_build_object('error', 'That table has closed.', 'closed', true); end if;
  perform private.poker_advance(p_table);
  select * into h from private.poker_hands where table_id = p_table;
  select * into s from private.poker_seats where table_id = p_table and user_id = v_user;
  if s.seat is null then v_err := 'Take a seat first.';
  elsif h.table_id is null or h.street in ('done', 'idle') or h.to_act is distinct from s.seat or s.leaving then v_err := 'It is not your turn.';
  elsif p_turn is not null and p_turn <> h.turn then v_err := 'That move was for an earlier turn.';
  else v_err := private.poker_apply(p_table, s.seat, coalesce(p_action, ''), p_amount);
  end if;
  if v_err is not null then return private.poker_view(p_table, v_user) || jsonb_build_object('error', v_err); end if;
  update private.poker_seats set timeouts = 0, seen_at = now() where table_id = p_table and seat = s.seat;
  perform private.poker_progress(p_table, s.seat, now());
  perform private.poker_publish(p_table);
  return private.poker_view(p_table, v_user);
end $$;

/** Sits out from the next hand (p_away true), or comes back. */
create or replace function public.poker_away(p_table bigint, p_away boolean) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); s private.poker_seats;
begin
  perform private.rate_limit(v_user, 'poker-seat', 30);
  perform 1 from public.poker_tables where id = p_table for update;
  if not found then return jsonb_build_object('error', 'That table has closed.', 'closed', true); end if;
  perform private.poker_advance(p_table);
  select * into s from private.poker_seats where table_id = p_table and user_id = v_user and not leaving;
  if s.seat is null then return private.poker_view(p_table, v_user) || jsonb_build_object('error', 'You are not seated at this table.'); end if;
  if coalesce(p_away, false) then
    update private.poker_seats set sitting_out = true, away_since = coalesce(away_since, now()), seen_at = now() where table_id = p_table and seat = s.seat;
  elsif s.stack = 0 and not s.in_hand then
    return private.poker_view(p_table, v_user) || jsonb_build_object('error', 'Add chips to play again.');
  else
    update private.poker_seats set sitting_out = false, away_since = null, timeouts = 0, seen_at = now() where table_id = p_table and seat = s.seat;
  end if;
  perform private.poker_wake(p_table);
  perform private.poker_publish(p_table);
  return private.poker_view(p_table, v_user);
end $$;

/** Adds chips from cash between hands, up to the table's largest buy-in. */
create or replace function public.poker_buy(p_table bigint, p_amount numeric) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); t public.poker_tables; h private.poker_hands; s private.poker_seats; pf public.portfolios; v_err text;
begin
  perform private.rate_limit(v_user, 'poker-seat', 30);
  select * into t from public.poker_tables where id = p_table for update;
  if t.id is null then return jsonb_build_object('error', 'That table has closed.', 'closed', true); end if;
  perform private.poker_advance(p_table);
  select * into h from private.poker_hands where table_id = p_table;
  select * into s from private.poker_seats where table_id = p_table and user_id = v_user and not leaving;
  select * into pf from public.portfolios where user_id = v_user for update;
  if s.seat is null then v_err := 'You are not seated at this table.';
  elsif h.table_id is not null and h.street not in ('done', 'idle') and s.in_hand and not s.folded then v_err := 'You can add chips once this hand is over.';
  elsif s.run <> pf.run then v_err := 'Leave the table and sit down again to buy in.';
  elsif p_amount is null or p_amount <> trunc(p_amount) or not (p_amount >= 1 and p_amount < 1e15) then v_err := 'Enter a whole number of chips.';
  elsif s.stack + p_amount > t.max_buy then v_err := format('You can have up to $%s in front of you when adding chips.', t.max_buy);
  elsif s.stack + p_amount < t.min_buy then v_err := format('Bring your stack to at least $%s.', t.min_buy);
  elsif p_amount > pf.cash then v_err := 'Not enough cash for that.';
  end if;
  if v_err is not null then return private.poker_view(p_table, v_user) || jsonb_build_object('error', v_err); end if;
  update public.portfolios set cash = cash - p_amount, updated_at = now() where user_id = v_user;
  update private.poker_seats set stack = stack + p_amount::bigint, sitting_out = false, away_since = null, timeouts = 0, seen_at = now()
  where table_id = p_table and seat = s.seat;
  perform private.poker_wake(p_table);
  perform private.poker_publish(p_table);
  return private.poker_view(p_table, v_user) || jsonb_build_object('portfolio', private.portfolio_json(v_user));
end $$;

/**
 * The fairness record of the last finished hand at a table: the 52 seals whose
 * hash was published before the deal, and the card and salt behind each seal
 * that was shown (the board, hands shown at showdown, and the caller's own two
 * cards). src/games/poker.js verifyProof() checks them in the browser.
 */
create or replace function public.poker_proof(p_table bigint) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare v_user uuid := private.uid(); p private.poker_proofs;
begin
  perform private.rate_limit(v_user, 'poker-proof', 20);
  select * into p from private.poker_proofs where table_id = p_table;
  if p.table_id is null then return jsonb_build_object('error', 'No finished hand to check yet.'); end if;
  return jsonb_build_object('hand', p.hand_no, 'deckHash', p.deck_hash, 'commits', to_jsonb(p.commits),
    'reveals', (select coalesce(jsonb_agg(distinct x), '[]') from jsonb_array_elements(p.reveals || coalesce(p.holes -> v_user::text, '[]')) x));
end $$;

-- A table with a free seat at every stake, from the first run on.
do $$ begin
  perform private.poker_ensure_tables();
end $$;

-- ---------------------------------------------------------------------------
-- A reliable 5-minute sync
--
-- The database starts the sync itself every 5 minutes with pg_cron and pg_net,
-- by calling this project's sync function (supabase/functions/sync), so nothing
-- depends on GitHub's schedule or a GitHub token.
-- ---------------------------------------------------------------------------

/**
 * Lets a sync run start at most once every 4 minutes. The sync function
 * (supabase/functions/sync) takes no key, so this is what keeps extra calls
 * from doing anything. Only the service role (the function itself) may call it.
 */
create table if not exists private.sync_state (
  id int primary key default 1 check (id = 1),
  started_at timestamptz not null default '-infinity'
);
insert into private.sync_state (id) values (1) on conflict (id) do nothing;

create or replace function public.sync_claim() returns boolean
language plpgsql volatile security definer set search_path = '' as $$
declare v_ok boolean;
begin
  update private.sync_state set started_at = now() where id = 1 and started_at < now() - interval '4 minutes'
  returning true into v_ok;
  return coalesce(v_ok, false);
end $$;

/** Starts the sync function now. Returns the pg_net request id, or null when it can't. */
create or replace function private.dispatch_sync() returns bigint
language plpgsql volatile security definer set search_path = '' as $$
declare v_id bigint;
begin
  select net.http_post(
    -- This project's sync function (deployed by .github/workflows/deploy-sync.yml).
    url := 'https://ksyzpzbdlwinoirnprso.supabase.co/functions/v1/sync',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    timeout_milliseconds := 10000
  ) into v_id;
  return v_id;
exception when others then
  raise warning 'dispatch_sync failed: %', sqlerrm;
  return null;
end $$;

-- Every 5 minutes, when pg_cron and pg_net are available (they are on Supabase; turn them on under
-- Database > Extensions if this notice says otherwise). Re-running this file updates the same job.
do $$ begin
  begin
    execute 'create extension if not exists pg_net';
  exception when others then null;
  end;
  begin
    execute 'create extension if not exists pg_cron';
  exception when others then null;
  end;
  if exists (select 1 from pg_extension where extname = 'pg_cron') and exists (select 1 from pg_extension where extname = 'pg_net') then
    perform cron.schedule('chami-sync', '*/5 * * * *', 'select private.dispatch_sync()');
  else
    raise notice 'Faster sync is off: turn on the pg_cron and pg_net extensions, then run this file again.';
  end if;
exception when others then
  raise notice 'Faster sync is off: %', sqlerrm;
end $$;

-- Tables: a once-a-minute backstop that plays out overdue turns at tables nobody is watching
-- (players' own browsers keep the clock the rest of the time). It does one indexed lookup when idle.
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('chami-tables', '* * * * *', 'select private.poker_sweep()');
  else
    raise notice 'Tables run without the pg_cron backstop: turn on the pg_cron extension, then run this file again.';
  end if;
exception when others then
  raise notice 'Tables run without the pg_cron backstop: %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------

revoke all on all functions in schema private from public;

-- The app talks to the REST API only. GraphQL can run several game calls in one
-- transaction, which would let a later call undo an earlier losing one, so it's off.
do $$ begin
  execute 'drop extension if exists pg_graphql';
exception when others then
  begin
    execute 'revoke usage on schema graphql, graphql_public from anon, authenticated';
  exception when others then null;
  end;
end $$;
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.claim_guest(text) to authenticated;
grant execute on function public.reset_password_with_code(text, text, text) to anon, authenticated;
grant execute on function public.leaderboard() to anon, authenticated;
grant execute on function public.submit_feedback(text, text, text) to anon, authenticated;
grant execute on function
  public.get_portfolio(),
  public.create_recovery_code(),
  public.buy(text, text, numeric, numeric),
  public.sell(text, text, numeric, numeric),
  public.reset_balance(),
  public.delete_account(text),
  public.check_market(text),
  public.play_roulette(jsonb),
  public.play_plinko(numeric, int, text, int),
  public.blackjack_state(),
  public.blackjack_deal(numeric),
  public.blackjack_act(text),
  public.fair_state(),
  public.play_dice(numeric, numeric, boolean),
  public.play_limbo(numeric, numeric),
  public.crash_start(numeric, numeric),
  public.crash_state(),
  public.crash_cashout(),
  public.play_slots(numeric),
  public.mines_state(),
  public.mines_start(numeric, int),
  public.mines_reveal(int),
  public.mines_cashout(),
  public.mines_auto(numeric, int, int[]),
  public.chicken_state(),
  public.chicken_start(numeric, text),
  public.chicken_step(),
  public.chicken_cashout(),
  public.chicken_auto(numeric, text, int),
  public.poker_lobby(),
  public.poker_state(bigint),
  public.poker_tick(bigint),
  public.poker_sit(bigint, numeric, int),
  public.poker_leave(bigint),
  public.poker_act(bigint, text, numeric, int),
  public.poker_away(bigint, boolean),
  public.poker_buy(bigint, numeric),
  public.poker_proof(bigint)
to authenticated;

do $$ begin
  grant execute on function public.sync_markets(jsonb), public.sync_resolutions(jsonb), public.held_markets(), public.sync_snapshots(),
    public.sync_claim() to service_role;
exception when undefined_object then null;
end $$;
