/**
 * Helpers for Tables, the card game played between players. The server runs
 * the game (the poker section of supabase/schema.sql): it shuffles, deals,
 * checks every move and pays the pots. This file only reads what the server
 * sends: card codes, hand names for the labels on screen, sizes for the bet
 * slider, where to draw each seat, and the fairness check.
 */
import { sha256Hex } from './fair.js'

const RANKS = '23456789TJQKA'
const SUIT_SYMBOL = { s: '♠', h: '♥', d: '♦', c: '♣' }

/** A card code from the server: a rank from 23456789TJQKA and a suit from shdc, like "Td". */
export const isCard = (c) => typeof c === 'string' && /^[2-9TJQKA][shdc]$/.test(c)

/** "Td" as the { rank, suit, id } PlayingCard draws, or null for anything that isn't a card. */
export const toCard = (code) => (isCard(code) ? { rank: code[0] === 'T' ? '10' : code[0], suit: SUIT_SYMBOL[code[1]], id: code } : null)

/** The top card of the best straight among the ranks present, or 0. The ace also plays low. */
function straightHigh(present) {
  for (let h = 14; h >= 6; h--) if (present[h] && present[h - 1] && present[h - 2] && present[h - 3] && present[h - 4]) return h
  return present[14] && present[2] && present[3] && present[4] && present[5] ? 5 : 0
}

/**
 * The strength of the best five-card hand among 5 to 7 cards, as the same
 * array the server computes (private.poker_rank): the category (8 straight
 * flush down to 0 high card), then the ranks that break ties, highest first.
 * Returns null unless given 5 to 7 valid cards.
 */
export function handRank(codes) {
  if (!Array.isArray(codes) || codes.length < 5 || codes.length > 7 || !codes.every(isCard)) return null
  const count = new Array(15).fill(0)
  const suits = { s: [], h: [], d: [], c: [] }
  for (const c of codes) {
    const r = RANKS.indexOf(c[0]) + 2
    count[r] += 1
    suits[c[1]].push(r)
  }
  const pad = (a) => [...a, 0, 0, 0, 0, 0].slice(0, 6)
  const flush = Object.values(suits).find((s) => s.length >= 5)
  if (flush) {
    const present = new Array(15).fill(0)
    for (const r of flush) present[r] = 1
    const sf = straightHigh(present)
    if (sf) return pad([8, sf])
  }
  const groups = { 4: [], 3: [], 2: [], 1: [] }
  for (let r = 14; r >= 2; r--) if (count[r]) groups[count[r]].push(r)
  const [quads, trips, pairs, singles] = [groups[4], groups[3], groups[2], groups[1]]
  if (quads.length) {
    let kicker = 0
    for (let r = 14; r >= 2 && !kicker; r--) if (count[r] && r !== quads[0]) kicker = r
    return pad([7, quads[0], kicker])
  }
  if (trips.length && (trips.length > 1 || pairs.length)) return pad([6, trips[0], Math.max(trips[1] ?? 0, pairs[0] ?? 0)])
  if (flush) return pad([5, ...[...flush].sort((a, b) => b - a).slice(0, 5)])
  const straight = straightHigh(count)
  if (straight) return pad([4, straight])
  if (trips.length) return pad([3, trips[0], singles[0], singles[1]])
  if (pairs.length >= 2) return pad([2, pairs[0], pairs[1], Math.max(pairs[2] ?? 0, singles[0] ?? 0)])
  if (pairs.length) return pad([1, pairs[0], singles[0], singles[1], singles[2]])
  return pad([0, ...singles.slice(0, 5)])
}

/** Compares two strengths: positive when a wins, negative when b wins, 0 for a tie. */
export function compareRanks(a, b) {
  for (let i = 0; i < 6; i++) if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) - (b[i] ?? 0)
  return 0
}

const ONE = [null, null, 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'jack', 'queen', 'king', 'ace']
const MANY = [null, null, 'twos', 'threes', 'fours', 'fives', 'sixes', 'sevens', 'eights', 'nines', 'tens', 'jacks', 'queens', 'kings', 'aces']
const cap = (s) => s.charAt(0).toUpperCase() + s.slice(1)

