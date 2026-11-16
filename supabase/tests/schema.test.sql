-- Tests for supabase/schema.sql on a plain Postgres with supabase-stub.sql.
-- Run with: npm run test:db
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;

create or replace function pg_temp.expect_error(p_sql text, p_like text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm ilike p_like then return; end if;
    raise exception 'expected error like "%" from %, got "%"', p_like, p_sql, sqlerrm;
  end;
  raise exception 'expected an error like "%" from %', p_like, p_sql;
end $$;
grant execute on function pg_temp.expect_error(text, text) to anon, authenticated, service_role;

create or replace function pg_temp.ok(p_cond boolean, p_msg text) returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FAILED: %', p_msg; end if;
  raise notice 'ok: %', p_msg;
end $$;
grant execute on function pg_temp.ok(boolean, text) to anon, authenticated, service_role;
-- Lets the tests play faster than the per-minute limits allow.
create or replace function pg_temp.clear_limits() returns void language sql security definer as $$ delete from private.rate_limits $$;
grant execute on function pg_temp.clear_limits() to anon, authenticated, service_role;
-- Read-only peeks at internals the client roles can't reach.
create or replace function pg_temp.mults(p_rows int, p_risk text) returns numeric[] language sql security definer as $$ select private.plinko_table(p_rows, p_risk) $$;
create or replace function pg_temp.bj_total(p_cards jsonb) returns int language sql security definer as $$ select (private.bj_value(p_cards)).total $$;
grant execute on function pg_temp.mults(int, text), pg_temp.bj_total(jsonb) to authenticated;
create or replace function pg_temp.set_nonce(p_user uuid, p_nonce int) returns void language sql security definer as $$
  update public.fair_seeds set nonce = p_nonce where user_id = p_user $$;
grant execute on function pg_temp.set_nonce(uuid, int) to authenticated;
set client_min_messages = notice;

-- Sign-up -------------------------------------------------------------------
insert into auth.users (email, raw_user_meta_data) values ('alice@users.test', '{"username":"alice"}'), ('bob@example.com', '{"username":"bob"}');
select id as alice from auth.users where email = 'alice@users.test' \gset
select id as bob from auth.users where email = 'bob@example.com' \gset
select pg_temp.ok((select cash from public.portfolios where user_id = :'alice') = 100000, 'new accounts start with $100,000');
select pg_temp.ok((select count(*) from public.equity_snapshots where user_id = :'alice') = 1, 'sign-up records a first equity snapshot');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('c@x.test', '{"username":"ALICE"}')$$, '%taken%');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('k@x.test', '{"username":"aIice"}')$$, '%taken%');
select pg_temp.ok(not public.username_available('AL1CE') and public.username_available('alicia'), 'look-alikes of a taken name are taken too');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('d@x.test', '{"username":"no spaces"}')$$, '%username%');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('i@x.test', '{"username":"al.ice"}')$$, '%username%');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('j@x.test', '{"username":"jb"}')$$, '%username%');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('e@x.test', '{"username":"CryptoOracle"}')$$, '%reserved%');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('f@x.test', '{"username":"Chaminade_Admin"}')$$, '%reserved%');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('g@x.test', '{"username":"quietkeIIy"}')$$, '%reserved%');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('h@x.test', '{"username":"sim_7"}')$$, '%reserved%');
select pg_temp.expect_error($$insert into auth.users (email, raw_user_meta_data) values ('victim@users.chamimarket.app', '{"username":"mallory"}')$$, '%not available%');
select pg_temp.expect_error($$update auth.users set email = 'victim@users.chamimarket.app' where id = (select id from public.profiles where username = 'bob')$$, '%not available%');

-- Markets (as the sync job) -------------------------------------------------
set role service_role;
select pg_temp.ok(public.sync_markets(jsonb_build_array(
  jsonb_build_object('id', '123', 'title', 'Will it rain?', 'category', 'sports', 'yesPrice', 0.6, 'noPrice', 0.4,
    'endDate', now() + interval '2 days', 'labels', jsonb_build_object('yes', 'Yes', 'no', 'No')),
  jsonb_build_object('id', '456', 'title', 'Ended game', 'category', 'sports', 'yesPrice', 0.5, 'noPrice', 0.5, 'endDate', now() - interval '1 hour'),
  jsonb_build_object('id', 'cham-1-20991020-win', 'title', 'Chaminade wins?', 'category', 'chaminade', 'yesPrice', 0.7, 'noPrice', 0.3,
    'endDate', now() + interval '1 day', 'gameStart', now() + interval '1 day'),
  jsonb_build_object('id', 'cham-2-20991021-win', 'title', 'Chaminade wins again?', 'category', 'chaminade', 'yesPrice', 0.6, 'noPrice', 0.4,
    'endDate', now() + interval '2 days'),
  jsonb_build_object('id', 'bad id!', 'title', 'x', 'yesPrice', 0.5, 'noPrice', 0.5),
  jsonb_build_object('id', 'q-btc-above-80000-1', 'title', 'BTC above?', 'category', 'quick', 'yesPrice', 0.5, 'noPrice', 0.5, 'endDate', now() + interval '1 hour')
)) = 5, 'sync_markets stores valid markets and skips bad ids');
reset role;
update public.markets set updated_at = now() - interval '20 minutes' where id = 'q-btc-above-80000-1';
select pg_temp.ok(abs(private.norm_cdf(0) - 0.5) < 1e-6 and abs(private.norm_cdf(1.959964) - 0.975) < 1e-5 and abs(private.norm_cdf(-1.959964) - 0.025) < 1e-5,
  'the normal CDF behind live crypto odds is accurate');
select pg_temp.ok(private.above_prob(80000, 80250, 0.0008, 30) = 0.2375 and private.above_prob(4000, 3990, 0.001, 12) = 0.7645
  and private.above_prob(80000, 80250, 0.0008, 0) = 0.02, 'server crypto odds match the browser''s probAbove()');
-- Without a live Coinbase price (no http extension here), an hourly crypto market trades only on a very fresh synced price.
update public.markets set updated_at = now() - interval '5 minutes' where id = 'q-btc-above-80000-1';
select pg_temp.ok((select err from private.quote('q-btc-above-80000-1', 'yes')) like '%refreshing%', 'a 5 minute old crypto price is too old to trade on');
update public.markets set updated_at = now() - interval '20 minutes' where id = 'q-btc-above-80000-1';

-- Row level security --------------------------------------------------------
set role authenticated;
select set_config('request.jwt.claim.sub', :'alice', false);
select pg_temp.ok((select count(*) from public.portfolios) = 1, 'players only see their own portfolio');
select pg_temp.ok((select count(*) from public.profiles) = 2, 'usernames are public');
select pg_temp.expect_error($$update public.portfolios set cash = 1e9$$, '%permission denied%');
select pg_temp.expect_error($$insert into public.positions (user_id, market_id, side, shares, cost_basis) values (auth.uid(), '123', 'yes', 1, 0)$$, '%permission denied%');
select pg_temp.expect_error($$select * from public.blackjack_tables$$, '%permission denied%');
select pg_temp.expect_error($$select public.sync_markets('[]')$$, '%permission denied%');
select pg_temp.expect_error($$select public.sync_resolutions('{"123":"yes"}')$$, '%permission denied%');
select pg_temp.expect_error($$select private.settle_market('123', 'yes')$$, '%permission denied%');
select pg_temp.expect_error($$select private.rand_int(10)$$, '%permission denied%');

-- Trading -------------------------------------------------------------------
select pg_temp.ok((public.buy('123', 'yes', 100, 0.6) ->> 'shares')::numeric = 166.6667, 'buy $100 at 60¢ gets 166.6667 shares');
select pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = 99900, 'cash drops by the amount spent');
select pg_temp.ok(public.buy('123', 'yes', 100, 0.5) ->> 'error' like '%price moved to 60%', 'a stale price is refused (as an answer, not an error)');
select pg_temp.expect_error($$select public.buy('123', 'yes', 200000, 0.6)$$, '%exceeds your available cash%');
select pg_temp.expect_error($$select public.buy('123', 'yes', 'NaN', 0.6)$$, '%at least $0.01%');
select pg_temp.expect_error($$select public.buy('123', 'yes', 0.001, 0.6)$$, '%at least $0.01%');
select pg_temp.ok(public.buy('456', 'yes', 10, 0.5) ->> 'error' like '%event has ended%', 'ended events are refused');
select pg_temp.ok(public.buy('nope', 'yes', 10, 0.5) ->> 'error' like '%not available%', 'unknown markets are refused');
select pg_temp.ok(public.buy('q-btc-above-80000-1', 'yes', 10, 0.5) ->> 'error' like '%refreshing%', 'stale hourly crypto prices are refused');
select pg_temp.ok(public.buy('123', 'maybe', 10, 0.5) ->> 'error' like '%Yes or No%', 'sides are Yes or No');
do $$ declare i int; begin
  perform pg_temp.clear_limits();
  for i in 1..30 loop perform public.buy('123', 'yes', 10, 0.01); end loop;
  perform pg_temp.expect_error($q$select public.buy('123', 'yes', 10, 0.01)$q$, '%Slow down%');
  perform pg_temp.clear_limits();
end $$;
select pg_temp.ok(true, 'refused trades still count toward the rate limit');
select pg_temp.ok((public.sell('123', 'yes', 66.6667, 0.6) ->> 'proceeds')::numeric = 40, 'selling 66.6667 shares at 60¢ returns $40');
select pg_temp.ok((public.get_portfolio() -> 'positions' -> '123:yes' ->> 'shares')::numeric = 100, '100 shares left after a partial sale');
select pg_temp.expect_error($$select public.sell('123', 'yes', 1000, 0.6)$$, '%only own%');
select pg_temp.ok((public.buy('cham-1-20991020-win', 'no', 30, 0.3) ->> 'shares')::numeric = 100, 'house markets trade at the synced price');

-- Parlays are no longer offered, but one opened earlier is still priced from its legs: 0.7 x 0.6 = 0.42.
select pg_temp.expect_error($$select public.buy('q-parlay-cham-1-20991020-win_y~cham-2-20991021-win_y', 'yes', 42, 0.42)$$, '%no longer offered%');
reset role;
select pg_temp.ok((select price from private.quote('q-parlay-cham-1-20991020-win_y~cham-2-20991021-win_y', 'yes')) = 0.42, 'older parlays are still priced from their legs');
set role authenticated;

-- Settlement ----------------------------------------------------------------
reset role;
set role service_role;
select pg_temp.ok(public.held_markets() @> '["123"]', 'held_markets lists open positions');
select pg_temp.ok(public.sync_resolutions('{"123": {"outcome": "yes", "title": "Will it rain?"}}') = 1, 'a result settles one position');
select pg_temp.ok(public.sync_resolutions('{"123": "no"}') = 0, 'a market settles only once');
select pg_temp.ok(public.sync_resolutions('{"cham-1-20991020-win": "void"}') = 1, 'void results refund');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', :'alice', false);
-- 99900 + 40 (sale) - 30 (house) + 100 (win) + 30 (void refund)
select pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = 100040, 'payouts land in cash: winners $1 a share, voids at cost');
select pg_temp.ok((public.get_portfolio() ->> 'realizedPnl')::numeric = 40, 'realized PnL counts the sale ($0) and the win ($40)');
select pg_temp.ok(public.buy('123', 'yes', 10, 1) ->> 'error' like '%resolved%', 'resolved markets are closed');

-- Roulette ------------------------------------------------------------------
select pg_temp.expect_error($$select public.play_roulette('[{"key":"split:1-5","amount":10}]')$$, '%Invalid bet%');
select pg_temp.expect_error($$select public.play_roulette('[{"key":"straight:1-2-3","amount":10}]')$$, '%Invalid bet%');
select pg_temp.expect_error($$select public.play_roulette('[{"key":"corner:3-4-6-7","amount":10}]')$$, '%Invalid bet%');
select pg_temp.expect_error($$select public.play_roulette('[{"key":"red:1-2","amount":10}]')$$, '%Invalid bet%');
select pg_temp.expect_error($$select public.play_roulette('[{"key":"straight:7","amount":0.5}]')$$, '%at least $1%');
do $$
declare r jsonb; n int; red int[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36]; i int; hits int := 0;
begin
  for i in 1..300 loop
    perform pg_temp.clear_limits();
    r := public.play_roulette(jsonb_build_array(
      jsonb_build_object('key', 'red:1-3-5-7-9-12-14-16-18-19-21-23-25-27-30-32-34-36', 'amount', 2),
      jsonb_build_object('key', 'straight:17', 'amount', 1),
      jsonb_build_object('key', 'split:17-20', 'amount', 1),
      jsonb_build_object('key', 'corner:17-18-20-21', 'amount', 1)));
    n := (r ->> 'result')::int;
    if (r ->> 'returned')::numeric <> (case when n = any (red) then 4 else 0 end) + (case when n = 17 then 36 else 0 end)
      + (case when n in (17, 20) then 18 else 0 end) + (case when n in (17, 18, 20, 21) then 9 else 0 end) then
      raise exception 'roulette paid % on %', r ->> 'returned', n;
    end if;
    if n = any (red) then hits := hits + 1; end if;
  end loop;
  perform pg_temp.ok(hits between 100 and 200, format('300 spins pay exact odds (red came up %s times)', hits));
end $$;

-- Plinko --------------------------------------------------------------------
select pg_temp.expect_error($$select public.play_plinko(10, 10, 'low', 1)$$, '%rows%');
select pg_temp.expect_error($$select public.play_plinko(10, 16, 'low', 26)$$, '%between 1 and 25%');
do $$
declare r jsonb; b jsonb; before numeric; mults numeric[] := pg_temp.mults(16, 'high');
begin
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.play_plinko(10, 16, 'high', 25);
  for b in select * from jsonb_array_elements(r -> 'balls') loop
    if jsonb_array_length(b -> 'path') <> 16 then raise exception 'path length'; end if;
    if (select sum(x::int) from jsonb_array_elements_text(b -> 'path') x) <> (b ->> 'bucket')::int then raise exception 'bucket'; end if;
    if (b ->> 'returned')::numeric <> round(10 * mults[(b ->> 'bucket')::int + 1], 2) then raise exception 'payout'; end if;
  end loop;
  perform pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = before - 250 + (r ->> 'returned')::numeric, '25 Plinko balls pay their buckets');
end $$;
select pg_temp.ok(array_length(pg_temp.mults(8, 'low'), 1) = 9 and array_length(pg_temp.mults(16, 'high'), 1) = 17, 'Plinko tables have rows + 1 buckets');

-- Blackjack -----------------------------------------------------------------
reset role;
create or replace function pg_temp.rig(p_user uuid, p_ranks text[]) returns void language plpgsql security definer as $$
declare shoe jsonb := '[]'; r text; i int := 0;
begin
  foreach r in array p_ranks loop shoe := shoe || jsonb_build_array(jsonb_build_object('rank', r, 'suit', '♠', 'id', 'r' || i)); i := i + 1; end loop;
  for i in 1..200 loop shoe := shoe || jsonb_build_array(jsonb_build_object('rank', '2', 'suit', '♣', 'id', 'f' || i)); end loop;
  insert into public.blackjack_tables (user_id, state) values (p_user, jsonb_build_object('phase', 'betting', 'shoe', shoe, 'cut', 0,
    'dealer', '[]'::jsonb, 'hands', '[]'::jsonb, 'active', 0, 'insurance', 0, 'result', null))
  on conflict (user_id) do update set state = excluded.state;
end $$;
grant execute on function pg_temp.rig(uuid, text[]) to authenticated;
set role authenticated;

do $$
declare r jsonb; before numeric; me uuid := auth.uid();
begin
  -- Dealer stands on soft 17: player 18 beats dealer A+6.
  perform pg_temp.rig(me, array['10', '6', '8', 'A']);
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.blackjack_deal(100);
  perform pg_temp.ok(r -> 'table' ->> 'phase' = 'player' and r -> 'table' -> 'dealer' -> 1 ->> 'hidden' = 'true' and not (r -> 'table') ? 'shoe',
    'the hole card and the shoe stay on the server');
  perform pg_temp.expect_error($q$select public.blackjack_deal(100)$q$, '%Finish the current hand%');
  r := public.blackjack_act('stand');
  perform pg_temp.ok(r -> 'table' -> 'hands' -> 0 ->> 'outcome' = 'win' and jsonb_array_length(r -> 'table' -> 'dealer') = 2,
    'dealer stands on soft 17');
  perform pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = before + 100, 'a win pays 1:1');

  -- Blackjack pays 3:2.
  perform pg_temp.rig(me, array['A', '9', 'K', '7']);
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.blackjack_deal(100);
  perform pg_temp.ok(r -> 'table' -> 'hands' -> 0 ->> 'outcome' = 'blackjack' and (public.get_portfolio() ->> 'cash')::numeric = before + 150,
    'blackjack pays 3:2');

  -- Insurance pays 2:1 against a dealer blackjack.
  perform pg_temp.rig(me, array['10', 'A', '9', 'K']);
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.blackjack_deal(100);
  perform pg_temp.ok(r -> 'table' ->> 'phase' = 'insurance', 'insurance is offered under an ace');
  r := public.blackjack_act('insurance');
  perform pg_temp.ok((r -> 'table' -> 'result' ->> 'insuranceBack')::numeric = 150 and (public.get_portfolio() ->> 'cash')::numeric = before,
    'insurance pays 2:1, so the hand breaks even');

  -- Split aces get one card each; 21 after a split is not a blackjack.
  perform pg_temp.rig(me, array['A', '9', 'A', '7', 'K', '5', '10']);
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.blackjack_deal(100);
  perform pg_temp.ok((r -> 'table' ->> 'canSplit')::boolean, 'a pair can be split');
  r := public.blackjack_act('split');
  perform pg_temp.ok(r -> 'table' ->> 'phase' = 'done'
    and r -> 'table' -> 'hands' -> 0 ->> 'outcome' = 'win' and r -> 'table' -> 'hands' -> 1 ->> 'outcome' = 'win'
    and (public.get_portfolio() ->> 'cash')::numeric = before + 200, 'split aces: two wins at 1:1, no 3:2');

  -- Double down: 11 + 10 = 21 pushes against the dealer's 21.
  perform pg_temp.rig(me, array['5', '6', '6', '10', '10', '5']);
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.blackjack_deal(100);
  r := public.blackjack_act('double');
  perform pg_temp.ok(r -> 'table' -> 'hands' -> 0 ->> 'outcome' = 'push' and (r -> 'table' -> 'hands' -> 0 ->> 'bet')::numeric = 200
    and (public.get_portfolio() ->> 'cash')::numeric = before, 'a doubled push returns both bets');
  perform pg_temp.expect_error($q$select public.blackjack_act('hit')$q$, '%Deal first%');
