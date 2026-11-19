-- Concurrency test for the Tables game: several database sessions play at one
-- table at the same time, one call per transaction, the way browsers do.
-- Run by scripts/test-db.sh after schema.test.sql, in three parts:
--   psql -v part=setup, then one "psql -v part=worker -v player=N" per session
--   (player 0 is the clock; a player number used twice is one player in two
--   tabs), then psql -v part=check.
-- Any error in a worker (a deadlock, a broken constraint) fails the run, and the
-- check confirms no chip was created or lost.
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = warning;
select :'part' = 'setup' as is_setup, :'part' = 'worker' as is_worker, :'part' = 'check' as is_check \gset

\if :is_setup
create schema pkrace;
insert into auth.users (email, raw_user_meta_data) select 'race' || n || '@users.test', jsonb_build_object('username', 'race_' || chr(96 + n)) from generate_series(1, 6) n;
create table pkrace.run as
  select (select id from public.poker_tables where stake = 'low' order by id limit 1) as table_id,
    (select sum(cash) from public.portfolios where user_id in (select id from public.profiles where username::text like 'race\_%')) as total;
create function pkrace.u(n int) returns uuid language sql security definer as $$ select id from public.profiles where username = 'race_' || chr(96 + n) $$;
create function pkrace.chips() returns numeric language sql security definer as $$
  select (select sum(cash) from public.portfolios where user_id in (select pkrace.u(n) from generate_series(1, 6) n))
    + (select coalesce(sum(stack + committed), 0) from private.poker_seats where user_id in (select pkrace.u(n) from generate_series(1, 6) n)) $$;
-- The clock: makes every deadline 30 seconds older.
create function pkrace.age() returns void language sql security definer as $$
  update public.poker_tables set deadline = deadline - interval '30 seconds' where id = (select table_id from pkrace.run);
  update private.poker_seats set away_since = away_since - interval '30 seconds' where table_id = (select table_id from pkrace.run) $$;
-- Lets a session call faster than the per-minute limits allow. Rows another session holds are left for next time, so this never waits.
create function pkrace.unlimit(p_player int) returns void language sql security definer as $$
  delete from private.rate_limits where ctid in (select ctid from private.rate_limits
    where p_player = 0 or user_id = pkrace.u(p_player) for update skip locked) $$;
-- One random call by one player, or a push of the clock for player 0. Exactly one call per transaction, as from a browser.
-- Refusals are fine; errors are not.
create function pkrace.step(p_player int) returns void language plpgsql as $$
declare t bigint := (select table_id from pkrace.run); st jsonb := (select state from public.poker_tables where id = t); act jsonb := st -> 'act';
  x float8 := random(); v_seated boolean;
begin
  perform set_config('request.jwt.claim.sub', pkrace.u(case when p_player = 0 then 1 + floor(random() * 6)::int else p_player end)::text, true);
  if p_player = 0 then
    perform public.poker_tick(t);
    return;
  end if;
  v_seated := exists (select 1 from jsonb_array_elements(st -> 'seats') q where q ->> 'name' = 'race_' || chr(96 + p_player));
  if not v_seated then
    if x < 0.7 then perform public.poker_sit(t, (500 + floor(random() * 2000))::numeric); else perform public.poker_state(t); end if;
  elsif x < 0.04 then perform public.poker_leave(t);
  elsif x < 0.07 then perform public.poker_away(t, random() < 0.5);
  elsif x < 0.12 then perform public.poker_buy(t, 100);
  elsif x < 0.2 then perform public.poker_act(t, 'fold');
  elsif x < 0.55 then perform public.poker_act(t, case when (act ->> 'toCall')::int > 0 then 'call' else 'check' end);
  elsif x < 0.9 then perform public.poker_act(t, case when (st ->> 'bet')::int > 0 then 'raise' else 'bet' end,
    least((act ->> 'maxRaise')::numeric, (act ->> 'minRaise')::numeric + floor(random() * 60)::numeric));
  else perform public.poker_act(t, case when (st ->> 'bet')::int > 0 then 'raise' else 'bet' end, (act ->> 'maxRaise')::numeric);
  end if;
end $$;
grant usage on schema pkrace to authenticated;
grant select on pkrace.run to authenticated;
grant execute on all functions in schema pkrace to authenticated;
\endif

\if :is_worker
set role authenticated;
select format(case when n % 2 = 1 then case when :player = 0 then 'select pkrace.age()' else 'select pkrace.unlimit(%s)' end else 'select pkrace.step(%s)' end, :player)
from generate_series(1, 800) n \gexec
\endif

\if :is_check
-- Everyone gets up, the clock runs the last hand out, and the books must balance.
set client_min_messages = notice;
do $$
declare t bigint := (select table_id from pkrace.run); n int; i int;
begin
  for i in 1..40 loop
    exit when not exists (select 1 from private.poker_seats where table_id = t);
    for n in 1..6 loop
      perform pkrace.unlimit(n);
      perform set_config('request.jwt.claim.sub', pkrace.u(n)::text, true);
      perform public.poker_leave(t);
    end loop;
    perform pkrace.age();
    perform pkrace.unlimit(0);
    perform public.poker_tick(t);
  end loop;
  if exists (select 1 from private.poker_seats where table_id = t) then raise exception 'FAILED: the table did not empty: %', (select state from public.poker_tables where id = t); end if;
  if pkrace.chips() <> (select total from pkrace.run) then
    raise exception 'FAILED: chips went from % to % with sessions playing at once', (select total from pkrace.run), pkrace.chips();
  end if;
  if (select coalesce(sum(net), 0) from public.game_rounds where game = 'poker' and user_id in (select pkrace.u(k) from generate_series(1, 6) k)) <> 0 then
    raise exception 'FAILED: the hands played at once do not sum to zero';
  end if;
  raise notice 'ok: % hands with eight sessions playing at once (one player in two tabs): no error, no deadlock, and every chip accounted for',
    (select hand_no from public.poker_tables where id = t);
end $$;
set client_min_messages = warning;
drop schema pkrace cascade;
\endif
