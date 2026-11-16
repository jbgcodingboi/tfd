import { lazy, Suspense, useState } from 'react'
import { HashRouter, Navigate, Route, Routes, useLocation } from 'react-router-dom'
import AppEffects from './AppEffects.jsx'
import Footer from './components/layout/Footer.jsx'
import Header from './components/layout/Header.jsx'
import ErrorBoundary from './components/ui/ErrorBoundary.jsx'
import { PageSkeleton } from './components/ui/Skeleton.jsx'
import Toaster from './components/ui/Toaster.jsx'
import ScrollToTop from './components/layout/ScrollToTop.jsx'
import CornerNotice from './components/legal/CornerNotice.jsx'
import FeedbackTab from './components/FeedbackTab.jsx'
import TermsGate from './components/legal/TermsGate.jsx'
import { GAME_PATH } from './games/names.js'
import { useUiStore } from './store/uiStore.js'

const HomePage = lazy(() => import('./pages/HomePage.jsx'))
const MarketPage = lazy(() => import('./pages/MarketPage.jsx'))
const EventPage = lazy(() => import('./pages/EventPage.jsx'))
const PortfolioPage = lazy(() => import('./pages/PortfolioPage.jsx'))
const LeaderboardPage = lazy(() => import('./pages/LeaderboardPage.jsx'))
const GamesPage = lazy(() => import('./pages/games/GamesPage.jsx'))
const RoulettePage = lazy(() => import('./pages/games/RoulettePage.jsx'))
const BlackjackPage = lazy(() => import('./pages/games/BlackjackPage.jsx'))
const PlinkoPage = lazy(() => import('./pages/games/PlinkoPage.jsx'))
const DicePage = lazy(() => import('./pages/games/DicePage.jsx'))
const MinesPage = lazy(() => import('./pages/games/MinesPage.jsx'))
const ChickenPage = lazy(() => import('./pages/games/ChickenPage.jsx'))
const LimboPage = lazy(() => import('./pages/games/LimboPage.jsx'))
const SlotsPage = lazy(() => import('./pages/games/SlotsPage.jsx'))
const TablesPage = lazy(() => import('./pages/games/TablesPage.jsx'))
const TermsPage = lazy(() => import('./pages/TermsPage.jsx'))
const NotFoundPage = lazy(() => import('./pages/NotFoundPage.jsx'))
const AuthModal = lazy(() => import('./components/AuthModal.jsx'))
const ResetBalanceModal = lazy(() => import('./components/ResetBalanceModal.jsx'))
const DeleteAccountModal = lazy(() => import('./components/DeleteAccountModal.jsx'))
const RecoveryCodeModal = lazy(() => import('./components/RecoveryCodeModal.jsx'))

/**
 * The account dialogs (log in, reset, delete, recovery code). Most visits never
 * open one, so their code is fetched the first time one is asked for; after
 * that they stay mounted, which lets them animate closed.
 */
function AccountDialogs() {
  const wanted = useUiStore((s) => s.auth.open || s.resetOpen || s.deleteOpen || Boolean(s.recovery))
  const [loaded, setLoaded] = useState(false)
  if (wanted && !loaded) setLoaded(true)
  if (!loaded) return null
  return (
    <Suspense fallback={null}>
      <AuthModal />
      <ResetBalanceModal />
      <DeleteAccountModal />
      <RecoveryCodeModal />
    </Suspense>
  )
}

function AppRoutes() {
  const { pathname } = useLocation()
  return (
    // The Suspense boundary sits outside the keyed error boundary, so it is not remounted on every
    // navigation: React then keeps the current page up while the next page's code arrives (a few
    // milliseconds once cached) instead of flashing the skeleton, which it holds for 300 ms once shown.
    <Suspense fallback={<PageSkeleton />}>
      <ErrorBoundary key={pathname}>
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/market/:id" element={<MarketPage />} />
          <Route path="/event/:id" element={<EventPage />} />
          <Route path="/portfolio" element={<PortfolioPage />} />
          <Route path="/leaderboard" element={<LeaderboardPage />} />
          <Route path="/games" element={<GamesPage />} />
          <Route path={GAME_PATH.roulette} element={<RoulettePage />} />
          <Route path={GAME_PATH.blackjack} element={<BlackjackPage />} />
          <Route path={GAME_PATH.plinko} element={<PlinkoPage />} />
          <Route path={GAME_PATH.dice} element={<DicePage />} />
          <Route path={GAME_PATH.mines} element={<MinesPage />} />
          <Route path={GAME_PATH.chicken} element={<ChickenPage />} />
          <Route path={GAME_PATH.limbo} element={<LimboPage key="limbo" />} />
          <Route path={GAME_PATH.crash} element={<LimboPage key="crash" crash />} />
          <Route path={GAME_PATH.slots} element={<SlotsPage />} />
          <Route path={GAME_PATH.poker} element={<TablesPage />} />
          <Route path={`${GAME_PATH.poker}/:tableId`} element={<TablesPage />} />
          {/* Old addresses named after each game (and the retired Boneyard) still land on the right page. */}
          {Object.entries(GAME_PATH).map(([game, to]) => (
            <Route key={game} path={`/games/${game}`} element={<Navigate to={to} replace />} />
          ))}
          <Route path="/terms" element={<TermsPage />} />
          <Route path="*" element={<NotFoundPage />} />
        </Routes>
      </ErrorBoundary>
    </Suspense>
  )
}

export default function App() {
  return (
    <HashRouter>
      <AppEffects />
      <ScrollToTop />
      <div className="flex min-h-screen flex-col">
        <button
          type="button"
          onClick={() => document.getElementById('main')?.focus()}
          className="sr-only focus:not-sr-only focus:fixed focus:top-2 focus:left-2 focus:z-50 focus:rounded-lg focus:bg-primary-500 focus:px-3 focus:py-2 focus:text-white"
        >
          Skip to content
        </button>
        <Header />
        <main id="main" tabIndex={-1} className="flex-1 outline-none">
          <AppRoutes />
        </main>
        <Footer />
      </div>
      <AccountDialogs />
      <Toaster />
      <CornerNotice />
      <FeedbackTab />
      <TermsGate />
    </HashRouter>
  )
}
