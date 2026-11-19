/**
 * Live connection to one table of the card game between players.
 *
 * The public state of a table arrives over Supabase Realtime as the table's
 * row changes (it never carries a hidden card). The player's own cards come
 * from one server call, made when they are dealt a new hand, when their seat
 * changes, and on a reload, so a refresh mid-hand restores seat and cards.
 * While Realtime is down the page polls instead. A private table is only
 * readable by the players seated at it (Realtime respects that), so someone
 * watching with the code polls instead of waiting for pushes.
 *
 * There is no game server keeping time. When a deadline the page can see
 * passes (a player's turn, the next deal), it pushes the clock with one small
 * call and the database plays out whatever is due.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useAccountStore } from '../../store/accountStore.js'
import * as backend from '../backend/api.js'
import { BackendError } from '../backend/api.js'

/** How often to ask for the table while Realtime is down, and (much less often) while it is up, which also tells the server this browser is still here. */
const POLL_DOWN_MS = 2500
const POLL_LIVE_MS = 20000
/** A deadline is pushed a little after it passes: the server allows moves a second of grace. */
const PUSH_AFTER_MS = 1300

export function useTable(tableId, code = null) {
  const username = useAccountStore((s) => s.user?.username ?? null)
  const [view, setView] = useState(null)
  const [status, setStatus] = useState('loading')
  const [live, setLive] = useState(false)
  // The newest version applied, and what the last server call said about this player.
  const cur = useRef({ version: -1, turn: null, me: null, cardsHand: null, loading: false, settledHand: null })
  const liveRef = useRef(false)

  const apply = useCallback((res) => {
    if (!res) return
    if (res.portfolio) useAccountStore.getState().adoptRemote(res.portfolio)
    if (res.closed) return setStatus('closed')
    if (res.private && !res.table) return setStatus('locked')
    if (!res.table || res.table.version < cur.current.version) return
    cur.current.version = res.table.version
    cur.current.turn = res.table.state.turn ?? null
    cur.current.me = res.me ?? null
    cur.current.cardsHand = res.me?.cards ? res.table.state.hand : null
    setView({ table: res.table, me: res.me ?? null, offset: (res.now ?? Date.now()) - Date.now() })
    setStatus('ready')
  }, [])

  const reload = useCallback(async () => {
    if (cur.current.loading) return
    cur.current.loading = true
    try {
      apply(await backend.pokerState(tableId, code))
    } catch (err) {
      setStatus((s) => (s === 'loading' ? 'error' : s))
      throw err
    } finally {
      cur.current.loading = false
    }
  }, [tableId, code, apply])
  const quietReload = useCallback(() => reload().catch(() => {}), [reload])

  // A new public row from Realtime.
  const onRow = useCallback(
    (row) => {
      if (!row || !(row.version > cur.current.version) || !row.state) return
      cur.current.version = row.version
      cur.current.turn = row.state.turn ?? null
      setView((v) => (v ? { ...v, table: { ...v.table, version: row.version, state: row.state } } : v))
      const me = cur.current.me
      const mine = me ? row.state.seats?.[me.seat] : null
      // Seat and cards come from the server only: ask when this player's seat changed under them or a new hand was dealt to them.
      const seatChanged = me && (!mine || mine.name !== username || Boolean(mine.left) !== Boolean(me.left))
      const needCards = me && mine?.inHand && row.state.phase !== 'waiting' && cur.current.cardsHand !== row.state.hand
      if (seatChanged || needCards) quietReload()
    },
    [username, quietReload],
  )

  useEffect(() => {
    cur.current = { version: -1, turn: null, me: null, cardsHand: null, loading: false, settledHand: null }
    let stop = null
    let gone = false
    backend.pokerState(tableId, code).then(apply, () => setStatus((s) => (s === 'loading' ? 'error' : s)))
    backend
      .subscribePokerTable(tableId, onRow, (up) => {
        setLive(up)
        // Anything that changed while the connection was down.
        if (up) quietReload()
      })
      .then((unsubscribe) => (gone ? unsubscribe() : (stop = unsubscribe)))
      .catch(() => {})
    return () => {
      gone = true
      stop?.()
    }
  }, [tableId, code, onRow, quietReload, apply])

  // Pushes only reach players seated at a private table (Realtime respects who may read its row), so anyone else is polling.
  const watching = Boolean(view?.table.private) && view?.me == null
  const pushed = live && !watching
  useEffect(() => {
    liveRef.current = pushed
  }, [pushed])

  // Polling: the fallback while Realtime is down, and a slow heartbeat while it is up.
  useEffect(() => {
    const t = setInterval(() => document.visibilityState === 'visible' && quietReload(), pushed ? POLL_LIVE_MS : POLL_DOWN_MS)
    const onVisible = () => document.visibilityState === 'visible' && quietReload()
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      clearInterval(t)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [pushed, quietReload])

  // The clock push: once a visible deadline has passed, ask the server to play out what is due.
  const deadline = view?.table.state.deadline ?? null
  const offset = view?.offset ?? 0
  useEffect(() => {
    // A spectator at a private table has nothing to push: the polling above plays the table out for them.
    if (!deadline || watching) return undefined
    let timer = null
    const push = async () => {
      const before = cur.current.version
      try {
        const res = await backend.pokerTick(tableId)
        if (res?.closed) return setStatus('closed')
        if (res?.version > cur.current.version && !liveRef.current) await reload()
      } catch {
        // The next push or poll tries again.
      }
      // Still the same deadline (another browser may be about to push it too): look again shortly.
      if (cur.current.version === before) timer = setTimeout(push, 3000)
    }
    // A little spread, so every browser at the table doesn't push in the same instant.
    timer = setTimeout(push, Math.max(0, deadline - (Date.now() + offset)) + PUSH_AFTER_MS + Math.random() * 700)
    return () => clearTimeout(timer)
  }, [deadline, offset, tableId, watching, reload])

  // After a hand this player was in, pick up the result for their history and stats.
  const state = view?.table.state ?? null
  const mySeat = view?.me?.seat ?? null
  useEffect(() => {
    if (!state || mySeat === null || state.phase !== 'showdown' || !state.seats?.[mySeat]?.inHand) return undefined
    if (cur.current.settledHand === state.hand) return undefined
    cur.current.settledHand = state.hand
    const t = setTimeout(() => useAccountStore.getState().refreshRemote().catch(() => {}), 1200)
    return () => clearTimeout(t)
  }, [state, mySeat])

  const actions = useMemo(() => {
    /** Runs a call, shows the table it answers with, and turns a refusal into an error for the caller to show. */
    const run = async (call) => {
      const res = await call()
      apply(res)
      if (res?.error) throw new BackendError(res.error)
      return res
    }
    return {
      reload,
      // The turn being answered goes along, so a late or repeated click is never played as the next decision.
      act: (action, amount) => run(() => backend.pokerAct({ table: tableId, action, amount, turn: cur.current.turn })),
      sit: (buyIn, seat) => run(() => backend.pokerSit({ table: tableId, buyIn, seat, code })),
      leave: () => run(() => backend.pokerLeave(tableId)),
      away: (away) => run(() => backend.pokerAway({ table: tableId, away })),
      buy: (amount) => run(() => backend.pokerBuy({ table: tableId, amount })),
    }
  }, [tableId, code, apply, reload])

  return { status, live: pushed, table: view?.table ?? null, state, me: view?.me ?? null, offset, actions }
}