end $$;

-- A long random session never creates or loses money.
do $$
declare r jsonb; before numeric; i int; k int; staked numeric := 0; returned numeric := 0; table_ jsonb;
begin
  before := (public.get_portfolio() ->> 'cash')::numeric;
  for i in 1..150 loop
    perform pg_temp.clear_limits();
    r := public.blackjack_deal(10);
    k := 0;
    while r -> 'table' ->> 'phase' <> 'done' and k < 60 loop
      if r -> 'table' ->> 'phase' = 'insurance' then
        r := public.blackjack_act(case when i % 2 = 0 then 'insurance' else 'no_insurance' end);
      elsif (r -> 'table' ->> 'canSplit')::boolean and i % 3 = 0 then
        r := public.blackjack_act('split');
      elsif (r -> 'table' ->> 'canDouble')::boolean and i % 5 = 0 then
        r := public.blackjack_act('double');
      elsif pg_temp.bj_total(r -> 'table' -> 'hands' -> (r -> 'table' ->> 'active')::int -> 'cards') < 15 then
        r := public.blackjack_act('hit');
      else
        r := public.blackjack_act('stand');
      end if;
      k := k + 1;
    end loop;
    if r -> 'table' ->> 'phase' <> 'done' then raise exception 'hand stuck in %: %', r -> 'table' ->> 'phase', r -> 'table'; end if;
    staked := staked + (r -> 'table' -> 'result' ->> 'staked')::numeric;
    returned := returned + (r -> 'table' -> 'result' ->> 'returned')::numeric;
  end loop;
  perform pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = before - staked + returned,
    format('150 random hands balance to the cent (staked %s, returned %s)', staked, returned));
end $$;

-- Provably fair games ---------------------------------------------------------
reset role;
-- Known seeds, so results can be checked against src/games (see src/games/fairgames.test.js vectors).
insert into public.fair_seeds (user_id, server_seed, client_seed, nonce) values (:'alice', repeat('b', 64), 'chami', 0)
on conflict (user_id) do update set server_seed = excluded.server_seed, client_seed = excluded.client_seed, nonce = 0;
set role authenticated;
select set_config('request.jwt.claim.sub', :'alice', false);
select pg_temp.clear_limits();
select pg_temp.expect_error($$select * from public.fair_seeds$$, '%permission denied%');
select pg_temp.expect_error($$select * from public.game_states$$, '%permission denied%');
select pg_temp.ok(public.fair_state() ->> 'serverSeedHash' = 'a0fab1377f49a759b57f63318262ebe89fabfc990e8e93ceac2984561482b9d4'
  and not public.fair_state() ? 'serverSeed', 'only the hash of the active server seed is shown');

do $$
declare r jsonb; before numeric := (public.get_portfolio() ->> 'cash')::numeric;
begin
  r := public.play_dice(10, 50, true);
  perform pg_temp.ok((r ->> 'roll')::int = 9490 and (r ->> 'nonce')::int = 0 and (r ->> 'win')::boolean
    and (r ->> 'multiplier')::numeric = 1.98 and (r ->> 'payout')::numeric = 19.8, 'dice nonce 0 rolls 94.90, the same as the browser engine');
  r := public.play_dice(10, 80, false);
  perform pg_temp.ok((r ->> 'roll')::int = 8371 and not (r ->> 'win')::boolean and (r ->> 'payout')::numeric = 0
    and (r ->> 'multiplier')::numeric = 1.2375, 'dice nonce 1 rolls 83.71 and loses under 80 (1.2375x)');
  perform pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = before - 20 + 19.8, 'dice pays from cash');
  perform pg_temp.expect_error($q$select public.play_dice(10, 1, true)$q$, '%between 2 and 98%');
  perform pg_temp.expect_error($q$select public.play_dice(0.05, 50, true)$q$, '%at least $0.10%');
end $$;

do $$
declare r jsonb; before numeric := (public.get_portfolio() ->> 'cash')::numeric;
begin
  perform pg_temp.expect_error($q$select public.mines_reveal(3)$q$, '%Start a round%');
  perform pg_temp.expect_error($q$select public.mines_start(10, 25)$q$, '%1 to 24 mines%');
  r := public.mines_start(10, 3);
  perform pg_temp.ok(r -> 'round' ->> 'phase' = 'playing' and not (r -> 'round') ? 'positions' and r -> 'round' -> 'result' = 'null'
    and (r -> 'round' ->> 'nonce')::int = 2, 'mine positions stay on the server during a round');
  perform pg_temp.expect_error($q$select public.mines_start(10, 3)$q$, '%current round%');
  perform pg_temp.expect_error($q$select public.fair_rotate('new-seed')$q$, '%does not exist%');
  perform pg_temp.expect_error($q$select public.mines_cashout()$q$, '%at least one tile%');
  r := public.mines_reveal(0);
  perform pg_temp.ok((r -> 'round' ->> 'multiplier')::numeric = 1.12 and (r -> 'round' ->> 'nextMultiplier')::numeric = 1.28, 'one gem with 3 mines is 1.12x, next 1.28x');
  perform pg_temp.expect_error($q$select public.mines_reveal(0)$q$, '%already open%');
  r := public.mines_reveal(1);
  r := public.mines_cashout();
  perform pg_temp.ok(r -> 'round' -> 'result' -> 'positions' = '[6, 7, 24]' and (r -> 'round' -> 'result' ->> 'payout')::numeric = 12.8,
    'cashing out two gems pays 1.28x and reveals mines 6, 7 and 24, the same as the browser engine');
  perform pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = before + 2.8, 'mines pays from cash');
end $$;

do $$
declare r jsonb; i int; before numeric := (public.get_portfolio() ->> 'cash')::numeric;
begin
  r := public.chicken_start(10, 'medium');
  perform pg_temp.ok(not (r -> 'round') ? 'crash' and (r -> 'round' ->> 'nonce')::int = 3 and (r -> 'round' ->> 'lanes')::int = 25,
    'the crash lane stays on the server');
  for i in 1..5 loop r := public.chicken_step(); end loop;
  perform pg_temp.ok((r -> 'round' ->> 'lane')::int = 5 and (r -> 'round' ->> 'multiplier')::numeric = 1.85, 'five medium lanes reach 1.85x');
  r := public.chicken_step();
  perform pg_temp.ok(r -> 'round' ->> 'phase' = 'done' and (r -> 'round' -> 'result' ->> 'hitLane')::int = 6
    and (r -> 'round' -> 'result' ->> 'payout')::numeric = 0, 'nonce 3 is hit on medium lane 6, the same as the browser engine');
  perform pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = before - 10, 'a hit loses the bet');
  perform pg_temp.expect_error($q$select public.chicken_step()$q$, '%Start a round%');
  perform pg_temp.expect_error($q$select public.chicken_start(10, 'insane')$q$, '%Daredevil%');
end $$;

do $$
declare r jsonb; i int; before numeric; staked numeric := 0; back numeric := 0; f jsonb;
begin
  before := (public.get_portfolio() ->> 'cash')::numeric;
  for i in 1..30 loop
    perform pg_temp.clear_limits();
    r := public.mines_auto(5, 5, array[0, 1, 2]);
    back := back + (r -> 'round' -> 'result' ->> 'payout')::numeric;
    if (r -> 'round' -> 'result' ->> 'win')::boolean and (r -> 'round' -> 'result' ->> 'multiplier')::numeric <> 1.99 then
      raise exception 'mines auto paid %', r -> 'round' -> 'result';
    end if;
    r := public.chicken_auto(5, 'hard', 3);
    back := back + (r -> 'round' -> 'result' ->> 'payout')::numeric;
    if (r -> 'round' -> 'result' ->> 'win')::boolean and ((r -> 'round' -> 'result' ->> 'multiplier')::numeric <> 1.91 or (r -> 'round' ->> 'lane')::int <> 3) then
      raise exception 'chicken auto paid %', r -> 'round' -> 'result';
    end if;
    staked := staked + 10;
  end loop;
  perform pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = before - staked + back,
    format('60 auto rounds balance to the cent (staked %s, returned %s)', staked, back));
  perform pg_temp.expect_error($q$select public.mines_auto(5, 5, array[1, 1])$q$, '%different tiles%');
  -- A bad tile after a safe one must not undo the round (that would test tiles for free).
  before := (public.get_portfolio() ->> 'cash')::numeric;
  i := (public.fair_state() ->> 'nonce')::int;
  perform pg_temp.expect_error($q$select public.mines_auto(5, 23, array[0, 99])$q$, '%from 0 to 24%');
  perform pg_temp.expect_error($q$select public.mines_auto(5, 23, array[0, -1])$q$, '%from 0 to 24%');
  perform pg_temp.ok((public.get_portfolio() ->> 'cash')::numeric = before and (public.fair_state() ->> 'nonce')::int = i,
    'mines auto rejects bad tiles before any round starts');
  perform pg_temp.expect_error($q$select public.chicken_auto(5, 'hard', 23)$q$, '%from 1 to 22%');

  -- Seeds retire on their own after 100 bets, but never while a round is open.
  perform pg_temp.clear_limits();
  r := public.mines_start(1, 3);
  perform pg_temp.set_nonce(auth.uid(), 100);
  r := public.play_dice(1, 50, true);
  f := public.fair_state();
  perform pg_temp.ok((r ->> 'nonce')::int = 100 and f -> 'previous' = 'null' and (f ->> 'nonce')::int = 101,
    'seeds stay put while a Mines round is open');
  r := public.mines_reveal(0);
  if r -> 'round' ->> 'phase' = 'playing' then r := public.mines_cashout(); end if;
  r := public.play_dice(1, 50, true);
  f := public.fair_state();
  perform pg_temp.ok((r ->> 'nonce')::int = 0 and f -> 'previous' ->> 'serverSeed' = repeat('b', 64) and (f -> 'previous' ->> 'nonce')::int = 101
    and f -> 'previous' ->> 'clientSeed' = 'chami' and (f ->> 'nonce')::int = 1 and f ->> 'clientSeed' ~ '^[0-9a-f]{16}$'
    and f ->> 'serverSeedHash' <> f -> 'previous' ->> 'serverSeedHash',
    'after 100 bets the next one retires the pair, reveals its server seed and starts fresh seeds');
end $$;

-- Rate limits ----------------------------------------------------------------
do $$ declare i int; begin
  perform pg_temp.clear_limits();
  for i in 1..40 loop perform public.play_plinko(1, 8, 'low', 1); end loop;
  perform pg_temp.expect_error($q$select public.play_plinko(1, 8, 'low', 1)$q$, '%Slow down%');
  perform pg_temp.ok(true, 'game plays are limited to 40 a minute');
  perform pg_temp.clear_limits();
end $$;

-- Portfolio JSON and the leaderboard -----------------------------------------
select pg_temp.ok((public.get_portfolio() -> 'games' ->> 'runRounds')::int = 300 + 25 + 5 + 150 + 2 + 2 + 60 + 3 + 40, 'every game round is recorded');
select pg_temp.ok((public.get_portfolio() -> 'games' -> 'stats' -> 'blackjack' ->> 'rounds')::int = 155, 'per-game stats');
reset role;
select pg_temp.ok(not exists (
  select 1 from (select game, count(*) n, sum(staked) w, sum(net) net, max(net) best from public.game_rounds where user_id = :'alice' group by game) g
  full join (select game, sum(rounds) n, sum(wagered) w, sum(net) net, max(best) best from private.game_totals where user_id = :'alice' group by game) t using (game)
  where g.n is distinct from t.n or g.w is distinct from t.w or g.net is distinct from t.net or g.best is distinct from t.best),
  'running game totals match the rounds played');
set role authenticated;
select pg_temp.ok(jsonb_array_length(public.leaderboard()) = 2, 'the leaderboard lists every player');
select pg_temp.ok((select (r ->> 'pnl')::numeric = (r ->> 'marketPnl')::numeric + (r -> 'games' ->> 'net')::numeric
  from jsonb_array_elements(public.leaderboard()) r where r ->> 'name' = 'alice'), 'markets PnL plus games net equals total PnL');
select pg_temp.ok((select (r ->> 'netWorth')::numeric from jsonb_array_elements(public.leaderboard()) r where r ->> 'name' = 'alice')
  = (public.get_portfolio() ->> 'cash')::numeric, 'net worth is cash when nothing is open');

-- Reset ---------------------------------------------------------------------
select pg_temp.ok((public.reset_balance() ->> 'cash')::numeric = 50000, 'reset starts a $50,000 run');
select pg_temp.expect_error($$select public.reset_balance()$$, '%reset again in 5 minutes%');
select pg_temp.ok((public.get_portfolio() ->> 'run')::int = 2 and public.get_portfolio() -> 'positions' = '{}', 'reset clears positions and bumps the run');
select pg_temp.ok((public.get_portfolio() -> 'games' ->> 'runRounds')::int = 0, 'game totals restart with the run');

-- The activity feed is public -------------------------------------------------
reset role;
set role anon;
select set_config('request.jwt.claim.sub', '', false);
select pg_temp.ok((select count(*) from public.activity where kind = 'buy') = 2, 'anyone can read the activity feed');
select pg_temp.expect_error($$select user_id from public.activity$$, '%permission denied%');
select pg_temp.expect_error($$select created_at from public.profiles$$, '%permission denied%');
select pg_temp.ok((select count(*) from public.activity a join public.profiles p on p.username = a.username) >= 0,
  'the feed and profiles still show usernames, but not which account a row belongs to or when it signed up');
select pg_temp.ok((select count(*) from public.portfolios) = 0, 'guests can''t read portfolios');
select pg_temp.expect_error($$select public.buy('123', 'yes', 10, 0.5)$$, '%permission denied%');
select pg_temp.ok(public.username_available('carol') and not public.username_available('Alice'), 'username availability is case-insensitive');
select pg_temp.ok(not public.username_available('cryptooracle') and not public.username_available('Official_Bot'), 'reserved names never show as available');
select pg_temp.ok(not public.username_available('Sh1tposter') and not public.username_available('b_i_t_c_h')
  and not public.username_available('MrSmith') and not public.username_available('Coach_Dave') and not public.username_available('bestteacher'),
  'crude names (look-alikes too) and names that pass as school staff are refused');
select pg_temp.ok(public.username_available('Drake') and public.username_available('Frank') and public.username_available('mrbeastfan')
  and public.username_available('coachella'), 'ordinary names that start the same way are still allowed');

-- Recovery codes --------------------------------------------------------------
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', :'bob', false);
select public.create_recovery_code() as code \gset
select pg_temp.ok(:'code' ~ '^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$', 'recovery codes look like XXXX-XXXX-XXXX');
reset role;
set role anon;
select pg_temp.ok(public.reset_password_with_code('bob@example.com', :'code', 'short') ->> 'error' like '%8 to 72%', 'new passwords need 8 to 72 characters');
select public.reset_password_with_code('bob@example.com', lower(replace(:'code', '-', ' ')), 'brand new password') ->> 'code' as code2 \gset
reset role;
select pg_temp.ok((select encrypted_password = extensions.crypt('brand new password', encrypted_password) from auth.users where id = :'bob'),
  'a recovery code sets a new bcrypt password (and is typed case- and dash-insensitively)');
set role anon;
select pg_temp.ok(public.reset_password_with_code('bob@example.com', :'code', 'another password') ->> 'error' like '%don''t match%', 'a used code stops working');
select pg_temp.ok(public.reset_password_with_code('nobody@example.com', 'AAAA-BBBB-CCCC', 'another password') ->> 'error' like '%don''t match%',
  'unknown accounts get the same message');
do $$ declare i int; begin
  for i in 1..4 loop perform public.reset_password_with_code('bob@example.com', 'AAAA-BBBB-CCCC', 'another password'); end loop;
end $$;
select pg_temp.ok(public.reset_password_with_code('bob@example.com', :'code2', 'another password') ->> 'error' like '%don''t match%',
  'five wrong codes lock recovery, even for the right code');
select pg_temp.ok(public.reset_password_with_code('bob@example.com', 'AAAA-BBBB-CCCC', 'another password')
  = public.reset_password_with_code('nobody@example.com', 'AAAA-BBBB-CCCC', 'another password'),
  'a locked account answers exactly like one that does not exist');
reset role;
update public.recovery_codes set locked_until = now() - interval '1 minute' where user_id = :'bob';
set role anon;
select pg_temp.ok(public.reset_password_with_code('bob@example.com', 'AAAA-BBBB-CCCC', 'another password') ->> 'error' like '%don''t match%',
  'an expired lock lets guessing resume');
reset role;
select pg_temp.ok((select failed_attempts = 1 and locked_until is null from public.recovery_codes where user_id = :'bob'), 'and the count starts over');
set role anon;
reset role;
select pg_temp.ok((select encrypted_password = extensions.crypt('brand new password', encrypted_password) from auth.users where id = :'bob'),
  'the locked attempt did not change the password');

-- Feedback ------------------------------------------------------------------------
reset role;
set role anon;
select set_config('request.jwt.claim.sub', '', false);
select pg_temp.ok((public.submit_feedback('suggestion', '  Add a  hockey'||chr(8203)||' tab please'||chr(7)||'  ', '#/games?x=<b>') ->> 'ok')::boolean, 'guests can send feedback');
select pg_temp.ok(public.submit_feedback('rant', 'hello there', null) ->> 'error' like '%type%', 'feedback needs a known type');
select pg_temp.ok(public.submit_feedback('bug', ' a ', null) ->> 'error' like '%more%', 'and a real message');
select pg_temp.ok(public.submit_feedback('bug', repeat('x', 1001), null) ->> 'error' like '%1,000%', 'and not an essay');
select pg_temp.ok(public.submit_feedback(null, 'hello there', null) ->> 'error' like '%type%', 'a missing type is an answer, not an error');
select pg_temp.expect_error($$select count(*) from public.feedback$$, '%permission denied%');
set role authenticated;
select set_config('request.jwt.claim.sub', :'bob', false);
select pg_temp.expect_error($$select count(*) from public.feedback$$, '%permission denied%');
do $$ declare i int; begin
  for i in 1..5 loop perform public.submit_feedback('bug', 'Bug number ' || i, '#/'); end loop;
