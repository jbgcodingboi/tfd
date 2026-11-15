import {
  GAMMA_BASE,
  MARKETS_PER_EVENT,
  MIN_LIQUIDITY,
  POLITICS_MARKET_LIMIT,
  SPORTS_MARKET_LIMIT,
  TAGGED_CATEGORIES,
} from '../config.js'
import { curate, endDateCutoff, TOP_SOCCER_LEAGUES } from '../utils/curation.js'
import { isSafeKey } from '../utils/safe.js'
import { fetchJson, HttpError } from './http.js'
import { isListable, normalizeGammaMarket, toNumber } from './normalize.js'

/** Leagues fetched as their own game feeds, on top of the general sports tag. */
export const LEAGUE_FEEDS = ['nfl', 'cfb', 'mlb', 'nba', 'nhl', ...TOP_SOCCER_LEAGUES]

const tagIdFrom = (tag) => {
  const id = toNumber(tag?.id)
  return id !== null && Number.isInteger(id) ? String(id) : null
}

/**
 * Looks up the Gamma tag id for each visible category at startup, first via
 * /tags/slug/:slug and then by scanning the tag list, so ids are discovered
 * rather than hardcoded.
 */
export async function discoverTagIds() {
  const result = {}
  await Promise.all(
    TAGGED_CATEGORIES.map(async (cat) => {
      try {
        const tag = await fetchJson(`${GAMMA_BASE}/tags/slug/${cat.tagSlug}`)
        const id = tagIdFrom(tag)
        if (id) result[cat.id] = id
      } catch {
        // Try the list endpoint below.
      }
    }),
  )
  const missing = TAGGED_CATEGORIES.filter((c) => !result[c.id])
  if (missing.length) {
    const tags = await fetchJson(`${GAMMA_BASE}/tags?limit=1000`)
    if (!Array.isArray(tags)) throw new HttpError('Malformed tag list')
    for (const cat of missing) {
      const match = tags.find((t) => typeof t?.slug === 'string' && t.slug.toLowerCase() === cat.tagSlug)
      const id = tagIdFrom(match)
      if (id) result[cat.id] = id
    }
  }
  if (!TAGGED_CATEGORIES.every((c) => result[c.id])) throw new HttpError('Could not discover category tags')
  return result
}

/** Series ids for the league feeds, from Gamma's /sports metadata. */
export async function discoverLeagues() {
  const rows = await fetchJson(`${GAMMA_BASE}/sports`, { memoMs: 3600000 })
  if (!Array.isArray(rows)) throw new HttpError('Malformed sports metadata')
  const leagues = []
  for (const row of rows) {
    const code = typeof row?.sport === 'string' ? row.sport.trim().toLowerCase() : ''
    const seriesId = toNumber(String(row?.series ?? '').split(',')[0])
    if (LEAGUE_FEEDS.includes(code) && Number.isInteger(seriesId) && !leagues.some((l) => l.code === code)) {
      leagues.push({ code, seriesId: String(seriesId) })
    }
  }
  return leagues
}

function eventsUrl(params, now, withDates) {
  const query = new URLSearchParams({
    active: 'true',
    closed: 'false',
    archived: 'false',
    order: 'volume24hr',
    ascending: 'false',
    ...params,
  })
  if (withDates) {
    query.set('end_date_min', new Date(Math.floor(now / 60000) * 60000).toISOString())
    query.set('end_date_max', new Date(endDateCutoff(now)).toISOString())
  }
  return `${GAMMA_BASE}/events?${query}`
}

async function fetchEvents(params, now) {
  try {
    return await fetchJson(eventsUrl(params, now, true))
  } catch (err) {
    // If the server rejects the date filters, retry without them; curation still applies.
    if (err instanceof HttpError && err.status >= 400 && err.status < 500 && err.status !== 429) {
      return fetchJson(eventsUrl(params, now, false))
    }
    throw err
  }
}

/** The most outcomes kept from one winner event (an election can list many long shots). */
export const MAX_GROUP_OUTCOMES = 100

/**
 * "Pick the winner" events (a champion, an MVP, an election): Polymarket runs
 * them as one Yes/No market per outcome, exactly one of which wins, and flags
 * them as neg risk. Game events (moneyline, spreads, totals) are not.
 */
const isWinnerEvent = (ev) => ev?.negRisk === true || ev?.enableNegRisk === true

/**
 * Every outcome of a winner event, tagged with the event as `group` so the
 * app can show them together, or null when it doesn't qualify. Long shots are
 * kept (each outcome only needs a live price); the event as a whole must be
 * liquid. `groupVolume` is the event's total, used to rank it as one entry.
 */
function winnerGroup(ev, markets, now) {
  const id = ev.id === undefined || ev.id === null ? '' : String(ev.id)
  if (!isWinnerEvent(ev) || !/^\d{1,15}$/.test(id)) return null
  const open = markets.filter((m) => isListable(m, 0))
  if (open.length < 2 || open.reduce((sum, m) => sum + m.liquidity, 0) < MIN_LIQUIDITY) return null
  const title = typeof ev.title === 'string' ? ev.title.trim().slice(0, 300) : ''
  const image = typeof ev.image === 'string' && /^https:\/\//.test(ev.image) ? ev.image : null
  const kept = curate(
    open.map((m) => ({ ...m, group: { id, title: title || m.eventTitle, label: m.outcomeLabel || m.title, image } })),
    now,
  )
    .sort((a, b) => b.yesPrice - a.yesPrice || b.volume - a.volume)
    .slice(0, MAX_GROUP_OUTCOMES)
  if (kept.length < 2) return null
  const volume = kept.reduce((sum, m) => sum + m.volume, 0)
  return kept.map((m) => ({ ...m, group: { ...m.group, size: kept.length }, groupVolume: volume }))
}

