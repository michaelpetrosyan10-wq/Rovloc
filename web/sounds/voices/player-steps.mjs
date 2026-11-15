// player-steps.mjs: the players' own bodies on the move: a kid's footsteps on the game's eight surfaces (walking and
// sprinting, 5 variants each: small, dry, close, clearly lighter than his: no sub drop, a short sole slap and the
// floor's quick answer), and the parkour sounds (web/src/engine/parkour.js): the hard landing, the slide, the leap.
// FootstepGlass and FootstepSprintGlass live with the glass (glass.mjs) and share stepFor() from here.

import * as K from '../kit/index.mjs';

const FAMILY = 'player-steps';
/** How far a player's steps carry: a few rooms, never as far as his (docs/SOUND.md 6). */
export const PLAYER_CARRY = Object.freeze({ ref: 4, max: 60, rolloff: 1, fade: 0.67 });

/**
 * A surface's answer to a light foot: [modes, contact cutoff Hz, extra texture builder or null].
 * @param {string} surface
 * @param {K.Rng} r
 * @param {number} sr
 * @param {boolean} sprint
 * @returns {{modes: K.Mode[], cutoff: number, bodyGain: number, texture: null|{buffer: Float32Array, gain: number, offset?: number}}}
 */
function surfaceOf(surface, r, sr, sprint) {
  switch (surface) {
    case 'Concrete':
      return { modes: K.scatterModes(r, 6, 220, 900, 0.025, 0.06, -2), cutoff: 2600, bodyGain: -4,
        texture: { buffer: K.grit(sr, r.fork('sand'), { count: r.int(5, 12), spread: 0.05, freq: [1500, 5000] }), gain: -16 } };
    case 'Tile':
      return { modes: [...K.scatterModes(r, 5, 260, 900, 0.02, 0.05, -2), ...K.scatterModes(r, 4, 1400, 3200, 0.012, 0.03, -4)], cutoff: 3200, bodyGain: -3, texture: null };
    case 'Wood': // classroom floor, boards on joists: a hollow knock
      return { modes: [...K.scatterModes(r, 4, 140, 320, 0.06, 0.12, 0), ...K.scatterModes(r, 4, 400, 1100, 0.02, 0.05, -3)], cutoff: 2000, bodyGain: 0, texture: null };
    case 'Metal': { // a grating or a steel stair: a short plate ring and a loose rattle
      const gains = K.strikeGains(12, r.range(0.1, 0.9), r.range(0.1, 0.9));
      const plate = K.modesFrom(r.range(380, 520), K.plateRatios(12, 1.41), { t60: 0.1, damp: 0.4, tilt: -2, gains, detune: 0.04, rng: r });
      plate[0].gain = (plate[0].gain ?? 1) * 0.35; // pinned at its edges
      return { modes: [...K.scatterModes(r, 4, 200, 500, 0.04, 0.08, 0), ...plate], cutoff: 3000, bodyGain: -3, texture: null };
    }
    case 'Carpet': // a muffled pat
      return { modes: K.scatterModes(r, 4, 120, 380, 0.02, 0.04, -3), cutoff: 900, bodyGain: -6,
        texture: { buffer: K.svf(K.burst(sr, r.fork('fibre'), { length: 0.03, cutoff: 3000, hp: 600 }), sr, 'bandpass', 1500, 0.6), gain: -18 } };
    case 'Grass': // blades and soil: a soft swish and a little crunch
      return { modes: K.scatterModes(r, 3, 90, 240, 0.02, 0.04, -2), cutoff: 700, bodyGain: -8,
        texture: { buffer: K.butter(K.grit(sr, r.fork('blades'), { count: r.int(20, 34), spread: sprint ? 0.08 : 0.12, freq: [450, 2600], q: 0.8, length: [0.003, 0.009] }), sr, 'lowpass', 3000, 2), gain: -9 } };
    default: { // Water: a puddle on the floor: a slap, a splash of droplets, a few bubbles
      const n = Math.round(0.3 * sr);
      const drops = K.shower(n, sr, K.poissonTimes(r.fork('t'), 0.22, (t) => 160 * Math.exp(-t / 0.06), 160), () => ({
        grain: K.bubble(sr, r, { freq: r.range(900, 3200), t60: r.range(0.012, 0.03), rise: r.range(0.2, 0.8) }),
        gain: r.range(0.2, 1),
      }));
      const spray = K.svf(K.burst(sr, r.fork('spray'), { length: 0.05, cutoff: 6000, hp: 900 }), sr, 'bandpass', 2400, 0.5);
      K.addAt(drops, K.unit(spray), 0, 0.8);
      return { modes: K.scatterModes(r, 3, 110, 300, 0.02, 0.04, -3), cutoff: 1400, bodyGain: -8, texture: { buffer: drops, gain: -3 } };
    }
  }
}

