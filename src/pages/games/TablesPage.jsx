import { useCallback, useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useParams, useSearchParams } from 'react-router-dom'
import GameShell from '../../components/games/GameShell.jsx'
import SoundToggle from '../../components/games/SoundToggle.jsx'
import ActionBar from '../../components/games/tables/ActionBar.jsx'
import BuyInDialog from '../../components/games/tables/BuyInDialog.jsx'
import PrivateTables, { CodeForm, ShareCode } from '../../components/games/tables/PrivateTables.jsx'
import TableFelt from '../../components/games/tables/TableFelt.jsx'
import EmptyState from '../../components/ui/EmptyState.jsx'
import { ChevronLeftIcon, GridIcon } from '../../components/ui/Icons.jsx'
import { GAME_NAME, GAME_PATH } from '../../games/names.js'
import { formatBlinds, formatChips, isCodeShape, normalizeCode, rankLabel, secondsLeft, verifyProof } from '../../games/poker.js'
import { tableSounds } from '../../games/sounds/tables.js'
import { useDocumentTitle } from '../../hooks/useDocumentTitle.js'
import { useNow } from '../../hooks/useNow.js'
import { usePolling } from '../../hooks/usePolling.js'
import { pokerCreate, pokerJoin, pokerLobby, pokerProof } from '../../services/backend/api.js'
import { BACKEND_ENABLED } from '../../services/backend/config.js'
import { useTable } from '../../services/games/tables.js'
import { useAccountStore } from '../../store/accountStore.js'
import { useChips } from '../../store/gameStore.js'
import { toast } from '../../store/toastStore.js'
import { useUiStore } from '../../store/uiStore.js'
import './tables.css'

/** A table's address; a private one carries its code so a reload (or a friend with the link) gets back in. */
const tablePath = (id, code) => `${GAME_PATH.poker}/${id}${code ? `?code=${code}` : ''}`
const reducedMotion = () => window.matchMedia?.('(prefers-reduced-motion: reduce)').matches

function Rules() {
  return (
    <>
      <p>
        No-limit hold’em between players, two to six at a table. Everyone gets two cards of their own; five more are dealt face up for all to share. The best
        five cards out of seven win the pot. There is no house cut: every chip lost is won by another player.
      </p>
      <ul className="list-disc space-y-1 pl-5">
        <li>You buy in from your available funds, 50 to 250 big blinds at the public tables. The chips come back when you leave the table.</li>
        <li>
          To play with friends, open a private table: it gets a six-character code to share. Only people who have the code can see it or sit down, it stays
          out of the lobby, and an empty one closes after half an hour. You can have three open at a time. You choose the blinds and the buy-in range for
          your table: from 10 to 1,000 big blinds, typed or set with the sliders.
        </li>
        <li>The two players after the dealer button post the blinds. Heads-up, the button posts the small blind and acts first before the flop.</li>
        <li>On your turn you fold, check or call, or bet or raise. A raise adds at least the last bet or raise; you can always go all-in for less.</li>
        <li>An all-in for less than a full raise does not let players who already acted raise again.</li>
        <li>When players are all-in for different amounts, side pots keep everyone playing only for what they could match.</li>
        <li>Ties split the pot. An odd chip goes to the first winner left of the button.</li>
        <li>You have 25 seconds to act. Out of time, you check if you can and fold if not; twice in a row sits you out. A seat left idle for three minutes is freed and its chips returned.</li>
        <li>At a showdown, hands that can’t win are mucked and never shown. When everyone left is all-in, the hands are turned up and the board is dealt out.</li>
      </ul>
      <p>
        The server shuffles with a cryptographic random source and seals every card of the deck before dealing. “Check the last hand” below confirms the
        cards you saw were the ones sealed, without revealing anyone’s folded hand.
      </p>
      <p>
        Keyboard: <kbd>F</kbd> folds, <kbd>C</kbd> checks or calls, <kbd>R</kbd> bets or raises the amount on the slider.
      </p>
    </>
  )
}