end $$;
select pg_temp.ok(public.submit_feedback('bug', 'one too many', null) ->> 'error' like '%for now%', 'players can send 5 an hour');
reset role;
select pg_temp.ok((select message = 'Add a hockey tab please' and page = '#/games?x=b' and user_id is null from public.feedback order by id limit 1),
  'messages are tidied, pages stripped of odd characters, and guests stay anonymous');
select pg_temp.ok((select count(*) = 5 and bool_and(username = 'bob') from public.feedback where user_id = :'bob'), 'player feedback carries their username');

-- Deleting an account ----------------------------------------------------------
select jsonb_array_length(public.leaderboard()) as players_before \gset
set role authenticated;
select set_config('request.jwt.claim.sub', :'bob', false);
select pg_temp.ok(public.delete_account('delete me') ->> 'error' like '%Type DELETE%', 'deleting needs the confirmation word');
reset role;
select pg_temp.ok(exists (select 1 from public.profiles where id = :'bob'), 'without it nothing is deleted');
set role authenticated;
select pg_temp.ok((public.delete_account(' delete ') ->> 'deleted')::boolean, 'typing DELETE deletes the account (any case, spaces trimmed)');
reset role;
select pg_temp.ok(not exists (select 1 from auth.users where id = :'bob')
  and not exists (select 1 from public.profiles where id = :'bob')
  and not exists (select 1 from public.portfolios where user_id = :'bob')
  and not exists (select 1 from public.history where user_id = :'bob')
  and not exists (select 1 from public.positions where user_id = :'bob')
  and not exists (select 1 from public.activity where user_id = :'bob')
  and not exists (select 1 from public.recovery_codes where user_id = :'bob')
  and not exists (select 1 from public.feedback where user_id = :'bob')
  and not exists (select 1 from private.rate_limits where user_id = :'bob'), 'every row tied to the account is gone');
select pg_temp.ok(jsonb_array_length(public.leaderboard()) = :players_before - 1
  and not exists (select 1 from jsonb_array_elements(public.leaderboard()) r where r ->> 'name' = 'bob'), 'the player leaves the leaderboard');
select pg_temp.ok(exists (select 1 from public.portfolios where user_id = :'alice'), 'other players are untouched');
select pg_temp.ok(public.username_available('bob'), 'the username is free again');

-- Limbo, Crash and Golden Sevens ------------------------------------------------------
reset role;
select pg_temp.ok((select array_agg(private.limbo_cents((private.fair_floats(repeat('b', 64), 'chami', n, 1))[1]) order by n)
  from generate_series(0, 5) n) = array[104, 118, 398, 233, 207, 206]::bigint[], 'limbo results match the browser engine');
select pg_temp.ok((select jsonb_object_agg(n, (private.slot_round(private.fair_floats(repeat('b', 64), 'chami', n, 744)) ->> 'units')::bigint)
  from unnest(array[0, 1, 15, 45, 424, 17392]) n) = '{"0": 30, "1": 0, "15": 470, "45": 635, "424": 7670, "17392": 123545}',
  'slot rounds (free spins and retriggers included) match the browser engine');
select pg_temp.ok((select (r ->> 'freeSpins')::int = 25 and jsonb_array_length(r -> 'spins') = 26
  from private.slot_round(private.fair_floats(repeat('b', 64), 'chami', 424, 744)) r), 'free spins retrigger (nonce 424: 25 free spins)');
-- A client seed whose first round crashes at 1.00×.
select 'c' || n as crash_at_one from generate_series(0, 5000) n
  where private.limbo_cents((private.fair_floats(repeat('b', 64), 'c' || n, 0, 1))[1]) = 100 limit 1 \gset
select set_config('test.crash_at_one', :'crash_at_one', false);
create or replace function pg_temp.seeds_at(p_user uuid, p_nonce int, p_client text default 'chami') returns void language sql security definer as $$
  update public.fair_seeds set server_seed = repeat('b', 64), client_seed = p_client, nonce = p_nonce where user_id = p_user $$;
create or replace function pg_temp.age_crash(p_user uuid, p_ms bigint) returns void language sql security definer as $$
  update public.game_states set state = state || jsonb_build_object('started', (state ->> 'started')::bigint - p_ms, 'ends', (state ->> 'ends')::bigint - p_ms)
  where user_id = p_user and game = 'crash' $$;
grant execute on function pg_temp.seeds_at(uuid, int, text), pg_temp.age_crash(uuid, bigint) to authenticated;
set role authenticated;
select set_config('request.jwt.claim.sub', :'alice', false);
select pg_temp.clear_limits();

do $$
declare r jsonb; before numeric; me uuid := auth.uid();
begin
  -- Limbo: nonce 2 draws 3.98×.
  perform pg_temp.seeds_at(me, 2);
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.play_limbo(10, 3.98);
  perform pg_temp.ok((r ->> 'result')::numeric = 3.98 and (r ->> 'win')::boolean and (r ->> 'payout')::numeric = 39.8
    and (r -> 'portfolio' ->> 'cash')::numeric = before - 10 + 39.8, 'limbo pays target × bet when the draw reaches it');
  r := public.play_limbo(10, 2);
  perform pg_temp.ok((r ->> 'result')::numeric = 2.33 and (r ->> 'payout')::numeric = 20, 'limbo nonce 3 draws 2.33×');
  r := public.play_limbo(10, 2.08);
  perform pg_temp.ok((r ->> 'result')::numeric = 2.07 and not (r ->> 'win')::boolean and (r ->> 'payout')::numeric = 0, 'a draw just under the target loses');
  perform pg_temp.expect_error($q$select public.play_limbo(10, 1)$q$, '%1.01%');
  perform pg_temp.expect_error($q$select public.play_limbo(10, 2000000)$q$, '%1,000,000%');

  -- Crash, cashed out by hand right away: nonce 0 crashes at 1.04×.
  perform pg_temp.seeds_at(me, 0);
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.crash_start(10);
  perform pg_temp.ok(r -> 'round' ->> 'phase' = 'playing' and not (r -> 'round') ? 'crash' and r -> 'round' -> 'result' = 'null'
    and (r -> 'portfolio' ->> 'cash')::numeric = before - 10, 'the crash point stays on the server while the round runs');
  perform pg_temp.expect_error($q$select public.crash_start(10)$q$, '%current round%');
  perform pg_temp.expect_error($q$select public.mines_start(10, 3)$q$, '%current round%');
  r := public.crash_cashout();
  perform pg_temp.ok((r -> 'round' -> 'result' ->> 'win')::boolean and (r -> 'round' -> 'result' ->> 'cashout')::numeric = 1
    and (r -> 'round' -> 'result' ->> 'crash')::numeric = 1.04 and (r -> 'portfolio' ->> 'cash')::numeric = before,
    'cashing out at 1.00× gives the bet back and reveals the crash point');

  -- Auto cash-out at 1.01×: nonce 2 crashes at 3.98×, so it wins once 166 ms have passed.
  perform pg_temp.seeds_at(me, 2);
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.crash_start(10, 1.01);
  perform pg_temp.ok(not (public.crash_state() -> 'round' ->> 'phase' = 'done') or true, 'polling is allowed');
  perform pg_sleep(0.25);
  r := public.crash_state();
  perform pg_temp.ok(r -> 'round' ->> 'phase' = 'done' and (r -> 'round' -> 'result' ->> 'payout')::numeric = 10.1
    and (r -> 'portfolio' ->> 'cash')::numeric = before + 0.1, 'auto cash-out pays at its target');

  -- Left running past the crash: settled as a loss by the next call, or by the sync job.
  perform pg_temp.seeds_at(me, 2);
  before := (public.get_portfolio() ->> 'cash')::numeric;
  r := public.crash_start(10);
  perform pg_temp.age_crash(me, 60000);
  r := public.crash_cashout();
  perform pg_temp.ok(not (r -> 'round' -> 'result' ->> 'win')::boolean and (r -> 'round' -> 'result' ->> 'crash')::numeric = 3.98
    and (r -> 'portfolio' ->> 'cash')::numeric = before - 10, 'a cash-out after the crash loses');
end $$;

do $$
declare r jsonb; me uuid := auth.uid();
begin
  perform pg_temp.seeds_at(me, 0, current_setting('test.crash_at_one'));
  r := public.crash_start(10);
  r := public.crash_state();
  perform pg_temp.ok(r -> 'round' ->> 'phase' = 'done' and (r -> 'round' -> 'result' ->> 'crash')::numeric = 1, 'a 1.00× crash point loses at once');
  -- A round the player walks away from doesn't block other games.
  perform pg_temp.seeds_at(me, 2);
  r := public.crash_start(10);
  perform pg_temp.age_crash(me, 60000);
  r := public.mines_start(1, 3);
  perform pg_temp.ok(r -> 'round' ->> 'phase' = 'playing' and public.crash_state() -> 'round' ->> 'phase' = 'done', 'a finished crash round is settled before the next game');
  r := public.mines_reveal(0);
  if r -> 'round' ->> 'phase' = 'playing' then r := public.mines_cashout(); end if;

  -- Golden Sevens: nonce 15 hits a 10x wild and 45 starts 10 free spins.
  perform pg_temp.seeds_at(me, 15);
  r := public.play_slots(1);
  perform pg_temp.ok((r ->> 'payout')::numeric = 4.7 and (r -> 'round' ->> 'units')::int = 470, 'slots pay 4.70x on nonce 15');
  perform pg_temp.seeds_at(me, 1);
  r := public.play_slots(2);
  perform pg_temp.ok((r ->> 'payout')::numeric = 0, 'a losing spin pays nothing');
  perform pg_temp.seeds_at(me, 45);
  r := public.play_slots(0.5);
  perform pg_temp.ok((r -> 'round' ->> 'freeSpins')::int = 10 and jsonb_array_length(r -> 'round' -> 'spins') = 11 and (r ->> 'payout')::numeric = 3.17,
    '3 stars play 10 free spins in the same round (payout rounded down)');
  perform pg_temp.expect_error($q$select public.play_slots(0.05)$q$, '%at least $0.10%');
  perform pg_temp.expect_error($q$select public.play_boneyard(1)$q$, '%does not exist%');
end $$;

reset role;
select pg_temp.ok((select count(*) from public.activity where kind = 'game' and game in ('limbo', 'crash', 'slots')) >= 10
  and exists (select 1 from public.activity where game = 'slots' and detail like '%free spins%'), 'every round of the new games is in the feed');
select pg_temp.ok((select detail from public.game_rounds where game = 'slots' and detail like '10 free spins%' limit 1) is not null, 'slot rounds note their free spins');
-- Every dice roll goes to the feed now, not just big wins.
select pg_temp.ok((select count(*) from public.game_rounds where game = 'dice') = (select count(*) from public.activity where game = 'dice'),
  'every dice round is in the feed');

-- Guests ------------------------------------------------------------------------------
reset role;
insert into auth.users (email, is_anonymous) values (null, true), (null, true), (null, true);
select id as guest from auth.users where is_anonymous order by created_at, id limit 1 \gset
select id as guest2 from auth.users where is_anonymous and id <> :'guest' order by id limit 1 \gset
select id as guest3 from auth.users where is_anonymous and id not in (:'guest', :'guest2') limit 1 \gset
select pg_temp.ok((select username::text from public.profiles where id = :'guest') ~ '^guest-[0-9a-f]{12}$'
  and (select cash from public.portfolios where user_id = :'guest') = 100000, 'guests get a placeholder name and $100,000');
select pg_temp.ok(not public.username_available('guest_lover') and not public.username_available('Gue5t'), 'names starting with guest are reserved');
set role authenticated;
select set_config('request.jwt.claim.sub', :'guest', false);
select pg_temp.clear_limits();
do $$
declare r jsonb;
begin
  r := public.play_dice(10, 50, true);
  perform pg_temp.ok((select username from public.activity order by id desc limit 1) = 'Guest', 'a guest shows as Guest in the feed');
  perform pg_temp.ok(not exists (select 1 from jsonb_array_elements(public.leaderboard()) x where x ->> 'id' = auth.uid()::text),
    'guests are not on the leaderboard');
  perform pg_temp.expect_error($q$select public.create_recovery_code()$q$, '%Sign up first%');
  perform pg_temp.ok(public.submit_feedback('other', 'hello from a guest') ->> 'ok' = 'true', 'guests can send feedback');
  perform pg_temp.ok(public.claim_guest('alice') ->> 'error' like '%taken%', 'a guest cannot take a used name');
  perform pg_temp.ok(public.claim_guest('aIice') ->> 'error' like '%taken%', 'or a look-alike of one');
  perform pg_temp.ok(public.claim_guest('x') ->> 'error' like '%3 to 20%', 'or a bad one');
  perform pg_temp.ok(public.claim_guest('Lucky_Lou') ->> 'username' = 'Lucky_Lou', 'a guest claims a free name');
  perform pg_temp.ok(public.claim_guest('Lucky_Lou') ->> 'username' = 'Lucky_Lou', 'claiming again (a retried sign-up) is fine');
  perform pg_temp.ok((select username::text from public.profiles where id = auth.uid()) = 'Lucky_Lou', 'a guest sees their own profile');
end $$;
select set_config('request.jwt.claim.sub', '', false);
set role anon;
select pg_temp.ok(not exists (select 1 from public.profiles where username = 'Lucky_Lou')
  and exists (select 1 from public.profiles where username = 'alice'), 'other players cannot see a guest profile or the name it picked');
reset role;
select pg_temp.ok((select username from public.feedback order by id desc limit 1) is null, 'guest feedback carries no username');
-- Supabase then sets the login email and password on the same account.
update auth.users set email = 'lucky_lou@users.chamimarket.app', is_anonymous = false where id = :'guest';
select pg_temp.ok((select cash from public.portfolios where user_id = :'guest') <> 100000
  and exists (select 1 from public.game_rounds where user_id = :'guest'), 'signing up keeps the guest balance and history');
select pg_temp.ok(exists (select 1 from jsonb_array_elements(private.leaderboard_rows()) x where x ->> 'name' = 'Lucky_Lou'), 'the new player joins the leaderboard');
set role anon;
select pg_temp.ok(exists (select 1 from public.profiles where username = 'Lucky_Lou'), 'once signed up the profile is public');
reset role;
set role authenticated;
select set_config('request.jwt.claim.sub', :'guest', false);
select pg_temp.ok(public.claim_guest('Other_Name') ->> 'error' like '%already has a username%', 'claiming is for guests only');
reset role;
-- A guest can't take someone else's login address without their name.
select pg_temp.expect_error(format($q$update auth.users set email = 'alice@users.chamimarket.app', is_anonymous = false where id = %L$q$, :'guest2'), '%not available%');
-- Idle guests are cleaned up by the sync job; ones still playing stay.
update auth.users set created_at = now() - interval '3 days' where id in (:'guest2', :'guest3');
update public.portfolios set updated_at = now() - interval '2 days' where user_id in (:'guest2', :'guest3');
insert into public.game_rounds (user_id, run, game, staked, returned, net) values (:'guest3', 1, 'dice', 1, 0, -1);
select public.sync_snapshots() \gset
select pg_temp.ok(not exists (select 1 from auth.users where id = :'guest2') and exists (select 1 from auth.users where id = :'guest3'),
  'a guest who never played is removed after a day, one who played is kept for 30');

-- Faster sync: the database asks GitHub to run the sync ---------------------------------
reset role;
-- Stand-in for pg_net.
create schema if not exists net;
create table net.calls (url text, body jsonb, headers jsonb);
create function net.http_post(url text, body jsonb, headers jsonb, timeout_milliseconds int) returns bigint language sql as $$
  insert into net.calls values (url, body, headers) returning 42::bigint $$;
select private.dispatch_sync() as dispatched \gset
select pg_temp.ok(:dispatched = 42
  and (select url from net.calls) = 'https://ksyzpzbdlwinoirnprso.supabase.co/functions/v1/sync'
  and (select count(*) from net.calls) = 1 and not ((select headers from net.calls) ? 'Authorization'),
  'the schedule starts this project''s sync function, with no key or token');
select pg_temp.expect_error($$set role authenticated; select private.dispatch_sync()$$, '%permission denied%');
reset role;
-- A sync can start at most once every 4 minutes, and only the sync function may claim one.
update private.sync_state set started_at = '-infinity';
select pg_temp.ok(public.sync_claim() and not public.sync_claim(), 'a second start within 4 minutes is refused');
update private.sync_state set started_at = now() - interval '5 minutes';
select pg_temp.ok(public.sync_claim(), 'a new run can start once 4 minutes have passed');
select pg_temp.expect_error($$set role anon; select public.sync_claim()$$, '%permission denied%');
reset role;
select pg_temp.expect_error($$set role authenticated; select public.sync_claim()$$, '%permission denied%');
reset role;
set client_min_messages = warning;
drop schema net cascade;
set client_min_messages = notice;

-- Tables (multiplayer poker) ---------------------------------------------------------
reset role;
set client_min_messages = warning;
insert into auth.users (email, raw_user_meta_data) values
  ('pone@users.test', '{"username":"pone"}'), ('ptwo@users.test', '{"username":"ptwo"}'), ('pthree@users.test', '{"username":"pthree"}'),
  ('pfour@users.test', '{"username":"pfour"}'), ('pfive@users.test', '{"username":"pfive"}'), ('psix@users.test', '{"username":"psix"}'),
  ('pseven@users.test', '{"username":"pseven"}');
insert into auth.users (email, is_anonymous) values (null, true);
select id as pkguest from auth.users where is_anonymous order by created_at desc, id limit 1 \gset

-- Test players by number, and peeks at what the client roles can't reach.
create or replace function pg_temp.u(n int) returns uuid language sql security definer as $$
  select id from public.profiles where username = (array['pone', 'ptwo', 'pthree', 'pfour', 'pfive', 'psix', 'pseven'])[n] $$;
