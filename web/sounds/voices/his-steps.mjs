// his-steps.mjs: HIS footsteps (the player's first request: "his footsteps to be louder so people know when hes
// around"). An 11-stud body: every footfall is a saturated sub thump (60 -> 42 Hz, the mass settling), the floor's
// own low-mid modes answering (130-420 Hz: what a laptop speaker plays of the weight), the dull slap of the contact,
// and on some variants an after-sound (grit, the boards creaking, the trailing foot dragging). Walking is heel then
// weight, slow and deliberate; chasing is one hard strike, closer, less tail. The same creature on every surface.
//
// Today the game plays the PLAYERS' footstep presets for him (creature/view.js _onFootstep: Footstep[Sprint]<Surface>),
// so he sounds like a player; these are his own (spec I1: what sounds like him is him). The run-time switch maps the
// game's eight surfaces onto his five: Concrete, Carpet -> Concrete; Tile, Glass, Water -> Tile; Wood -> Wood;
// Metal -> Metal; Grass -> Gravel. In a duct (on all fours) he plays CreatureStepDuct.

import * as K from '../kit/index.mjs';

const FAMILY = 'his-steps';
/** How far his steps carry (docs/SOUND.md 6): further than anything a player does. */
const CARRY = Object.freeze({ ref: 10, max: 140, rolloff: 0.9, fade: 0.7 });

/** Gait parameters per pace. */
const PACE = {
  walk: { heel: [0.055, 0.095], heelGain: -5, drive: 3, thumpGain: -8, t60: [0.38, 0.55], bodyGain: 0, contact: [0.014, 1400, -3], afterChance: 0.8, length: 1.3, loudness: -17 },
  chase: { heel: null, heelGain: 0, drive: 2.5, thumpGain: -14, t60: [0.24, 0.32], bodyGain: 0, contact: [0.016, 2000, -2], afterChance: 0.35, length: 0.8, loudness: -18 },
};

/**
 * The floor's modes for a surface (fresh per variant: a different spot on the floor, so different detuning and
 * strike gains).
 * @param {string} surface
 * @param {K.Rng} r
 */
function floorModes(surface, r) {
  switch (surface) {
    case 'Concrete': // a slab on grade: a few dull modes, well damped
      return K.scatterModes(r, 8, 130, 440, 0.08, 0.18, -1);
    case 'Tile': // the same slab, glazed tiles bedded on it: a little higher and harder
      return [...K.scatterModes(r, 8, 160, 500, 0.07, 0.16, -1), ...K.scatterModes(r, 3, 900, 1600, 0.03, 0.06, -6)];
    case 'Wood': // the stage: hollow boards on joists, a boomy low body that rings longer
      return [...K.scatterModes(r, 4, 85, 210, 0.25, 0.42, -1), ...K.scatterModes(r, 5, 230, 560, 0.1, 0.2, -1)];
    case 'Metal': { // a steel grating on a gantry: a dense inharmonic plate over a low frame
      const base = r.range(230, 290);
      const gains = K.strikeGains(14, r.range(0.15, 0.85), r.range(0.2, 0.8));
      const plate = K.modesFrom(base, K.plateRatios(14, 1.37), { t60: 0.35, damp: 0.45, tilt: -2.5, gains, detune: 0.03, rng: r });
      // the grating is welded into its frame along every edge: its fundamental is pinned, the upper modes ring
      plate[0].gain = (plate[0].gain ?? 1) * 0.3;
      plate[1].gain = (plate[1].gain ?? 1) * 0.6;
      return [...K.scatterModes(r, 5, 110, 300, 0.14, 0.26, -1), ...plate];
    }
    default: // gravel over a roof deck: little ring, the deck's thud
      return K.scatterModes(r, 4, 90, 260, 0.06, 0.14, -2);
  }
}

/**
 * The trailing foot dragging: friction slips under a slowly sliding sole, through the floor's modes and a band of
 * scraped noise, swelling and dying with the slide.
 * @param {number} sr
 * @param {K.Rng} r
 * @param {number} seconds
 * @param {K.Mode[]} modes
 */
