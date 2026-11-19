/**
 * End-to-end check of the Tables game: two players in two phone-sized browsers
 * sit at one table and play real hands against the real database functions,
 * through the production build.
 *
 *   npm run test:e2e
 *
 * It starts scripts/dev-backend.mjs (supabase/schema.sql on a throwaway local
 * Postgres), builds the site against it, serves the build, and drives both
 * players with Playwright. Needs Postgres 16+ and Playwright with Chromium on
 * the machine; neither is a dependency of the site, so CI does not run this.
 * Screenshots go to E2E_SHOTS (a folder) when set.
 */
import { spawn, spawnSync } from 'node:child_process'
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const BACKEND = 'http://127.0.0.1:54321'
const SITE = 'http://127.0.0.1:4179'
const SHOTS = process.env.E2E_SHOTS
const { chromium, devices } = createRequire(import.meta.url)('playwright')
const TERMS_VERSION = (await import('../src/config.js')).TERMS_VERSION

const children = []
function start(cmd, args, env, ready) {
  const child = spawn(cmd, args, { cwd: ROOT, env: { ...process.env, ...env }, stdio: ['ignore', 'pipe', 'pipe'] })
  children.push(child)
  return new Promise((done, fail) => {
    let out = ''
    const onData = (d) => {
      out += d
      if (out.includes(ready)) done(child)
    }
    child.stdout.on('data', onData)
    child.stderr.on('data', onData)
    child.on('exit', (code) => fail(new Error(`${cmd} ${args.join(' ')} stopped (${code}):\n${out}`)))
  })
}
const cleanup = () => children.forEach((c) => c.kill('SIGTERM'))
const check = (cond, what) => {
  if (!cond) throw new Error(`FAILED: ${what}`)
  console.log(`  ok: ${what}`)
}
const post = async (path, body, token) => {
  const res = await fetch(BACKEND + path, { method: 'POST', headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) })
  return res.json()
}

/** A phone-sized browser already signed in as a new player who has accepted the Terms. */
async function player(browser, name) {
  const session = await post('/auth/v1/signup', { email: `${name}@users.chamimarket.app`, password: 'correct horse battery', data: { username: name } })
  if (!session.access_token) throw new Error(`could not sign up ${name}: ${JSON.stringify(session)}`)
  const context = await browser.newContext({ ...devices['iPhone 13'], reducedMotion: 'reduce' })
  await context.addInitScript(
    ([s, terms]) => {
      localStorage.setItem('chami-auth', JSON.stringify(s))
      localStorage.setItem('redbook:terms', JSON.stringify({ version: terms, at: new Date().toISOString() }))
    },
    [session, TERMS_VERSION],
  )
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', (e) => errors.push(String(e)))
  page.on('console', (m) => m.type() === 'error' && !/WebSocket|websocket|ERR_CONNECTION|Failed to load resource/i.test(m.text()) && errors.push(m.text()))
  return { name, page, session, errors }
}

const cardsOf = (page, scope) => page.locator(`${scope} [role="img"][aria-label*=" of "]`).evaluateAll((els) => els.map((e) => e.getAttribute('aria-label')))
/** The line announcing a hand's winner (with the controls on a phone). */
const won = (page) => page.locator('.tb-controls').getByText(/wins \$\d/).first()
const shot = async (page, file) => SHOTS && (mkdirSync(SHOTS, { recursive: true }), await page.screenshot({ path: join(SHOTS, file) }))

