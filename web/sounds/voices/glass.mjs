// glass.mjs: GLASS (named by the player: "other sounds be scary too like the glass"). Glass is a spray of many short,
// high, inharmonic pings over a low thump, never one long whistle: a thin shell cracks (a sharp broadband snap and its
// few shell partials), shatters into 30-60 shards that each ring a few tens of milliseconds while they fall and
// bounce (a Poisson shower whose density dies away), and whatever it hit thuds under it. The flask carries a chemical
// that splashes and fizzes; a tube light fails with a pop of pressure and a buzz cut short; shards underfoot are a
// gritty crunch, not pings.

import * as K from '../kit/index.mjs';
import { PLAYER_CARRY } from './player-steps.mjs';

const FAMILY = 'glass';

/**
 * Shards falling and bouncing: `count` pings (2.5-11 kHz unless given), their rate dying away over `spread` s.
 * @param {number} sr
 * @param {K.Rng} r
 * @param {{count: number, spread: number, lo?: number, hi?: number, t60?: [number, number]}} spec
 */
function shards(sr, r, { count, spread, lo = 2500, hi = 11000, t60 = [0.015, 0.06] }) {
  const n = Math.round((spread + 0.15) * sr);
  const tau = spread / 3;
  const peakRate = count / tau;
  const times = K.poissonTimes(r.fork('times'), spread, (t) => peakRate * Math.exp(-t / tau), peakRate);
  const g = r.fork('pings');
  return K.shower(n, sr, times, (t) => ({
    grain: K.ping(sr, g, { freq: lo * (hi / lo) ** g.next(), t60: g.range(t60[0], t60[1]), ratios: [1, g.range(2.1, 2.5), g.range(3.9, 4.6)], spread: 0.05 }),
    // later shards are smaller bounces: quieter
    gain: g.range(0.25, 1) * (0.35 + 0.65 * Math.exp(-t / tau)),
  }));
}

/**
 * The crack: a sub-millisecond broadband snap into a thin glass shell's partials.
 * @param {number} sr
 * @param {K.Rng} r
 * @param {number} base the shell's lowest partial (Hz)
 */
function crack(sr, r, base) {
  const snap = K.burst(sr, r.fork('snap'), { length: 0.0006, attack: 0.00005, cutoff: 16000, hp: 300 });
  const shell = K.modal(snap, sr, K.modesFrom(base, K.GLASS, { t60: 0.05, damp: 0.6, tilt: -1, detune: 0.04, rng: r }), Math.round(0.12 * sr));
  const out = K.unit(shell);
  K.addAt(out, K.unit(snap), 0, 0.9);
  return out;
}

/**
 * What it hit: a low-mid thud (the floor or a wall answering a small hard mass).
 * @param {number} sr
 * @param {K.Rng} r
 */
