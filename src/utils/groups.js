/**
 * Winner events ("Super Bowl Champion 2027") arrive as one market per outcome,
 * each tagged with the event as `group` (see services/gamma.js). The listing
 * shows each event once.
 */

/** Market ids and grouped events, in list order, each event where its first outcome is. */
export function collapseGroups(markets) {
  const out = []
  const groups = new Map()
  for (const m of markets) {
    if (!m.group) {
      out.push(m)
      continue
    }
    let entry = groups.get(m.group.id)
    if (!entry) {
      entry = { kind: 'group', id: m.group.id, title: m.group.title, size: m.group.size ?? 0, markets: [] }
      groups.set(m.group.id, entry)
      out.push(entry)
    }
    entry.markets.push(m)
  }
  // A search can leave only some outcomes; the event card shows those and still links to all of them.
  return out.map((e) => (e.kind === 'group' ? { ...e, size: Math.max(e.size, e.markets.length) } : e))
}

/** How many listing entries a set of markets makes, counting each event once. */
export function countEntries(markets) {
  const groups = new Set()
  let n = 0
  for (const m of markets) {
    if (!m.group) n++
    else if (!groups.has(m.group.id)) {
      groups.add(m.group.id)
      n++
    }
  }
  return n
}

/** An event's outcomes from a set of markets, most likely first. */
export const groupMembers = (markets, id) =>
  markets.filter((m) => m?.group?.id === id).sort((a, b) => b.yesPrice - a.yesPrice || b.volume - a.volume)
