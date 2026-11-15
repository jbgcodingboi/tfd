import { describe, expect, it } from 'vitest'
import { sortMarkets } from './filters.js'
import { collapseGroups, countEntries, groupMembers } from './groups.js'

const group = { id: '900', title: 'Super Bowl Champion 2027', size: 3 }
const team = (id, yes, volume) => ({ id, title: `Team ${id}`, category: 'sports', yesPrice: yes, volume, groupVolume: 3000, group: { ...group, label: `Team ${id}` } })
const single = (id, volume) => ({ id, title: `Market ${id}`, category: 'sports', yesPrice: 0.5, volume })

describe('winner events in the listing', () => {
  const list = [single('a', 2000), team('t1', 0.2, 500), single('b', 100), team('t2', 0.5, 2000), team('t3', 0.01, 500)]

  it('shows each event once, where its first outcome is', () => {
    const out = collapseGroups(list)
    expect(out.map((e) => (e.kind === 'group' ? `g:${e.id}` : e.id))).toEqual(['a', 'g:900', 'b'])
    expect(out[1]).toMatchObject({ title: 'Super Bowl Champion 2027', size: 3 })
    expect(out[1].markets.map((m) => m.id)).toEqual(['t1', 't2', 't3'])
  })

  it('counts each event once', () => {
    expect(countEntries(list)).toBe(3)
    expect(countEntries([])).toBe(0)
  })

  it('lists an event’s outcomes most likely first', () => {
    expect(groupMembers(list, '900').map((m) => m.id)).toEqual(['t2', 't1', 't3'])
    expect(groupMembers(list, 'nope')).toEqual([])
  })

  it('ranks an event by its total volume', () => {
    // The event (3,000 in all) outranks market a (2,000), though no single team does.
    const sorted = collapseGroups(sortMarkets(list, 'volume'))
    expect(sorted[0]).toMatchObject({ kind: 'group', id: '900' })
    expect(sorted[1].id).toBe('a')
  })
})