function thud(sr, r) {
  return K.footfall(sr, r, {
    length: 0.4,
    thump: { f0: 95, f1: 65, drop: 0.02, t60: 0.1, drive: 2, gain: -6 },
    body: { modes: K.scatterModes(r, 6, 150, 520, 0.05, 0.12, -1), gain: 0, excite: 0.002, cutoff: 2500 },
    contact: { length: 0.003, cutoff: 3000, gain: -4 },
  });
}

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  {
    name: 'FlaskShatter',
    title: 'A flask smashing',
    description: 'A thin lab flask thrown hard: the crack, a shower of glass dying away, the chemical splashing out and fizzing.',
    family: FAMILY,
    group: 'reference',
    class: 'glass',
    repeats: true,
    variants: 4,
    channels: 1,
    loop: null,
    space: 'dry',
    loudness: -20.5,
    carry: Object.freeze({ ref: 8, max: 180, rolloff: 0.9, fade: 0.7 }),
    board: 'Glass',
    render: ({ sr, rng }) => {
      const r = rng.fork('flask');
      const out = new Float32Array(Math.round(2.0 * sr));
      K.addAt(out, crack(sr, r.fork('crack'), r.range(1700, 2600)), 0, 0.8);
      // thrown hard: the flask and its load hit the floor with weight (the low-mid that anchors the spray)
      K.addAt(out, K.unit(thud(sr, r.fork('thud'))), r.range(0.001, 0.004) * sr, 1.5);
      K.addAt(out, K.unit(shards(sr, r.fork('shards'), { count: r.int(35, 60), spread: r.range(0.3, 0.5) })), r.range(0.003, 0.008) * sr, 0.6);
      // the chemical: a slap of liquid, then droplets and bubbles fizzing for a second
      const liquid = r.fork('liquid');
      const splash = K.svf(K.burst(sr, liquid.fork('slap'), { length: 0.05, cutoff: 3000, hp: 200, colour: 'pink' }), sr, 'bandpass', 900, 0.5);
      K.addAt(out, K.unit(splash), 0.012 * sr, 0.35);
      const fizzLen = 1.4;
      const fizz = K.shower(Math.round(fizzLen * sr), sr, K.poissonTimes(liquid.fork('t'), fizzLen, (t) => 220 * Math.exp(-t / 0.45), 220), () => ({
        grain: K.bubble(sr, liquid, { freq: liquid.range(1200, 4500), t60: liquid.range(0.006, 0.02), rise: liquid.range(0.3, 1) }),
        gain: liquid.range(0.2, 1),
      }));
      K.addAt(out, K.unit(fizz), 0.03 * sr, 0.18);
      return out;
    },
  },
  {
    name: 'ChemHiss',
    title: 'The chemical cloud hissing',
    description: 'The spilled chemical reacting where the flask broke: bubbling, spitting and hissing while the cloud hangs there.',
    family: FAMILY,
    group: 'reference',
    class: 'liquid',
    variants: 1,
    channels: 1,
    loop: { seconds: 8, crossfade: 0.6 },
    space: 'dry',
    loudness: -30,
    carry: Object.freeze({ ref: 4, max: 70, rolloff: 1, fade: 0.67 }),
    board: 'Glass',
    render: ({ sr, rng, seconds }) => {
      const n = Math.round(seconds * sr);
      const r = rng.fork('react');
      // bubbles of every size, surging in slow waves
      const surge = K.smoothRandom(n, sr, 1.5, r.fork('surge'), 0.4, 1);
      const bubbles = K.shower(n, sr, K.poissonTimes(r.fork('t'), seconds, 260), (t) => ({
        grain: K.bubble(sr, r, { freq: 500 * 8 ** r.next(), t60: r.range(0.006, 0.035), rise: r.range(0.2, 1.2) }),
        gain: r.range(0.15, 1) * surge[Math.min(n - 1, Math.round(t * sr))],
      }));
      // spitting: tiny droplets flicked off the surface
      const spits = K.shower(n, sr, K.poissonTimes(r.fork('s'), seconds, 30), () => ({ grain: K.click(sr, r, { freq: r.range(2000, 5000), q: 2, length: 0.002 }), gain: r.range(0.2, 0.8) }));
      // the hiss of the gas coming off, dark and breathing with the surges
      const hiss = K.svf(K.pink(n, r.fork('hiss')), sr, 'bandpass', 1600, 0.7);
      const out = K.unit(bubbles);
      K.addAt(out, K.unit(spits), 0, 0.3);
      K.mul(K.unit(hiss), surge);
      K.addAt(out, hiss, 0, 0.35);
      return K.butter(out, sr, 'lowpass', 6000, 2);
    },
  },
  {
    name: 'GlassCrunch',
    title: 'Broken glass underfoot',
    description: 'Stepping onto a patch of shards: a gritty crunch as they break up and grind under a shoe.',
    family: FAMILY,
    group: 'reference',
    class: 'crunch',
    repeats: true,
    variants: 5,
    channels: 1,
    loop: null,
    space: 'dry',
    loudness: -22,
    carry: Object.freeze({ ref: 6, max: 170, rolloff: 0.9, fade: 0.7 }),
    board: 'Glass',
    render: ({ sr, rng }) => crunch(sr, rng.fork('crunch'), { count: rng.int(70, 110), spread: rng.range(0.25, 0.4), step: true }),
  },
  ...[false, true].map((sprint) => ({
    name: `Footstep${sprint ? 'Sprint' : ''}Glass`,
    title: `Your footsteps, ${sprint ? 'sprinting' : 'walking'}, on broken glass`,
    description: `A kid ${sprint ? 'running' : 'walking'} over shards: each step crunches and grinds.`,
    family: FAMILY,
    group: /** @type {const} */ ('reference'),
    class: 'crunch',
    repeats: true,
    variants: 5,
    channels: /** @type {const} */ (1),
    loop: null,
    space: /** @type {const} */ ('dry'),
    loudness: sprint ? -25 : -28,
    carry: PLAYER_CARRY,
    board: 'Glass',
    render: (/** @type {{sr: number, rng: K.Rng}} */ { sr, rng }) => crunch(sr, rng.fork('step'), { count: rng.int(sprint ? 30 : 40, sprint ? 45 : 60), spread: sprint ? rng.range(0.08, 0.12) : rng.range(0.14, 0.2), step: true }),
  })),
  {
    name: 'LightBurst',
    title: 'A light tube bursting',
    description: 'A fluorescent tube failing overhead: a pop of pressure, thin glass raining down, the buzz cut off dead.',
    family: FAMILY,
    group: 'reference',
    class: 'glass',
    variants: 3,
    channels: 1,
    loop: null,
    space: 'dry',
    loudness: -19.5,
    carry: Object.freeze({ ref: 8, max: 150, rolloff: 0.9, fade: 0.7 }),
    board: 'Glass',
    render: ({ sr, rng }) => {
      const r = rng.fork('tube');
      const out = new Float32Array(Math.round(1.8 * sr));
      // the ballast buzzing as it fails: a rough 100 Hz pulse train through the fitting, surging, then cut dead
      const buzzLen = r.range(0.18, 0.3);
      const nb = Math.round(buzzLen * sr);
      const pulses = new Float32Array(nb);
      const period = sr / 100;
      for (let t = 0; t < nb; t += period * (1 + r.range(-0.02, 0.02))) pulses[Math.round(t)] = r.range(0.6, 1);
      const buzz = K.modal(pulses, sr, K.scatterModes(r, 8, 200, 2400, 0.004, 0.012, -2), nb);
      // it arcs on at once (an arc has no fade-in), surging, and is cut dead
      K.mul(buzz, K.segments(nb, sr, [[0, 0.7], [buzzLen * 0.8, 1, 2], [buzzLen, 1]]));
      K.fade(buzz, sr, 0.0005, 0.003);
      K.addAt(out, K.unit(buzz), 0, 0.8);
      // the arc striking: an electrical snap at the start of the buzz
      K.addAt(out, K.unit(K.burst(sr, r.fork('arc'), { length: 0.0012, attack: 0.0001, cutoff: 9000, hp: 500 })), 0, 0.7);
      const at = Math.round(buzzLen * sr);
      // the pop: the vacuum of the tube giving way, a pressure thump with a sharp edge
      const pop = K.thump(sr, { f0: 120, f1: 60, drop: 0.012, t60: 0.08, drive: 3 });
      K.addAt(out, K.unit(pop), at, 0.8);
      K.addAt(out, crack(sr, r.fork('crack'), r.range(2600, 3400)), at, 0.9);
      // thin tube glass: many small high shards raining from the ceiling, landing a beat later
      K.addAt(out, K.unit(shards(sr, r.fork('shards'), { count: r.int(30, 45), spread: r.range(0.35, 0.5), lo: 3000, hi: 11000, t60: [0.01, 0.04] })), at + r.range(0.12, 0.2) * sr, 0.6);
      // and the fitting's low rattle as the end caps drop
      K.addAt(out, K.unit(thud(sr, r.fork('cap'))), at + r.range(0.25, 0.35) * sr, 0.35);
      return out;
    },
  },
  {
    name: 'GlassBreak',
    title: 'A window breaking far away',
    description: 'Somewhere far inside the school a window gives way: a dark crash and glass raining down a long corridor.',
    family: FAMILY,
    group: 'reference',
    class: 'far',
    variants: 2,
    channels: 2,
    loop: null,
    space: 'baked',
    loudness: -26,
    board: 'Glass',
    render: ({ sr, rng }) => {
      const r = rng.fork('window');
      const dry = new Float32Array(Math.round(1.6 * sr));
      // a big pane: a lower shell, a heavier thud, more and bigger shards over a longer fall
      K.addAt(dry, crack(sr, r.fork('crack'), r.range(900, 1400)), 0, 1);
      K.addAt(dry, K.unit(thud(sr, r.fork('frame'))), 0.002 * sr, 1);
      K.addAt(dry, K.unit(shards(sr, r.fork('shards'), { count: r.int(80, 120), spread: r.range(0.7, 0.9), lo: 1500, hi: 8000, t60: [0.02, 0.08] })), 0.01 * sr, 0.8);
      // heard from far down the building: dark (air and walls), mostly reverberation
      return K.place(dry, sr, K.SPACES.corridor, { wet: 0.8, darken: 1800, rng: r.fork('space') });
    },
  },
];

