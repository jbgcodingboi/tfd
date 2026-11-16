/**
 * Sounds for Tables, built from the shared synth note (which already respects
 * the mute switch).
 */
import { tone } from '../sound.js'

export const tableSounds = {
  /** A card landing; `at` delays it in seconds. */
  card: (at = 0) => {
    tone(2400, { at, dur: 0.07, type: 'sawtooth', slide: 600, gain: 0.012 })
    tone(170, { at: at + 0.05, dur: 0.06, type: 'sine', gain: 0.05 })
  },
  /** Chips going in: a call, bet or raise. */
  chips: () => {
    tone(2300, { dur: 0.025, type: 'square', gain: 0.025 })
    tone(3400, { at: 0.012, dur: 0.03, type: 'triangle', gain: 0.03 })
    tone(2800, { at: 0.06, dur: 0.03, type: 'triangle', gain: 0.022 })
  },
  /** A check: two knocks on the felt. */
  check: () => {
    tone(160, { dur: 0.05, type: 'sine', gain: 0.09 })
    tone(150, { at: 0.11, dur: 0.05, type: 'sine', gain: 0.07 })
  },
  fold: () => tone(520, { dur: 0.12, type: 'triangle', slide: 240, gain: 0.03 }),
  allIn: () => {
    ;[2300, 2700, 3100, 3500].forEach((f, i) => tone(f, { at: i * 0.035, dur: 0.03, type: 'square', gain: 0.022 }))
    tone(196, { at: 0.02, dur: 0.3, type: 'sawtooth', slide: 392, gain: 0.03 })
  },
  /** It is your turn. */
  turn: () => {
    tone(880, { dur: 0.09, type: 'triangle', gain: 0.06 })
    tone(1175, { at: 0.1, dur: 0.14, type: 'triangle', gain: 0.06 })
  },
  /** Time is nearly up. */
  hurry: () => tone(990, { dur: 0.06, type: 'square', gain: 0.03 }),
  win: () => [587, 740, 880, 1175].forEach((f, i) => tone(f, { at: i * 0.075, dur: 0.2, type: 'triangle', gain: 0.07 })),
  lose: () => tone(230, { dur: 0.3, type: 'sine', slide: 130, gain: 0.05 }),
}
