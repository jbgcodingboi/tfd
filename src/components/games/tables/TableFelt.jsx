import { useState } from 'react'
import { formatChips, initials, potSummary, rankLabel, toCard, viewPosition } from '../../../games/poker.js'
import PlayingCard from '../PlayingCard.jsx'

/** The length of a turn (private.poker_k('turn') in supabase/schema.sql), for drawing the clock. */
const TURN_MS = 25000
const RING = 2 * Math.PI * 22

const LAST = { fold: 'Fold', check: 'Check', call: 'Call', bet: 'Bet', raise: 'Raise', allin: 'All in', sb: 'SB', bb: 'BB' }
const SPOKEN = { SB: 'small blind', BB: 'big blind' }

/** The action clock around a seat's avatar. */
function Clock({ fraction }) {
  const tone = fraction > 0.5 ? '#2fbf71' : fraction > 0.2 ? '#e8b13a' : '#f5703c'
  return (
    <svg viewBox="0 0 48 48" className="tb-ring" aria-hidden="true">
      <circle cx="24" cy="24" r="22" stroke="rgb(0 0 0 / 0.45)" />
      <circle cx="24" cy="24" r="22" stroke={tone} strokeDasharray={RING} strokeDashoffset={RING * (1 - fraction)} />
    </svg>
  )
}

function Seat({ seat, index, pos, isMe, myCards, live, showdown, toAct, fraction, seconds, button, winDelay, canSit, onSit }) {
  if (!seat) {
    return (
      <div className={`tb-seat tb-pos-${pos} flex flex-col items-center`}>
        {canSit ? (
          <button
            type="button"
            onClick={() => onSit(index)}
            className="grid size-12 place-items-center rounded-full border-2 border-dashed border-white/40 bg-black/25 text-[11px] font-bold text-white/90 transition hover:border-warn hover:bg-black/45 hover:text-warn sm:size-14"
            aria-label={`Sit in seat ${index + 1}`}
          >
            Sit
          </button>
        ) : (
          <span className="grid size-10 place-items-center rounded-full border border-dashed border-white/15 text-[10px] text-white/30" aria-label={`Seat ${index + 1}, empty`}>
            {index + 1}
          </span>
        )}
      </div>
    )
  }
  const inHand = seat.inHand && !seat.folded
  const shown = showdown && Array.isArray(seat.cards) ? seat.cards : null
  const cards = shown ?? (isMe && seat.inHand ? myCards : null)
  const won = showdown && seat.won > 0
  const dim = seat.left || (seat.away && !seat.inHand) || (seat.inHand && seat.folded) || (live && !seat.inHand)
  const tag = seat.left ? 'Left' : seat.away && !inHand ? 'Sitting out' : seat.allIn && inHand ? 'All in' : live && seat.last ? LAST[seat.last] : null
  // The viewer's own cards are drawn larger than anyone else's.
  const big = isMe
  return (
    <div
      className={`tb-seat tb-pos-${pos} flex items-center ${big ? 'gap-1.5' : 'flex-col'} ${toAct ? 'tb-turn' : ''} ${won ? 'tb-win' : ''} ${dim ? 'tb-out' : ''}`}
      style={won ? { animationDelay: winDelay } : undefined}
      aria-label={`${seat.name}${isMe ? ' (you)' : ''}, ${formatChips(seat.stack)}${tag ? `, ${SPOKEN[tag] ?? tag.toLowerCase()}` : ''}${toAct ? `, to act, ${seconds} seconds left` : ''}`}
    >
      <div className={`flex shrink-0 items-end justify-center ${big ? 'h-20 min-w-14' : 'h-[3.25rem]'}`}>
        {cards
          ? cards.map((c, i) => (
              <div key={c} className={i ? (big ? '-ml-4' : '-ml-3') : ''}>
                <PlayingCard card={toCard(c)} mini={!big} small={big} delay={i * 90} deal="tb-deal" />
              </div>
            ))
          : inHand &&
            (live || showdown) &&
            [0, 1].map((i) => (
              <div key={i} className={i ? '-ml-4' : ''}>
                <PlayingCard card={null} hidden mini delay={i * 90} deal="tb-deal" />
              </div>
            ))}
      </div>
      {/* The viewer's name plate sits beside their cards; everyone else's overlaps the bottom of theirs, to keep a seat short enough for a phone. */}
      <div className={`flex flex-col items-center ${big ? '' : '-mt-5'}`}>
      <div className="relative z-10 flex items-center gap-1.5 rounded-full bg-black/75 py-0.5 pr-2.5 pl-0.5 shadow-lg backdrop-blur-sm">
        <span className="tb-avatar size-7 text-[10px] font-bold text-white sm:size-9 sm:text-[11px]" aria-hidden="true">
          {toAct ? <span className="tabular text-xs">{seconds}</span> : initials(seat.name)}
          {toAct && <Clock fraction={fraction} />}
        </span>
        <span className="min-w-0 leading-tight">
          <span className={`block max-w-[3.5rem] truncate text-[10px] font-semibold sm:max-w-[5rem] sm:text-[11px] ${isMe ? 'text-warn' : 'text-white'}`}>{isMe ? 'You' : seat.name}</span>
          <span className="block text-[11px] font-bold text-white/90 tabular">{formatChips(seat.stack)}</span>
        </span>
        {button && (
          <span className="absolute -top-2 -left-1.5 grid size-[1.125rem] place-items-center rounded-full bg-white text-[10px] font-black text-black shadow" title="Dealer button">
            D
          </span>
        )}
      </div>
      <div className="relative z-10 -mt-0.5 flex h-4 items-center gap-1 text-[10px] font-semibold whitespace-nowrap">
        {won ? (
          <span className="tb-won rounded-full bg-yes px-2 py-px font-bold text-black tabular" style={{ animationDelay: winDelay }}>
            +{formatChips(seat.won)}
          </span>
        ) : shown && seat.rank ? (
          <span className="rounded-full bg-black/70 px-1.5 py-px text-white/90">{rankLabel(seat.rank).split(',')[0]}</span>
        ) : tag ? (
          <span className={`rounded-full px-1.5 py-px ${seat.allIn && inHand ? 'bg-warn text-black' : 'bg-black/60 text-white/80'}`}>{tag}</span>
        ) : null}
      </div>
      </div>
    </div>
  )
}