create or replace function pg_temp.lb() returns jsonb language sql security definer as $$ select private.leaderboard_rows() $$;
create or replace function pg_temp.rank(p_cards text) returns int[] language sql security definer as $$ select private.poker_rank(string_to_array(p_cards, ' ')) $$;
-- A table with $50/$100 blinds and any buy-in, so stacks can be whatever a scenario needs.
create or replace function pg_temp.pk_table(p_seats int default 6) returns bigint language plpgsql security definer as $$
declare v_id bigint;
begin
  insert into public.poker_tables (stake, small_blind, big_blind, min_buy, max_buy, max_seats) values ('test', 50, 100, 1, 1000000, p_seats) returning id into v_id;
  perform private.poker_publish(v_id);
  return v_id;
end $$;
create or replace function pg_temp.pk_drop(p_table bigint) returns void language sql security definer as $$ delete from public.poker_tables where id = p_table $$;
create or replace function pg_temp.pk_user(p_table bigint, p_seat int) returns uuid language sql security definer as $$
  select user_id from private.poker_seats where table_id = p_table and seat = p_seat $$;
create or replace function pg_temp.pk_seat(p_table bigint, p_seat int) returns jsonb language sql security definer as $$
  select to_jsonb(s) from private.poker_seats s where table_id = p_table and seat = p_seat $$;
create or replace function pg_temp.pk_hand(p_table bigint) returns jsonb language sql security definer as $$
  select to_jsonb(h) from private.poker_hands h where table_id = p_table $$;
-- Moves a table's clock forward: its deadline and everyone's time away get that much older.
create or replace function pg_temp.pk_age(p_table bigint, p_secs numeric) returns void language plpgsql security definer as $$
begin
  update public.poker_tables set deadline = deadline - make_interval(secs => p_secs) where id = p_table;
  update private.poker_seats set away_since = away_since - make_interval(secs => p_secs), seen_at = seen_at - make_interval(secs => p_secs) where table_id = p_table;
end $$;
create or replace function pg_temp.pk_cash(p_n int) returns numeric language sql security definer as $$ select cash from public.portfolios where user_id = pg_temp.u(p_n) $$;
create or replace function pg_temp.pk_round(p_n int) returns jsonb language sql security definer as $$
  select to_jsonb(g) from public.game_rounds g where user_id = pg_temp.u(p_n) order by id desc limit 1 $$;
create or replace function pg_temp.sha(p text) returns text language sql security definer as $$ select encode(extensions.digest(p, 'sha256'), 'hex') $$;
-- Where a test player is seated, if anywhere.
create or replace function pg_temp.pk_where(p_n int) returns jsonb language sql security definer as $$
  select to_jsonb(s) - 'hole' - 'hole_idx' from private.poker_seats s where user_id = pg_temp.u(p_n) $$;
-- Deals the next hand now with the button on p_button, then swaps in hole cards ({"<seat>": ["As", "Kd"]}) and a board.
create or replace function pg_temp.pk_deal(p_table bigint, p_button int, p_holes jsonb default '{}', p_board text[] default null) returns void
language plpgsql security definer as $$
declare h private.poker_hands; n int; k text; v jsonb;
begin
  select * into h from private.poker_hands where table_id = p_table;
  if h.table_id is not null and h.street not in ('done', 'idle') then raise exception 'a hand is still being played'; end if;
  if h.table_id is null then
    insert into private.poker_hands (table_id, hand_no, street, deck, salts, commits, deck_hash, next_card, button, last_raise)
    values (p_table, 0, 'idle', '{}', '{}', '{}', '', 0, (p_button + 5) % 6, 0);
  else
    update private.poker_hands set button = (p_button + 5) % 6 where table_id = p_table;
  end if;
  update public.poker_tables set deadline = now() - interval '2 seconds' where id = p_table;
  perform private.poker_advance(p_table);
  select * into h from private.poker_hands where table_id = p_table;
  if h.street <> 'preflop' or h.button <> p_button then raise exception 'could not deal with the button on seat %: %', p_button, to_jsonb(h) - 'deck' - 'salts' - 'commits'; end if;
  for k, v in select * from jsonb_each(p_holes) loop
    update private.poker_seats set hole = array[v ->> 0, v ->> 1] where table_id = p_table and seat = k::int;
  end loop;
  if p_board is not null then
    n := h.next_card;
    update private.poker_hands set deck[n + 2] = p_board[1], deck[n + 3] = p_board[2], deck[n + 4] = p_board[3], deck[n + 6] = p_board[4], deck[n + 8] = p_board[5]
    where table_id = p_table;
  end if;
end $$;
-- Every chip the test players own: cash, stacks and what is in the pots.
create or replace function pg_temp.pk_chips() returns numeric language sql security definer as $$
  select (select sum(cash) from public.portfolios where user_id in (select pg_temp.u(n) from generate_series(1, 7) n))
    + (select coalesce(sum(stack + committed), 0) from private.poker_seats) $$;
-- Every card a client must not see right now: the deck and burn cards, and every hand that hasn't been shown.
create or replace function pg_temp.pk_hidden(p_table bigint) returns text[] language sql security definer as $$
  select coalesce(array_agg(c), '{}') from (
    select unnest(h.deck) as c from private.poker_hands h where h.table_id = p_table and h.street <> 'idle'
    union select unnest(s.hole) from private.poker_seats s where s.table_id = p_table and s.in_hand
    except select unnest(h.board) from private.poker_hands h where h.table_id = p_table
    except select unnest(s.hole) from private.poker_seats s join private.poker_hands h using (table_id) where s.table_id = p_table and s.shown and h.street = 'done') q $$;
