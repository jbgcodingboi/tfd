import { useMemo, useState } from 'react'
import { Link, useParams, useSearchParams } from 'react-router-dom'
import ClosesIn from '../components/market/ClosesIn.jsx'
import MarketAvatar from '../components/market/MarketAvatar.jsx'
import MobileTradeBar from '../components/market/MobileTradeBar.jsx'
import OutcomeBadge from '../components/market/OutcomeBadge.jsx'
import PositionSummary from '../components/market/PositionSummary.jsx'
import PriceChart from '../components/market/PriceChart.jsx'
import TradePanel from '../components/market/TradePanel.jsx'
import EmptyState from '../components/ui/EmptyState.jsx'
import { ChevronLeftIcon, SearchIcon } from '../components/ui/Icons.jsx'
import { PageSkeleton } from '../components/ui/Skeleton.jsx'
import { CATEGORIES } from '../config.js'
import { useDocumentTitle } from '../hooks/useDocumentTitle.js'
import { flashClass, usePriceFlash } from '../hooks/usePriceFlash.js'
import { useMarketStore } from '../store/marketStore.js'
import { useResolution } from '../store/resolutionStore.js'
import { formatCents, formatCompactCurrency, formatDate, formatProbability } from '../utils/format.js'
import { groupMembers } from '../utils/groups.js'

const categoryLabel = Object.fromEntries(CATEGORIES.map((c) => [c.id, c.label]))

/** One outcome: its name and chance, and Yes / No buttons that pick it for the trade panel. */
function OutcomeRow({ market, active, side, onPick }) {
  const resolution = useResolution(market.id)
  const flash = usePriceFlash(market.yesPrice)
  const label = market.group?.label ?? market.title
  const pressed = (s) => active && side === s
  return (
    <li className={`flex items-center gap-3 px-3 py-2.5 transition ${active ? 'bg-surface-2' : ''}`}>
      <button type="button" onClick={() => onPick(market.id, side)} className="flex min-w-0 flex-1 items-center gap-3 text-left">
        <span className="hidden shrink-0 sm:block">
          <MarketAvatar market={market} size="size-8" />
        </span>
        <span className="min-w-0 truncate font-medium">{label}</span>
      </button>
      <span className={`w-12 shrink-0 rounded-md text-right font-bold tabular ${flashClass(flash)}`}>{formatProbability(market.yesPrice)}</span>
      {resolution ? (
        <span className="w-[9.5rem] sm:w-[11rem] shrink-0 text-right">
          <OutcomeBadge outcome={resolution.outcome} labels={market.labels} />
        </span>
      ) : (
        <span className="grid w-[9.5rem] sm:w-[11rem] shrink-0 grid-cols-2 gap-1.5">
          <button
            type="button"
            onClick={() => onPick(market.id, 'yes')}
            aria-pressed={pressed('yes')}
            aria-label={`Yes on ${label}, ${formatCents(market.yesPrice)}`}
            className={`rounded-lg px-1.5 py-1.5 text-xs font-semibold whitespace-nowrap tabular transition ${
              pressed('yes') ? 'bg-yes text-white' : 'bg-yes-soft text-yes hover:bg-yes hover:text-white'
            }`}
          >
            Yes {formatCents(market.yesPrice)}
          </button>
          <button
            type="button"
            onClick={() => onPick(market.id, 'no')}
            aria-pressed={pressed('no')}
            aria-label={`No on ${label}, ${formatCents(market.noPrice)}`}
            className={`rounded-lg px-1.5 py-1.5 text-xs font-semibold whitespace-nowrap tabular transition ${
              pressed('no') ? 'bg-no text-white' : 'bg-no-soft text-no hover:bg-no hover:text-white'
            }`}
          >
            No {formatCents(market.noPrice)}
          </button>
        </span>
      )}
    </li>
  )
}

/**
 * A winner event ("Super Bowl Champion 2027"): every outcome with its chance
 * and Yes / No prices, and the trade panel for the one picked. Each outcome is
 * its own Yes/No market underneath.
 */