/** Every open table by stakes, with seats filled, the way back to a seat already taken, and private tables for friends. */
function Lobby() {
  const navigate = useNavigate()
  const [lobby, setLobby] = useState(null)
  const [error, setError] = useState(null)
  const [working, setWorking] = useState(false)
  const [createError, setCreateError] = useState(null)
  const [joinError, setJoinError] = useState(null)
  const load = useCallback(
    () =>
      pokerLobby()
        .then((l) => (setLobby(l), setError(null)))
        .catch((err) => setError(err.message)),
    [],
  )
  usePolling(load, 8000, { immediate: true })

  /** Runs a server call that answers { table, code } or { error } and opens the table it names. */
  const open = async (call, fail) => {
    if (working) return
    setWorking(true)
    fail(null)
    try {
      const res = await call()
      if (res.error) fail(res.error)
      else navigate(tablePath(res.table, res.code))
    } catch (err) {
      fail(err.message)
    } finally {
      setWorking(false)
    }
  }

  if (!lobby) {
    return error ? (
      <EmptyState icon={GridIcon} title="Could not load the tables" action={<button type="button" className="btn btn-primary" onClick={load}>Try again</button>}>
        {error}
      </EmptyState>
    ) : (
      <div className="skeleton h-64" aria-label="Loading tables" />
    )
  }
  const seat = lobby.seat
  return (
    <div className="space-y-4">
      {seat && (
        <div className="card flex flex-wrap items-center justify-between gap-3 border-warn/50 p-4">
          <p className="text-sm">
            You have a seat at {seat.private ? 'a private ' : 'the '}
            <span className="font-semibold">{formatBlinds(seat.smallBlind, seat.bigBlind)}</span> table with <span className="font-semibold tabular">{formatChips(seat.stack)}</span>.
          </p>
          <Link to={tablePath(seat.table)} className="btn btn-primary h-11 px-5">
            Back to my seat
          </Link>
        </div>
      )}
      {!lobby.canSit && (
        <p className="card p-4 text-sm text-muted">
          Guests can watch any table. Sign up (it keeps your balance) to take a seat: hands move chips between players, so seats are for real accounts.
        </p>
      )}
      <ul className="grid gap-3 sm:grid-cols-2" aria-label="Open tables">
        {lobby.tables.map((t) => (
          <li key={t.id}>
            <Link
              to={tablePath(t.id)}
              className="group card flex h-full flex-col gap-3 p-4 transition hover:-translate-y-0.5 hover:border-line-strong focus-visible:ring-2 focus-visible:ring-primary-400"
            >
              <div className="flex items-start justify-between gap-3">
                <div>
                  <h2 className="text-lg font-semibold tabular">
                    {formatBlinds(t.smallBlind, t.bigBlind, ' / ')}
                  </h2>
                  <p className="text-xs text-muted tabular">
                    Buy-in {formatChips(t.minBuy)} to {formatChips(t.maxBuy)}
                  </p>
                </div>
                <span className={`rounded-full px-2.5 py-1 text-xs font-semibold tabular ${t.seated >= t.seats ? 'bg-no-soft text-no' : t.seated > 0 ? 'bg-yes-soft text-yes' : 'bg-surface-2 text-muted'}`}>
                  {t.seated}/{t.seats} seated
                </span>
              </div>
              <div className="flex gap-1" aria-hidden="true">
                {Array.from({ length: t.seats }, (_, i) => (
                  <span key={i} className={`h-1.5 flex-1 rounded-full ${i < t.seated ? 'bg-yes' : 'bg-surface-3'}`} />
                ))}
              </div>
              <p className="min-h-5 truncate text-xs text-subtle">{t.players.length ? t.players.join(', ') : 'Nobody here yet. Be the first to sit.'}</p>
              <span className="mt-auto text-sm font-semibold text-primary-300 group-hover:underline">
                {seat?.table === t.id ? 'Back to my seat' : t.seated >= t.seats ? 'Watch' : lobby.canSit ? 'Open table' : 'Watch'}
              </span>
            </Link>
          </li>
        ))}
      </ul>
      <PrivateTables
        lobby={lobby}
        working={working}
        createError={createError}
        joinError={joinError}
        onCreate={(stake, buyIn) => open(() => pokerCreate({ stake, minBuy: buyIn.min, maxBuy: buyIn.max }), setCreateError)}
        onJoin={(code) => open(() => pokerJoin(code), setJoinError)}
        onOpen={(t) => navigate(tablePath(t.id, t.code))}
      />
      <p className="text-xs leading-relaxed text-subtle">A new public table opens whenever every one at a stake is full. You can sit at one table at a time.</p>
    </div>
  )
}