-- Every card named anywhere in a JSON answer.
create or replace function pg_temp.json_cards(j jsonb) returns text[] language sql as $$
  select coalesce(array_agg(distinct v #>> '{}'), '{}') from jsonb_path_query(j, '$.** ? (@.type() == "string")') v where v #>> '{}' ~ '^[2-9TJQKA][shdc]$' $$;
grant execute on function pg_temp.pk_cash(int), pg_temp.pk_round(int), pg_temp.sha(text), pg_temp.pk_where(int), pg_temp.lb(), pg_temp.u(int), pg_temp.rank(text), pg_temp.pk_table(int), pg_temp.pk_drop(bigint), pg_temp.pk_user(bigint, int), pg_temp.pk_seat(bigint, int),
  pg_temp.pk_hand(bigint), pg_temp.pk_age(bigint, numeric), pg_temp.pk_deal(bigint, int, jsonb, text[]), pg_temp.pk_chips(), pg_temp.pk_hidden(bigint),
  pg_temp.json_cards(jsonb) to authenticated, anon;

-- The rest run as whoever calls them (a signed-in player), through the public functions only.
create or replace function pg_temp.pk_as(p_n int) returns void language sql as $$
  select set_config('request.jwt.claim.sub', pg_temp.u(p_n)::text, false), pg_temp.clear_limits() $$;
create or replace function pg_temp.pk_state(p_table bigint) returns jsonb language sql as $$ select state from public.poker_tables where id = p_table $$;
-- Player p_n sits down; fails the test when the server refuses.
create or replace function pg_temp.pk_sit(p_table bigint, p_n int, p_buy numeric, p_seat int default null) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform pg_temp.pk_as(p_n);
  r := public.poker_sit(p_table, p_buy, p_seat);
  if r ? 'error' then raise exception 'player % could not sit: %', p_n, r ->> 'error'; end if;
  return r;
end $$;
-- A new test table with players 1..n in seats 0..n-1 holding the given stacks.
create or replace function pg_temp.pk_setup(p_stacks numeric[]) returns bigint language plpgsql as $$
declare v_table bigint := pg_temp.pk_table(); i int;
begin
  for i in 1..array_length(p_stacks, 1) loop perform pg_temp.pk_sit(v_table, i, p_stacks[i], i - 1); end loop;
  return v_table;
end $$;
-- The player in a seat makes a move. pk_do fails the test when it is refused; pk_err returns the refusal instead.
create or replace function pg_temp.pk_move(p_table bigint, p_seat int, p_action text, p_amount numeric default null, p_turn int default null) returns jsonb language plpgsql as $$
begin
  perform pg_temp.clear_limits();
  perform set_config('request.jwt.claim.sub', pg_temp.pk_user(p_table, p_seat)::text, false);
  return public.poker_act(p_table, p_action, p_amount, p_turn);
end $$;
create or replace function pg_temp.pk_do(p_table bigint, p_seat int, p_action text, p_amount numeric default null) returns jsonb language plpgsql as $$
declare r jsonb := pg_temp.pk_move(p_table, p_seat, p_action, p_amount);
begin
  if r ? 'error' then raise exception 'seat % could not % %: % (%)', p_seat, p_action, p_amount, r ->> 'error', r -> 'table' -> 'state' -> 'act'; end if;
  return r -> 'table' -> 'state';
end $$;
create or replace function pg_temp.pk_err(p_table bigint, p_seat int, p_action text, p_amount numeric default null, p_turn int default null) returns text language sql as $$
  select coalesce(pg_temp.pk_move(p_table, p_seat, p_action, p_amount, p_turn) ->> 'error', 'accepted') $$;
-- Plays moves in order: 'seat:action[:amount]', e.g. '0:raise:300 1:call 2:fold'.
create or replace function pg_temp.pk_play(p_table bigint, p_moves text) returns jsonb language plpgsql as $$
declare m text; parts text[]; r jsonb;
begin
  foreach m in array string_to_array(p_moves, ' ') loop
    parts := string_to_array(m, ':');
    r := pg_temp.pk_do(p_table, parts[1]::int, parts[2], parts[3]::numeric);
  end loop;
  return r;
end $$;
-- A push of the clock by any signed-in player.
create or replace function pg_temp.pk_tick(p_table bigint, p_secs numeric) returns jsonb language plpgsql as $$
begin
  perform pg_temp.pk_age(p_table, p_secs);
  perform pg_temp.pk_as(7);
  perform public.poker_tick(p_table);
  return pg_temp.pk_state(p_table);
end $$;
-- Everyone gets up (between hands) and the table is thrown away.
create or replace function pg_temp.pk_close(p_table bigint) returns void language plpgsql as $$
declare i int; r jsonb;
begin
  if pg_temp.pk_state(p_table) ->> 'phase' not in ('waiting', 'showdown') then raise exception 'closing table % mid-hand', p_table; end if;
  for i in 0..5 loop
    if pg_temp.pk_user(p_table, i) is not null and not (pg_temp.pk_seat(p_table, i) ->> 'leaving')::boolean then
      perform pg_temp.clear_limits();
      perform set_config('request.jwt.claim.sub', pg_temp.pk_user(p_table, i)::text, false);
      r := public.poker_leave(p_table);
      if r ? 'error' then raise exception 'seat % could not leave: %', i, r ->> 'error'; end if;
    end if;
  end loop;
  perform pg_temp.pk_tick(p_table, 600);
  perform pg_temp.pk_drop(p_table);
end $$;
create or replace function pg_temp.stacks(st jsonb) returns int[] language sql as $$
  select array_agg(coalesce((s ->> 'stack')::int, -1) order by n) from jsonb_array_elements(st -> 'seats') with ordinality as t(s, n) $$;
set client_min_messages = notice;
select pg_temp.pk_chips() as pk_total \gset

-- Hand strength: every category, and the ranks that break ties.
select pg_temp.ok(pg_temp.rank('As Ks Qs Js Ts 2d 3c') = array[8, 14, 0, 0, 0, 0] and pg_temp.rank('9h 8h 7h 6h 5h As Ad') = array[8, 9, 0, 0, 0, 0]
  and pg_temp.rank('5h 4h 3h 2h Ah Kd Kc') = array[8, 5, 0, 0, 0, 0], 'straight flushes: royal, nine-high, and the ace playing low');
select pg_temp.ok(pg_temp.rank('9c 9d 9h 9s Kd Ks 2c') = array[7, 9, 13, 0, 0, 0] and pg_temp.rank('Qs Qh Qd Qc 3s Ah 2d') = array[7, 12, 14, 0, 0, 0],
  'four of a kind takes the best other card as its kicker');
select pg_temp.ok(pg_temp.rank('Ks Kh Kd 2c 2d 9s 8s') = array[6, 13, 2, 0, 0, 0] and pg_temp.rank('Ks Kh Kd 9c 9d 9s 2s') = array[6, 13, 9, 0, 0, 0]
  and pg_temp.rank('Ks Kh Kd 9c 9d 4s 4h') = array[6, 13, 9, 0, 0, 0] and pg_temp.rank('2s 2h 2d Ac Ad Ks Kh') = array[6, 2, 14, 0, 0, 0],
  'full houses: two sets of three, or three and two pairs, use the best pair');
select pg_temp.ok(pg_temp.rank('Ah Jh 9h 6h 3h 2h Kd') = array[5, 14, 11, 9, 6, 3] and pg_temp.rank('Ah Kh Qh Jh 9h Td 2c') = array[5, 14, 13, 12, 11, 9],
  'a flush plays its five highest cards, and beats the straight it also makes');
select pg_temp.ok(pg_temp.rank('Ts 9d 8h 7c 6s 2d 2c') = array[4, 10, 0, 0, 0, 0] and pg_temp.rank('Ad 2s 3h 4c 5d Kd Qs') = array[4, 5, 0, 0, 0, 0]
  and pg_temp.rank('Ad Ks Qh Jc Td 2d 3s') = array[4, 14, 0, 0, 0, 0] and pg_temp.rank('Ad 2s 3h 4c 5d 6d Qs') = array[4, 6, 0, 0, 0, 0]
  and pg_temp.rank('Ts 9d 8h 7c 6s 5d 4c') = array[4, 10, 0, 0, 0, 0] and (pg_temp.rank('Qd Ks Ah 2c 3d 4s 9h'))[1] = 0,
  'straights: the wheel is five-high, a six-high straight beats it, and K-A-2 does not wrap around');
select pg_temp.ok(pg_temp.rank('Qs Qh Qd Ac 9d 4s 2h') = array[3, 12, 14, 9, 0, 0], 'three of a kind with two kickers');
select pg_temp.ok(pg_temp.rank('Ks Kh 4d 4c As 9d 2h') = array[2, 13, 4, 14, 0, 0] and pg_temp.rank('Ks Kh 9d 9c 4s 4h Ad') = array[2, 13, 9, 14, 0, 0]
  and pg_temp.rank('Ks Kh 9d 9c 4s 4h 3d') = array[2, 13, 9, 4, 0, 0], 'two pair: the best two pairs, and the kicker can come from a third pair');
select pg_temp.ok(pg_temp.rank('As Ad Kh 9c 5d 3s 2h') = array[1, 14, 13, 9, 5, 0] and pg_temp.rank('As Kd 9h 7c 5d 3s 2h') = array[0, 14, 13, 9, 7, 5],
  'a pair with three kickers, and high card with five');
select pg_temp.ok(pg_temp.rank('As Kd Ah 7c 5d 3s 2h') > pg_temp.rank('Ac Qd Ah 7c 5d 3s 2h')
  and pg_temp.rank('As Kd Ah 7c 5d 3s 2h') = pg_temp.rank('Ac Kh Ah 7c 5d 3s 2h')
  and pg_temp.rank('Ks Qd Ah Jc 9d 3s 2h') > pg_temp.rank('Kc Qh Ah Jc 8d 3s 2h'), 'kickers decide, down to the fifth card, and equal hands tie whatever the suits');
select pg_temp.ok(pg_temp.rank('2c 3d As Ks Qs Js Ts') = pg_temp.rank('Ah Ad As Ks Qs Js Ts')
  and pg_temp.rank('2c 3d Ah Kd Qc Js 9h') = pg_temp.rank('4c 5d Ah Kd Qc Js 9h')
  and pg_temp.rank('Kh Jd Qs Qh Qd Qc As') = pg_temp.rank('2h 3d Qs Qh Qd Qc As'), 'when the board is the best hand, everyone ties');
select pg_temp.ok((select bool_and(a > b) from (select pg_temp.rank(h) a, lead(pg_temp.rank(h)) over (order by n) b from unnest(array[
  '6h 5h 4h 3h 2h', '2c 2d 2h 2s 3d', '2c 2d 2h 3s 3d', '7h 5h 4h 3h 2h', '5c 4d 3h 2s Ad', 'Ac Ad Ah Ks Qd', 'Ac Ad Kh Ks Qd', 'Ac Ad Kh Qs Jd', 'Ac Kd Qh Js 9d'
  ]) with ordinality as t(h, n)) q where b is not null),
  'the weakest hand of each category beats the strongest of the next: straight flush, four of a kind, full house, flush, straight, three of a kind, two pair, pair, high card');
select pg_temp.ok(pg_temp.rank('As Ks Qs Js Ts') = array[8, 14, 0, 0, 0, 0] and pg_temp.rank('As Ad Kh 9c 5d 3s') = array[1, 14, 13, 9, 5, 0], 'five and six cards rank too');
select pg_temp.expect_error($$select pg_temp.rank('As Ks Qs Js')$$, '%5 to 7 cards%');
select pg_temp.expect_error($$select pg_temp.rank('As Ks Qs Js 1s')$$, '%Bad card%');

-- The lobby, sitting down and the money ---------------------------------------------
set role authenticated;
select pg_temp.pk_as(1);
select pg_temp.ok((select jsonb_agg(t ->> 'stake') from jsonb_array_elements(public.poker_lobby() -> 'tables') t) = '["micro", "low", "mid", "high"]'
  and public.poker_lobby() -> 'seat' = 'null' and (public.poker_lobby() ->> 'canSit')::boolean, 'the lobby lists an open table at every stake');
select (t ->> 'id')::bigint as lowtable from jsonb_array_elements(public.poker_lobby() -> 'tables') t where t ->> 'stake' = 'low' \gset
do $$
declare r jsonb; lobby jsonb := public.poker_lobby(); tbl bigint; other bigint; i int; before numeric := (public.get_portfolio() ->> 'cash')::numeric;
begin
  select (t ->> 'id')::bigint into tbl from jsonb_array_elements(lobby -> 'tables') t where t ->> 'stake' = 'low';
  perform pg_temp.ok(public.poker_sit(tbl, 100) ->> 'error' like '%$200 to $1000%' and public.poker_sit(tbl, 1001) ->> 'error' like '%$200 to $1000%'
    and public.poker_sit(tbl, 250.5) ->> 'error' like '%whole dollars%' and public.poker_sit(tbl, 'NaN') ->> 'error' like '%$200%'
    and public.poker_sit(tbl, null) ->> 'error' like '%$200%', 'a buy-in is 20 to 100 big blinds in whole dollars');
  perform pg_temp.ok(public.poker_sit(tbl, 500, 6) ->> 'error' like '%Pick a seat%' and public.poker_sit(-1, 500) ->> 'error' like '%closed%', 'seats and tables must exist');
  r := public.poker_sit(tbl, 500, 2);
  perform pg_temp.ok((r -> 'me' ->> 'seat')::int = 2 and (r -> 'me' ->> 'stack')::int = 500 and (r -> 'portfolio' ->> 'cash')::numeric = before - 500
    and (r -> 'portfolio' ->> 'tableChips')::numeric = 500 and r -> 'table' -> 'state' -> 'seats' -> 2 ->> 'name' = 'pone'
    and r -> 'table' -> 'state' ->> 'phase' = 'waiting', 'sitting down moves the buy-in from cash to the table');
  perform pg_temp.ok(public.poker_sit(tbl, 500) ->> 'error' like '%already have a seat%', 'one seat per player');
  select (t ->> 'id')::bigint into other from jsonb_array_elements(lobby -> 'tables') t where t ->> 'stake' = 'mid';
  perform pg_temp.ok(public.poker_sit(other, 2000) ->> 'error' like '%already have a seat%', 'at any table');
  perform pg_temp.ok((public.poker_lobby() -> 'seat' ->> 'table')::bigint = tbl, 'the lobby knows where the player is seated');
  perform pg_temp.ok(public.poker_buy(tbl, 600) ->> 'error' like '%up to $1000%' and public.poker_buy(tbl, 0.5) ->> 'error' like '%whole number%', 'adding chips stops at the largest buy-in');
  r := public.poker_buy(tbl, 300);
  perform pg_temp.ok((r -> 'me' ->> 'stack')::int = 800 and (r -> 'portfolio' ->> 'cash')::numeric = before - 800, 'adding chips moves more cash to the stack');
  perform pg_temp.pk_as(2);
  perform pg_temp.ok(public.poker_sit(tbl, 500, 2) ->> 'error' like '%just taken%', 'a taken seat is refused');
  perform pg_temp.ok(public.poker_leave(tbl) ->> 'error' like '%not seated%' and public.poker_act(tbl, 'fold') ->> 'error' like '%Take a seat%'
    and public.poker_away(tbl, true) ->> 'error' like '%not seated%' and public.poker_buy(tbl, 100) ->> 'error' like '%not seated%', 'only seated players can act, leave, sit out or add chips');
  perform pg_temp.pk_as(1);
  r := public.poker_leave(tbl);
  perform pg_temp.ok(r -> 'me' = 'null' and (r -> 'portfolio' ->> 'cash')::numeric = before and (r -> 'portfolio' ->> 'tableChips')::numeric = 0
    and r -> 'table' -> 'state' -> 'seats' -> 2 = 'null', 'leaving moves the whole stack back to cash');
end $$;
-- Guests can watch but not sit.
select set_config('request.jwt.claim.sub', :'pkguest', false);
select pg_temp.ok(public.poker_sit(:lowtable, 500) ->> 'error' like '%Sign up%' and not (public.poker_lobby() ->> 'canSit')::boolean
  and public.poker_state(:lowtable) -> 'me' = 'null' and public.poker_state(:lowtable) -> 'table' -> 'state' ->> 'phase' = 'waiting', 'guests can watch a table but not take a seat');
-- A full table opens another at the same stake; spare empty ones are closed again.
do $$
declare tbl bigint; i int; n int;
begin
  perform pg_temp.pk_as(1);
  select (t ->> 'id')::bigint into tbl from jsonb_array_elements(public.poker_lobby() -> 'tables') t where t ->> 'stake' = 'micro';
  for i in 1..6 loop perform pg_temp.pk_sit(tbl, i, 100); end loop;
  perform pg_temp.pk_as(7);
  perform pg_temp.ok(public.poker_sit(tbl, 100) ->> 'error' like '%full%', 'a seventh player finds the table full');
  select count(*) into n from jsonb_array_elements(public.poker_lobby() -> 'tables') t where t ->> 'stake' = 'micro';
  perform pg_temp.ok(n = 2 and (select (t ->> 'seated')::int from jsonb_array_elements(public.poker_lobby() -> 'tables') t where (t ->> 'id')::bigint = tbl) = 6,
    'when every table at a stake is full a new one opens');
  for i in 1..6 loop
    perform pg_temp.pk_as(i);
    perform public.poker_leave(tbl);
  end loop;
end $$;
reset role;
update public.poker_tables set updated_at = now() - interval '11 minutes' where stake = 'micro';
select private.poker_sweep() as swept \gset
select pg_temp.ok((select count(*) from public.poker_tables where stake = 'micro') = 1
  and (select count(*) from public.poker_tables where stake in ('low', 'mid', 'high')) = 3, 'spare empty tables close after ten minutes; one per stake always stays');
select pg_temp.ok(pg_temp.pk_chips() = :pk_total, 'sitting, adding chips and leaving never create or lose a chip');
set role authenticated;

-- A whole three-handed hand: positions, bet sizes, the pot and the records ------------
do $$
declare t bigint := pg_temp.pk_setup(array[10000, 10000, 10000]); st jsonb; r jsonb; rounds int;
begin
  perform pg_temp.pk_deal(t, 0, '{"0": ["As", "Ah"], "1": ["7c", "2d"], "2": ["Kc", "Qd"]}', array['Kd', '8s', '3h', '4c', '9d']);
  perform pg_temp.pk_as(1);
  st := public.poker_state(t) -> 'table' -> 'state';
  perform pg_temp.ok(st ->> 'phase' = 'preflop' and (st ->> 'button')::int = 0 and (st ->> 'sb')::int = 1 and (st ->> 'bb')::int = 2
    and pg_temp.stacks(st) = array[10000, 9950, 9900, -1, -1, -1] and (st ->> 'pot')::int = 150 and (st ->> 'bet')::int = 100
    and st -> 'act' = '{"seat": 0, "toCall": 100, "canRaise": true, "minRaise": 200, "maxRaise": 10000}',
    'three-handed: blinds sit left of the button and the player after the big blind acts first');
  perform pg_temp.ok(pg_temp.pk_err(t, 1, 'call') like '%not your turn%' and pg_temp.pk_err(t, 0, 'check') like '%bet to call%'
    and pg_temp.pk_err(t, 0, 'bet', 300) like '%already a bet%' and pg_temp.pk_err(t, 0, 'raise', 199) like '%smallest raise here is 200%'
    and pg_temp.pk_err(t, 0, 'raise', 250.5) like '%whole number%' and pg_temp.pk_err(t, 0, 'raise', 10001) like '%that many chips%'
    and pg_temp.pk_err(t, 0, 'raise', null) like '%whole number%' and pg_temp.pk_err(t, 0, 'shove') like '%Unknown move%'
    and pg_temp.pk_err(t, 0, null) like '%Unknown move%', 'bad moves are refused with a reason and change nothing');
  st := pg_temp.pk_do(t, 0, 'raise', 250);
  perform pg_temp.ok(st -> 'act' = '{"seat": 1, "toCall": 200, "canRaise": true, "minRaise": 400, "maxRaise": 10000}',
    'after a raise of 150 the next raise must add at least 150');
  perform pg_temp.ok(pg_temp.pk_err(t, 1, 'raise', 399) like '%smallest raise here is 400%', 'a raise below the minimum is refused');
  st := pg_temp.pk_play(t, '1:call 2:call');
  perform pg_temp.ok(st ->> 'phase' = 'flop' and st -> 'board' = '["Kd", "8s", "3h"]' and (st ->> 'pot')::int = 750 and st -> 'pots' = '[750]'
    and st -> 'act' = '{"seat": 1, "toCall": 0, "canRaise": true, "minRaise": 100, "maxRaise": 9750}', 'the flop: three cards, and the first player after the button acts');
  perform pg_temp.ok(pg_temp.pk_err(t, 1, 'call') like '%nothing to call%' and pg_temp.pk_err(t, 1, 'raise', 200) like '%Nobody has bet%'
    and pg_temp.pk_err(t, 1, 'bet', 99) like '%smallest bet here is 100%', 'the smallest bet is the big blind');
  st := pg_temp.pk_play(t, '1:check 2:bet:100 0:raise:300 1:fold 2:call');
  perform pg_temp.ok(st ->> 'phase' = 'turn' and jsonb_array_length(st -> 'board') = 4 and (st ->> 'pot')::int = 1350 and (st -> 'act' ->> 'seat')::int = 2
    and (st -> 'seats' -> 1 ->> 'folded')::boolean, 'the turn: a folded player is skipped');
  st := pg_temp.pk_play(t, '2:check 0:check 2:check 0:check');
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and pg_temp.stacks(st) = array[10800, 9750, 9450, -1, -1, -1]
    and st -> 'result' -> 'pots' = '[{"seats": [0, 2], "amount": 1350, "winners": [{"seat": 0, "amount": 1350}]}]'
    and st -> 'seats' -> 0 -> 'cards' = '["As", "Ah"]' and st -> 'seats' -> 2 -> 'cards' = '["Kc", "Qd"]' and st -> 'seats' -> 1 -> 'cards' = 'null'
    and st -> 'seats' -> 0 -> 'rank' = '[1, 14, 13, 9, 8, 0]' and (st -> 'seats' -> 0 ->> 'won')::int = 1350,
    'showdown: the best hand takes the pot and the folded hand stays face down');
  perform pg_temp.pk_as(1);
  r := public.get_portfolio();
  perform pg_temp.ok(r -> 'games' -> 'history' -> 0 ->> 'game' = 'poker' and (r -> 'games' -> 'history' -> 0 ->> 'staked')::numeric = 550
    and (r -> 'games' -> 'history' -> 0 ->> 'net')::numeric = 800 and r -> 'games' -> 'history' -> 0 ->> 'detail' = 'Won with a pair · $50/$100'
    and (r ->> 'cash')::numeric = 90000 and (r ->> 'tableChips')::numeric = 10800, 'the winner''s history shows the hand''s net result; the chips stay at the table');
  perform pg_temp.pk_as(2);
  r := public.get_portfolio();
  perform pg_temp.ok((r -> 'games' -> 'history' -> 0 ->> 'net')::numeric = -250 and r -> 'games' -> 'history' -> 0 ->> 'detail' like 'Folded%'
    and (r -> 'games' -> 'stats' -> 'poker' ->> 'rounds')::int = 1, 'a fold records the chips lost');
  perform pg_temp.ok((select count(*) from public.activity where game = 'poker') = 1
    and (select username = 'pone' and net = 800 and detail = 'with a pair ($50/$100)' from public.activity where game = 'poker' order by id desc limit 1),
    'only the winner goes to the live feed');
  perform pg_temp.ok((select (x ->> 'netWorth')::numeric = 100800 and (x ->> 'pnl')::numeric = 800 and (x -> 'games' ->> 'net')::numeric = 800 and (x ->> 'marketPnl')::numeric = 0
    from jsonb_array_elements(pg_temp.lb()) x where x ->> 'name' = 'pone'), 'chips at a table count toward net worth, and the win shows as games winnings on the leaderboard');
  perform pg_temp.pk_close(t);
end $$;

-- Heads-up: the button posts the small blind, acts first before the flop and last after it ----
do $$
declare t bigint := pg_temp.pk_setup(array[5000, 5000]); st jsonb;
begin
  perform pg_temp.pk_deal(t, 0);
  st := pg_temp.pk_state(t);
  perform pg_temp.ok((st ->> 'button')::int = 0 and (st ->> 'sb')::int = 0 and (st ->> 'bb')::int = 1 and pg_temp.stacks(st) = array[4950, 4900, -1, -1, -1, -1]
    and st -> 'act' = '{"seat": 0, "toCall": 50, "canRaise": true, "minRaise": 200, "maxRaise": 5000}', 'heads-up: the button is the small blind and acts first before the flop');
  st := pg_temp.pk_do(t, 0, 'call');
  perform pg_temp.ok(st ->> 'phase' = 'preflop' and st -> 'act' = '{"seat": 1, "toCall": 0, "canRaise": true, "minRaise": 200, "maxRaise": 5000}',
    'the big blind may still raise after a call');
  st := pg_temp.pk_do(t, 1, 'check');
  perform pg_temp.ok(st ->> 'phase' = 'flop' and (st -> 'act' ->> 'seat')::int = 1, 'after the flop the big blind acts first and the button last');
  st := pg_temp.pk_play(t, '1:check 0:check');
  perform pg_temp.ok(st ->> 'phase' = 'turn' and (st -> 'act' ->> 'seat')::int = 1, 'and on every later round');
  st := pg_temp.pk_play(t, '1:bet:200 0:fold');
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and not (st -> 'result' ->> 'showdown')::boolean and pg_temp.stacks(st) = array[4900, 5100, -1, -1, -1, -1]
    and st -> 'seats' -> 1 -> 'cards' = 'null' and st -> 'seats' -> 0 -> 'cards' = 'null' and st -> 'result' -> 'pots' -> 0 ->> 'amount' = '200',
    'when everyone else folds the winner takes the pot without showing, and the uncalled bet comes back');
  -- The clock deals the next hand: the button moves to the other player.
  st := pg_temp.pk_tick(t, 3);
  perform pg_temp.ok(st ->> 'phase' = 'showdown', 'the finished hand stays on the table for a few seconds');
  st := pg_temp.pk_tick(t, 5);
  perform pg_temp.ok(st ->> 'phase' = 'preflop' and (st ->> 'button')::int = 1 and (st ->> 'sb')::int = 1 and (st ->> 'bb')::int = 0 and (st -> 'act' ->> 'seat')::int = 1
    and (st ->> 'hand')::int = 2, 'the next hand is dealt by the clock and the button moves on');
  st := pg_temp.pk_do(t, 1, 'fold');
  perform pg_temp.ok(pg_temp.stacks(st) = array[4950, 5050, -1, -1, -1, -1] and st -> 'result' -> 'players' = '[{"net": 50, "won": 100, "seat": 0}, {"net": -50, "won": 0, "seat": 1}]',
    'a big blind who is folded to wins the small blind');
  perform pg_temp.pk_close(t);
end $$;

-- The big blind raising reopens the betting for the players who only called.
do $$
declare t bigint := pg_temp.pk_setup(array[5000, 5000, 5000]); st jsonb;
begin
  perform pg_temp.pk_deal(t, 2);
  st := pg_temp.pk_state(t);
  perform pg_temp.ok((st ->> 'sb')::int = 0 and (st ->> 'bb')::int = 1 and (st -> 'act' ->> 'seat')::int = 2, 'with the button on the last seat the blinds wrap around');
  st := pg_temp.pk_play(t, '2:call 0:call 1:raise:400');
  perform pg_temp.ok(st -> 'act' = '{"seat": 2, "toCall": 300, "canRaise": true, "minRaise": 700, "maxRaise": 5000}', 'a raise from the big blind sends the action round again');
  st := pg_temp.pk_play(t, '2:fold 0:fold');
  perform pg_temp.ok(pg_temp.stacks(st) = array[4900, 5200, 4900, -1, -1, -1], 'and takes the calls when both fold');
  perform pg_temp.pk_close(t);
end $$;

-- An all-in raise smaller than a full raise does not reopen the betting.
do $$
declare t bigint := pg_temp.pk_setup(array[10000, 10000, 250]); st jsonb;
begin
  perform pg_temp.pk_deal(t, 0);
  st := pg_temp.pk_play(t, '0:call 1:call 2:check 1:bet:100');
  perform pg_temp.ok(st -> 'act' = '{"seat": 2, "toCall": 100, "canRaise": true, "minRaise": 150, "maxRaise": 150}', 'a short stack may go all-in for less than a full raise');
  st := pg_temp.pk_do(t, 2, 'raise', 150);
  perform pg_temp.ok(st -> 'seats' -> 2 ->> 'last' = 'allin' and (st -> 'seats' -> 2 ->> 'allIn')::boolean
    and st -> 'act' = '{"seat": 0, "toCall": 150, "canRaise": true, "minRaise": 250, "maxRaise": 9900}',
    'a player who has not acted yet may still raise, by at least the last full bet on top');
  st := pg_temp.pk_do(t, 0, 'call');
  perform pg_temp.ok(st -> 'act' = '{"seat": 1, "toCall": 50, "canRaise": false, "minRaise": 250, "maxRaise": 9900}', 'the bettor, who already acted, can only call or fold');
  perform pg_temp.ok(pg_temp.pk_err(t, 1, 'raise', 400) like '%only call or fold%' and pg_temp.pk_err(t, 1, 'check') like '%bet to call%', 'so a raise from them is refused');
  st := pg_temp.pk_do(t, 1, 'call');
  perform pg_temp.ok(st ->> 'phase' = 'turn' and (st ->> 'pot')::int = 750 and (st -> 'act' ->> 'seat')::int = 1, 'and the round ends once they call');
  st := pg_temp.pk_play(t, '1:check 0:check 1:check 0:check');
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and (select sum(x) from unnest(pg_temp.stacks(st)) x where x >= 0) = 20250, 'the pot is paid in full');
  perform pg_temp.pk_close(t);
end $$;

-- ...but a full raise from a player yet to act does, and so do short all-ins that add up to a full raise.
do $$
declare t bigint := pg_temp.pk_setup(array[10000, 10000, 250]); st jsonb;
begin
  perform pg_temp.pk_deal(t, 0);
  st := pg_temp.pk_play(t, '0:call 1:call 2:check 1:bet:100 2:raise:150 0:raise:250');
  perform pg_temp.ok(st -> 'act' = '{"seat": 1, "toCall": 150, "canRaise": true, "minRaise": 350, "maxRaise": 9900}', 'a full raise over a short all-in reopens the betting');
  st := pg_temp.pk_play(t, '1:fold');
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and jsonb_array_length(st -> 'board') = 5 and (st ->> 'runout')::int = 2
    and st -> 'result' -> 'pots' -> 0 ->> 'amount' = '700' and jsonb_array_length(st -> 'result' -> 'pots') = 1,
    'with one player left to bet the board runs out, and the uncalled part of the raise goes back');
  perform pg_temp.pk_close(t);
end $$;

