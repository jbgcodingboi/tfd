/**
 * Decisions about what the 30-second refresh asks the backend for. Kept pure
 * so the rules can be tested: every call here is made by every open tab, so
 * skipping the ones that can't have new answers is most of the site's
 * backend traffic.
 */

/** A portfolio the server sent this recently is not asked for again. */
export const PORTFOLIO_FRESH_MS = 10_000
/** With nothing that can settle, the portfolio is re-read this often instead of on every refresh. */
export const PORTFOLIO_IDLE_MS = 5 * 60_000
/** Results are re-read from a little before the newest one seen, in case rows landed out of order. */
export const RESOLUTIONS_OVERLAP_MS = 2 * 60_000

/**
 * Whether this refresh should re-read the portfolio. A call that just
 * answered (the first load, a trade, a game round) already carried it. Beyond
 * that, only a held market settling changes a portfolio from the server's
 * side, so with no open positions it is read every few minutes rather than
 * every 30 seconds.
 */
export function portfolioRefreshDue({ ageMs, openPositions }) {
  if (!(ageMs >= PORTFOLIO_FRESH_MS)) return false
  return openPositions > 0 || ageMs >= PORTFOLIO_IDLE_MS
}

/**
 * The time to ask for results from on the next refresh: just before the
 * newest result seen so far, so each refresh fetches only what is new instead
 * of the whole two-week list. Null (ask for everything) until a first answer
 * has arrived.
 */
export function resolutionsSince(previous, resolutions, loaded) {
  if (!loaded) return previous ?? null
  let newest = 0
  for (const r of Object.values(resolutions ?? {})) if (Number.isFinite(r?.at) && r.at > newest) newest = r.at
  const next = newest ? newest - RESOLUTIONS_OVERLAP_MS : null
  if (previous === null || previous === undefined) return next ?? previous ?? null
  return next && next > previous ? next : previous
}