/** Confirms in the browser that the last hand's cards were the ones sealed before the deal. */
function FairCheck({ tableId, code, hashes }) {
  const [result, setResult] = useState(null)
  const [busy, setBusy] = useState(false)
  const check = async () => {
    setBusy(true)
    try {
      const proof = await pokerProof(tableId, code)
      if (proof.error) setResult({ error: proof.error })
      else setResult({ hand: proof.hand, hash: proof.deckHash, ...(await verifyProof(proof, hashes.current.get(proof.hand))) })
    } catch (err) {
      setResult({ error: err.message })
    } finally {
      setBusy(false)
    }
  }
  return (
    <details className="card p-4 text-sm text-muted">
      <summary className="cursor-pointer font-semibold text-fg">Fair deal</summary>
      <div className="mt-3 space-y-3 leading-relaxed">
        <p>
          Before each deal the server seals all 52 cards and publishes one hash of the seals. After the hand you can open the seals of every card that was
          shown, and of your own two, and see that nothing was swapped. Folded and mucked hands stay sealed.
        </p>
        <button type="button" className="btn btn-ghost h-11" onClick={check} disabled={busy}>
          {busy ? 'Checking…' : 'Check the last hand'}
        </button>
        <div aria-live="polite">
          {result?.error && <p className="text-no">{result.error}</p>}
          {result && !result.error && (
            <p className={result.ok ? 'text-yes' : 'text-no'}>
              {result.ok
                ? `Hand #${result.hand}: the 52 seals match the published hash and all ${result.checked} revealed cards open their seals.`
                : `Hand #${result.hand} did not check out: ${result.problems.join(' ')}`}
              <span className="mt-1 block font-mono text-[11px] break-all text-subtle">{result.hash}</span>
            </p>
          )}
        </div>
      </div>
    </details>
  )
}

/** The same in one line of text, for the controls on a phone, where the felt has no room for it. */
function summaryOf(state, seconds) {
  if (state.phase === 'showdown') {
    const winners = state.seats.filter((s) => s && s.won > 0)
    const text = winners.map((s) => `${s.name} wins ${formatChips(s.won)}${s.rank ? ` with ${rankLabel(s.rank).toLowerCase()}` : ''}`).join('; ')
    return text ? `${text}.${seconds > 0 ? ` Next hand in ${seconds}s.` : ''}` : null
  }
  if (state.phase === 'waiting') {
    const ready = state.seats.filter((s) => s && !s.away && !s.left && s.stack > 0).length
    return ready >= 2 ? `Dealing in ${seconds}s.` : null
  }
  return null
}

/** The line in the middle of the felt: who won, or what the table is waiting for. */
function Banner({ state, seconds, winDelay }) {
  if (state.phase === 'showdown') {
    const winners = state.seats.map((s, i) => ({ s, i })).filter(({ s }) => s && s.won > 0)
    return (
      <div className="tb-banner flex max-w-full flex-col items-center gap-0.5 rounded-2xl bg-black/60 px-4 py-1.5 text-center backdrop-blur-sm" style={{ animationDelay: winDelay }} aria-live="polite">
        {winners.map(({ s, i }) => (
          <span key={i} className="text-xs text-white sm:text-sm">
            <span className="font-bold text-yes">{s.name}</span> wins <span className="font-bold tabular">{formatChips(s.won)}</span>
            {s.rank ? ` with ${rankLabel(s.rank).toLowerCase()}` : ''}
          </span>
        ))}
        {seconds > 0 && <span className="text-[10px] text-white/60">Next hand in {seconds}s</span>}
      </div>
    )
  }
  if (state.phase === 'waiting') {
    const ready = state.seats.filter((s) => s && !s.away && !s.left && s.stack > 0).length
    return (
      <span className="rounded-full bg-black/45 px-3 py-1 text-xs font-semibold text-white/80" aria-live="polite">
        {ready >= 2 ? `Dealing in ${seconds}s` : ready === 1 ? 'Waiting for one more player' : 'Waiting for players'}
      </span>
    )
  }
  return null
}

