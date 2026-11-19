import { describe, expect, it } from 'vitest'
import { sha256Hex } from './fair.js'
import { betPresets, CODE_ALPHABET, compareRanks, formatChips, formatCode, isCodeShape, normalizeCode, tableLink, handLabel, handRank, initials, isCard, potRaiseTo, potSummary, rankLabel, secondsLeft, toCard, verifyProof, viewPosition } from './poker.js'

const rank = (text) => handRank(text.split(' '))

describe('cards', () => {
  it('reads the codes the server sends', () => {
    expect(toCard('Td')).toEqual({ rank: '10', suit: '♦', id: 'Td' })
    expect(toCard('As')).toEqual({ rank: 'A', suit: '♠', id: 'As' })
    expect(toCard('1s')).toBeNull()
    expect(isCard('Kh')).toBe(true)
    expect([null, 'kh', 'Kx', '10h', 'Kh ', 7].some(isCard)).toBe(false)
  })
})

describe('hand strength (the same vectors as supabase/tests/schema.test.sql)', () => {
  it('ranks every category with the cards that break ties', () => {
    const vectors = [
      ['As Ks Qs Js Ts 2d 3c', [8, 14, 0, 0, 0, 0]],
      ['9h 8h 7h 6h 5h As Ad', [8, 9, 0, 0, 0, 0]],
      ['5h 4h 3h 2h Ah Kd Kc', [8, 5, 0, 0, 0, 0]],
      ['9c 9d 9h 9s Kd Ks 2c', [7, 9, 13, 0, 0, 0]],
      ['Qs Qh Qd Qc 3s Ah 2d', [7, 12, 14, 0, 0, 0]],
      ['Ks Kh Kd 2c 2d 9s 8s', [6, 13, 2, 0, 0, 0]],
      ['Ks Kh Kd 9c 9d 9s 2s', [6, 13, 9, 0, 0, 0]],
      ['Ks Kh Kd 9c 9d 4s 4h', [6, 13, 9, 0, 0, 0]],
      ['2s 2h 2d Ac Ad Ks Kh', [6, 2, 14, 0, 0, 0]],
      ['Ah Jh 9h 6h 3h 2h Kd', [5, 14, 11, 9, 6, 3]],
      ['Ah Kh Qh Jh 9h Td 2c', [5, 14, 13, 12, 11, 9]],
      ['Ts 9d 8h 7c 6s 2d 2c', [4, 10, 0, 0, 0, 0]],
      ['Ad 2s 3h 4c 5d Kd Qs', [4, 5, 0, 0, 0, 0]],
      ['Ad Ks Qh Jc Td 2d 3s', [4, 14, 0, 0, 0, 0]],
      ['Ad 2s 3h 4c 5d 6d Qs', [4, 6, 0, 0, 0, 0]],
      ['Ts 9d 8h 7c 6s 5d 4c', [4, 10, 0, 0, 0, 0]],
      ['Qs Qh Qd Ac 9d 4s 2h', [3, 12, 14, 9, 0, 0]],
      ['Ks Kh 4d 4c As 9d 2h', [2, 13, 4, 14, 0, 0]],
      ['Ks Kh 9d 9c 4s 4h Ad', [2, 13, 9, 14, 0, 0]],
      ['Ks Kh 9d 9c 4s 4h 3d', [2, 13, 9, 4, 0, 0]],
      ['As Ad Kh 9c 5d 3s 2h', [1, 14, 13, 9, 5, 0]],
      ['As Kd 9h 7c 5d 3s 2h', [0, 14, 13, 9, 7, 5]],
      ['As Ks Qs Js Ts', [8, 14, 0, 0, 0, 0]],
      ['As Ad Kh 9c 5d 3s', [1, 14, 13, 9, 5, 0]],
    ]
    for (const [cards, expected] of vectors) expect(rank(cards), cards).toEqual(expected)
    // King-ace-two does not wrap around.
    expect(rank('Qd Ks Ah 2c 3d 4s 9h')[0]).toBe(0)
  })

  it('orders the categories, breaks ties by kickers and ties equal hands', () => {
    const ladder = ['6h 5h 4h 3h 2h', '2c 2d 2h 2s 3d', '2c 2d 2h 3s 3d', '7h 5h 4h 3h 2h', '5c 4d 3h 2s Ad', 'Ac Ad Ah Ks Qd', 'Ac Ad Kh Ks Qd', 'Ac Ad Kh Qs Jd', 'Ac Kd Qh Js 9d']
    for (let i = 1; i < ladder.length; i++) expect(compareRanks(rank(ladder[i - 1]), rank(ladder[i]))).toBeGreaterThan(0)
    expect(compareRanks(rank('As Kd Ah 7c 5d 3s 2h'), rank('Ac Qd Ah 7c 5d 3s 2h'))).toBeGreaterThan(0)
    expect(compareRanks(rank('Ks Qd Ah Jc 9d 3s 2h'), rank('Kc Qh Ah Jc 8d 3s 2h'))).toBeGreaterThan(0)
    expect(compareRanks(rank('As Kd Ah 7c 5d 3s 2h'), rank('Ac Kh Ah 7c 5d 3s 2h'))).toBe(0)
    // The board plays: everyone ties.
    expect(compareRanks(rank('2c 3d As Ks Qs Js Ts'), rank('Ah Ad As Ks Qs Js Ts'))).toBe(0)
    expect(compareRanks(rank('2c 3d Ah Kd Qc Js 9h'), rank('4c 5d Ah Kd Qc Js 9h'))).toBe(0)
  })

  it('refuses anything that is not 5 to 7 cards', () => {
    expect(handRank(['As', 'Ks', 'Qs', 'Js'])).toBeNull()
    expect(handRank(['As', 'Ks', 'Qs', 'Js', '1s'])).toBeNull()
    expect(handRank(null)).toBeNull()
  })
})