/**
 * Shards breaking up and grinding under a shoe: a dense cloud of short noise clicks and tiny pings, with the
 * step's dull contact under it.
 * @param {number} sr
 * @param {K.Rng} r
 * @param {{count: number, spread: number, step: boolean}} spec
 */
function crunch(sr, r, { count, spread, step }) {
  const n = Math.round((spread + 0.25) * sr);
  const out = new Float32Array(n);
  // the grinding: clusters of clicks (a shard snapping is two or three cracks)
  const g = r.fork('grind');
  const times = K.poissonTimes(g.fork('t'), spread, (t) => (count / spread) * 2 * Math.exp(-t / (spread * 0.6)), (count / spread) * 2);
  for (const t of times) {
    const cluster = g.int(1, 3);
    for (let k = 0; k < cluster; k++) {
      const c = K.click(sr, g, { freq: g.range(1500, 7000), q: g.range(0.8, 2), length: g.range(0.0008, 0.003) });
      K.addAt(out, c, (t + k * g.range(0.001, 0.004)) * sr, g.range(0.3, 1));
    }
    if (g.chance(0.15)) K.addAt(out, K.ping(sr, g, { freq: g.range(3000, 9000), t60: g.range(0.005, 0.015) }), t * sr, g.range(0.05, 0.15));
  }
  K.unit(out);
  if (step) {
    const sole = K.footfall(sr, r.fork('sole'), {
      length: 0.4,
      thump: { f0: 100, f1: 75, drop: 0.02, t60: 0.05, drive: 1.5, gain: -14 },
      body: { modes: K.scatterModes(r, 5, 200, 800, 0.02, 0.05, -2), gain: -2, excite: 0.002, cutoff: 2000 },
      contact: { length: 0.005, cutoff: 1800, gain: 0, hp: 120 },
    });
    K.addAt(out, K.unit(sole), 0, 0.7);
  }
  return out;
}