/** A private table opened without its code (or with a wrong one): asks for the code. */
function LockedTable({ tableId }) {
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(params.get('code') ? 'That code does not open this table.' : null)
  const submit = async (code) => {
    setBusy(true)
    setError(null)
    try {
      const res = await pokerJoin(code)
      if (res.error) setError(res.error)
      else if (res.table !== tableId) navigate(tablePath(res.table, res.code))
      else navigate(tablePath(tableId, res.code), { replace: true })
    } catch (err) {
      setError(err.message)
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className="mx-auto max-w-md space-y-4 py-6">
      <Link to={GAME_PATH.poker} className="inline-flex items-center gap-1 text-sm text-muted hover:text-fg">
        <ChevronLeftIcon /> All tables
      </Link>
      <section className="card space-y-3 p-5">
        <h2 className="text-lg font-semibold">This is a private table</h2>
        <p className="text-sm text-muted">Enter the code your friend shared to watch or sit down.</p>
        <CodeForm onSubmit={submit} busy={busy} error={error} />
      </section>
    </div>
  )
}

function Room({ tableId }) {
  const [params] = useSearchParams()
  const code = normalizeCode(params.get('code')) || null
  const navigate = useNavigate()
  const user = useAccountStore((s) => s.user)
  const cash = useChips()
  const openAuth = useUiStore((s) => s.openAuth)
  const { status, live, table, state, me, offset, actions } = useTable(tableId, isCodeShape(code ?? '') ? code : null)
  const now = useNow(state?.deadline ? 250 : 1000)
  const [working, setWorking] = useState(false)
  const [dialog, setDialog] = useState(null)
  const hashes = useRef(new Map())

  /** Runs a server call, keeping the buttons from firing twice, and shows a refusal as a toast. */
  const run = async (call, title = 'Not accepted') => {
    if (working) return false
    setWorking(true)
    try {
      await call()
      return true
    } catch (err) {
      toast({ tone: 'error', title, description: err.message })
      return false
    } finally {
      setWorking(false)
    }
  }

  // Sounds, from what changed between one state and the next.
  const heard = useRef(null)
  useEffect(() => {
    if (!state) return
    if (state.deckHash) hashes.current.set(state.hand, state.deckHash)
    const prev = heard.current
    heard.current = state
    if (!prev || prev === state) return
    const quiet = reducedMotion()
    const mySeat = me?.seat ?? null
    if (state.hand !== prev.hand && state.phase === 'preflop') {
      if (!quiet) for (let i = 0; i < 4; i++) tableSounds.card(i * 0.09)
    } else if ((state.board?.length ?? 0) > (prev.board?.length ?? 0) && !quiet) {
      for (let i = 0; i < state.board.length - prev.board.length; i++) tableSounds.card(i * (state.runout > 0 ? 0.48 : 0.11))
    }
    const actor = prev.act?.seat
    const last = actor !== undefined && actor !== null ? state.seats[actor]?.last : null
    if (last && (state.turn !== prev.turn || state.phase !== prev.phase) && state.hand === prev.hand) {
      if (last === 'fold') tableSounds.fold()
      else if (last === 'check') tableSounds.check()
      else if (last === 'allin') tableSounds.allIn()
      else if (last === 'call' || last === 'bet' || last === 'raise') tableSounds.chips()
    }
    if (state.phase === 'showdown' && prev.phase !== 'showdown' && mySeat !== null && state.seats[mySeat]?.inHand) {
      const net = state.result?.players?.find((p) => p.seat === mySeat)?.net ?? 0
      if (net > 0) tableSounds.win()
      else if (net < 0 && !state.seats[mySeat].folded) tableSounds.lose()
    }
    const mine = state.act?.seat === mySeat && mySeat !== null
    if (mine && (prev.act?.seat !== mySeat || prev.turn !== state.turn)) {
      tableSounds.turn()
      navigator.vibrate?.(60)
    }
  }, [state, me?.seat])

  // A nudge when the player's own clock is nearly out.
  const myTurn = Boolean(state && me && state.act?.seat === me.seat)
  const seconds = state ? secondsLeft(state.deadline, now, offset) : 0
  const warned = useRef(null)
  useEffect(() => {
    if (myTurn && seconds === 5 && warned.current !== state.turn) {
      warned.current = state.turn
      tableSounds.hurry()
    }
  }, [myTurn, seconds, state?.turn])

  if (status === 'closed') {
    return (
      <EmptyState icon={GridIcon} title="This table has closed" action={<Link to={GAME_PATH.poker} className="btn btn-primary">See open tables</Link>}>
        Empty tables close after a while. Any chips you had there are back in your available funds.
      </EmptyState>
    )
  }
  if (status === 'locked') return <LockedTable tableId={tableId} />
  if (!state || !table) {
    return status === 'error' ? (
      <EmptyState icon={GridIcon} title="Could not reach the table" action={<button type="button" className="btn btn-primary" onClick={() => actions.reload().catch(() => {})}>Try again</button>}>
        Check your connection. If you were seated, your seat and cards are waiting.
      </EmptyState>
    ) : (
      <div className="skeleton aspect-[4/5] rounded-[3rem] sm:aspect-video" aria-label="Loading the table" />
    )
  }

  const guest = Boolean(user?.guest)
  const mine = me ? state.seats[me.seat] : null
  const canSit = !me && !guest
  const winDelay = state.phase === 'showdown' && state.runout > 0 ? `${state.runout * 480 + 250}ms` : '0ms'
  const sit = (seat) => (guest ? openAuth('signup') : setDialog({ kind: 'sit', seat }))
  const leave = () =>
    run(async () => {
      const res = await actions.leave()
      if (!res.me) toast({ tone: 'success', title: 'You left the table', description: 'Your chips are back in your available funds.' })
    }, 'Could not leave')

  return (
    <>
     <div className="space-y-2 sm:space-y-3">
      <div className="flex items-center justify-between gap-2">
        <Link to={GAME_PATH.poker} className="inline-flex min-h-9 items-center gap-1 text-sm text-muted hover:text-fg">
          <ChevronLeftIcon /> All tables
        </Link>
        <div className="flex items-center gap-2 text-xs">
          <span className="rounded-full bg-surface-2 px-2.5 py-1 font-semibold tabular">
            {formatBlinds(table.smallBlind, table.bigBlind)}
          </span>
          {table.private && table.code && <ShareCode tableId={tableId} code={table.code} compact />}
          {state.hand > 0 && <span className="text-subtle tabular max-sm:sr-only">Hand #{state.hand}</span>}
          <span className={`flex items-center gap-1.5 ${live ? 'text-yes' : 'text-warn'}`} title={live ? 'Updates arrive live' : 'Live updates are down; the page is checking every few seconds'}>
            <span className={`size-2 rounded-full ${live ? 'bg-yes' : 'bg-warn'}`} aria-hidden="true" />
            {live ? 'Live' : 'Syncing'}
          </span>
          <SoundToggle />
        </div>
      </div>
      <TableFelt
        table={table}
        state={state}
        me={me}
        now={now}
        offset={offset}
        canSit={canSit}
        onSit={sit}
        banner={<Banner state={state} seconds={seconds} winDelay={winDelay} />}
      />
      <ActionBar
        table={table}
        state={state}
        me={me}
        guest={guest}
        working={working}
        onAct={(action, amount) => run(() => actions.act(action, amount), 'Move not accepted')}
        onSit={sit}
        onLeave={leave}
        onAway={(away) => run(() => actions.away(away))}
        onAddChips={() => setDialog({ kind: 'buy' })}
        onSignUp={() => openAuth('signup')}
        summary={summaryOf(state, seconds)}
      />
     </div>
      <FairCheck tableId={tableId} code={code} hashes={hashes} />
      <BuyInDialog
        key={dialog ? `${dialog.kind}-${dialog.seat ?? ''}` : 'closed'}
        open={dialog?.kind === 'sit'}
        onClose={() => setDialog(null)}
        title={`Sit at the ${formatBlinds(table.smallBlind, table.bigBlind)} table`}
        description="Choose how many chips to bring. You are dealt in on the next hand."
        min={table.minBuy}
        max={table.maxBuy}
        cash={cash}
        busy={working}
        onConfirm={async (amount) => {
          if (await run(() => actions.sit(amount, dialog.seat), 'Could not sit down')) setDialog(null)
        }}
      />
      <BuyInDialog
        key={dialog?.kind === 'buy' ? 'buy-open' : 'buy-closed'}
        open={dialog?.kind === 'buy'}
        onClose={() => setDialog(null)}
        title="Add chips"
        description={`You can have up to ${formatChips(table.maxBuy)} in front of you when adding.`}
        min={Math.max(1, table.minBuy - (mine?.stack ?? 0))}
        max={Math.max(0, table.maxBuy - (mine?.stack ?? 0))}
        cash={cash}
        busy={working}
        confirmLabel="Add"
        onConfirm={async (amount) => {
          if (await run(() => actions.buy(amount), 'Could not add chips')) setDialog(null)
        }}
      />
      {status === 'ready' && me?.left && state.phase !== 'showdown' && (
        <button type="button" className="btn btn-ghost w-full" onClick={() => navigate(GAME_PATH.poker)}>
          Back to all tables
        </button>
      )}
    </>
  )
}

export default function TablesPage() {
  useDocumentTitle('Games')
  const { tableId } = useParams()
  const id = /^\d{1,15}$/.test(tableId ?? '') ? Number(tableId) : null
  return (
    <GameShell
      game="poker"
      title={GAME_NAME.poker}
      subtitle="Play against other players, live. No house cut: what one player loses, another wins."
      rules={<Rules />}
      compact={id !== null}
    >
      {!BACKEND_ENABLED ? (
        <EmptyState icon={GridIcon} title="Texas Hold’em needs the shared server">
          This game is played between signed-in players, so it only runs when the site is connected to its backend. Every other game works here on its own.
        </EmptyState>
      ) : id !== null ? (
        <Room key={id} tableId={id} />
      ) : tableId ? (
        <EmptyState icon={GridIcon} title="No such table" action={<Link to={GAME_PATH.poker} className="btn btn-primary">See open tables</Link>} />
      ) : (
        <Lobby />
      )}
    </GameShell>
  )
}