function drag(sr, r, seconds, modes) {
  const n = Math.round(seconds * sr);
  const slide = K.segments(n, sr, [[0, 0], [seconds * r.range(0.25, 0.45), 1, 2], [seconds, 0, -2]]);
  // the sole's pressure is never even: it catches and lets go
  const catches = K.smoothRandom(n, sr, 35, r.fork('catch'), 0.05, 1);
  const vel = new Float32Array(n);
  const press = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    vel[i] = slide[i] * (0.3 + 1.6 * catches[i] ** 2);
    press[i] = 0.4 + 0.8 * (1 - catches[i]);
  }
  // tens to a few hundred slips a second: a scuff you can count into, not a hiss
  const slips = K.stickSlip(n, sr, { velocity: vel, force: press, stiffness: 45, muS: 1, muD: 0.65, irregularity: 0.7, roughness: 0.8, grain: 70, rng: r.fork('slips') });
  const grind = K.modal(slips, sr, [...modes.map((m) => ({ ...m, t60: m.t60 * 0.3 })), ...K.scatterModes(r, 5, 450, 1300, 0.015, 0.04, -3)], n);
  const scrape = K.svf(K.pink(n, r.fork('scrape')), sr, 'bandpass', r.range(450, 800), 1.4);
  for (let i = 0; i < n; i++) scrape[i] *= slide[i] * catches[i] ** 3;
  K.unit(grind);
  K.unit(scrape);
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = grind[i] + 0.3 * scrape[i];
  return K.fade(K.butter(out, sr, 'lowpass', 1600, 2), sr, 0.01, 0.05);
}

/**
 * Boards creaking as the weight settles: slow heavy stick-slip into the boards' upper modes.
 * @param {number} sr
 * @param {K.Rng} r
 */
function creak(sr, r) {
  const seconds = r.range(0.22, 0.4);
  const n = Math.round(seconds * sr);
  const push = K.segments(n, sr, [[0, 0.2], [seconds * 0.4, 1], [seconds, 0.1]]);
  const wander = K.smoothRandom(n, sr, 12, r.fork('wander'), 0.4, 1.3);
  for (let i = 0; i < n; i++) push[i] *= wander[i];
  const slips = K.stickSlip(n, sr, { velocity: push, force: 1.4, stiffness: r.range(40, 70), muS: 1, muD: 0.55, irregularity: 0.65, rng: r.fork('slips') });
  const modes = K.scatterModes(r, 7, 260, 900, 0.03, 0.08, -2);
  const out = K.modal(slips, sr, modes, n + Math.round(0.08 * sr));
  return K.fade(out, sr, 0.004, 0.04);
}

/**
 * A grating's bars buzzing after the strike: a quick decaying train of small knocks of the loose bars.
 * @param {number} sr
 * @param {K.Rng} r
 */
function rattle(sr, r) {
  const n = Math.round(0.35 * sr);
  const out = new Float32Array(n);
  let t = r.range(0.015, 0.03);
  let level = 1;
  while (t < 0.3 && level > 0.05) {
    const knock = K.burst(sr, r.fork(`k${t.toFixed(4)}`), { length: 0.0015, cutoff: 5000, hp: 400 });
    const ring = K.modal(knock, sr, K.scatterModes(r, 4, 700, 2600, 0.02, 0.05, -2), Math.round(0.06 * sr));
    K.addAt(out, K.unit(ring), t * sr, level);
    t += r.range(0.018, 0.04);
    level *= r.range(0.55, 0.8);
  }
  return out;
}

/**
 * One footfall of his on a surface at a pace.
 * @param {'walk'|'chase'} pace
 * @param {string} surface
 */
function step(pace, surface) {
  const P = PACE[pace];
  return ({ sr, rng, variant }) => {
    const r = rng.fork('floor');
    const modes = floorModes(surface, r);
    const after = r.fork('after');
    let texture;
    let afterPart;
    // what the surface adds at the contact
    if (surface === 'Concrete') texture = { buffer: K.grit(sr, r.fork('sand'), { count: r.int(8, 16), spread: r.range(0.04, 0.09), freq: [900, 4000], q: 1.2 }), gain: -18 };
    if (surface === 'Tile') texture = { buffer: K.modal(K.burst(sr, r.fork('tile'), { length: 0.0012, cutoff: 6000, hp: 1200 }), sr, K.scatterModes(r, 5, 1600, 3600, 0.01, 0.025, -2), Math.round(0.05 * sr)), gain: -13 };
    if (surface === 'Gravel') texture = { buffer: K.grit(sr, r.fork('grit'), { count: pace === 'walk' ? r.int(45, 70) : r.int(30, 45), spread: pace === 'walk' ? r.range(0.18, 0.28) : r.range(0.1, 0.16), freq: [500, 3800], q: 1.4 }), gain: -6 };
    if (surface === 'Metal') texture = { buffer: rattle(sr, r.fork('rattle')), gain: -11, offset: 0.005 };
    // the after-sound: what each surface does once the weight is on it
    if (after.chance(P.afterChance)) {
      if (surface === 'Wood') afterPart = { buffer: creak(sr, after), gain: -14, offset: after.range(0.07, 0.18) };
      else if (surface === 'Gravel') afterPart = { buffer: K.grit(sr, after.fork('shift'), { count: after.int(12, 22), spread: 0.25, freq: [400, 2600] }), gain: -14, offset: after.range(0.2, 0.32) };
      else if (surface === 'Metal') afterPart = { buffer: creak(sr, after), gain: -20, offset: after.range(0.1, 0.2) };
      else afterPart = { buffer: drag(sr, after, after.range(0.22, 0.38), modes), gain: pace === 'walk' ? -18 : -22, offset: after.range(0.2, 0.36) };
    }
    const g = rng.fork('gait');
    const sound = K.footfall(sr, g, {
      length: P.length,
      heel: P.heel ? { delay: g.range(P.heel[0], P.heel[1]), gain: P.heelGain, cutoff: 700 } : undefined,
      thump: { f0: g.range(56, 64), f1: g.range(40, 45), drop: g.range(0.05, 0.08), t60: g.range(P.t60[0], P.t60[1]), drive: P.drive, gain: P.thumpGain },
      body: { modes, gain: P.bodyGain, excite: pace === 'walk' ? 0.006 : 0.004, cutoff: 1600 },
      contact: { length: P.contact[0], cutoff: P.contact[1] * g.range(0.85, 1.15), gain: P.contact[2] },
      texture,
      after: afterPart,
    });
    // now and then the mask knocks as he lands (his signature riding on the gait)
    if (variant % 2 === 0) K.addAt(sound, K.chatter(Math.round(0.4 * sr), sr, rng.fork('mask'), { rate: 8, from: 0.01, to: 0.08, cluster: [1, 3], t60: [0.01, 0.025] }), (P.heel ? 0.07 : 0) * sr, 0.03);
    // the weight: the whole step driven into a soft curve until its body fills in under its peak (a big thing's does),
    // so it is loud at -1 dBTP without the limiter, and denser on a small speaker
    return K.densify(sound, sr, -1 - P.loudness);
  };
}