describe('labels', () => {
  it('names a hand in words', () => {
    expect(rankLabel(rank('As Ks Qs Js Ts'))).toBe('Royal flush')
    expect(rankLabel(rank('9h 8h 7h 6h 5h'))).toBe('Straight flush, nine high')
    expect(rankLabel(rank('9c 9d 9h 9s Kd'))).toBe('Four of a kind, nines')
    expect(rankLabel(rank('Ks Kh Kd 2c 2d'))).toBe('Full house, kings over twos')
    expect(rankLabel(rank('Ah Jh 9h 6h 3h'))).toBe('Flush, ace high')
    expect(rankLabel(rank('Ad 2s 3h 4c 5d'))).toBe('Straight, five high')
    expect(rankLabel(rank('Qs Qh Qd Ac 9d'))).toBe('Three of a kind, queens')
    expect(rankLabel(rank('Ks Kh 4d 4c As'))).toBe('Two pair, kings and fours')
    expect(rankLabel(rank('6s 6d Kh 9c 5d'))).toBe('Pair of sixes')
    expect(rankLabel(rank('Ts Kd 9h 7c 5d'))).toBe('King high')
    expect(rankLabel(null)).toBe('')
  })
  it('labels what a player holds on every street', () => {
    expect(handLabel(['As', 'Ad'])).toBe('Pair of aces')
    expect(handLabel(['7c', 'Kd'], [])).toBe('King high')
    expect(handLabel(['7c', 'Kd'], ['Ks', '7d', '2h'])).toBe('Two pair, kings and sevens')
    expect(handLabel(['7c', 'Kd'], ['Ks', '7d', '2h', '7h'])).toBe('Full house, sevens over kings')
    expect(handLabel(null, ['Ks', '7d', '2h'])).toBe('')
    expect(handLabel(['7c'], [])).toBe('')
  })
  it('formats chips and initials', () => {
    expect(formatChips(1250)).toBe('$1,250')
    expect(formatChips('40')).toBe('$40')
    expect(formatChips(undefined)).toBe('$0')
    expect(initials('lucky_lou')).toBe('LL')
    expect(initials('alice')).toBe('AL')
    expect(initials('')).toBe('?')
  })
})

describe('bet sizing', () => {
  // Blinds 50/100, a bet of 300 to the player, 750 in the middle, 9,700 behind.
  const facing = { pot: 750, bet: 300, act: { seat: 2, toCall: 300, canRaise: true, minRaise: 600, maxRaise: 9700 } }
  const opening = { pot: 600, bet: 0, act: { seat: 1, toCall: 0, canRaise: true, minRaise: 100, maxRaise: 4000 } }

  it('sizes a raise as a share of the pot after calling', () => {
    // Call 300 makes the pot 1,050; a pot-sized raise is 300 + 1,050.
    expect(potRaiseTo(facing, 1)).toBe(1350)
    expect(potRaiseTo(facing, 0.5)).toBe(825)
    expect(potRaiseTo(opening, 1)).toBe(600)
    expect(potRaiseTo(opening, 0.5)).toBe(300)
  })
  it('stays inside what the server allows', () => {
    expect(potRaiseTo({ ...facing, act: { ...facing.act, maxRaise: 1000 } }, 1)).toBe(1000)
    expect(potRaiseTo({ pot: 30, bet: 0, act: { toCall: 0, canRaise: true, minRaise: 100, maxRaise: 4000 } }, 0.5)).toBe(100)
    expect(potRaiseTo({ pot: 100 }, 1)).toBe(0)
  })
  it('offers presets without duplicates, ending with all-in', () => {
    expect(betPresets(opening)).toEqual([
      { label: 'Min', to: 100 },
      { label: '½ pot', to: 300 },
      { label: '⅔ pot', to: 400 },
      { label: 'Pot', to: 600 },
      { label: 'All in', to: 4000 },
    ])
    // A short stack: every size is the whole stack.
    expect(betPresets({ pot: 2000, bet: 500, act: { toCall: 150, canRaise: true, minRaise: 150, maxRaise: 150 } })).toEqual([{ label: 'All in', to: 150 }])
    expect(betPresets({ pot: 2000, bet: 500, act: { toCall: 500, canRaise: false, minRaise: 1000, maxRaise: 5000 } })).toEqual([])
    expect(betPresets(null)).toEqual([])
  })
  it('splits the pot display into collected pots and bets in front of players', () => {
    expect(potSummary({ pot: 1750, pots: [1000, 150, 600] })).toEqual({ total: 1750, pots: [1000, 150, 600], collected: 1750, inFront: 0 })
    expect(potSummary({ pot: 950, pots: [750] })).toEqual({ total: 950, pots: [750], collected: 750, inFront: 200 })
    expect(potSummary({})).toEqual({ total: 0, pots: [], collected: 0, inFront: 0 })
  })
})

