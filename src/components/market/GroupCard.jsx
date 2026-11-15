import { memo } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { CATEGORIES } from '../../config.js'
import { flashClass, usePriceFlash } from '../../hooks/usePriceFlash.js'
import { useResolution } from '../../store/resolutionStore.js'
import { formatCompactCurrency, formatDate, formatProbability } from '../../utils/format.js'
import ClosesIn from './ClosesIn.jsx'
import MarketAvatar from './MarketAvatar.jsx'

const categoryLabel = Object.fromEntries(CATEGORIES.map((c) => [c.id, c.label]))
const SHOWN = 3

/** One outcome of the event: its name, chance, and Yes / No buttons that open the event on it. */
function OutcomeLine({ market, onPick }) {
  const flash = usePriceFlash(market.yesPrice)
  const resolution = useResolution(market.id)
  const label = market.group?.label ?? market.title
  return (
    <li className="flex items-center gap-2 text-sm">
      <span className="min-w-0 flex-1 truncate">{label}</span>
      <span className={`w-11 shrink-0 rounded-md text-right font-semibold tabular ${flashClass(flash)}`}>{formatProbability(market.yesPrice)}</span>
      {resolution ? (
        <span className="w-[6.5rem] shrink-0 text-right text-xs font-semibold text-muted uppercase">{resolution.outcome === 'yes' ? 'Won' : 'Settled'}</span>
      ) : (
        <span className="relative z-10 grid w-[6.5rem] shrink-0 grid-cols-2 gap-1">
          <button
            type="button"
            onClick={() => onPick(market.id, 'yes')}
            aria-label={`Buy Yes on ${label}, ${formatProbability(market.yesPrice)} chance`}
            className="rounded-md bg-yes-soft px-2 py-1 text-xs font-semibold text-yes transition hover:bg-yes hover:text-white"
          >
            Yes
          </button>
          <button
            type="button"
            onClick={() => onPick(market.id, 'no')}
            aria-label={`Buy No on ${label}, ${formatProbability(market.noPrice)} chance`}
            className="rounded-md bg-no-soft px-2 py-1 text-xs font-semibold text-no transition hover:bg-no hover:text-white"
          >
            No
          </button>
        </span>
      )}
    </li>
  )
}

/** A winner event in the listing: its leading outcomes, and a link to all of them. */
function GroupCard({ group }) {
  const navigate = useNavigate()
  const lead = [...group.markets].sort((a, b) => b.yesPrice - a.yesPrice).slice(0, SHOWN)
  const first = group.markets[0]
  const href = `/event/${encodeURIComponent(group.id)}`
  const pick = (id, side) => navigate(`${href}?m=${encodeURIComponent(id)}&side=${side}`)
  const volume = first.groupVolume ?? group.markets.reduce((sum, m) => sum + m.volume, 0)
  const more = group.size - lead.length

  return (
    <article className="card group relative flex flex-col gap-3 p-4 transition hover:border-line-strong hover:bg-surface-2">
      <div className="flex items-start gap-3">
        <MarketAvatar market={{ ...first, image: first.group?.image ?? first.image, title: group.title }} />
        <h3 className="min-w-0 flex-1 text-[15px] leading-snug font-semibold">
          <Link
            to={href}
            className="line-clamp-2 rounded after:absolute after:inset-0 after:rounded-[0.875rem] after:content-[''] focus-visible:outline-none focus-visible:after:outline-2 focus-visible:after:outline-primary-300"
          >
            {group.title}
          </Link>
        </h3>
      </div>

      <ul className="mt-auto space-y-1.5" aria-label="Leading outcomes">
        {lead.map((m) => (
          <OutcomeLine key={m.id} market={m} onPick={pick} />
        ))}
      </ul>

      <div className="flex items-center justify-between gap-2 text-xs text-muted">
        <span className="tabular">{formatCompactCurrency(volume)} Vol.</span>
        <ClosesIn endDate={first.endDate} />
        <span className="truncate">
          {more > 0 ? <span className="font-medium text-primary-300">All {group.size} outcomes</span> : `${categoryLabel[first.category]} · Ends ${formatDate(first.endDate)}`}
        </span>
      </div>
    </article>
  )
}

export default memo(GroupCard)