async function main() {
  await start('node', ['scripts/dev-backend.mjs'], {}, 'Local backend ready')
  const built = spawnSync('npx', ['vite', 'build', '--outDir', 'dist-e2e'], { cwd: ROOT, env: { ...process.env, VITE_SUPABASE_URL: BACKEND, VITE_SUPABASE_ANON_KEY: 'local' }, encoding: 'utf8' })
  if (built.status !== 0) throw new Error(`build failed:\n${built.stdout}${built.stderr}`)
  await start('npx', ['vite', 'preview', '--outDir', 'dist-e2e', '--port', '4179', '--strictPort', '--host', '127.0.0.1'], {}, '4179')
  const browser = await chromium.launch()
  const a = await player(browser, 'north_seat')
  const b = await player(browser, 'south_seat')

  // The lobby, then both players sit at the $1/$2 table.
  await a.page.goto(`${SITE}/#/games/tables`)
  await a.page.getByRole('heading', { name: '$1 / $2' }).waitFor()
  check((await a.page.title()) === 'Games · Chami Market', 'the tab title stays neutral')
  check((await a.page.getByRole('list', { name: 'Open tables' }).getByRole('listitem').count()) === 4, 'the lobby lists a table at each of the four stakes')
  await shot(a.page, '1-lobby.png')
  await a.page.getByRole('link', { name: /\$1 \/ \$2/ }).click()
  const tableUrl = await a.page.waitForURL(/games\/tables\/\d+/).then(() => a.page.url())
  for (const p of [a, b]) {
    if (p === b) await b.page.goto(tableUrl)
    await p.page.getByRole('button', { name: 'Take a seat' }).click()
    await p.page.getByRole('button', { name: 'Most' }).click()
    await p.page.getByRole('button', { name: /Sit down with \$200/ }).click()
    await p.page.getByLabel(/\(you\), \$/).waitFor()
  }
  check(true, 'both players bought in for $200 and are seated')

  // The first hand is dealt by the clock. Each player sees two cards of their own and none of the other's.
  await a.page.getByText(/Hand #1/).waitFor({ timeout: 20000 })
  await b.page.getByText(/Hand #1/).waitFor({ timeout: 20000 })
  await a.page.locator('.tb-pos-0 [aria-label*=" of "]').nth(1).waitFor()
  await b.page.locator('.tb-pos-0 [aria-label*=" of "]').nth(1).waitFor()
  const mineA = await cardsOf(a.page, '.tb-pos-0')
  const mineB = await cardsOf(b.page, '.tb-pos-0')
  check(mineA.length === 2 && mineB.length === 2, `each player is dealt two cards (${mineA.join(', ')} and ${mineB.join(', ')})`)
  const seenByA = await cardsOf(a.page, '.tb-felt')
  const seenByB = await cardsOf(b.page, '.tb-felt')
  check(!mineB.some((c) => seenByA.includes(c)) && !mineA.some((c) => seenByB.includes(c)), 'neither browser has been sent the other player’s cards')
  check((await a.page.locator('.tb-felt [aria-label="Face-down card"]').count()) === 2, 'the opponent’s two cards are face down')
  await shot(a.page, '2-dealt.png')

  // A refresh mid-hand brings back the seat and the same cards.
  await a.page.reload()
  await a.page.locator('.tb-pos-0 [aria-label*=" of "]').nth(1).waitFor()
  check(JSON.stringify(await cardsOf(a.page, '.tb-pos-0')) === JSON.stringify(mineA), 'a refresh mid-hand restores the seat and the same two cards')

  // Play it to a showdown: whoever's turn it is checks or calls (one raise on the way).
  let raised = false
  for (let i = 0; i < 40; i++) {
    if (await won(a.page).isVisible().catch(() => false)) break
    for (const p of [a, b]) {
      const call = p.page.getByRole('button', { name: /^(Check|Call)/ })
      if (!(await call.isVisible().catch(() => false))) continue
      const raise = p.page.getByRole('button', { name: /^(Bet|Raise to) \$/ })
      if (!raised && (await raise.isVisible().catch(() => false))) {
        await shot(p.page, '3-my-turn.png')
        await p.page.getByRole('button', { name: 'Pot', exact: true }).click().catch(() => {})
        await raise.click()
        raised = true
      } else {
        await call.click().catch(() => {})
      }
      await p.page.waitForTimeout(350)
    }
    await a.page.waitForTimeout(250)
  }
  await won(a.page).waitFor({ timeout: 15000 })
  await won(b.page).waitFor({ timeout: 15000 })
  const banner = await won(a.page).innerText()
  check(raised, 'a pot-sized raise from the slider presets was accepted')
  check(/wins \$\d/.test(banner), `the hand reaches a showdown and a winner is announced (“${banner.split('\n')[0]}”)`)
  check((await cardsOf(a.page, '.tb-middle')).length === 5, 'all five board cards are out')
  await shot(a.page, '4-showdown.png')
  const state = await post('/rest/v1/rpc/poker_state', { p_table: Number(tableUrl.split('/').pop()) }, a.session.access_token)
  const stacks = state.table.state.seats.filter(Boolean).map((s) => s.stack)
  check(stacks.reduce((x, y) => x + y, 0) === 400, `the two stacks still add up to the $400 brought to the table (${stacks.join(' + ')})`)

  // The fairness check opens the seals of the cards that were shown.
  await a.page.getByText('Fair deal', { exact: true }).click()
  await a.page.getByRole('button', { name: 'Check the last hand' }).click()
  await a.page.getByText(/the 52 seals match the published hash/).waitFor()
  check(true, 'the last hand passes the fairness check in the browser')

  // The next hand starts on its own; then one player leaves and gets their chips back.
  await a.page.getByText(/Hand #2/).waitFor({ timeout: 20000 })
  check(true, 'the next hand is dealt without anyone asking')
  const before = (await post('/rest/v1/rpc/get_portfolio', {}, b.session.access_token)).cash
  await b.page.getByRole('button', { name: /^Leave table/ }).click()
  await b.page.getByText(/You are watching|You have left/).first().waitFor()
  await won(a.page).waitFor({ timeout: 15000 })
  await b.page.waitForTimeout(8000)
  const after = await post('/rest/v1/rpc/get_portfolio', {}, b.session.access_token)
  const mine = await post('/rest/v1/rpc/get_portfolio', {}, a.session.access_token)
  check(after.tableChips === 0 && after.cash > before, 'leaving folds the hand and returns the stack to available funds')
  check(after.cash + mine.cash + mine.tableChips === 200000, 'between them the two players still have exactly $200,000')
  check(after.games.history.some((h) => h.game === 'poker') && mine.games.stats.poker.rounds >= 2, 'both players’ hands are in their game history')
  await shot(b.page, '5-watching.png')
  // A private table: one player opens it and reads out its code, a friend types the code in and sits down.
  await a.page.goto(`${SITE}/#/games/tables`)
  await a.page.getByRole('radio', { name: '$1/$2' }).click()
  await a.page.getByRole('button', { name: 'Create table' }).click()
  await a.page.waitForURL(/games\/tables\/\d+\?code=[A-Z2-9]{6}/)
  const privateUrl = a.page.url()
  const code = privateUrl.match(/code=([A-Z2-9]{6})/)[1]
  const privateId = privateUrl.match(/tables\/(\d+)/)[1]
  await a.page.getByText(`${code.slice(0, 3)}-${code.slice(3)}`).first().waitFor()
  check(true, `a private table opens with a code (${code})`)
  await b.page.goto(`${SITE}/#/games/tables`)
  check((await b.page.getByRole('list', { name: 'Open tables' }).locator(`a[href$="/${privateId}"]`).count()) === 0, 'the private table is not in the lobby')
  await b.page.goto(`${SITE}/#/games/tables/${privateId}`)
  await b.page.getByText('This is a private table').waitFor()
  check(true, 'opened without the code, it asks for the code')
  await b.page.getByLabel('Join code').fill('ZZZZZZ')
  await b.page.getByRole('button', { name: 'Join' }).click()
  await b.page.getByRole('alert').waitFor()
  check(true, 'a wrong code is refused')
  await b.page.getByLabel('Join code').fill(code.toLowerCase())
  await b.page.getByRole('button', { name: 'Join' }).click()
  await b.page.waitForURL(/code=/)
  await b.page.getByRole('button', { name: 'Take a seat' }).click()
  await b.page.getByRole('button', { name: 'Least' }).click()
  await b.page.getByRole('button', { name: /Sit down with/ }).click()
  await b.page.getByLabel(/\(you\), \$/).waitFor()
  check(true, 'a friend typed the code and took a seat')
  const spectator = await post('/rest/v1/rpc/poker_state', { p_table: Number(privateId) }, a.session.access_token)
  const outsider = await post('/rest/v1/rpc/poker_state', { p_table: Number(privateId) }, (await post('/auth/v1/signup', { email: 'outsider_x@users.chamimarket.app', password: 'correct horse battery', data: { username: 'outsider_x' } })).access_token)
  check(spectator.table && outsider.private === true && !outsider.table, `a player without the code gets nothing back about the table (${JSON.stringify(outsider).slice(0, 120)})`)
  check(a.errors.length === 0 && b.errors.length === 0, `no errors in either browser${a.errors.concat(b.errors).length ? `: ${a.errors.concat(b.errors).join(' | ')}` : ''}`)
  await browser.close()
}

main()
  .then(() => {
    console.log('tables end-to-end check passed')
    cleanup()
    process.exit(0)
  })
  .catch((err) => {
    console.error(err.message)
    cleanup()
    process.exit(1)
  })
