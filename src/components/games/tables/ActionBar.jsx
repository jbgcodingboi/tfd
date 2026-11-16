import { useState } from 'react'
import { betPresets, formatChips, handLabel } from '../../../games/poker.js'
import { kbdClass, useHotkeys } from '../roulette/useHotkeys.js'

/** The moves for the player whose turn it is: fold, check or call, and a bet or raise sized with the slider. */
function TurnControls({ table, state, working, onAct }) {
  const act = state.act
  const presets = betPresets(state)
  const [picked, setPicked] = useState(null)
  const to = Math.min(act.maxRaise, Math.max(act.minRaise, picked ?? act.minRaise))
  const verb = state.bet > 0 ? 'raise' : 'bet'
  const allIn = to >= act.maxRaise
  const step = table.bigBlind
  const callLabel = act.toCall > 0 ? `Call ${formatChips(act.toCall)}` : 'Check'
  const raiseLabel = allIn ? `All in ${formatChips(to)}` : `${verb === 'bet' ? 'Bet' : 'Raise to'} ${formatChips(to)}`
  const fold = () => !working && onAct('fold')
  const call = () => !working && onAct(act.toCall > 0 ? 'call' : 'check')
  const raise = () => !working && act.canRaise && onAct(verb, to)
  useHotkeys({ f: fold, c: call, r: () => (act.canRaise ? raise() : false) })
  return (
    <div className="space-y-2">
      {act.canRaise && (
        <div>
          <div className="flex items-center gap-2">
            <button type="button" className="btn btn-ghost size-11 shrink-0 p-0 text-lg" onClick={() => setPicked(Math.max(act.minRaise, to - step))} disabled={working || to <= act.minRaise} aria-label={`Lower by ${formatChips(step)}`}>
              −
            </button>
            <input
              type="range"
              className="tb-range"
              min={act.minRaise}
              max={act.maxRaise}
              step={1}
              value={to}
              disabled={working || act.minRaise >= act.maxRaise}
              onChange={(e) => setPicked(Number(e.target.value))}
              aria-label={verb === 'bet' ? 'Bet size' : 'Raise to'}
              aria-valuetext={formatChips(to)}
            />
            <button type="button" className="btn btn-ghost size-11 shrink-0 p-0 text-lg" onClick={() => setPicked(Math.min(act.maxRaise, to + step))} disabled={working || allIn} aria-label={`Raise by ${formatChips(step)}`}>
              +
            </button>
          </div>
          <div className={`flex gap-1.5 overflow-x-auto scrollbar-thin ${presets.length > 1 ? '' : 'invisible'}`} role="group" aria-label="Bet sizes">
            {presets.map((p) => (
              <button
                key={p.label}
                type="button"
                className={`btn h-9 min-w-[4.25rem] flex-1 px-2 text-xs whitespace-nowrap ${to === p.to ? 'btn-primary' : 'btn-ghost'}`}
                onClick={() => setPicked(p.to)}
                disabled={working}
                aria-pressed={to === p.to}
              >
                {p.label}
              </button>
            ))}
          </div>
        </div>
      )}
      <div className={`grid gap-2 ${act.canRaise ? 'grid-cols-3' : 'grid-cols-2'}`}>
        <button type="button" className="btn btn-ghost h-[3.25rem] text-base" onClick={fold} disabled={working}>
          Fold
          <kbd className={kbdClass}>F</kbd>
        </button>
        <button type="button" className="btn h-[3.25rem] bg-yes-strong px-1 text-[15px] whitespace-nowrap text-black hover:bg-yes disabled:opacity-50 sm:text-base" onClick={call} disabled={working}>
          {callLabel}
          <kbd className={kbdClass}>C</kbd>
        </button>
        {act.canRaise && (
          <button type="button" className="btn btn-primary h-[3.25rem] px-1 text-[15px] leading-tight whitespace-nowrap sm:text-base" onClick={raise} disabled={working}>
            {raiseLabel}
            <kbd className={kbdClass}>R</kbd>
          </button>
        )}
      </div>
    </div>
  )
}

/**
 * Everything a player does at the table, kept at the bottom of the screen
 * within reach of a thumb: the moves on their turn, and between turns sitting
 * out, adding chips and leaving.
 */