/** A strength in words: "Two pair, kings and fours". */
export function rankLabel(rank) {
  if (!Array.isArray(rank)) return ''
  const [cat, a, b] = rank
  switch (cat) {
    case 8:
      return a === 14 ? 'Royal flush' : `Straight flush, ${ONE[a]} high`
    case 7:
      return `Four of a kind, ${MANY[a]}`
    case 6:
      return `Full house, ${MANY[a]} over ${MANY[b]}`
    case 5:
      return `Flush, ${ONE[a]} high`
    case 4:
      return `Straight, ${ONE[a]} high`
    case 3:
      return `Three of a kind, ${MANY[a]}`
    case 2:
      return `Two pair, ${MANY[a]} and ${MANY[b]}`
    case 1:
      return `Pair of ${MANY[a]}`
    default:
      return ONE[a] ? `${cap(ONE[a])} high` : ''
  }
}

/** What a player holds right now, in words. Before the flop that is just a pair or the high card. */
export function handLabel(hole, board = []) {
  const cards = [...(hole ?? []), ...(board ?? [])].filter(isCard)
  if ((hole ?? []).filter(isCard).length !== 2) return ''
  if (cards.length >= 5) return rankLabel(handRank(cards))
  const [x, y] = hole.map((c) => RANKS.indexOf(c[0]) + 2)
  return x === y ? `Pair of ${MANY[x]}` : `${cap(ONE[Math.max(x, y)])} high`
}

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v))

/**
 * The total to bet or raise to for a share of the pot. A pot-sized raise first
 * calls, then raises by the pot as it stands after the call, so `fraction` of
 * the pot is bet + fraction x (pot + call). Kept between the smallest and
 * largest amounts the server allows, in whole chips.
 */
export function potRaiseTo(state, fraction) {
  const act = state?.act
  if (!act) return 0
  const size = Math.round(fraction * ((state.pot ?? 0) + (act.toCall ?? 0)))
  return clamp((state.bet ?? 0) + size, act.minRaise, act.maxRaise)
}

/** Quick sizes for the bet slider: the smallest allowed, shares of the pot, and all-in. Duplicates are dropped. */
export function betPresets(state) {
  const act = state?.act
  if (!act?.canRaise) return []
  const list = [
    { label: 'Min', to: act.minRaise },
    { label: '½ pot', to: potRaiseTo(state, 0.5) },
    { label: '⅔ pot', to: potRaiseTo(state, 2 / 3) },
    { label: 'Pot', to: potRaiseTo(state, 1) },
    { label: 'All in', to: act.maxRaise },
  ]
  // A size that is the whole stack is shown once, as "All in".
  const seen = new Set()
  return list.filter((p, i) => (i === list.length - 1 || p.to !== act.maxRaise) && !seen.has(p.to) && seen.add(p.to))
}

/** The pots to show on the felt: chips collected on earlier rounds (main pot first, then side pots), plus bets still in front of players. */
export function potSummary(state) {
  const pots = Array.isArray(state?.pots) ? state.pots.filter((p) => p > 0) : []
  const collected = pots.reduce((a, b) => a + b, 0)
  const total = state?.pot ?? 0
  return { total, pots, collected, inFront: Math.max(0, total - collected) }
}

/**
 * Where a seat is drawn. Seats run clockwise and the viewer always sits at
 * the bottom (position 0); a spectator sees seat 0 there.
 */
export const viewPosition = (seat, mySeat, seats = 6) => (((seat - (mySeat ?? 0)) % seats) + seats) % seats

/** Whole seconds left before a deadline, on the server's clock (`offset` is server time minus this device's). */
export const secondsLeft = (deadline, now, offset = 0) => (deadline ? Math.max(0, Math.ceil((deadline - (now + offset)) / 1000)) : 0)

/** Chip amounts are whole dollars: "$1,250". */
export const formatChips = (n) => `$${Math.round(Number(n) || 0).toLocaleString('en-US')}`