/** The felt: six seats around the board and the pot. Everything shown comes from the server's public state, plus this player's own two cards. */
export default function TableFelt({ table, state, me, now, offset, canSit, onSit, banner }) {
  const seats = state.seats ?? []
  const mySeat = me?.seat ?? null
  const live = !['waiting', 'showdown'].includes(state.phase)
  const showdown = state.phase === 'showdown'
  const pot = potSummary(state)
  const remaining = state.deadline ? state.deadline - (now + offset) : 0
  const fraction = Math.min(1, Math.max(0, remaining / TURN_MS))
  const seconds = Math.max(0, Math.ceil(remaining / 1000))
  const board = state.board ?? []
  // How many board cards were already out before the latest ones, so only the new ones are staggered.
  const [seen, setSeen] = useState({ hand: state.hand, cards: board.length, base: board.length })
  if (seen.hand !== state.hand || seen.cards !== board.length) {
    setSeen({ hand: state.hand, cards: board.length, base: seen.hand === state.hand ? Math.min(seen.cards, board.length) : 0 })
  }
  const base = seen.hand === state.hand && seen.cards === board.length ? seen.base : 0
  const step = state.runout > 0 ? 480 : 110
  // After an all-in the board is dealt out first; results wait for the last card.
  const winDelay = showdown && state.runout > 0 ? `${Math.max(0, board.length - base) * step + 250}ms` : '0ms'
  const showdownPot = showdown ? (state.result?.pots ?? []).reduce((a, p) => a + p.amount, 0) : 0

  return (
    <section className="felt tb-felt" aria-label={`Table, $${table.smallBlind} and $${table.bigBlind} blinds`}>
      <div className="tb-line" aria-hidden="true" />
      <div className="tb-middle flex flex-col items-center gap-1 sm:gap-2">
        <div className="flex h-5 flex-wrap items-center justify-center gap-1.5 text-xs font-bold text-white tabular" aria-live="polite">
          {live && pot.total > 0 && (
            <>
              <span className="rounded-full bg-black/55 px-3 py-0.5">Pot {formatChips(pot.total)}</span>
              {pot.pots.length > 1 &&
                pot.pots.map((p, i) => (
                  <span key={i} className="rounded-full bg-black/35 px-2 py-0.5 text-[10px] font-semibold text-white/80">
                    {i === 0 ? 'Main' : `Side ${i}`} {formatChips(p)}
                  </span>
                ))}
            </>
          )}
          {showdown && showdownPot > 0 && <span className="rounded-full bg-black/55 px-3 py-0.5">Pot {formatChips(showdownPot)}</span>}
        </div>
        <div className="flex h-[3.25rem] items-center justify-center gap-1 sm:h-20 sm:gap-1.5" aria-label={board.length ? `Board: ${board.join(' ')}` : 'No cards on the board yet'}>
          {board.map((c, i) => (
            <PlayingCard key={`${state.hand}-${i}`} card={toCard(c)} size="board" delay={Math.max(0, i - base) * step} deal="tb-board" />
          ))}
        </div>
        {/* On a phone the same line is shown with the controls, where there is room for it. */}
        <div className="hidden min-h-6 sm:block">{banner}</div>
      </div>
      {seats.map((seat, i) => {
        const pos = viewPosition(i, mySeat, seats.length)
        return (
          seat &&
          live &&
          seat.bet > 0 && (
            <span key={`bet-${i}-${seat.bet}`} className={`tb-bet tb-bet-${pos} tb-chip flex items-center gap-1 rounded-full bg-black/60 py-0.5 pr-2 pl-1 text-[11px] font-bold text-white tabular`}>
              <span className="size-3 rounded-full border-2 border-dashed border-white/80 bg-primary-400" aria-hidden="true" />
              {formatChips(seat.bet)}
            </span>
          )
        )
      })}
      {seats.map((seat, i) => (
        <Seat
          key={i}
          seat={seat}
          index={i}
          pos={viewPosition(i, mySeat, seats.length)}
          isMe={i === mySeat}
          myCards={i === mySeat ? me?.cards : null}
          live={live}
          showdown={showdown}
          toAct={live && state.act?.seat === i}
          fraction={fraction}
          seconds={seconds}
          button={state.button === i && state.phase !== 'waiting'}
          winDelay={winDelay}
          canSit={canSit}
          onSit={onSit}
        />
      ))}
    </section>
  )
}
