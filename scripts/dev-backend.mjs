/**
 * A local stand-in for the Supabase backend, for trying backend mode (real
 * accounts, the shared leaderboard, the Tables game) on one machine with no
 * Supabase project:
 *
 *   npm run dev:backend
 *   VITE_SUPABASE_URL=http://127.0.0.1:54321 VITE_SUPABASE_ANON_KEY=local npm run dev
 *
 * It runs supabase/schema.sql on a throwaway local Postgres (16+, the same
 * set-up as `npm run test:db`) and serves the few endpoints the app calls:
 * sign-up, log-in and guest sessions, /rest/v1/rpc/<function>, and the
 * activity feed. There is no Realtime here, so pages fall back to polling,
 * which is also how they behave when Realtime is down in production.
 *
 * For development only. Sessions are unsigned and anyone who can reach the
 * port can act as any player. It listens on 127.0.0.1 and everything is
 * deleted when it stops.
 */
import { spawnSync } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { chownSync, mkdtempSync, readdirSync, rmSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const PORT = Number(process.env.DEV_BACKEND_PORT ?? 54321)
const PG_PORT = Number(process.env.PG_DEV_PORT ?? 54330)

function pgBin() {
  if (process.env.PG_BIN) return process.env.PG_BIN
  const base = '/usr/lib/postgresql'
  const versions = readdirSync(base).sort((a, b) => Number(a) - Number(b))
  return join(base, versions.at(-1), 'bin')
}

const BIN = pgBin()
const DIR = mkdtempSync(join(tmpdir(), 'chami-backend-'))
const asPostgres = process.getuid?.() === 0 ? ['runuser', '-u', 'postgres', '--'] : []
if (asPostgres.length) chownSync(DIR, Number(spawnSync('id', ['-u', 'postgres']).stdout.toString()), 0)

function run(cmd, args, input) {
  const [bin, ...rest] = [...asPostgres, join(BIN, cmd), ...args]
  const res = spawnSync(bin, rest, { input, encoding: 'utf8', env: { ...process.env, PGOPTIONS: '-c client_min_messages=warning' }, maxBuffer: 64 * 1024 * 1024 })
  return { ok: res.status === 0, out: res.stdout ?? '', err: res.stderr ?? '' }
}

const psqlArgs = ['-X', '-h', DIR, '-p', String(PG_PORT), '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q']

/** Runs SQL and returns the last line printed (statements here end with one select of a JSON text). */
function sql(text) {
  const res = run('psql', [...psqlArgs, '-A', '-t', '-f', '-'], text)
  if (!res.ok) {
    const message = (res.err.match(/ERROR:\s+(.*)/) ?? [])[1] ?? 'Database error'
    throw Object.assign(new Error(message), { status: 400 })
  }
  return res.out.trim().split('\n').at(-1) ?? ''
}

/** A value as a SQL literal that no content can break out of. */
function lit(value) {
  const tag = `q${randomBytes(6).toString('hex')}`
  return `$${tag}$${String(value)}$${tag}$`
}

function stop() {
  run('pg_ctl', ['-D', join(DIR, 'data'), '-m', 'immediate', 'stop'])
  rmSync(DIR, { recursive: true, force: true })
}

function must(res, what) {
  if (res.ok) return
  console.error(`${what} failed:\n${res.err || res.out}`)
  stop()
  process.exit(1)
}

must(run('initdb', ['-D', join(DIR, 'data'), '-U', 'postgres', '-A', 'trust', '-E', 'UTF8', '--locale=C']), 'initdb')
must(run('pg_ctl', ['-D', join(DIR, 'data'), '-o', `-p ${PG_PORT} -k ${DIR} -c listen_addresses='' -c fsync=off`, '-l', join(DIR, 'log'), '-w', 'start']), 'Starting Postgres')
must(run('psql', [...psqlArgs, '-f', join(ROOT, 'supabase/tests/supabase-stub.sql')]), 'Loading the Supabase stand-in')
must(run('psql', [...psqlArgs, '-f', join(ROOT, 'supabase/schema.sql')]), 'Loading supabase/schema.sql')

/** Argument names and types of every public function, to cast what the browser sends. */
const FUNCTIONS = JSON.parse(
  sql(`select jsonb_object_agg(p.proname, jsonb_build_object('names', coalesce(to_jsonb(p.proargnames), '[]'),
    'types', (select coalesce(jsonb_agg(format_type(t, null) order by o), '[]') from unnest(p.proargtypes) with ordinality as x(t, o))))::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'`),
)

const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url')
const isUuid = (v) => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v)

/** The signed-in user id from a request, or null. Tokens here are not signed: this is a development tool. */
function userOf(req) {
  try {
    const token = (req.headers.authorization ?? '').replace(/^Bearer\s+/i, '')
    const sub = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).sub
    return isUuid(sub) ? sub : null
  } catch {
    return null
  }
}

function session(id) {
  const u = JSON.parse(sql(`select jsonb_build_object('id', id, 'email', email, 'is_anonymous', is_anonymous, 'user_metadata', raw_user_meta_data, 'created_at', created_at)::text
    from auth.users where id = ${lit(id)}::uuid`) || 'null')
  if (!u) throw Object.assign(new Error('Invalid login credentials'), { status: 400 })
  const user = { ...u, aud: 'authenticated', role: 'authenticated', app_metadata: {}, email: u.email ?? '' }
  const exp = Math.floor(Date.now() / 1000) + 3600 * 24
  const access = `${b64({ alg: 'none', typ: 'JWT' })}.${b64({ sub: id, role: 'authenticated', aud: 'authenticated', exp, is_anonymous: u.is_anonymous })}.dev`
  return { access_token: access, token_type: 'bearer', expires_in: 3600 * 24, expires_at: exp, refresh_token: `dev.${id}`, user }
}

