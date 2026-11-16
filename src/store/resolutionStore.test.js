import { beforeEach, describe, expect, it } from 'vitest'
import { useResolutionStore } from './resolutionStore.js'

describe('merging results from the server', () => {
  beforeEach(() => useResolutionStore.setState({ resolutions: {} }))

  it('adds new results and keeps the ones already known', () => {
    const store = useResolutionStore.getState()
    store.merge({ a: { outcome: 'yes', at: 1 } })
    store.merge({ b: { outcome: 'no', at: 2 } })
    expect(useResolutionStore.getState().resolutions).toEqual({ a: { outcome: 'yes', at: 1 }, b: { outcome: 'no', at: 2 } })
  })
  it('leaves the state untouched when a refresh brings nothing new, so nothing re-renders', () => {
    const store = useResolutionStore.getState()
    store.merge({ a: { outcome: 'yes', at: 1 } })
    const before = useResolutionStore.getState().resolutions
    store.merge({})
    store.merge({ a: { outcome: 'yes', at: 1 } })
    expect(useResolutionStore.getState().resolutions).toBe(before)
  })
  it('ignores unsafe market ids', () => {
    useResolutionStore.getState().merge(JSON.parse('{"__proto__": {"outcome": "yes", "at": 1}, "ok": {"outcome": "void", "at": 3}}'))
    expect(Object.keys(useResolutionStore.getState().resolutions)).toEqual(['ok'])
  })
})