export default function EventPage() {
  const { id } = useParams()
  const [params, setParams] = useSearchParams()
  const status = useMarketStore((s) => s.status)
  const order = useMarketStore((s) => s.order)
  const markets = useMarketStore((s) => s.markets)
  const members = useMemo(() => groupMembers(order.map((mid) => markets[mid]), id), [order, markets, id])
  const [sheet, setSheet] = useState(false)
  useDocumentTitle('Market')

  const picked = members.find((m) => m.id === params.get('m')) ?? members[0] ?? null
  const side = params.get('side') === 'no' ? 'no' : 'yes'
  const setPick = (marketId, nextSide) =>
    setParams(
      (prev) => {
        const p = new URLSearchParams(prev)
        p.set('m', marketId)
        p.set('side', nextSide)
        return p
      },
      { replace: true },
    )
  const onPick = (marketId, nextSide) => {
    setPick(marketId, nextSide)
    // On phones the trade panel lives in a sheet; open it straight away.
    if (window.matchMedia?.('(max-width: 1023px)').matches) setSheet(true)
  }
  const onSideChange = (nextSide) => picked && setPick(picked.id, nextSide)

  if (!picked) {
    if (status === 'loading') return <PageSkeleton />
    return (
      <div className="mx-auto max-w-xl px-4 py-16">
        <EmptyState
          icon={SearchIcon}
          title="Market not found"
          action={
            <Link to="/" className="btn btn-primary">
              Browse markets
            </Link>
          }
        >
          This market isn't in the current listings. It may have closed or dropped out of the live feed.
        </EmptyState>
      </div>
    )
  }

  const group = picked.group
  const volume = picked.groupVolume ?? members.reduce((sum, m) => sum + m.volume, 0)
  const label = group.label

  return (
    <div className="mx-auto max-w-7xl px-4 py-6 pb-36 lg:pb-6">
      <Link to="/" className="inline-flex items-center gap-1 text-sm text-muted hover:text-fg">
        <ChevronLeftIcon /> All markets
      </Link>
      <div className="mt-4 grid gap-6 lg:grid-cols-[minmax(0,1fr)_360px]">
        <div className="min-w-0 space-y-4">
          <header className="flex items-start gap-4">
            <MarketAvatar market={{ ...picked, image: group.image ?? picked.image, title: group.title }} size="size-14" />
            <div className="min-w-0">
              <p className="text-xs text-muted">
                {categoryLabel[picked.category]} · {formatCompactCurrency(volume)} Vol. · Ends {formatDate(picked.endDate)}
                <ClosesIn endDate={picked.endDate} className="ml-2" />
              </p>
              <h1 className="mt-1 text-xl leading-tight font-bold text-balance sm:text-2xl">{group.title}</h1>
              <p className="mt-1 text-sm text-muted">
                {members.length} outcomes. Exactly one wins: pick one and buy Yes if you think it will, or No if you think it won't.
              </p>
            </div>
          </header>

          <section className="card overflow-hidden" aria-label="Outcomes">
            <div className="flex items-center gap-3 border-b border-line px-3 py-2 text-xs text-muted">
              <span className="flex-1">Outcome</span>
              <span className="w-12 text-right">Chance</span>
              <span className="w-[9.5rem] sm:w-[11rem] text-right">Buy</span>
            </div>
            <ul className="divide-y divide-line">
              {members.map((m) => (
                <OutcomeRow key={m.id} market={m} active={m.id === picked.id} side={side} onPick={onPick} />
              ))}
            </ul>
          </section>

          <section className="space-y-4" aria-label={`Selected: ${label}`}>
            <h2 className="text-lg font-semibold">
              {label} <span className="text-sm font-normal text-muted">· {formatProbability(picked.yesPrice)} chance</span>
            </h2>
            <PriceChart market={picked} side={side} />
            <PositionSummary market={picked} />
            <div className="card space-y-2 p-4 text-sm leading-relaxed text-muted">
              <p className="font-medium text-fg">Rules</p>
              <p className="whitespace-pre-line">{picked.description || 'No rules were provided for this market.'}</p>
              <p className="text-xs text-subtle">
                Ends {formatDate(picked.endDate)}. Each outcome settles automatically from the official result: winning shares pay $1.00 in
                play money and losing shares pay $0.00.{' '}
                <Link to={`/market/${encodeURIComponent(picked.id)}`} className="text-primary-300 hover:underline">
                  Order book and details for {label}
                </Link>
              </p>
            </div>
          </section>
        </div>

        <aside className="hidden lg:block" aria-label="Trade">
          <div className="sticky top-24 space-y-2">
            <p className="text-sm text-muted">
              Trading <span className="font-semibold text-fg">{label}</span>
            </p>
            <TradePanel market={picked} side={side} onSideChange={onSideChange} />
          </div>
        </aside>
      </div>
      <MobileTradeBar
        market={picked}
        side={side}
        onSideChange={onSideChange}
        caption={`${label} · ${formatProbability(picked.yesPrice)} chance`}
        open={sheet}
        onOpenChange={setSheet}
      />
    </div>
  )
}