const AUTH = {
  'POST /auth/v1/signup'(req, body) {
    const meta = lit(JSON.stringify(body.data ?? {}))
    const id = body.email
      ? sql(`insert into auth.users (email, encrypted_password, raw_user_meta_data)
          values (lower(${lit(body.email)}), extensions.crypt(${lit(body.password ?? '')}, extensions.gen_salt('bf', 4)), ${meta}::jsonb) returning id`)
      : sql(`insert into auth.users (is_anonymous, raw_user_meta_data) values (true, ${meta}::jsonb) returning id`)
    return session(id)
  },
  'POST /auth/v1/token'(req, body, query) {
    if (query.get('grant_type') === 'refresh_token') return session(String(body.refresh_token ?? '').replace(/^dev\./, ''))
    const id = sql(`select id from auth.users where email = lower(${lit(body.email ?? '')}) and encrypted_password = extensions.crypt(${lit(body.password ?? '')}, encrypted_password)`)
    if (!isUuid(id)) throw Object.assign(new Error('Invalid login credentials'), { status: 400 })
    return session(id)
  },
  'GET /auth/v1/user'(req) {
    return session(userOf(req)).user
  },
  'PUT /auth/v1/user'(req, body) {
    const id = userOf(req)
    if (!id) throw Object.assign(new Error('Not authenticated'), { status: 401 })
    if (body.email) sql(`update auth.users set email = lower(${lit(body.email)}), is_anonymous = false where id = ${lit(id)}::uuid`)
    if (body.password) sql(`update auth.users set encrypted_password = extensions.crypt(${lit(body.password)}, extensions.gen_salt('bf', 4)) where id = ${lit(id)}::uuid`)
    if (body.data) sql(`update auth.users set raw_user_meta_data = raw_user_meta_data || ${lit(JSON.stringify(body.data))}::jsonb where id = ${lit(id)}::uuid`)
    return session(id).user
  },
  'POST /auth/v1/logout'() {
    return {}
  },
}

/** Calls a public function the way PostgREST does: as the caller's role, with their id in the JWT claims. */
function rpc(name, args, user) {
  const fn = FUNCTIONS[name]
  if (!/^[a-z_]+$/.test(name) || !fn) throw Object.assign(new Error(`Could not find the function public.${name}`), { status: 404 })
  const json = lit(JSON.stringify(args ?? {}))
  const list = Object.keys(args ?? {}).map((key) => {
    const type = fn.types[fn.names.indexOf(key)]
    if (!/^[a-z_0-9]+$/.test(key) || !type) throw Object.assign(new Error(`Unknown argument ${key}`), { status: 400 })
    if (type === 'jsonb') return `${key} => (${json}::jsonb -> '${key}')`
    if (type.endsWith('[]')) return `${key} => (select array_agg(x::${type.slice(0, -2)}) from jsonb_array_elements_text(${json}::jsonb -> '${key}') x)`
    return `${key} => (${json}::jsonb ->> '${key}')::${type}`
  })
  const out = sql(`set role ${user ? 'authenticated' : 'anon'};
    select set_config('request.jwt.claim.sub', ${lit(user ?? '')}, false);
    select coalesce(to_jsonb(public.${name}(${list.join(', ')})), 'null')::text;`)
  return JSON.parse(out || 'null')
}

/** The activity feed is the one table the app reads directly that matters here; the rest answer empty. */
function table(name, query) {
  if (name !== 'activity') return []
  const kind = query.get('kind') === 'eq.game' ? `kind = 'game'` : `kind in ('buy', 'sell')`
  const limit = Math.min(200, Number(query.get('limit')) || 100)
  return JSON.parse(sql(`select coalesce(jsonb_agg(t), '[]')::text from (
    select id, username, kind, market_id, market_title, side, side_label, shares, price, amount, game, net, detail, created_at
    from public.activity where ${kind} order by created_at desc limit ${limit}) t`))
}

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
  'Access-Control-Max-Age': '600',
}

const server = createServer((req, res) => {
  const url = new URL(req.url, 'http://local')
  const chunks = []
  req.on('data', (c) => chunks.push(c))
  req.on('end', () => {
    const send = (status, data) => {
      res.writeHead(status, { ...CORS, 'Content-Type': 'application/json' })
      res.end(JSON.stringify(data))
    }
    if (req.method === 'OPTIONS') return send(200, {})
    try {
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString() || '{}') : {}
      const auth = AUTH[`${req.method} ${url.pathname}`]
      if (auth) return send(200, auth(req, body, url.searchParams))
      const call = url.pathname.match(/^\/rest\/v1\/rpc\/([a-z_]+)$/)
      if (call && req.method === 'POST') return send(200, rpc(call[1], body, userOf(req)))
      const read = url.pathname.match(/^\/rest\/v1\/([a-z_]+)$/)
      if (read && req.method === 'GET') return send(200, table(read[1], url.searchParams))
      send(404, { message: 'Not served by the local backend' })
    } catch (err) {
      send(err.status ?? 500, { message: err.message, msg: err.message, error_description: err.message })
    }
  })
})
// Realtime is not served: closing the upgrade makes the app poll instead.
server.on('upgrade', (req, socket) => socket.destroy())
server.listen(PORT, '127.0.0.1', () => {
  console.log(`Local backend ready on http://127.0.0.1:${PORT}`)
  console.log(`Start the site with: VITE_SUPABASE_URL=http://127.0.0.1:${PORT} VITE_SUPABASE_ANON_KEY=local npm run dev`)
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close()
    stop()
    process.exit(0)
  })
}
