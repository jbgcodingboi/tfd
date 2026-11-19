import { useId, useState } from 'react'
import { buyInBounds, buyInProblem, formatBlinds, formatChips, formatCode, isCodeShape, linkRange, niceStep, normalizeCode, privateStandard, tableLink } from '../../../games/poker.js'
import { copyText } from './copyText.js'

/** A box to type a join code into. `onSubmit` gets the normalized code; the caller shows what the server answers. */
export function CodeForm({ onSubmit, busy, error, label = 'Join code', button = 'Join' }) {
  const id = useId()
  const [text, setText] = useState('')
  const code = normalizeCode(text)
  return (
    <form
      className="space-y-1.5"
      onSubmit={(e) => {
        e.preventDefault()
        if (isCodeShape(code)) onSubmit(code)
      }}
    >
      <label htmlFor={id} className="text-xs font-medium text-muted">
        {label}
      </label>
      <div className="flex gap-2">
        <input
          id={id}
          className="input flex-1 font-mono text-lg tracking-[0.25em] uppercase"
          value={text}
          onChange={(e) => setText(e.target.value.slice(0, 12))}
          placeholder="ABC-DEF"
          autoComplete="off"
          autoCapitalize="characters"
          spellCheck={false}
          inputMode="text"
          maxLength={12}
          aria-invalid={Boolean(error)}
          aria-describedby={error ? `${id}-error` : undefined}
        />
        <button type="submit" className="btn btn-primary h-11 px-5" disabled={busy || !isCodeShape(code)}>
          {busy ? 'Looking…' : button}
        </button>
      </div>
      {error && (
        <p id={`${id}-error`} className="text-sm text-no" role="alert">
          {error}
        </p>
      )}
    </form>
  )
}

/** The join code of a private table, with ways to pass it on. */
export function ShareCode({ tableId, code, compact = false }) {
  return (
    <span className="inline-flex flex-wrap items-center gap-1.5">
      <span className="rounded-md bg-surface-2 px-2 py-0.5 font-mono text-sm font-bold tracking-[0.2em] text-warn" aria-label={`Join code ${code.split('').join(' ')}`}>
        {formatCode(code)}
      </span>
      <button type="button" className="btn btn-ghost h-8 px-2.5 text-xs" onClick={() => copyText(formatCode(code), 'Code')}>
        Copy code
      </button>
      {!compact && (
        <button type="button" className="btn btn-ghost h-8 px-2.5 text-xs" onClick={() => copyText(tableLink(window.location.origin + window.location.pathname.replace(/\/$/, ''), tableId, code), 'Link')}>
          Copy link
        </button>
      )}
    </span>
  )
}

/** One end of the buy-in range: a typed amount and a slider that stay in step. */
function AmountField({ label, value, onChange, lo, hi }) {
  const id = useId()
  const n = Number(value)
  const step = niceStep(lo, hi)
  return (
    <div>
      <div className="flex items-center justify-between gap-3">
        <label htmlFor={id} className="text-xs font-medium text-muted">
          {label}
        </label>
        <span className="relative">
          <span className="pointer-events-none absolute top-1/2 left-2.5 -translate-y-1/2 text-sm text-muted">$</span>
          <input
            id={id}
            type="number"
            inputMode="numeric"
            min={lo}
            max={hi}
            step={1}
            className="input h-9 w-32 py-1 pl-6 text-right tabular"
            value={value}
            onChange={(e) => onChange(e.target.value)}
          />
        </span>
      </div>
      <input
        type="range"
        className="tb-range"
        min={lo}
        max={hi}
        step={step}
        value={Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : lo}
        onChange={(e) => onChange(e.target.value)}
        aria-label={`${label} slider`}
        aria-valuetext={formatChips(n)}
      />
    </div>
  )
}

/**
 * Play with friends: open a private table at a stake (it gets a code to share),
 * or type a code to find one. The lobby passes the stakes and the private
 * tables the player already opened.
 */
