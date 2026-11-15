import { useState } from 'react'
import { useNow } from '../../hooks/useNow.js'
import { useResolution } from '../../store/resolutionStore.js'
import { hasEnded } from '../../utils/curation.js'
import { formatCents } from '../../utils/format.js'
import Modal from '../ui/Modal.jsx'
import TradePanel from './TradePanel.jsx'

/**
 * Mobile: a fixed bar that opens the trade panel as a bottom sheet. `caption`
 * says what is being traded (an event page names the outcome); pass `open` and
 * `onOpenChange` to open the sheet from elsewhere on the page.
 */
export default function MobileTradeBar({ market, side, onSideChange, caption, open: openProp, onOpenChange }) {
  const [openState, setOpenState] = useState(false)
  const open = openProp ?? openState
  const setOpen = onOpenChange ?? setOpenState
  const resolution = useResolution(market.id)
  const now = useNow(30000)
  if (resolution || market.closed || market.acceptingOrders === false || hasEnded(market, now)) return null

  const openWith = (s) => {
    onSideChange(s)
    setOpen(true)
  }

  return (
    <>
      <div className="fixed inset-x-0 bottom-0 z-30 border-t border-line bg-canvas/95 px-4 pt-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] backdrop-blur lg:hidden">
        {caption && <p className="mx-auto mb-2 max-w-lg truncate text-center text-xs text-muted">{caption}</p>}
        <div className="mx-auto grid max-w-lg grid-cols-2 gap-2">
          <button type="button" className="btn bg-yes py-3 text-white hover:bg-yes-strong" onClick={() => openWith('yes')}>
            Buy {market.labels.yes} {formatCents(market.yesPrice)}
          </button>
          <button type="button" className="btn bg-no py-3 text-white hover:bg-no-strong" onClick={() => openWith('no')}>
            Buy {market.labels.no} {formatCents(market.noPrice)}
          </button>
        </div>
      </div>
      <Modal open={open} onClose={() => setOpen(false)} title="Trade" description={market.title} variant="sheet">
        <TradePanel market={market} side={side} onSideChange={onSideChange} onDone={() => setOpen(false)} />
      </Modal>
    </>
  )
}