/**
 * Open, liquid, curated binary markets from one events feed. A winner event
 * keeps every outcome (see winnerGroup); any other event contributes at most
 * MARKETS_PER_EVENT markets (highest volume first), so a single game with many
 * prop markets can't crowd out the rest.
 */
async function fetchFeed({ params, category, league = null }, now) {
  const events = await fetchEvents(params, now)
  if (!Array.isArray(events)) throw new HttpError('Malformed events response')
  const out = []
  for (const ev of events) {
    if (!Array.isArray(ev?.markets)) continue
    const context = { title: ev.title, image: ev.image, endDate: ev.endDate, tags: ev.tags }
    const normalized = ev.markets.map((m) => normalizeGammaMarket({ ...m, events: [context] }, category, { league })).filter(Boolean)
    const group = winnerGroup(ev, normalized, now)
    if (group) {
      out.push(...group)
      continue
    }
    const markets = normalized.filter((m) => isListable(m, MIN_LIQUIDITY)).sort((a, b) => b.volume - a.volume)
    out.push(...curate(markets, now).slice(0, MARKETS_PER_EVENT))
  }
  return out
}

/**
 * The full curated listing: league game feeds first (so their markets keep
 * the league code), then the general Sports and Politics tags. Sports gets the
 * larger share of the listing.
 */
export async function fetchCatalog({ tagIds = null, now = Date.now() } = {}) {
  const ids = tagIds ?? (await discoverTagIds())
  const leagues = await discoverLeagues().catch(() => [])
  const feeds = [
    ...leagues.map((l) => ({ category: 'sports', league: l.code, params: { series_id: l.seriesId, limit: '50' } })),
    { category: 'sports', params: { tag_id: ids.sports, limit: '100', offset: '0' } },
    { category: 'sports', params: { tag_id: ids.sports, limit: '100', offset: '100' } },
    { category: 'politics', params: { tag_id: ids.politics, limit: '100', offset: '0' } },
  ]
  const results = await Promise.allSettled(feeds.map((f) => fetchFeed(f, now)))
  if (results.every((r) => r.status === 'rejected')) throw results[0].reason

  const ok = { sports: false, politics: false }
  const seen = new Set()
  const byCategory = { sports: [], politics: [] }
  results.forEach((r, i) => {
    if (r.status !== 'fulfilled') return
    ok[feeds[i].category] = true
    for (const m of r.value) {
      if (seen.has(m.id)) continue
      seen.add(m.id)
      byCategory[m.category].push(m)
    }
  })
  // A winner event counts once, by its total volume, and keeps all of its outcomes.
  const top = (list, n) => {
    const units = new Map()
    for (const m of list) {
      const key = m.group ? `g:${m.group.id}` : m.id
      const unit = units.get(key) ?? { volume: m.groupVolume ?? m.volume, markets: [] }
      unit.markets.push(m)
      units.set(key, unit)
    }
    return [...units.values()]
      .sort((a, b) => b.volume - a.volume)
      .slice(0, n)
      .flatMap((u) => u.markets)
  }
  return {
    tagIds: ids,
    list: [...top(byCategory.sports, SPORTS_MARKET_LIMIT), ...top(byCategory.politics, POLITICS_MARKET_LIMIT)],
    ok,
  }
}

/** Single market lookup, used to refresh held markets and detect resolutions. */
export async function fetchMarketById(id, category, meta) {
  if (!/^\d+$/.test(id)) return null
  const raw = await fetchJson(`${GAMMA_BASE}/markets/${id}`)
  return normalizeGammaMarket(raw, category, meta)
}

/**
 * Results of recently closed markets, for settling positions. Used by the
 * scheduled snapshot job, which can reach the API even when a browser can't.
 */
export async function fetchRecentResolutions({ tagIds, now = Date.now(), days = 30 } = {}) {
  const resolutions = {}
  const pages = [
    { tag_id: tagIds.sports, offset: '0' },
    { tag_id: tagIds.sports, offset: '100' },
    { tag_id: tagIds.sports, offset: '200' },
    { tag_id: tagIds.politics, offset: '0' },
  ]
  for (const page of pages) {
    const query = new URLSearchParams({
      closed: 'true',
      limit: '100',
      order: 'endDate',
      ascending: 'false',
      end_date_min: new Date(now - days * 864e5).toISOString(),
      ...page,
    })
    const events = await fetchJson(`${GAMMA_BASE}/events?${query}`).catch(() => null)
    if (!Array.isArray(events)) continue
    for (const ev of events) {
      for (const raw of Array.isArray(ev?.markets) ? ev.markets : []) {
        const m = normalizeGammaMarket(raw, page.tag_id === tagIds.politics ? 'politics' : 'sports')
        if (m?.resolvedOutcome && isSafeKey(m.id)) resolutions[m.id] = m.resolvedOutcome
      }
    }
  }
  return resolutions
}