export default function PrivateTables({ lobby, working, createError, joinError, onCreate, onJoin, onOpen }) {
  const [stake, setStake] = useState(null)
  // The buy-in being typed or dragged, for the stake it was set at (switching stake goes back to that stake's starting range).
  const [edit, setEdit] = useState(null)
  // Auto: the largest buy-in follows the smallest at twice its size, and the other way round. Custom: each end is set on its own.
  const [linked, setLinked] = useState(true)
  const stakes = lobby.stakes ?? []
  const chosen = stakes.find((s) => s.stake === stake) ?? stakes[0]
  const start = chosen ? privateStandard(chosen) : { min: 0, max: 0 }
  const typed = edit && edit.stake === chosen?.stake ? edit : null
  const minText = typed?.min ?? String(start.min)
  const maxText = typed?.max ?? String(start.max)
  const range = { min: Number(minText), max: Number(maxText) }
  const bounds = chosen ? buyInBounds(chosen.bigBlind) : { min: 0, max: 0 }
  const problem = chosen && (minText === '' || maxText === '') ? 'Enter both buy-ins.' : chosen ? buyInProblem(range, chosen.bigBlind) : null
  const standard = minText === String(start.min) && maxText === String(start.max)
  const setBuyIn = (patch) => setEdit({ stake: chosen.stake, min: minText, max: maxText, ...patch })
  const changeEnd = (side, v) => setBuyIn(linked ? linkRange(side, v, bounds) : { [side]: v })
  const reset = () => {
    setEdit(null)
    setLinked(true)
  }
  // In Auto each slider can only go as far as keeps its partner (twice or half of it) inside the limits.
  const minSlider = linked
    ? { lo: bounds.min, hi: Math.max(bounds.min, Math.floor(bounds.max / 2)) }
    : { lo: bounds.min, hi: Math.max(bounds.min, Math.min(bounds.max, Number(maxText) || bounds.max)) }
  const maxSlider = linked
    ? { lo: Math.min(bounds.max, 2 * bounds.min), hi: bounds.max }
    : { lo: Math.min(bounds.max, Math.max(bounds.min, Number(minText) || bounds.min)), hi: bounds.max }
  return (
    <section className="card space-y-4 p-4" aria-labelledby="friends-heading">
      <div>
        <h2 id="friends-heading" className="text-lg font-semibold">
          Play with friends
        </h2>
        <p className="mt-0.5 text-sm text-muted">Open a private table and share its code. Only people with the code can see it or sit down.</p>
      </div>
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="space-y-2">
          <p className="text-xs font-medium text-muted" id="stake-label">
            Create a private table
          </p>
          {lobby.canSit ? (
            <>
              <div className="grid grid-cols-2 gap-1.5" role="radiogroup" aria-labelledby="stake-label">
                {stakes.map((s) => (
                  <button
                    key={s.stake}
                    type="button"
                    role="radio"
                    aria-checked={chosen?.stake === s.stake}
                    className={`btn h-11 flex-col gap-0 leading-tight tabular ${chosen?.stake === s.stake ? 'btn-primary' : 'btn-ghost'}`}
                    onClick={() => setStake(s.stake)}
                  >
                    <span>
                      {formatBlinds(s.smallBlind, s.bigBlind)}
                    </span>
                  </button>
                ))}
              </div>
              {chosen && (
                <fieldset className="space-y-1 rounded-xl border border-line p-3">
                  <legend className="px-1 text-xs font-medium text-muted">Buy-in range</legend>
                  <div className="flex flex-wrap items-center gap-2">
                    <div className="inline-flex rounded-lg border border-line p-0.5" role="group" aria-label="How the two buy-ins move">
                      <button
                        type="button"
                        className={`btn h-8 px-3 text-xs ${linked ? 'btn-primary' : 'btn-ghost border-transparent'}`}
                        aria-pressed={linked}
                        onClick={() => {
                          setLinked(true)
                          if (typed) setBuyIn(linkRange('min', minText, bounds))
                        }}
                      >
                        Auto 1:2
                      </button>
                      <button
                        type="button"
                        className={`btn h-8 px-3 text-xs ${!linked ? 'btn-primary' : 'btn-ghost border-transparent'}`}
                        aria-pressed={!linked}
                        onClick={() => setLinked(false)}
                      >
                        Custom…
                      </button>
                    </div>
                    {(!standard || !linked) && (
                      <button type="button" className="btn btn-ghost h-8 px-3 text-xs" onClick={reset}>
                        Reset to standard
                      </button>
                    )}
                  </div>
                  <AmountField label="Smallest buy-in" value={minText} onChange={(v) => changeEnd('min', v)} lo={minSlider.lo} hi={minSlider.hi} />
                  <AmountField label="Largest buy-in" value={maxText} onChange={(v) => changeEnd('max', v)} lo={maxSlider.lo} hi={maxSlider.hi} />
                  <p className="text-xs text-subtle">
                    {linked
                      ? standard
                        ? 'Standard: the largest is twice the smallest, and moving one moves the other.'
                        : 'Auto: the largest is always twice the smallest. Choose Custom… to set each yourself.'
                      : 'Custom: set the smallest and the largest yourself.'}
                  </p>
                  {problem && (
                    <p className="text-sm text-no" role="alert">
                      {problem}
                    </p>
                  )}
                </fieldset>
              )}
              <button
                type="button"
                className="btn btn-primary h-11 w-full"
                disabled={working || !chosen || Boolean(problem)}
                onClick={() => onCreate(chosen.stake, range)}
              >
                {working ? 'Opening…' : 'Create table'}
              </button>
              {createError && (
                <p className="text-sm text-no" role="alert">
                  {createError}
                </p>
              )}
            </>
          ) : (
            <p className="text-sm text-muted">Sign up to open a private table. Guests can still join one with a code and watch.</p>
          )}
        </div>
        <CodeForm onSubmit={onJoin} busy={working} error={joinError} label="Have a code? Join a friend’s table" />
      </div>
      {lobby.mine?.length > 0 && (
        <div>
          <h3 className="text-xs font-medium text-muted">Your private tables</h3>
          <ul className="mt-1.5 divide-y divide-line text-sm" aria-label="Your private tables">
            {lobby.mine.map((t) => (
              <li key={t.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                <span className="tabular">
                  {formatBlinds(t.smallBlind, t.bigBlind)} · {t.seated}/{t.seats} seated
                  {t.minBuy ? <span className="block text-xs text-subtle">Buy-in {formatChips(t.minBuy)} to {formatChips(t.maxBuy)}</span> : null}
                </span>
                <span className="flex flex-wrap items-center gap-2">
                  <ShareCode tableId={t.id} code={t.code} compact />
                  <button type="button" className="btn btn-ghost h-8 px-3 text-xs" onClick={() => onOpen(t)}>
                    Open
                  </button>
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </section>
  )
}