/** Two letters for a seat's avatar. */
export const initials = (name) => {
  const parts = String(name ?? '').split(/[_\W]+/).filter(Boolean)
  const text = parts.length > 1 ? parts[0][0] + parts[1][0] : (parts[0] ?? '?').slice(0, 2)
  return text.toUpperCase()
}

/**
 * Checks a finished hand's fairness record (poker_proof) in the browser.
 * Before the deal the server sealed each of the 52 cards as
 * sha256("<salt>:<card>") and published the hash of all the seals. This
 * confirms the seals still hash to that value (`expectedHash`, when the page
 * saw it during the hand) and that every card shown opens its own seal.
 */
export async function verifyProof(proof, expectedHash) {
  const problems = []
  const commits = Array.isArray(proof?.commits) ? proof.commits : []
  const reveals = Array.isArray(proof?.reveals) ? proof.reveals : []
  if (commits.length !== 52) problems.push('The record should hold 52 sealed cards.')
  const hash = await sha256Hex(commits.join(','))
  if (hash !== proof?.deckHash) problems.push('The seals do not match the hash published with the hand.')
  if (expectedHash && expectedHash !== proof?.deckHash) problems.push('This record is for a different deck than the one shown during the hand.')
  const seen = new Set()
  for (const r of reveals) {
    if (!isCard(r?.card) || !Number.isInteger(r?.i) || r.i < 1 || r.i > 52) problems.push('A revealed card is malformed.')
    else if ((await sha256Hex(`${r.salt}:${r.card}`)) !== commits[r.i - 1]) problems.push(`The ${r.card} does not open its seal.`)
    else if (seen.has(r.card)) problems.push(`The ${r.card} appears twice.`)
    seen.add(r?.card)
  }
  return { ok: problems.length === 0, checked: reveals.length, problems }
}

/** The letters and digits a join code is made of: no 0, O, 1 or I, so a code read aloud or off a screen is not misread. */
export const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

/**
 * A join code as typed: any case, with spaces or dashes allowed, and the look-alikes
 * a person might type for the digits (O for 0, I or L for 1) left alone, since no
 * code contains them and the server will simply find no table.
 */
export const normalizeCode = (text) => String(text ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '')

/** True for six characters from the code alphabet. */
export const isCodeShape = (code) => code.length === 6 && [...code].every((c) => CODE_ALPHABET.includes(c))

/** "ABCDEF" as "ABC-DEF", easier to read out to a friend. */
export const formatCode = (code) => (code?.length === 6 ? `${code.slice(0, 3)}-${code.slice(3)}` : (code ?? ''))

/** The address of a table, with its join code when it has one. Relative to the site's own address bar (the site uses hash routing). */
export const tableLink = (origin, tableId, code) => `${origin}/#/games/tables/${tableId}${code ? `?code=${normalizeCode(code)}` : ''}`

/**
 * What a private table's creator may set for its buy-in range, at given blinds
 * (supabase/schema.sql poker_create): whole dollars, at least 10 big blinds,
 * at most 1,000 big blinds and $1,000,000.
 */
export const buyInBounds = (bigBlind) => ({ min: 10 * bigBlind, max: Math.min(1000 * bigBlind, 1_000_000) })

/** Why a custom buy-in range can't be used, in the server's words, or null when it can. */
export function buyInProblem({ min, max }, bigBlind) {
  const bounds = buyInBounds(bigBlind)
  if (![min, max].every((v) => Number.isInteger(v) && v > 0)) return 'Buy-ins are whole dollars.'
  if (min < bounds.min) return `The smallest buy-in at these blinds is ${formatChips(bounds.min)} (10 big blinds).`
  if (max < min) return 'The largest buy-in can’t be below the smallest.'
  if (max > bounds.max) return `The largest buy-in at these blinds is ${formatChips(bounds.max)}.`
  return null
}

const STEPS = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000]

/** A round slider step for a range: the smallest of 1, 5, 10, 25, 50, 100 ... that leaves at most 200 stops. */
export function niceStep(lo, hi) {
  const span = Math.max(0, hi - lo)
  return STEPS.find((s) => span / s <= 200) ?? STEPS.at(-1)
}