do $$
declare t bigint := pg_temp.pk_setup(array[10000, 10000, 250, 300]); st jsonb;
begin
  perform pg_temp.pk_deal(t, 0, '{"0": ["Qs", "Qd"], "1": ["7c", "2d"], "2": ["As", "Ad"], "3": ["Ks", "Kd"]}', array['3h', '8c', '9d', 'Jh', '4s']);
  st := pg_temp.pk_play(t, '3:call 0:call 1:call 2:check 1:bet:100 2:raise:150 3:raise:200');
  perform pg_temp.ok(st -> 'act' = '{"seat": 0, "toCall": 200, "canRaise": true, "minRaise": 300, "maxRaise": 9900}', 'two short all-ins: 100, then 150, then 200');
  st := pg_temp.pk_do(t, 0, 'call');
  perform pg_temp.ok(st -> 'act' = '{"seat": 1, "toCall": 100, "canRaise": true, "minRaise": 300, "maxRaise": 9900}',
    'short all-ins that add up to a full raise reopen the betting for the first bettor');
  st := pg_temp.pk_do(t, 1, 'raise', 500);
  perform pg_temp.ok(st -> 'act' = '{"seat": 0, "toCall": 300, "canRaise": true, "minRaise": 800, "maxRaise": 9900}', 'and their raise of 300 sets the next minimum');
  st := pg_temp.pk_do(t, 0, 'call');
  perform pg_temp.ok(st ->> 'phase' = 'turn' and st -> 'pots' = '[1000, 150, 600]' and (st ->> 'pot')::int = 1750, 'three pots: one per all-in size, plus the rest');
  st := pg_temp.pk_play(t, '1:check 0:check 1:check 0:check');
  perform pg_temp.ok(st -> 'result' -> 'pots' = '[{"seats": [0, 1, 2, 3], "amount": 1000, "winners": [{"seat": 2, "amount": 1000}]},
      {"seats": [0, 1, 3], "amount": 150, "winners": [{"seat": 3, "amount": 150}]},
      {"seats": [0, 1], "amount": 600, "winners": [{"seat": 0, "amount": 600}]}]'
    and pg_temp.stacks(st) = array[10000, 9400, 1000, 150, -1, -1], 'each pot goes to the best hand among the players who paid into it');
  perform pg_temp.pk_close(t);
end $$;

-- Side pots with four all-ins of different sizes, and a bet nobody could match.
do $$
declare t bigint := pg_temp.pk_setup(array[1000, 300, 600, 150, 2000]); st jsonb;
begin
  perform pg_temp.pk_deal(t, 0, '{"0": ["7c", "2d"], "1": ["Ks", "Kd"], "2": ["Qs", "Qd"], "3": ["As", "Ad"], "4": ["Js", "Jd"]}', array['3h', '8c', '9d', '5h', '4s']);
  st := pg_temp.pk_do(t, 3, 'raise', 150);
  perform pg_temp.ok(st -> 'act' = '{"seat": 4, "toCall": 150, "canRaise": true, "minRaise": 250, "maxRaise": 2000}', 'an all-in of 150 over a 100 blind is not a full raise');
  st := pg_temp.pk_play(t, '4:raise:2000 0:call 1:call 2:call');
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and (st ->> 'runout')::int = 5 and st -> 'board' = '["3h", "8c", "9d", "5h", "4s"]', 'with everyone all-in the whole board is dealt at once');
  perform pg_temp.ok(st -> 'result' -> 'pots' = '[{"seats": [0, 1, 2, 3, 4], "amount": 750, "winners": [{"seat": 3, "amount": 750}]},
      {"seats": [0, 1, 2, 4], "amount": 600, "winners": [{"seat": 1, "amount": 600}]},
      {"seats": [0, 2, 4], "amount": 900, "winners": [{"seat": 2, "amount": 900}]},
      {"seats": [0, 4], "amount": 800, "winners": [{"seat": 4, "amount": 800}]}]',
    'four all-ins make four pots, each won by the best hand that paid into it');
  perform pg_temp.ok(pg_temp.stacks(st) = array[0, 600, 900, 750, 1800, -1], 'the biggest stack gets back the 1,000 nobody could call');
  perform pg_temp.ok((select bool_and(s -> 'cards' <> 'null') from jsonb_array_elements(st -> 'seats') s where s <> 'null')
    and (st -> 'seats' -> 0 ->> 'away')::boolean, 'every all-in hand is turned face up, and a player left with no chips sits out');
  -- The same hand with the best cards on the biggest stack: one player wins every pot.
  perform pg_temp.pk_as(1);
  perform pg_temp.ok((public.poker_buy(t, 1000) -> 'me' ->> 'stack')::int = 1000 and not (pg_temp.pk_state(t) -> 'seats' -> 0 ->> 'away')::boolean, 'adding chips brings a busted player back');
  perform pg_temp.pk_deal(t, 0, '{"0": ["7c", "2d"], "1": ["Ks", "Kd"], "2": ["Qs", "Qd"], "3": ["Js", "Jd"], "4": ["As", "Ad"]}', array['3h', '8c', '9d', '5h', '4s']);
  st := pg_temp.pk_play(t, '3:raise:750 4:raise:1800 0:call 1:call 2:call');
  perform pg_temp.ok(pg_temp.stacks(st) = array[0, 0, 0, 0, 5050, -1] and jsonb_array_length(st -> 'result' -> 'pots') = 4
    and (select sum((p -> 'winners' -> 0 ->> 'amount')::int) from jsonb_array_elements(st -> 'result' -> 'pots') p) = 4250, 'the best hand, when it covers everyone, sweeps all the pots');
  perform pg_temp.pk_close(t);
end $$;

-- A tie for the main pot with an odd chip, dead money from a fold, and a side pot.
do $$
declare t bigint := pg_temp.pk_setup(array[1000, 1000, 301, 1000]); st jsonb;
begin
  perform pg_temp.pk_deal(t, 0, '{"0": ["Qh", "Qc"], "2": ["Ah", "Kc"], "3": ["Ad", "Ks"]}', array['As', '7d', '2c', '9h', '4s']);
  st := pg_temp.pk_play(t, '3:call 0:call 1:fold 2:raise:301 3:call 0:call 3:bet:100 0:call 3:check 0:check 3:check 0:check');
  perform pg_temp.ok(st -> 'result' -> 'pots' = '[{"seats": [0, 2, 3], "amount": 953, "winners": [{"seat": 2, "amount": 477}, {"seat": 3, "amount": 476}]},
      {"seats": [0, 3], "amount": 200, "winners": [{"seat": 3, "amount": 200}]}]',
    'a tied main pot is split, the odd chip going to the first winner left of the button; the folded blind stays in it');
  perform pg_temp.ok(pg_temp.stacks(st) = array[599, 950, 477, 1275, -1, -1], 'and the side pot goes to the better of the two who built it');
  perform pg_temp.pk_close(t);
end $$;

-- The board plays: three players split, two odd chips.
do $$
declare t bigint := pg_temp.pk_setup(array[1000, 1000, 1000, 1000]); st jsonb;
begin
  perform pg_temp.pk_deal(t, 0, '{}', array['As', 'Ks', 'Qs', 'Js', 'Ts']);
  st := pg_temp.pk_play(t, '3:call 0:call 1:fold 2:check 2:check 3:check 0:check 2:check 3:check 0:check 2:check 3:check 0:check');
  perform pg_temp.ok(st -> 'result' -> 'pots' = '[{"seats": [0, 2, 3], "amount": 350, "winners": [{"seat": 2, "amount": 117}, {"seat": 3, "amount": 117}, {"seat": 0, "amount": 116}]}]'
    and pg_temp.stacks(st) = array[1016, 950, 1017, 1017, -1, -1], 'a three-way split of 350: the two odd chips go clockwise from the button');
  perform pg_temp.ok((select count(*) from jsonb_array_elements(st -> 'seats') s where s <> 'null' and s -> 'cards' <> 'null') = 3, 'tying hands are all shown');
  perform pg_temp.pk_close(t);
end $$;

-- Who shows and who mucks.
do $$
declare t bigint := pg_temp.pk_setup(array[5000, 5000, 5000]); st jsonb; r jsonb;
begin
  -- The river is bet: the bettor (kings) shows first, then clockwise. Nines can't win and are mucked; aces show and win.
  perform pg_temp.pk_deal(t, 0, '{"0": ["9c", "2h"], "1": ["As", "Ah"], "2": ["Kc", "Qd"]}', array['Kd', '9s', '3h', '4c', '7d']);
  st := pg_temp.pk_play(t, '0:call 1:call 2:check 1:check 2:check 0:check 1:check 2:check 0:check 1:check 2:bet:200 0:call 1:call');
  perform pg_temp.ok(st -> 'seats' -> 2 -> 'cards' = '["Kc", "Qd"]' and st -> 'seats' -> 1 -> 'cards' = '["As", "Ah"]' and st -> 'seats' -> 0 -> 'cards' = 'null'
    and st -> 'seats' -> 0 -> 'rank' = 'null' and pg_temp.stacks(st) = array[4700, 5600, 4700, -1, -1, -1],
    'the river bettor shows first; a caller who is beaten mucks and a caller who wins shows');
  perform pg_temp.pk_as(2);
  r := public.poker_state(t);
  perform pg_temp.ok(not pg_temp.json_cards(r) && array['9c', '2h'] and r -> 'me' -> 'cards' = '["As", "Ah"]', 'the winner never sees the mucked hand');
  perform pg_temp.pk_as(1);
  perform pg_temp.ok(public.poker_state(t) -> 'me' -> 'cards' = '["9c", "2h"]', 'its owner still does');
  perform pg_temp.ok(pg_temp.pk_round(1) ->> 'detail' = 'Lost with a pair · $50/$100', 'and their own history names it');
  -- The river is checked round: the first player left of the button shows first. Aces there mean nobody else has to show.
  perform pg_temp.pk_deal(t, 0, '{"0": ["9c", "2h"], "1": ["As", "Ah"], "2": ["Kc", "Qd"]}', array['Kd', '9s', '3h', '4c', '7d']);
  st := pg_temp.pk_play(t, '0:call 1:call 2:check 1:check 2:check 0:check 1:check 2:check 0:check 1:check 2:check 0:check');
  perform pg_temp.ok(st -> 'seats' -> 1 -> 'cards' = '["As", "Ah"]' and st -> 'seats' -> 2 -> 'cards' = 'null' and st -> 'seats' -> 0 -> 'cards' = 'null',
    'after a checked river the first player left of the button shows, and beaten hands behind them muck');
  -- The same cards with the aces last to show: each hand shown is the best so far, so all three are seen.
  perform pg_temp.pk_deal(t, 1, '{"1": ["As", "Ah"], "2": ["9c", "2h"], "0": ["Kc", "Qd"]}', array['Kd', '9s', '3h', '4c', '7d']);
  st := pg_temp.pk_play(t, '1:call 2:call 0:check 2:check 0:check 1:check 2:check 0:check 1:check 2:check 0:check 1:check');
  perform pg_temp.ok(st -> 'seats' -> 2 -> 'cards' = '["9c", "2h"]' and st -> 'seats' -> 0 -> 'cards' = '["Kc", "Qd"]' and st -> 'seats' -> 1 -> 'cards' = '["As", "Ah"]',
    'a hand that is the best shown so far is shown, even if a later one beats it');
  perform pg_temp.pk_close(t);
end $$;

-- All-in heads-up: calls for less, the refund, and no raise against a player who is all-in.
do $$
declare t bigint := pg_temp.pk_setup(array[1000, 300]); st jsonb;
begin
  perform pg_temp.pk_deal(t, 0, '{"0": ["As", "Ad"], "1": ["7c", "2d"]}', array['3h', '8c', '9d', 'Jh', '4s']);
  st := pg_temp.pk_do(t, 0, 'raise', 1000);
  perform pg_temp.ok(st -> 'act' = '{"seat": 1, "toCall": 200, "canRaise": false, "minRaise": 300, "maxRaise": 300}', 'a short stack can call all-in for less');
  st := pg_temp.pk_do(t, 1, 'call');
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and pg_temp.stacks(st) = array[1300, 0, -1, -1, -1, -1] and st -> 'result' -> 'pots' -> 0 ->> 'amount' = '600'
    and st -> 'seats' -> 1 -> 'cards' = '["7c", "2d"]', 'the caller can only lose what they had; the rest of the raise comes back');
  perform pg_temp.pk_close(t);
  t := pg_temp.pk_setup(array[5000, 300]);
  perform pg_temp.pk_deal(t, 0);
  st := pg_temp.pk_play(t, '0:call 1:raise:300');
  perform pg_temp.ok(st -> 'act' = '{"seat": 0, "toCall": 200, "canRaise": false, "minRaise": 500, "maxRaise": 5000}'
    and pg_temp.pk_err(t, 0, 'raise', 600) like '%only call or fold%', 'no raise is offered when every other player is all-in');
  st := pg_temp.pk_do(t, 0, 'fold');
  perform pg_temp.ok(pg_temp.stacks(st) = array[4900, 400, -1, -1, -1, -1], 'folding to the all-in gives up the call');
  perform pg_temp.pk_close(t);
  -- Blinds bigger than a stack: both post what they have and the hand plays itself.
  t := pg_temp.pk_setup(array[30, 60]);
  perform pg_temp.pk_tick(t, 5);
  st := pg_temp.pk_state(t);
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and (st ->> 'runout')::int = 5 and (select sum(x) from unnest(pg_temp.stacks(st)) x where x >= 0) = 90
    and st -> 'result' -> 'pots' -> 0 ->> 'amount' = '60', 'players too short for the blinds post what they have and the board runs out');
  perform pg_temp.pk_close(t);
end $$;
reset role;
select pg_temp.ok(pg_temp.pk_chips() = :pk_total, 'every scenario so far balances to the chip');
set role authenticated;

-- The clock: nobody can stall a table -------------------------------------------------
do $$
declare v_total numeric := pg_temp.pk_chips(); t bigint := pg_temp.pk_setup(array[2000, 2000, 2000]); st jsonb; v bigint; r jsonb;
  now_ms bigint := (extract(epoch from now()) * 1000)::bigint;
begin
  perform pg_temp.pk_deal(t, 0);
  select version into v from public.poker_tables where id = t;
  st := pg_temp.pk_tick(t, 20);
  perform pg_temp.ok((select version from public.poker_tables where id = t) = v and (st -> 'act' ->> 'seat')::int = 0, 'a push before the deadline changes nothing');
  st := pg_temp.pk_tick(t, 3.5);
  perform pg_temp.ok((st -> 'act' ->> 'seat')::int = 0, 'a move may arrive up to a second late');
  st := pg_temp.pk_tick(t, 1);
  perform pg_temp.ok((st -> 'seats' -> 0 ->> 'folded')::boolean and (st -> 'act' ->> 'seat')::int = 1 and (pg_temp.pk_seat(t, 0) ->> 'timeouts')::int = 1
    and not (st -> 'seats' -> 0 ->> 'away')::boolean, 'out of time facing a bet: the player is folded and the turn moves on');
  perform pg_temp.ok((st ->> 'deadline')::bigint between now_ms + 23400 and now_ms + 23600, 'the next turn is timed from the deadline that ran out, not from the late push');
  st := pg_temp.pk_do(t, 1, 'call');
  st := pg_temp.pk_tick(t, 27);
  perform pg_temp.ok(st ->> 'phase' = 'flop' and not (st -> 'seats' -> 2 ->> 'folded')::boolean and (pg_temp.pk_seat(t, 2) ->> 'timeouts')::int = 1,
    'out of time with nothing to call: the player is checked, not folded');
  st := pg_temp.pk_do(t, 1, 'bet', 100);
  st := pg_temp.pk_tick(t, 27);
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and (st -> 'seats' -> 2 ->> 'away')::boolean and pg_temp.stacks(st) = array[2000, 2100, 1900, -1, -1, -1],
    'a second timeout in a row sits the player out');
  st := pg_temp.pk_tick(t, 10);
  perform pg_temp.ok(st ->> 'phase' = 'preflop' and not (st -> 'seats' -> 2 ->> 'inHand')::boolean and (st -> 'seats' -> 0 ->> 'inHand')::boolean
    and (st -> 'seats' -> 1 ->> 'inHand')::boolean and (st ->> 'button')::int = 1, 'a player sitting out is not dealt in; the others play on');
  st := pg_temp.pk_play(t, '1:call 0:check');
  perform pg_temp.ok((pg_temp.pk_seat(t, 0) ->> 'timeouts')::int = 0, 'a move made in time clears the count');
  perform pg_temp.pk_as(3);
  perform pg_temp.ok(public.poker_act(t, 'check') ->> 'error' like '%not your turn%', 'a player sitting out has no turn');
  r := public.poker_away(t, false);
  perform pg_temp.ok(not (r -> 'me' ->> 'away')::boolean and not (r -> 'table' -> 'state' -> 'seats' -> 2 ->> 'away')::boolean, 'coming back is one call');
  r := public.poker_away(t, true);
  r := public.poker_away(t, false);
  -- Everyone walks away mid-hand. One push an hour later plays the whole table out.
  st := pg_temp.pk_tick(t, 3600);
  perform pg_temp.ok(st ->> 'phase' = 'waiting' and st -> 'seats' = '[null, null, null, null, null, null]' and st -> 'deadline' = 'null'
    and (select seated from public.poker_tables where id = t) = 0, 'an abandoned table plays itself out and every seat is freed');
  perform pg_temp.ok(pg_temp.pk_chips() = v_total and pg_temp.pk_where(1) is null and pg_temp.pk_where(2) is null and pg_temp.pk_where(3) is null, 'and every stack is back in its owner''s cash');
  perform pg_temp.pk_drop(t);
end $$;

-- A lone player who closes the tab doesn't hold the seat; one whose browser keeps asking does.
do $$
declare c1 numeric := pg_temp.pk_cash(1); t bigint := pg_temp.pk_setup(array[2000]); st jsonb;
begin
  perform pg_temp.ok(pg_temp.pk_state(t) -> 'deadline' <> 'null', 'a table with someone seated is looked at again in a few minutes');
  perform pg_temp.pk_age(t, 100);
  perform pg_temp.pk_as(1);
  perform public.poker_state(t);
  st := pg_temp.pk_tick(t, 100);
  perform pg_temp.ok(st -> 'seats' -> 0 ->> 'name' = 'pone', 'a player whose browser is still there keeps the seat while waiting');
  st := pg_temp.pk_tick(t, 200);
  perform pg_temp.ok(st -> 'seats' -> 0 = 'null' and pg_temp.pk_cash(1) = c1, 'three minutes of silence frees the seat and returns the chips');
  perform pg_temp.pk_drop(t);