/**
 * One footstep of a player.
 * @param {string} surface
 * @param {boolean} sprint
 * @returns {import('../lib/voices.mjs').Voice['render']}
 */
export function stepFor(surface, sprint) {
  return ({ sr, rng }) => {
    const r = rng.fork('floor');
    const s = surfaceOf(surface, r, sr, sprint);
    const g = rng.fork('gait');
    const sound = K.footfall(sr, g, {
      length: 0.6,
      // a walking heel just before the ball of the foot; a sprint lands on the ball alone
      heel: sprint ? undefined : { delay: g.range(0.025, 0.045), gain: -5, cutoff: 1200, length: 0.003 },
      thump: { f0: g.range(95, 110), f1: g.range(70, 80), drop: 0.02, t60: 0.06, drive: 1.5, gain: -16 },
      body: { modes: s.modes, gain: s.bodyGain, excite: 0.002, cutoff: s.cutoff },
      contact: { length: sprint ? 0.004 : 0.006, cutoff: s.cutoff * g.range(0.8, 1.2), gain: 0, hp: 120 },
      texture: s.texture ?? undefined,
      after: sprint && g.chance(0.6) ? { buffer: scuff(sr, g.fork('scuff')), gain: -14, offset: g.range(0.01, 0.03) } : undefined,
    });
    return sound;
  };
}

/**
 * A rubber sole scuffing as it pushes off: a short stick-slip squeak-grind, dark.
 * @param {number} sr
 * @param {K.Rng} r
 */
function scuff(sr, r) {
  const seconds = r.range(0.05, 0.1);
  const n = Math.round(seconds * sr);
  const push = K.segments(n, sr, [[0, 0], [seconds * 0.3, 1], [seconds, 0]]);
  const slips = K.stickSlip(n, sr, { velocity: push, force: 0.5, stiffness: 300, muS: 1, muD: 0.6, irregularity: 0.6, roughness: 0.5, rng: r.fork('slips') });
  const out = K.modal(slips, sr, K.scatterModes(r, 5, 600, 2200, 0.008, 0.02, -2), n + Math.round(0.02 * sr));
  return K.fade(K.butter(out, sr, 'lowpass', 2500, 2), sr, 0.002, 0.01);
}

const SURFACES = [
  ['Concrete', 'concrete'], ['Tile', 'tile'], ['Wood', 'wooden floor'], ['Metal', 'metal'], ['Carpet', 'carpet'],
  ['Grass', 'grass and gravel'], ['Water', 'water'],
];

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [];
for (const [surface, words] of SURFACES) {
  for (const sprint of [false, true]) {
    voices.push({
      name: `Footstep${sprint ? 'Sprint' : ''}${surface}`,
      title: `Your footsteps, ${sprint ? 'sprinting' : 'walking'}, on ${words}`,
      description: sprint ? `A kid running flat out on ${words}: quick, light, a scuff as the foot pushes off.` : `A kid walking on ${words}: small, dry, close. Nothing like his.`,
      family: FAMILY,
      group: 'reference',
      class: 'light',
      repeats: true,
      variants: 5,
      channels: 1,
      loop: null,
      space: 'dry',
      loudness: sprint ? -28 : -30,
      carry: PLAYER_CARRY,
      board: 'Your footsteps',
      render: stepFor(surface, sprint),
    });
  }
}

voices.push({
  name: 'HardLanding',
  title: 'You land hard',
  description: 'A drop from a height: your whole body hitting the floor, your bag thumping, the wind knocked out of you.',
  family: FAMILY,
  group: 'reference',
  class: 'body',
  variants: 4,
  channels: 1,
  loop: null,
  space: 'dry',
  loudness: -23,
  carry: Object.freeze({ ref: 6, max: 90, rolloff: 1, fade: 0.67 }),
  board: 'Your footsteps',
  render: ({ sr, rng }) => {
    const r = rng.fork('land');
    const both = K.footfall(sr, r.fork('feet'), {
      length: 0.9,
      heel: { delay: r.range(0.012, 0.025), gain: -3, cutoff: 1500, length: 0.004 },
      thump: { f0: 85, f1: 58, drop: 0.03, t60: 0.18, drive: 2.5, gain: -6 },
      body: { modes: K.scatterModes(r, 7, 140, 700, 0.04, 0.1, -1), gain: 0, excite: 0.006, cutoff: 1800 },
      contact: { length: 0.012, cutoff: 1600, gain: -2 },
    });
    // the backpack and its contents a beat later
    const bag = K.modal(K.burst(sr, r.fork('bag'), { length: 0.02, cutoff: 1200, hp: 100 }), sr, K.scatterModes(r, 5, 180, 900, 0.03, 0.07, -2), Math.round(0.25 * sr));
    K.addAt(both, K.unit(bag), r.range(0.05, 0.08) * sr, 0.35);
    // the breath knocked out: a short voiced "huh" through a small throat (a kid's)
    const n = Math.round(0.28 * sr);
    const oof = K.breath(n, sr, { rng: r.fork('oof'), vowel: 'uh', scale: 1.25, voiced: 0.5, f0: r.range(190, 240) });
    K.mul(oof, K.segments(n, sr, [[0, 0], [0.02, 1, 2], [0.28, 0, 3]]));
    K.addAt(both, K.unit(oof), r.range(0.06, 0.1) * sr, 0.3);
    return K.densify(both, sr, 21);
  },
});