describe('table layout and clock', () => {
  it('draws the viewer at the bottom and everyone else clockwise from there', () => {
    expect([0, 1, 2, 3, 4, 5].map((s) => viewPosition(s, 4))).toEqual([2, 3, 4, 5, 0, 1])
    expect([0, 1, 2, 3, 4, 5].map((s) => viewPosition(s, null))).toEqual([0, 1, 2, 3, 4, 5])
  })
  it('counts down on the server clock', () => {
    expect(secondsLeft(10_000, 4_200)).toBe(6)
    expect(secondsLeft(10_000, 4_200, 3_000)).toBe(3)
    expect(secondsLeft(10_000, 12_000)).toBe(0)
    expect(secondsLeft(null, 12_000)).toBe(0)
  })
})

describe('fairness check', () => {
  const deck = ['As', 'Kd', '7c', '2h', 'Ts']
  const build = async () => {
    const cards = [...deck, ...Array.from({ length: 47 }, (_, i) => `x${i}`)]
    const salts = cards.map((_, i) => `salt${i}`)
    const commits = await Promise.all(cards.map((c, i) => sha256Hex(`${salts[i]}:${c}`)))
    return { hand: 7, deckHash: await sha256Hex(commits.join(',')), commits, reveals: [1, 3, 5].map((i) => ({ i, card: cards[i - 1], salt: salts[i - 1] })) }
  }
  it('accepts a record whose seals and revealed cards match', async () => {
    const proof = await build()
    expect(await verifyProof(proof, proof.deckHash)).toEqual({ ok: true, checked: 3, problems: [] })
  })
  it('catches a swapped card, a changed seal and a different deck', async () => {
    const proof = await build()
    const swapped = { ...proof, reveals: [{ ...proof.reveals[0], card: 'Ah' }] }
    expect((await verifyProof(swapped)).problems).toEqual(['The Ah does not open its seal.'])
    const resealed = { ...proof, commits: proof.commits.map((c, i) => (i === 10 ? c.replace(/./, (ch) => (ch === 'a' ? 'b' : 'a')) : c)) }
    expect((await verifyProof(resealed)).ok).toBe(false)
    expect((await verifyProof(proof, 'f'.repeat(64))).problems).toEqual(['This record is for a different deck than the one shown during the hand.'])
    expect((await verifyProof({ deckHash: 'x', commits: [], reveals: [] })).ok).toBe(false)
  })
})

describe('private table codes', () => {
  it('has no look-alike characters in its alphabet', () => {
    expect(CODE_ALPHABET).toHaveLength(32)
    for (const c of '01OI') expect(CODE_ALPHABET).not.toContain(c)
    expect(new Set(CODE_ALPHABET).size).toBe(32)
  })
  it('reads a code however it was typed', () => {
    expect(normalizeCode(' abc-d2e ')).toBe('ABCD2E')
    expect(normalizeCode('ab cd ef')).toBe('ABCDEF')
    expect(normalizeCode(null)).toBe('')
    expect(normalizeCode('ab_c.d!e#f')).toBe('ABCDEF')
  })
  it('knows the shape of a real code', () => {
    expect(isCodeShape('ABCD23')).toBe(true)
    expect(isCodeShape('ABCD2')).toBe(false)
    expect(isCodeShape('ABCD234')).toBe(false)
    expect(isCodeShape('ABCD20')).toBe(false)
    expect(isCodeShape('ABCDOI')).toBe(false)
    expect(isCodeShape('')).toBe(false)
  })
  it('shows a code in two halves for reading aloud', () => {
    expect(formatCode('ABCD23')).toBe('ABC-D23')
    expect(formatCode('SHORT')).toBe('SHORT')
    expect(formatCode(null)).toBe('')
  })
  it('makes a link a friend can open', () => {
    expect(tableLink('https://example.test', 12, 'abc-d23')).toBe('https://example.test/#/games/tables/12?code=ABCD23')
    expect(tableLink('https://example.test', 7)).toBe('https://example.test/#/games/tables/7')
  })
})