end $$;

-- A late or repeated click can't be played as the next decision.
do $$
declare t bigint := pg_temp.pk_setup(array[2000, 2000]); st jsonb; v_turn int;
begin
  perform pg_temp.pk_deal(t, 0);
  v_turn := (pg_temp.pk_state(t) ->> 'turn')::int;
  perform pg_temp.ok(pg_temp.pk_err(t, 0, 'call', null, v_turn - 1) like '%earlier turn%', 'a move for an earlier turn is refused');
  perform pg_temp.ok(pg_temp.pk_err(t, 0, 'call', null, v_turn) = 'accepted' and pg_temp.pk_err(t, 0, 'call', null, v_turn) like '%not your turn%', 'a double click plays once');
  st := pg_temp.pk_play(t, '1:check 1:check');
  perform pg_temp.ok((st -> 'act' ->> 'seat')::int = 0 and pg_temp.pk_err(t, 0, 'check', null, v_turn) like '%earlier turn%'
    and (pg_temp.pk_state(t) -> 'act' ->> 'seat')::int = 0, 'and a stale copy of it is not played when the turn comes round again');
  st := pg_temp.pk_play(t, '0:check 1:check 0:check 1:check 0:check');
  perform pg_temp.pk_close(t);
end $$;

-- Leaving and joining ---------------------------------------------------------------
do $$
declare c2 numeric := pg_temp.pk_cash(2); c3 numeric := pg_temp.pk_cash(3); t bigint := pg_temp.pk_setup(array[3000, 3000, 3000]); st jsonb; r jsonb; v_turn int; v_deadline text;
begin
  perform pg_temp.pk_deal(t, 0);
  st := pg_temp.pk_state(t);
  v_turn := (st ->> 'turn')::int;
  v_deadline := st ->> 'deadline';
  -- The big blind leaves while it is someone else's turn.
  perform pg_temp.pk_as(3);
  r := public.poker_leave(t);
  st := r -> 'table' -> 'state';
  perform pg_temp.ok((r -> 'portfolio' ->> 'cash')::numeric = c3 - 100 and (r -> 'me' ->> 'left')::boolean and (st -> 'seats' -> 2 ->> 'folded')::boolean
    and (st -> 'seats' -> 2 ->> 'left')::boolean and (st ->> 'turn')::int = v_turn and st ->> 'deadline' = v_deadline and (st -> 'act' ->> 'seat')::int = 0,
    'leaving mid-hand folds at once and returns the stack; the blind stays in the pot and the turn is undisturbed');
  perform pg_temp.ok(public.poker_sit(t, 500) ->> 'error' like '%still finishing%' and public.poker_leave(t) ->> 'error' like '%not seated%'
    and (public.poker_lobby() -> 'seat') = 'null', 'the seat is theirs until the hand ends, but only to finish it');
  -- A fourth player sits down during the hand: they wait for the next one.
  r := pg_temp.pk_sit(t, 4, 1000, 4);
  perform pg_temp.ok(not (r -> 'table' -> 'state' -> 'seats' -> 4 ->> 'inHand')::boolean and r -> 'me' -> 'cards' = 'null' and (r -> 'table' -> 'state' ->> 'turn')::int = v_turn,
    'a player who sits down during a hand is not in it');
  st := pg_temp.pk_do(t, 0, 'raise', 300);
  -- The small blind leaves on their own turn: one player is left and wins.
  perform pg_temp.pk_as(2);
  r := public.poker_leave(t);
  st := r -> 'table' -> 'state';
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and pg_temp.stacks(st) = array[3150, 0, 0, -1, 1000, -1] and (r -> 'portfolio' ->> 'cash')::numeric = c2 - 50,
    'when leaving leaves one player in the hand, they win it');
  st := pg_temp.pk_tick(t, 10);
  perform pg_temp.ok(st -> 'seats' -> 1 = 'null' and st -> 'seats' -> 2 = 'null' and st ->> 'phase' = 'preflop' and (st -> 'seats' -> 4 ->> 'inHand')::boolean,
    'the seats are freed for the next hand, which deals the newcomer in');
  perform pg_temp.ok((pg_temp.pk_round(3) ->> 'net')::numeric = -100
    and (pg_temp.pk_round(2) ->> 'net')::numeric = -50, 'a hand left mid-way is recorded like any fold');
  -- Sitting out by choice: this hand is played normally, the next one skips them.
  perform pg_temp.pk_as(4);
  r := public.poker_away(t, true);
  perform pg_temp.ok((r -> 'me' ->> 'away')::boolean and (r -> 'table' -> 'state' -> 'seats' -> 4 ->> 'inHand')::boolean, 'sitting out takes effect from the next hand');
  st := pg_temp.pk_state(t);
  st := pg_temp.pk_do(t, (st -> 'act' ->> 'seat')::int, 'fold');
  st := pg_temp.pk_tick(t, 10);
  perform pg_temp.ok(st ->> 'phase' = 'waiting' and (st -> 'seats' -> 4 ->> 'away')::boolean, 'with one player ready there is no hand to deal');
  perform pg_temp.pk_as(4);
  r := public.poker_away(t, false);
  st := pg_temp.pk_tick(t, 5);
  perform pg_temp.ok(not r ? 'error' and st ->> 'phase' = 'preflop', 'and it resumes when they are back');
  st := pg_temp.pk_do(t, (st -> 'act' ->> 'seat')::int, 'fold');
  perform pg_temp.pk_close(t);

  -- An all-in player who leaves is still in for the pot; the winnings follow them out.
  c2 := pg_temp.pk_cash(2);
  t := pg_temp.pk_setup(array[3000, 500]);
  perform pg_temp.pk_deal(t, 0, '{"0": ["7c", "2d"], "1": ["As", "Ad"]}', array['3h', '8c', '9d', 'Jh', '4s']);
  st := pg_temp.pk_play(t, '0:call 1:raise:500');
  perform pg_temp.pk_as(2);
  r := public.poker_leave(t);
  perform pg_temp.ok((r -> 'me' ->> 'left')::boolean and not (r -> 'table' -> 'state' -> 'seats' -> 1 ->> 'folded')::boolean
    and (r -> 'portfolio' ->> 'cash')::numeric = c2 - 500, 'an all-in player who leaves is not folded');
  st := pg_temp.pk_do(t, 0, 'call');
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and (st -> 'seats' -> 1 ->> 'won')::int = 1000, 'and still wins the pot');
  st := pg_temp.pk_tick(t, 12);
  perform pg_temp.ok(st -> 'seats' -> 1 = 'null' and pg_temp.pk_cash(2) = c2 + 500, 'which goes to their cash when the seat is freed');
  perform pg_temp.pk_close(t);
end $$;
-- Both blinds leave before the first player has acted: that player wins the blinds without putting a chip in, and it is recorded.
do $$
declare t bigint := pg_temp.pk_setup(array[1000, 1000, 1000]); st jsonb; r jsonb;
begin
  perform pg_temp.pk_deal(t, 0);
  perform pg_temp.pk_as(2);
  r := public.poker_leave(t);
  perform pg_temp.pk_as(3);
  r := public.poker_leave(t);
  st := r -> 'table' -> 'state';
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and pg_temp.stacks(st) = array[1100, 0, 0, -1, -1, -1]
    and st -> 'result' -> 'players' = '[{"net": 100, "won": 100, "seat": 0}, {"net": -50, "won": 0, "seat": 1}, {"net": -50, "won": 0, "seat": 2}]',
    'when both blinds leave, the player still to act wins them (the big blind gets its unmatched half back)');
  perform pg_temp.ok((pg_temp.pk_round(1) ->> 'staked')::numeric = 0 and (pg_temp.pk_round(1) ->> 'net')::numeric = 100
    and pg_temp.pk_round(1) ->> 'detail' like 'Won, everyone else folded%', 'a win with no chips put in is still recorded');
  perform pg_temp.pk_close(t);
end $$;
reset role;
select pg_temp.ok(pg_temp.pk_chips() = :pk_total, 'timeouts, leaving and joining balance to the chip');

-- Hidden cards never leave the server ---------------------------------------------------
select pg_temp.ok((select array_agg(tablename::text order by tablename) from pg_publication_tables where pubname = 'supabase_realtime' and tablename like 'poker%') = array['poker_tables']
  and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname <> 'public'),
  'Realtime publishes the public table row and nothing from the private schema');
select pg_temp.ok((select array_agg(column_name::text order by column_name::text) from information_schema.column_privileges
    where table_schema = 'public' and table_name = 'poker_tables' and grantee = 'anon' and privilege_type = 'SELECT')
  = array['big_blind', 'deadline', 'hand_no', 'id', 'max_buy', 'max_seats', 'min_buy', 'seated', 'small_blind', 'stake', 'state', 'updated_at', 'version']
  and not exists (select 1 from information_schema.table_privileges where table_name like 'poker%' and grantee in ('anon', 'authenticated', 'PUBLIC'))
  and not exists (select 1 from information_schema.column_privileges where table_name like 'poker%' and grantee in ('anon', 'authenticated', 'PUBLIC') and privilege_type <> 'SELECT'),
  'clients may read thirteen named columns of the public table row and can write nothing');
select pg_temp.ok(not exists (select 1 from information_schema.routine_privileges where routine_schema = 'private' and grantee in ('anon', 'authenticated', 'PUBLIC'))
  and not has_schema_privilege('anon', 'private', 'usage') and not has_schema_privilege('authenticated', 'private', 'usage'),
  'no client role can reach the private schema or call anything in it');
set role anon;
select set_config('request.jwt.claim.sub', '', false);
select pg_temp.ok((select count(*) from (select id, state, version from public.poker_tables) t) >= 4, 'anyone can read the public state of the tables');
select pg_temp.expect_error($$select * from public.poker_tables$$, '%permission denied%');
select pg_temp.expect_error($$update public.poker_tables set state = '{}'$$, '%permission denied%');
select pg_temp.expect_error($$insert into public.poker_tables (stake, small_blind, big_blind, min_buy, max_buy) values ('x', 1, 2, 3, 4)$$, '%permission denied%');
select pg_temp.expect_error($$delete from public.poker_tables$$, '%permission denied%');
select pg_temp.expect_error($$select * from private.poker_seats$$, '%permission denied%');
select pg_temp.expect_error($$select hole from private.poker_seats$$, '%permission denied%');
select pg_temp.expect_error($$select deck from private.poker_hands$$, '%permission denied%');
select pg_temp.expect_error($$select * from private.poker_proofs$$, '%permission denied%');
select pg_temp.expect_error($$select public.poker_lobby()$$, '%permission denied%');
select pg_temp.expect_error($$select public.poker_state(1)$$, '%permission denied%');
select pg_temp.expect_error($$select public.poker_tick(1)$$, '%permission denied%');
select pg_temp.expect_error($$select public.poker_sit(1, 100)$$, '%permission denied%');
select pg_temp.expect_error($$select public.poker_leave(1)$$, '%permission denied%');
select pg_temp.expect_error($$select public.poker_act(1, 'fold')$$, '%permission denied%');
select pg_temp.expect_error($$select public.poker_away(1, true)$$, '%permission denied%');
select pg_temp.expect_error($$select public.poker_buy(1, 100)$$, '%permission denied%');
select pg_temp.expect_error($$select public.poker_proof(1)$$, '%permission denied%');
reset role;
set role authenticated;
select pg_temp.pk_as(7);
select pg_temp.expect_error($$select * from public.poker_tables$$, '%permission denied%');
select pg_temp.expect_error($$update public.poker_tables set state = '{}'$$, '%permission denied%');
select pg_temp.expect_error($$select * from private.poker_seats$$, '%permission denied%');
select pg_temp.expect_error($$select deck, salts from private.poker_hands$$, '%permission denied%');
select pg_temp.expect_error($$select holes from private.poker_proofs$$, '%permission denied%');
select pg_temp.expect_error($$select private.poker_view(1, auth.uid())$$, '%permission denied%');
select pg_temp.expect_error($$select private.poker_shuffle()$$, '%permission denied%');
select pg_temp.expect_error($$select private.poker_publish(1)$$, '%permission denied%');
select pg_temp.expect_error($$select private.poker_advance(1)$$, '%permission denied%');
select pg_temp.expect_error($$select private.poker_cashout(1, 0)$$, '%permission denied%');
select pg_temp.expect_error($$select private.poker_evict(auth.uid())$$, '%permission denied%');
select pg_temp.expect_error($$select private.poker_sweep()$$, '%permission denied%');
select pg_temp.expect_error($$select private.game_record(auth.uid(), 1, 'poker', 0, 1000000, 'free money')$$, '%permission denied%');
select pg_temp.ok(true, 'anon can call no table function; signed-in players only the public ones; nobody can read seats, decks or fairness records directly');

-- Checks one answer from the server: it may name the board, hands shown at a finished showdown, and the asker's own two cards (p_own). Nothing else.
reset role;
create or replace function pg_temp.pk_hole(p_table bigint, p_n int) returns text[] language sql security definer as $$
  select coalesce((select hole from private.poker_seats where table_id = p_table and user_id = pg_temp.u(p_n) and in_hand), '{}') $$;
create or replace function pg_temp.pk_hole_at(p_table bigint, p_seat int) returns text[] language sql security definer as $$
  select coalesce((select hole from private.poker_seats where table_id = p_table and seat = p_seat and in_hand), '{}') $$;
create or replace function pg_temp.pk_no_leak(p_table bigint, p_answer jsonb, p_own text[], p_what text) returns void language plpgsql as $$
declare v_bad text[];
begin
  select array_agg(c) into v_bad from unnest(pg_temp.json_cards(p_answer)) c where c = any (pg_temp.pk_hidden(p_table)) and c <> all (p_own);
  if v_bad is not null then raise exception 'LEAK: % shows %: %', p_what, v_bad, p_answer; end if;
end $$;
grant execute on function pg_temp.pk_hole(bigint, int), pg_temp.pk_hole_at(bigint, int) to authenticated;
set role authenticated;

-- Fairness: the deck is sealed before the deal and the shown cards can be checked afterwards.
do $$
declare t bigint := pg_temp.pk_setup(array[2000, 2000, 2000]); st jsonb; v_hash text; p jsonb; mine jsonb; shown text[]; i int; r jsonb; v_seat int; v_mucked int[];
begin
  st := pg_temp.pk_tick(t, 5);
  v_hash := st ->> 'deckHash';
  perform pg_temp.ok(st ->> 'phase' = 'preflop' and v_hash ~ '^[0-9a-f]{64}$', 'the hash of the sealed deck is published with the deal');
  perform pg_temp.pk_as(7);
  perform pg_temp.ok(jsonb_array_length(public.poker_proof(t) -> 'commits') is null and public.poker_proof(t) ->> 'error' like '%No finished hand%', 'there is nothing to check until a hand has finished');
  -- Every answer during the hand, to a spectator and to each player.
  for i in 1..40 loop
    exit when st ->> 'phase' = 'showdown';
    v_seat := (st -> 'act' ->> 'seat')::int;
    r := pg_temp.pk_move(t, v_seat, case when (st -> 'act' ->> 'toCall')::int > 0 then 'call' else 'check' end);
    perform pg_temp.pk_no_leak(t, r, pg_temp.pk_hole_at(t, v_seat), 'a move');
    perform pg_temp.pk_no_leak(t, pg_temp.pk_move(t, (v_seat + 1) % 3, 'raise', 99999), pg_temp.pk_hole_at(t, (v_seat + 1) % 3), 'a refused move');
    st := pg_temp.pk_state(t);
    perform pg_temp.pk_no_leak(t, to_jsonb((select tt from (select id, stake, small_blind, big_blind, min_buy, max_buy, max_seats, seated, version, hand_no, deadline, state, updated_at
      from public.poker_tables where id = t) tt)), '{}', 'the public row');
    perform pg_temp.pk_as(7);
    perform pg_temp.pk_no_leak(t, public.poker_state(t), '{}', 'a spectator''s view');
    perform pg_temp.pk_no_leak(t, public.poker_tick(t), '{}', 'a clock push');
    perform pg_temp.pk_no_leak(t, public.poker_lobby(), '{}', 'the lobby');
    perform pg_temp.pk_no_leak(t, public.poker_proof(t), '{}', 'the fairness record');
    perform pg_temp.pk_no_leak(t, public.poker_sit(t, 0), '{}', 'a refused seat');
    perform pg_temp.pk_as(2);
    r := public.poker_state(t);
    perform pg_temp.pk_no_leak(t, r, pg_temp.pk_hole(t, 2), 'a player''s view');
    if r -> 'me' -> 'cards' is distinct from pg_temp.pk_seat(t, 1) -> 'hole' or jsonb_array_length(r -> 'me' -> 'cards') <> 2 then
      raise exception 'a player should see their own two cards: %', r -> 'me';
    end if;
  end loop;
  perform pg_temp.ok(true, 'through a whole hand, every answer to a spectator and to each player names only the board and that player''s own two cards');
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and st ->> 'deckHash' = v_hash, 'the hand was played to a showdown under the same seal');
  select array_agg(c) into shown from (select jsonb_array_elements_text(st -> 'board') c union
    select jsonb_array_elements_text(s -> 'cards') from jsonb_array_elements(st -> 'seats') s where s <> 'null' and s -> 'cards' <> 'null') q;
  select array_agg(n - 1) into v_mucked from jsonb_array_elements(st -> 'seats') with ordinality as q(s, n) where s <> 'null' and s -> 'cards' = 'null';
  perform pg_temp.pk_as(7);
  p := public.poker_proof(t);
  perform pg_temp.ok(pg_temp.sha((select string_agg(c, ',' order by n) from jsonb_array_elements_text(p -> 'commits') with ordinality as q(c, n))) = v_hash
    and jsonb_array_length(p -> 'commits') = 52 and (p ->> 'hand')::int = (st ->> 'hand')::int and p ->> 'deckHash' = v_hash,
    'afterwards the 52 seals hash to the value published before the deal');
  perform pg_temp.ok((select bool_and(pg_temp.sha((x ->> 'salt') || ':' || (x ->> 'card')) = p -> 'commits' ->> ((x ->> 'i')::int - 1)) from jsonb_array_elements(p -> 'reveals') x),
    'every revealed card opens its seal');
  perform pg_temp.ok((select array_agg(x ->> 'card' order by x ->> 'card') from jsonb_array_elements(p -> 'reveals') x) = (select array_agg(c order by c) from unnest(shown) c)
    and (select count(distinct x ->> 'i') from jsonb_array_elements(p -> 'reveals') x) = array_length(shown, 1),
    'a spectator gets the board and the hands that were shown, and nothing else');
  -- Board cards sit where the deal puts them: after two cards each, one burned before the flop, the turn and the river.
  perform pg_temp.ok((select array_agg((x ->> 'i')::int order by (x ->> 'i')::int) from jsonb_array_elements(p -> 'reveals') x where x ->> 'card' = any (select jsonb_array_elements_text(st -> 'board')))
    = array[8, 9, 10, 12, 14], 'the board comes from the deck positions the deal fixes (a card is burned before each street)');
  perform pg_temp.pk_no_leak(t, p, '{}', 'the fairness record after the hand');
  perform pg_temp.pk_as(1);
  mine := public.poker_state(t) -> 'me' -> 'cards';
  p := public.poker_proof(t);
  perform pg_temp.ok((select count(*) from jsonb_array_elements(p -> 'reveals') x where mine ? (x ->> 'card')) = 2
    and (select bool_and(pg_temp.sha((x ->> 'salt') || ':' || (x ->> 'card')) = p -> 'commits' ->> ((x ->> 'i')::int - 1)) from jsonb_array_elements(p -> 'reveals') x),
    'a player can also open the seals of their own two cards, shown or not');
  perform pg_temp.pk_no_leak(t, p, pg_temp.pk_hole(t, 1), 'a player''s fairness record');
  -- The seal of each card is hiding: the same card gets a different seal every hand.
  st := pg_temp.pk_tick(t, 12);
  perform pg_temp.ok(st ->> 'deckHash' <> v_hash and st ->> 'phase' = 'preflop', 'the next hand has a new seal');
  st := pg_temp.pk_play(t, format('%s:fold', st -> 'act' ->> 'seat'));
  st := pg_temp.pk_play(t, format('%s:fold', st -> 'act' ->> 'seat'));
  perform pg_temp.pk_close(t);
