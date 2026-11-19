import { useId, useState } from 'react'
import { formatChips, formatCode, isCodeShape, normalizeCode, tableLink } from '../../../games/poker.js'
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

/**
 * Play with friends: open a private table at a stake (it gets a code to share),
 * or type a code to find one. The lobby passes the stakes and the private
 * tables the player already opened.
 */
export default function PrivateTables({ lobby, working, createError, joinError, onCreate, onJoin, onOpen }) {
  const [stake, setStake] = useState(null)
  const stakes = lobby.stakes ?? []
  const chosen = stakes.find((s) => s.stake === stake) ?? stakes[1] ?? stakes[0]
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
                      ${s.smallBlind}/${s.bigBlind}
                    </span>
                  </button>
                ))}
              </div>
              {chosen && (
                <p className="text-xs text-subtle tabular">
                  Buy-in {formatChips(chosen.minBuy)} to {formatChips(chosen.maxBuy)}
                </p>
              )}
              <button type="button" className="btn btn-primary h-11 w-full" disabled={working || !chosen} onClick={() => onCreate(chosen.stake)}>
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
                  ${t.smallBlind}/${t.bigBlind} · {t.seated}/{t.seats} seated
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
