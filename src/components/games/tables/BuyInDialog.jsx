import { useId, useState } from 'react'
import { formatChips } from '../../../games/poker.js'
import Modal from '../../ui/Modal.jsx'

/**
 * Picks how many chips to bring to the table (or to add to a stack), between
 * what the table allows and what the player's cash covers. The server checks
 * the amount again.
 */
export default function BuyInDialog({ open, onClose, title, description, min, max, cash, busy, onConfirm, confirmLabel = 'Sit down' }) {
  const id = useId()
  const top = Math.floor(Math.min(max, cash))
  const possible = top >= min
  const [picked, setPicked] = useState(null)
  const amount = Math.min(top, Math.max(min, picked ?? Math.min(top, Math.round((min + max) / 2))))
  return (
    <Modal open={open} onClose={onClose} title={title} description={description} variant="sheet">
      {possible ? (
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault()
            onConfirm(amount)
          }}
        >
          <div>
            <label htmlFor={id} className="flex items-baseline justify-between text-sm">
              <span className="text-muted">Chips to bring</span>
              <span className="text-2xl font-bold tabular">{formatChips(amount)}</span>
            </label>
            <input
              id={id}
              type="range"
              className="tb-range mt-1"
              min={min}
              max={top}
              step={1}
              value={amount}
              onChange={(e) => setPicked(Number(e.target.value))}
              aria-valuetext={formatChips(amount)}
            />
            <div className="flex justify-between text-xs text-subtle tabular">
              <span>{formatChips(min)}</span>
              <span>{formatChips(top)}</span>
            </div>
          </div>
          <div className="grid grid-cols-3 gap-2">
            {[
              ['Least', min],
              ['Half', Math.min(top, Math.max(min, Math.round(max / 2)))],
              ['Most', top],
            ].map(([label, v]) => (
              <button key={label} type="button" className={`btn h-11 ${amount === v ? 'btn-primary' : 'btn-ghost'}`} onClick={() => setPicked(v)}>
                {label}
              </button>
            ))}
          </div>
          <p className="text-xs text-subtle">
            These chips leave your available funds ({formatChips(cash)}) while you are seated and come back when you leave. Play money only.
          </p>
          <button type="submit" className="btn btn-primary h-12 w-full text-base" disabled={busy}>
            {busy ? 'One moment…' : `${confirmLabel} with ${formatChips(amount)}`}
          </button>
        </form>
      ) : (
        <p className="text-sm text-muted">
          This needs at least {formatChips(min)} and you have {formatChips(cash)} available. Try a table with smaller blinds.
        </p>
      )}
    </Modal>
  )
}
