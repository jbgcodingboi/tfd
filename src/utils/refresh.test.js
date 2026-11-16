import { describe, expect, it } from 'vitest'
import { PORTFOLIO_FRESH_MS, PORTFOLIO_IDLE_MS, RESOLUTIONS_OVERLAP_MS, portfolioRefreshDue, resolutionsSince } from './refresh.js'

describe('portfolioRefreshDue', () => {
  it('never re-reads a portfolio the server just sent', () => {
    expect(portfolioRefreshDue({ ageMs: 0, openPositions: 3 })).toBe(false)
    expect(portfolioRefreshDue({ ageMs: PORTFOLIO_FRESH_MS - 1, openPositions: 3 })).toBe(false)
  })
  it('re-reads on every refresh while a position is open, so settlements show up within a cycle', () => {
    expect(portfolioRefreshDue({ ageMs: PORTFOLIO_FRESH_MS, openPositions: 1 })).toBe(true)
    expect(portfolioRefreshDue({ ageMs: 30_000, openPositions: 2 })).toBe(true)
  })
  it('with nothing open, re-reads only every few minutes', () => {
    expect(portfolioRefreshDue({ ageMs: 30_000, openPositions: 0 })).toBe(false)
    expect(portfolioRefreshDue({ ageMs: PORTFOLIO_IDLE_MS - 1, openPositions: 0 })).toBe(false)
    expect(portfolioRefreshDue({ ageMs: PORTFOLIO_IDLE_MS, openPositions: 0 })).toBe(true)
  })
  it('treats a portfolio that was never loaded as not due (the load itself is on its way)', () => {
    expect(portfolioRefreshDue({ ageMs: NaN, openPositions: 1 })).toBe(false)
  })
})

describe('resolutionsSince', () => {
  const at = Date.UTC(2026, 10, 1)
  it('asks for everything until a first answer arrives', () => {
    expect(resolutionsSince(null, {}, false)).toBeNull()
    expect(resolutionsSince(null, { a: { outcome: 'yes', at } }, false)).toBeNull()
  })
  it('then asks from just before the newest result seen', () => {
    expect(resolutionsSince(null, { a: { outcome: 'yes', at: at - 5000 }, b: { outcome: 'no', at } }, true)).toBe(at - RESOLUTIONS_OVERLAP_MS)
  })
  it('never moves backwards, and stays put when nothing new came', () => {
    const since = at - RESOLUTIONS_OVERLAP_MS
    expect(resolutionsSince(since, {}, true)).toBe(since)
    expect(resolutionsSince(since, { old: { outcome: 'yes', at: at - 864e5 } }, true)).toBe(since)
    expect(resolutionsSince(since, { c: { outcome: 'void', at: at + 60_000 } }, true)).toBe(since + 60_000)
  })
  it('keeps asking for everything while the server has no results at all', () => {
    expect(resolutionsSince(null, {}, true)).toBeNull()
  })
  it('ignores malformed rows', () => {
    expect(resolutionsSince(null, { a: { at: 'soon' }, b: null }, true)).toBeNull()
  })
})