export default function ActionBar({ table, state, me, guest, working, summary, onAct, onSit, onLeave, onAway, onAddChips, onSignUp }) {
  const live = !['waiting', 'showdown'].includes(state.phase)
  if (!me) {
    const free = state.seats.findIndex((s) => !s)
    return (
      <section className="card tb-controls p-3 sm:p-4" aria-label="Controls">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-sm text-muted" aria-live="polite">
            {summary && <span className="block font-semibold text-fg sm:hidden">{summary}</span>}
            {guest ? 'You are watching. Seats are for signed-up players: every hand moves chips between real accounts.' : free < 0 ? 'You are watching. This table is full.' : 'You are watching. Take a seat to be dealt in on the next hand.'}
          </p>
          {guest ? (
            <button type="button" className="btn btn-primary h-12 flex-1 sm:flex-none" onClick={onSignUp}>
              Sign up to play
            </button>
          ) : (
            free >= 0 && (
              <button type="button" className="btn btn-primary h-12 flex-1 px-6 sm:flex-none" onClick={() => onSit(free)} disabled={working}>
                Take a seat
              </button>
            )
          )}
        </div>
      </section>
    )
  }
  const mine = state.seats[me.seat]
  const myTurn = live && state.act?.seat === me.seat && !me.left
  const inHand = Boolean(mine?.inHand && !mine.folded)
  const label = inHand || state.phase === 'showdown' ? handLabel(me.cards, state.board) : ''
  const actor = live && state.act ? state.seats[state.act.seat] : null
  const busted = mine && mine.stack === 0 && !inHand
  let note = 'Waiting for the next hand.'
  if (me.left) note = 'You have left. Your seat is freed when this hand ends.'
  else if (myTurn) note = 'Your move.'
  else if (busted) note = 'You are out of chips. Add more to keep playing, or leave the table.'
  else if (mine?.away) note = live && inHand ? 'You will sit out after this hand.' : 'You are sitting out. Your seat is held for three minutes.'
  else if (live && inHand && actor) note = `Waiting for ${actor.name}.`
  else if (live && mine?.inHand) note = 'You folded this hand.'
  else if (live) note = 'You are dealt in from the next hand.'
  else if (state.phase === 'waiting') note = 'Waiting for another player to sit down.'
  // What just happened at the table comes first; on larger screens it is on the felt instead.
  const headline = !myTurn && !me.left && summary
  return (
    <section className="card tb-controls space-y-2 p-2.5 sm:space-y-2.5 sm:p-4" aria-label="Controls">
      <div className="flex min-h-5 items-center justify-between gap-3 text-sm leading-tight">
        <span className={myTurn ? 'font-semibold text-warn' : 'text-muted'} aria-live="polite">
          {headline ? (
            <>
              <span className="font-semibold text-fg sm:hidden">{headline}</span>
              <span className="max-sm:hidden">{note}</span>
            </>
          ) : (
            note
          )}
        </span>
        {label && <span className="shrink-0 rounded-full bg-surface-2 px-2.5 py-0.5 text-xs font-semibold">{label}</span>}
      </div>
      {myTurn && <TurnControls key={state.turn} table={table} state={state} working={working} onAct={onAct} />}
      {!myTurn && !me.left && (
        <div className="flex flex-wrap gap-2">
          {(busted || !inHand || !live) && (
            <button type="button" className={`btn h-11 flex-1 ${busted ? 'btn-primary' : 'btn-ghost'}`} onClick={onAddChips} disabled={working || (mine?.stack ?? 0) >= table.maxBuy}>
              Add chips
            </button>
          )}
          {!busted && (
            <button
              type="button"
              className="btn btn-ghost h-11 flex-1"
              onClick={() => onAway(!mine?.away)}
              disabled={working}
              aria-label={mine?.away ? 'I’m back: deal me in again' : 'Sit out from the next hand'}
            >
              {mine?.away ? 'I’m back' : 'Sit out'}
            </button>
          )}
          <button type="button" className="btn btn-ghost h-11 flex-1" onClick={onLeave} disabled={working} aria-label="Leave table">
            Leave
          </button>
        </div>
      )}
    </section>
  )
}
