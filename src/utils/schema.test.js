import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

/**
 * Supabase turns on pg_safeupdate for API callers: a DELETE or UPDATE with no
 * WHERE clause fails with "DELETE requires a WHERE clause", even inside a
 * SECURITY DEFINER function. A plain Postgres (which the database tests run
 * on) doesn't, so such a statement passes every test and only fails on the
 * live site. This reads supabase/schema.sql and checks every DELETE and UPDATE
 * statement in it has one.
 */
const schema = readFileSync(new URL('../../supabase/schema.sql', import.meta.url), 'utf8')

/** The SQL with comments and quoted text blanked out, so a `;` or the word where inside them is not mistaken for code. */
function code(sql) {
  return sql
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/--[^\n]*/g, ' ')
    .replace(/'(?:[^']|'')*'/g, "''")
}

const DELETE = /\bdelete\s+from\s+[\w."]+/i
const UPDATE = /\bupdate\s+[\w."]+(?:\s+(?:as\s+)?\w+)?\s+set\b/i

/** Statements (split at semicolons) that delete or update with no where. An upsert's "do update set" and "for update" locks are not updates. */
export function withoutWhere(sql) {
  return code(sql)
    .split(';')
    .map((s) => s.replace(/\bdo\s+update\s+set\b/gi, ' ').replace(/\bfor\s+update\b/gi, ' '))
    .filter((s) => (DELETE.test(s) || UPDATE.test(s)) && !/\bwhere\b/i.test(s))
    .map((s) => s.trim().replace(/\s+/g, ' ').slice(0, 90))
}

describe('statements Supabase would refuse', () => {
  it('finds a delete or update with no where', () => {
    expect(withoutWhere('delete from private.cache; update public.t set a = 1;')).toEqual(['delete from private.cache', 'update public.t set a = 1'])
    expect(withoutWhere('create function f() as $$ begin delete from private.cache; end $$;').length).toBe(1)
  })
  it('leaves statements with a where, upserts, locks and text alone', () => {
    const fine = `
      delete from private.cache where id = 1;
      update public.t set a = 1 where id = 2;
      update public.t x set a = 1 from public.u where u.id = x.id;
      insert into public.t (id) values (1) on conflict (id) do update set a = 2;
      select * from public.t for update;
      -- delete from nothing;
      /* update x set y = 1; */
      select 'delete from nothing; update x set y = 1';
    `
    expect(withoutWhere(fine)).toEqual([])
  })
  it('finds none in supabase/schema.sql', () => {
    expect(withoutWhere(schema)).toEqual([])
  })
})