voices.push({
  name: 'SlideScrape',
  title: 'You slide',
  description: 'Sliding along the floor on your side: shoes and clothes grinding over grit for most of a second.',
  family: FAMILY,
  group: 'reference',
  class: 'friction',
  variants: 4,
  channels: 1,
  loop: null,
  space: 'dry',
  loudness: -24,
  carry: PLAYER_CARRY,
  board: 'Your footsteps',
  render: ({ sr, rng }) => {
    const seconds = rng.range(0.65, 0.8);
    const n = Math.round(seconds * sr);
    const r = rng.fork('slide');
    // fast at the start, scrubbing off speed
    const speed = K.segments(n, sr, [[0, 0], [0.03, 1, 3], [seconds * 0.7, 0.45], [seconds, 0, -2]]);
    const rough = K.smoothRandom(n, sr, 25, r.fork('rough'), 0.3, 1);
    const vel = new Float32Array(n);
    for (let i = 0; i < n; i++) vel[i] = speed[i] * 3 * rough[i];
    const slips = K.stickSlip(n, sr, { velocity: vel, force: 0.8, stiffness: 120, muS: 1, muD: 0.7, irregularity: 0.7, roughness: 0.8, grain: 120, rng: r.fork('slips') });
    const grind = K.modal(slips, sr, [...K.scatterModes(r, 6, 180, 700, 0.02, 0.05, -1), ...K.scatterModes(r, 5, 900, 2600, 0.008, 0.02, -4)], n);
    // cloth on the floor: a broad, dark hiss following the speed
    const cloth = K.svf(K.pink(n, r.fork('cloth')), sr, 'bandpass', 900, 0.5);
    K.mul(cloth, speed);
    const grains = K.grit(sr, r.fork('grit'), { count: r.int(25, 40), spread: seconds * 0.8, freq: [800, 4000] });
    const out = K.unit(grind);
    K.addAt(out, K.unit(cloth), 0, 0.5);
    K.addAt(out, grains, 0, 0.25);
    // the body going down onto the floor at the start
    K.addAt(out, K.unit(K.modal(K.burst(sr, r.fork('down'), { length: 0.01, cutoff: 900 }), sr, K.scatterModes(r, 4, 120, 400, 0.05, 0.1, 0), Math.round(0.2 * sr))), 0, 0.6);
    return K.fade(K.butter(out, sr, 'lowpass', 3000, 2), sr, 0.001, 0.05);
  },
});

voices.push({
  name: 'LeapWhoosh',
  title: 'You leap',
  description: 'A running jump across a gap: the air rushing past your ears, rising and falling with the arc.',
  family: FAMILY,
  group: 'reference',
  class: 'swell',
  variants: 3,
  channels: 1,
  loop: null,
  space: 'dry',
  loudness: -26,
  carry: PLAYER_CARRY,
  board: 'Your footsteps',
  render: ({ sr, rng }) => {
    const seconds = rng.range(0.55, 0.65);
    const n = Math.round(seconds * sr);
    const r = rng.fork('air');
    const arc = K.segments(n, sr, [[0, 0], [seconds * r.range(0.45, 0.55), 1, -3], [seconds, 0, 2]]);
    // turbulence around the head: a band of noise whose centre rides the speed, buffeted
    const buffet = K.smoothRandom(n, sr, 14, r.fork('buffet'), 0.5, 1);
    const centre = new Float32Array(n);
    for (let i = 0; i < n; i++) centre[i] = 250 + 900 * arc[i];
    const rush = K.svf(K.pink(n, r.fork('rush')), sr, 'bandpass', centre, 0.9);
    const low = K.svf(K.brown(n, sr, r.fork('low')), sr, 'lowpass', 220, 0.7);
    const out = new Float32Array(n);
    K.unit(rush);
    K.unit(low);
    for (let i = 0; i < n; i++) out[i] = (rush[i] + 0.5 * low[i]) * arc[i] * buffet[i];
    return K.fade(out, sr, 0.03, 0.06);
  },
});