end $$;

-- Every table call is rate limited.
do $$
declare i int; t bigint := pg_temp.pk_table();
begin
  perform pg_temp.pk_as(7);
  for i in 1..40 loop perform public.poker_lobby(); end loop;
  perform pg_temp.expect_error($q$select public.poker_lobby()$q$, '%Slow down%');
  for i in 1..150 loop perform public.poker_state(t); end loop;
  perform pg_temp.expect_error(format($q$select public.poker_state(%s)$q$, t), '%Slow down%');
  for i in 1..60 loop perform public.poker_tick(t); end loop;
  perform pg_temp.expect_error(format($q$select public.poker_tick(%s)$q$, t), '%Slow down%');
  for i in 1..90 loop perform public.poker_act(t, 'fold'); end loop;
  perform pg_temp.expect_error(format($q$select public.poker_act(%s, 'fold')$q$, t), '%Slow down%');
  for i in 1..10 loop
    perform public.poker_sit(t, 0);
    perform public.poker_leave(t);
    perform public.poker_away(t, true);
  end loop;
  perform pg_temp.expect_error(format($q$select public.poker_buy(%s, 100)$q$, t), '%Slow down%');
  perform pg_temp.expect_error(format($q$select public.poker_sit(%s, 100)$q$, t), '%Slow down%');
  perform pg_temp.expect_error(format($q$select public.poker_leave(%s)$q$, t), '%Slow down%');
  perform pg_temp.expect_error(format($q$select public.poker_away(%s, false)$q$, t), '%Slow down%');
  for i in 1..20 loop perform public.poker_proof(t); end loop;
  perform pg_temp.expect_error(format($q$select public.poker_proof(%s)$q$, t), '%Slow down%');
  perform pg_temp.clear_limits();
  perform pg_temp.pk_drop(t);
  perform pg_temp.ok(true, 'every table call is rate limited, refused calls included');
end $$;

-- Thousands of random hands: every chip is accounted for after every move, every hand finishes, no hidden card is ever sent.
-- It runs in batches, each its own transaction, the way real calls arrive (and so the table rows it rewrites can be tidied up as it goes).
reset role;
create temp table pk_sim (hands int, moves int, allins int, timeouts int, leaves int, showdowns int, side int, splits int, mucks int);
insert into pk_sim values (0, 0, 0, 0, 0, 0, 0, 0, 0);
grant select, update on pk_sim to authenticated;
create or replace function pg_temp.pk_sim(t bigint, p_hands int) returns void language plpgsql as $$
declare v_total numeric := pg_temp.pk_chips(); v_target int; v_step int := 0; st jsonb; act jsonb; r jsonb; w jsonb; p jsonb;
  v_seat int; v_n int; x float8; v_min bigint; v_max bigint; v_call bigint; v_amt bigint; v_can boolean; v_move text; v_phase text; v_cash numeric;
  v_hand int; v_showdowns int := 0; v_side int := 0; v_splits int := 0; v_timeouts int := 0; v_leaves int := 0; v_allins int := 0; v_moves int := 0; v_mucks int := 0;
begin
  v_hand := (pg_temp.pk_state(t) ->> 'hand')::int;
  v_target := v_hand + p_hands;
  loop
    v_step := v_step + 1;
    st := pg_temp.pk_state(t);
    v_phase := st ->> 'phase';
    exit when (st ->> 'hand')::int >= v_target and v_phase in ('showdown', 'waiting');
    if v_step > p_hands * 80 then raise exception 'the simulation is not getting anywhere: %', st; end if;

    if v_phase in ('showdown', 'waiting') then
      if v_phase = 'showdown' and (st ->> 'hand')::int <> v_hand then
        v_hand := (st ->> 'hand')::int;
        -- No rake: the hand's results add up to zero and every pot is paid out exactly.
        if (select sum((q ->> 'net')::numeric) from jsonb_array_elements(st -> 'result' -> 'players') q) <> 0
          or (select sum((q ->> 'amount')::numeric) from jsonb_array_elements(st -> 'result' -> 'pots') q)
            <> (select sum((q ->> 'won')::numeric) from jsonb_array_elements(st -> 'result' -> 'players') q)
          or exists (select 1 from jsonb_array_elements(st -> 'result' -> 'pots') q
            where (q ->> 'amount')::numeric <> (select sum((z ->> 'amount')::numeric) from jsonb_array_elements(q -> 'winners') z)) then
          raise exception 'hand % does not add up: %', v_hand, st -> 'result';
        end if;
        if (st -> 'result' ->> 'showdown')::boolean then
          v_showdowns := v_showdowns + 1;
          if jsonb_array_length(st -> 'result' -> 'pots') > 1 then v_side := v_side + 1; end if;
          if exists (select 1 from jsonb_array_elements(st -> 'result' -> 'pots') q where jsonb_array_length(q -> 'winners') > 1) then v_splits := v_splits + 1; end if;
          if exists (select 1 from jsonb_array_elements(st -> 'seats') q where q <> 'null' and (q ->> 'inHand')::boolean and not (q ->> 'folded')::boolean and q -> 'cards' = 'null') then
            v_mucks := v_mucks + 1;
          end if;
        end if;
        perform pg_temp.pk_as(7);
        perform pg_temp.pk_no_leak(t, public.poker_state(t), '{}', 'a spectator''s view of a finished hand');
        perform pg_temp.pk_no_leak(t, public.poker_proof(t), '{}', 'the fairness record of a finished hand');
      end if;
      -- Between hands players come and go, sit out, come back and add chips.
      for v_n in 1..6 loop
        w := pg_temp.pk_where(v_n);
        v_cash := pg_temp.pk_cash(v_n);
        x := random();
        r := null;
        perform pg_temp.pk_as(v_n);
        if w is null then
          if x < 0.6 and v_cash >= 300 then r := public.poker_sit(t, trunc(least(v_cash, 300 + floor(random() * 4000)::numeric))); end if;
        elsif (w ->> 'leaving')::boolean then null;
        elsif (w ->> 'stack')::bigint = 0 then
          if x < 0.7 and v_cash >= 300 then r := public.poker_buy(t, trunc(least(v_cash, 300 + floor(random() * 3000)::numeric))); else r := public.poker_leave(t); end if;
        elsif (w ->> 'sitting_out')::boolean then
          if x < 0.7 then r := public.poker_away(t, false); end if;
        elsif x < 0.03 then r := public.poker_leave(t);
        elsif x < 0.06 then r := public.poker_away(t, true);
        elsif x < 0.10 and v_cash >= 100 then r := public.poker_buy(t, 100);
        else r := public.poker_state(t);
        end if;
        if r ? 'error' then raise exception 'player % was refused between hands: % (%)', v_n, r ->> 'error', w; end if;
      end loop;
      perform pg_temp.pk_age(t, 12);
      perform pg_temp.pk_as(7);
      perform public.poker_tick(t);
    else
      act := st -> 'act';
      v_seat := (act ->> 'seat')::int;
      if v_seat is null or pg_temp.pk_user(t, v_seat) is null then raise exception 'a live hand with nobody to act at step %: % / %', v_step, st, pg_temp.pk_hand(t) - 'deck' - 'salts' - 'commits'; end if;
      x := random();
      if x < 0.03 then
        -- The player to act has gone: the clock plays for them.
        perform pg_temp.pk_age(t, 27);
        perform pg_temp.pk_as(7);
        perform public.poker_tick(t);
        v_timeouts := v_timeouts + 1;
      elsif x < 0.05 then
        -- Someone leaves in the middle of the hand, whether or not it is their turn.
        v_n := 1 + floor(random() * 6)::int;
        w := pg_temp.pk_where(v_n);
        if w is not null and not (w ->> 'leaving')::boolean then
          perform pg_temp.pk_as(v_n);
          r := public.poker_leave(t);
          if r ? 'error' then raise exception 'player % could not leave mid-hand: %', v_n, r ->> 'error'; end if;
          v_leaves := v_leaves + 1;
        end if;
      else
        v_call := (act ->> 'toCall')::bigint;
        v_can := (act ->> 'canRaise')::boolean;
        v_min := (act ->> 'minRaise')::bigint;
        v_max := (act ->> 'maxRaise')::bigint;
        x := random();
        v_move := case
          when not v_can and v_call = 0 then case when x < 0.03 then 'fold' else 'check' end
          when not v_can then case when x < 0.3 then 'fold' else 'call' end
          when v_call = 0 then case when x < 0.02 then 'fold' when x < 0.6 then 'check' when x < 0.93 then 'raise' else 'allin' end
          else case when x < 0.22 then 'fold' when x < 0.72 then 'call' when x < 0.93 then 'raise' else 'allin' end end;
        if v_move in ('raise', 'allin') then
          v_amt := case when v_move = 'allin' then v_max else least(v_max, v_min + floor(random() * 3 * v_min)::bigint) end;
          if v_amt = v_max then v_allins := v_allins + 1; end if;
          r := pg_temp.pk_move(t, v_seat, case when (st ->> 'bet')::bigint = 0 then 'bet' else 'raise' end, v_amt);
        else
          r := pg_temp.pk_move(t, v_seat, v_move);
        end if;
        if r ? 'error' then raise exception 'seat % could not % (%): % in %', v_seat, v_move, v_amt, r ->> 'error', st; end if;
        v_moves := v_moves + 1;
        perform pg_temp.pk_no_leak(t, r, pg_temp.pk_hole_at(t, v_seat), 'the answer to a move');
      end if;
      if v_step % 5 = 0 then
        perform pg_temp.pk_no_leak(t, to_jsonb((select tt from (select id, version, hand_no, deadline, state from public.poker_tables where id = t) tt)), '{}', 'the public row');
        perform pg_temp.pk_as(7);
        perform pg_temp.pk_no_leak(t, public.poker_state(t), '{}', 'a spectator''s view');
        v_n := 1 + floor(random() * 6)::int;
        perform pg_temp.pk_as(v_n);
        perform pg_temp.pk_no_leak(t, public.poker_state(t), pg_temp.pk_hole(t, v_n), 'a player''s view');
      end if;
    end if;
    if pg_temp.pk_chips() <> v_total then raise exception 'chips changed from % to % at step % (hand %): %', v_total, pg_temp.pk_chips(), v_step, st ->> 'hand', st; end if;
  end loop;
  update pk_sim set hands = v_hand, moves = moves + v_moves, allins = allins + v_allins, timeouts = timeouts + v_timeouts, leaves = leaves + v_leaves,
    showdowns = showdowns + v_showdowns, side = side + v_side, splits = splits + v_splits, mucks = mucks + v_mucks;
end $$;
set role authenticated;
select setseed(0.2026);
select pg_temp.pk_chips() as sim_total, pg_temp.pk_table() as sim_table \gset
select format('select pg_temp.pk_sim(%s, 10)', :sim_table) from generate_series(1, 201) \gexec
select pg_temp.pk_close(:sim_table);
select pg_temp.ok(pg_temp.pk_chips() = :sim_total, format('%s random hands (%s moves, %s all-ins, %s timeouts, %s players leaving mid-hand): cash, stacks and pots add up to the same total after every step',
  hands, moves, allins, timeouts, leaves)) from pk_sim;
select pg_temp.ok(hands >= 2000 and showdowns > 300 and side > 50 and splits > 0 and mucks > 20 and timeouts > 100 and leaves > 50 and allins > 500,
  format('the hands covered %s showdowns, %s with side pots, %s split pots and %s with a mucked hand; none sent a hidden card to anyone', showdowns, side, splits, mucks)) from pk_sim;
reset role;
select pg_temp.ok(pg_temp.pk_chips() = :pk_total, 'after every table test the chips still add up to what the players started with');
select pg_temp.ok((select sum(net) = 0 and sum(staked) = sum(returned) and count(*) > 5000 from public.game_rounds where game = 'poker'),
  'the recorded results of every hand sum to zero: no rake, nothing created');
select pg_temp.ok(not exists (
  select 1 from (select user_id, game, count(*) n, sum(staked) w, sum(net) net, max(net) best from public.game_rounds where game = 'poker' group by 1, 2) g
  full join (select user_id, game, sum(rounds) n, sum(wagered) w, sum(net) net, max(best) best from private.game_totals where game = 'poker' group by 1, 2) x using (user_id, game)
  where g.n is distinct from x.n or g.w is distinct from x.w or g.net is distinct from x.net or g.best is distinct from x.best),
  'leaderboard totals match the hands recorded');
select pg_temp.ok((select count(*) from private.poker_seats) = 0 and (select count(*) from public.poker_tables where stake = 'test') = 0, 'no seat or test table is left behind');

-- A balance reset or a deleted account can't carry chips over or leave a hand stuck.
-- (The simulation left some players broke, so everyone starts these with a fresh $100,000.)
update public.portfolios set cash = 100000 where user_id in (select pg_temp.u(n) from generate_series(1, 7) n);
set role authenticated;
do $$
declare t bigint := pg_temp.pk_setup(array[2000, 2000, 2000]); st jsonb; r jsonb; v_seat int; v_other int;
begin
  perform pg_temp.pk_deal(t, 0);
  perform pg_temp.pk_as(1);
  r := public.reset_balance();
  st := pg_temp.pk_state(t);
  perform pg_temp.ok((r ->> 'cash')::numeric = 50000 and (r ->> 'tableChips')::numeric = 0 and (st -> 'seats' -> 0 ->> 'folded')::boolean
    and (st -> 'seats' -> 0 ->> 'left')::boolean and (st -> 'act' ->> 'seat')::int = 1 and public.poker_lobby() -> 'seat' = 'null',
    'a balance reset mid-hand folds the player and takes them off the table; the turn passes on');
  st := pg_temp.pk_do(t, 1, 'fold');
  st := pg_temp.pk_tick(t, 10);
  perform pg_temp.ok(st -> 'seats' -> 0 = 'null' and pg_temp.pk_cash(1) = 50000 and pg_temp.stacks(st) = array[-1, 1900, 1950, -1, -1, -1] and st ->> 'phase' = 'preflop',
    'the chips they had at the table end with the old run: the new one starts at exactly $50,000');
  -- The player to act deletes their account.
  v_seat := (st -> 'act' ->> 'seat')::int;
  v_other := 3 - v_seat;
  perform set_config('request.jwt.claim.sub', pg_temp.pk_user(t, v_seat)::text, false);
  perform pg_temp.ok((public.delete_account('DELETE') ->> 'deleted')::boolean, 'an account can be deleted in the middle of a hand');
  st := pg_temp.pk_state(t);
  perform pg_temp.ok(st ->> 'phase' = 'showdown' and (st -> 'seats' -> v_seat ->> 'left')::boolean and (st -> 'seats' -> v_other ->> 'won')::int > 0
    and pg_temp.pk_user(t, v_seat) is null, 'the hand ends in the other player''s favour instead of hanging');
  st := pg_temp.pk_tick(t, 10);
  perform pg_temp.ok(st -> 'seats' -> v_seat = 'null' and st ->> 'phase' = 'waiting' and st -> 'seats' -> v_other ->> 'name' is not null, 'and the empty seat is cleared');
  perform pg_temp.pk_close(t);
  -- All-in, then a reset, then the hand is won: the pot is not paid into the new run.
  t := pg_temp.pk_table();
  perform pg_temp.pk_sit(t, 4, 500, 0);
  perform pg_temp.pk_sit(t, 5, 2000, 1);
  perform pg_temp.pk_deal(t, 0, '{"0": ["As", "Ad"], "1": ["7c", "2d"]}', array['3h', '8c', '9d', 'Jh', '4s']);
  st := pg_temp.pk_do(t, 0, 'raise', 500);
  perform pg_temp.pk_as(4);
  r := public.reset_balance();
  st := pg_temp.pk_do(t, 1, 'call');
  perform pg_temp.ok((st -> 'seats' -> 0 ->> 'won')::int = 1000, 'an all-in player who resets is still in for the pot');
  st := pg_temp.pk_tick(t, 12);
  perform pg_temp.ok(st -> 'seats' -> 0 = 'null' and pg_temp.pk_cash(4) = 50000, 'but winning it adds nothing to the new run');
  perform pg_temp.pk_close(t);
end $$;
reset role;
select pg_temp.ok((select count(*) from private.poker_seats) = 0 and not exists (select 1 from public.poker_tables where stake = 'test'), 'the tables are empty again');

\echo 'all database tests passed'