const SURFACES = [
  ['Concrete', 'concrete', 'the corridors and the basement'],
  ['Tile', 'tile', 'the hallways and the washrooms'],
  ['Wood', 'wooden boards', 'the auditorium stage'],
  ['Metal', 'a metal grating', 'gantries and catwalks'],
  ['Gravel', 'gravel', 'the roofs'],
];

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [];
for (const [surface, words, where] of SURFACES) {
  for (const pace of /** @type {const} */ (['walk', 'chase'])) {
    voices.push({
      name: `CreatureStep${pace === 'walk' ? 'Walk' : 'Chase'}${surface}`,
      title: `His footsteps, ${pace === 'walk' ? 'walking' : 'chasing'}, on ${words}`,
      description: pace === 'walk'
        ? `Slow, heavy, heel then weight: something far too big walking on ${words} (${where}).`
        : `Hard and fast, one strike after another: he is running at you on ${words} (${where}).`,
      family: FAMILY,
      group: 'reference',
      class: 'heavy',
      him: ['gait'],
      repeats: true,
      variants: 5,
      channels: 1,
      loop: null,
      space: 'dry',
      loudness: PACE[pace].loudness,
      carry: CARRY,
      board: 'His footsteps',
      render: step(pace, surface),
    });
  }
}

/** On all fours in a sheet-metal duct: palms and knees thumping the panels, the mask knocking the steel. */
voices.push({
  name: 'CreatureStepDuct',
  title: 'Him crawling in a vent',
  description: 'Something huge on all fours inside the ducts: the steel booming under its weight, the mask knocking.',
  family: FAMILY,
  group: 'reference',
  class: 'heavy',
  him: ['gait', 'porcelain'],
  repeats: true,
  variants: 5,
  channels: 1,
  loop: null,
  space: 'dry',
  loudness: -18,
  carry: CARRY,
  board: 'His footsteps',
  render: ({ sr, rng }) => {
    const r = rng.fork('duct');
    // the panel oil-cans: a low sheet-steel boom (dense plate modes from 70 Hz) and the duct's air column
    const panel = K.modesFrom(r.range(68, 84), K.plateRatios(16, 1.618), { t60: 0.5, damp: 0.6, tilt: -3.5, gains: K.strikeGains(16, r.range(0.2, 0.8), r.range(0.2, 0.8)), detune: 0.02, rng: r });
    const sound = K.footfall(sr, r.fork('palm'), {
      length: 1.0,
      heel: { delay: r.range(0.03, 0.06), gain: -6, cutoff: 600, length: 0.006 },
      thump: { f0: 58, f1: 44, drop: 0.05, t60: 0.3, drive: 3, gain: -1 },
      body: { modes: [...K.scatterModes(r, 3, 120, 300, 0.15, 0.3, 0), ...panel], gain: 0, excite: 0.007, cutoff: 1200 },
      contact: { length: 0.01, cutoff: 800, gain: -8 },
    });
    const duct = K.comb(sound, sr, { delay: r.range(0.0045, 0.006), feedback: 0.4, damp: 0.5 });
    K.addAt(K.unit(duct), K.chatter(Math.round(0.6 * sr), sr, r.fork('mask'), { rate: 10, from: 0.02, to: 0.3, cluster: [2, 4] }), 0, 0.08);
    return K.densify(duct, sr, 17);
  },
});
