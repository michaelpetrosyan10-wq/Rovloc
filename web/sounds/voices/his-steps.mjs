// his-steps.mjs: HIS footsteps (the player: "I also want his footsteps to be louder so people know when hes around ...
// his footsteps be scary"; of the candidates made from recordings they chose the lowest: "a dull body thud").
//
// A footfall of his is a body hitting the floor, not a shoe: a heavy punch into a body and a soft heavy impact, both
// played at about half speed (an octave down, twice as long: the weight of something eleven studs tall), a sub thump
// under them, and, quietly, a real footstep on the surface he walks on, slowed to his size, which gives each surface
// its character. No knock, no click: everything bright in the recordings is filtered away.
//
//   walking   heel, then the weight 55-85 ms later; slow and deliberate; on some steps his shroud drags after it
//   chasing   one hard strike, driven harder, shorter: he is running at you
//
// Five takes each, from five different punches, impacts and footsteps. The game maps its eight surfaces onto these
// five (SynthPresets.luau CreatureStepSurface); how far they carry is CreatureConfig.Footfalls.

import * as K from '../kit/index.mjs';
import { recorded, withSub } from '../lib/recipe.mjs';

const FAMILY = 'his-steps';
const IMPACT = 'kenney/impact-sounds';
const RPG = 'kenney/rpg-audio';
/** Take `i` (0-4, wrapping) of one of Kenney's impact recordings. */
const impact = (stem, i) => `${IMPACT}/${stem}_00${((i % 5) + 5) % 5}.ogg`;

/**
 * What each surface adds under the body's thud: the layers at the contact.
 * `g` is the surface's level for the pace (dB), `i` the take, `walking` the pace.
 * @type {Record<string, (i: number, g: number, walking: boolean) => import('../lib/recipe.mjs').Layer[]>}
 */
const SURFACE = {
  // a slab: the flat slap of a big sole, a little grit under it
  Concrete: (i, g) => [
    { src: impact('footstep_concrete', i), rate: [0.58, 0.66], lp: 2400, gain: g },
    { src: `${RPG}/footstep0${[0, 1, 3, 6, 9][i]}.ogg`, rate: [0.55, 0.62], lp: 1700, gain: g - 6, at: 0.012 },
  ],
  // glazed tile on the slab: harder and shorter
  Tile: (i, g) => [
    { src: impact('impactGeneric_light', i), rate: [0.7, 0.8], lp: 2600, gain: g - 1 },
    { src: impact('footstep_concrete', i + 2), rate: [0.74, 0.84], lp: 3000, gain: g - 4, at: 0.004 },
  ],
  // the stage's boards: a hollow boom, and now and then a board giving under him
  Wood: (i, g, walking) => [
    { src: impact('footstep_wood', i), rate: [0.92, 1.02], gain: g + 4 },
    { src: impact('impactPlank_medium', i), rate: [0.8, 0.9], lp: 1200, gain: g + 1, at: 0.008 },
    // (only when he walks: a board takes his weight and gives)
    ...(walking ? [{ src: `${RPG}/creak${1 + (i % 3)}.ogg`, rate: [0.4, 0.48], lp: 1100, gain: g - 12, at: [0.16, 0.24], fadeIn: 0.05, fadeOut: 0.1, chance: 0.5 }] : []),
  ],
  // a steel gantry: the plate booms, its ring slowed and dulled until it is only weight
  Metal: (i, g) => [
    { src: impact('impactPlate_heavy', i), rate: [0.56, 0.64], lp: [1300, 4], gain: g + 4 },
    { src: impact('impactMetal_heavy', i), rate: [0.38, 0.44], lp: [1000, 4], gain: g - 7, at: 0.006 },
  ],
  // carpet: everything swallowed but the weight
  Carpet: (i, g) => [
    { src: impact('footstep_carpet', [0, 1, 3, 0, 3][i]), rate: [0.78, 0.88], lp: 1800, gain: g + 4 },
    { src: impact('footstep_snow', [1, 2, 1, 2, 1][i]), rate: [0.55, 0.65], lp: 1200, gain: g + 1, at: 0.004 },
    { src: `${RPG}/cloth${1 + (i % 4)}.ogg`, rate: [0.5, 0.6], lp: 900, gain: g - 8, at: 0.01 },
  ],
};

/** Walking: how long after the heel the weight lands, per take (seconds). */
const HEEL_LEAD = [0.06, 0.075, 0.055, 0.085, 0.068];
/** The lead of take `i` at a pace on a surface: none when he chases, and none on carpet, which swallows the heel. */
const lead = (walking, surface, i) => (walking && surface !== 'Carpet' ? HEEL_LEAD[i] : 0);

/** The low-pass over the whole step, per surface (Hz): carpet swallows what a slab reflects. */
const DARKEN = { Concrete: 0, Tile: 0, Wood: 0, Metal: 0, Carpet: 1900 };

/**
 * @param {'walk'|'chase'} pace
 * @param {string} surface
 */
function step(pace, surface) {
  const walking = pace === 'walk';
  return recorded({
    name: `CreatureStep${walking ? 'Walk' : 'Chase'}${surface}`,
    title: `His footsteps, ${walking ? 'walking' : 'chasing'}, on ${WORDS[surface][0]}`,
    description: walking
      ? `Slow and far too heavy: a body coming down on ${WORDS[surface][0]} (${WORDS[surface][1]}).`
      : `Hard and fast, one strike after another: he is running at you on ${WORDS[surface][0]} (${WORDS[surface][1]}).`,
    family: FAMILY,
    group: 'reference',
    class: 'heavy',
    him: ['gait'],
    repeats: true,
    variants: 5,
    channels: 1,
    loop: null,
    space: 'dry',
    first: true,
    loudness: -14,
    board: 'His footsteps',
    layers: (variant) => {
      const i = variant - 1;
      // walking: the heel (the surface's own sound) lands first, the weight follows; chasing: all at once
      const weight = lead(walking, surface, i);
      const body = walking
        ? [
          { src: impact('impactPunch_heavy', i), rate: [0.52, 0.58], lp: 1600, eq: [['lowshelf', 95, 0.8, 2]], gain: 0, at: weight },
          // what a small speaker plays of the weight: two mid punches' bodies, one slowed with it, one less
          { src: impact('impactPunch_medium', i), rate: [0.55, 0.62], lp: 1300, gain: -2, at: weight },
          { src: impact('impactPunch_medium', i + 2), rate: [0.8, 0.9], hp: 140, lp: 1100, gain: -2, at: weight },
          // the soft impact under it, driven until its harmonics reach up out of the sub
          { src: impact('impactSoft_heavy', i + 2), rate: [0.47, 0.53], drive: 9, lp: 900, gain: -9, at: weight + 0.004 },
          // his shroud dragging after the step
          { src: `${RPG}/cloth${1 + ((i + 1) % 4)}.ogg`, rate: [0.4, 0.5], lp: 1300, gain: -24, at: [0.3, 0.42], fadeIn: 0.05, fadeOut: 0.1, chance: 0.6 },
        ]
        : [
          { src: impact('impactPunch_heavy', i + 2), rate: [0.6, 0.67], lp: 1900, drive: 5, gain: 0 },
          { src: impact('impactPunch_medium', i + 3), rate: [0.62, 0.7], lp: 1500, gain: -1 },
          { src: impact('impactPunch_medium', i + 1), rate: [0.86, 0.96], hp: 140, lp: 1300, gain: -1 },
          { src: impact('impactSoft_heavy', i), rate: [0.54, 0.6], drive: 9, lp: 900, gain: -10, at: 0.003 },
        ];
      return [...SURFACE[surface](i, walking ? -5 : -4, walking), ...body];
    },
    finish: (ctx, mix) => {
      const { sr } = ctx;
      const r = ctx.rng.fork('finish');
      const weight = lead(walking, surface, ctx.variant - 1);
      let x = withSub(mix, sr, { f0: r.range(52, 58), f1: r.range(36, 41), drop: 0.08, t60: walking ? r.range(0.42, 0.55) : r.range(0.26, 0.34), drive: 4, gain: -12, at: weight });
      if (DARKEN[surface]) x = K.butter(x, sr, 'lowpass', DARKEN[surface], 2);
      // the weight: the whole step driven into a soft curve until its body fills in under its peak, which is also what
      // puts the sub's harmonics where a laptop speaker can play them
      return K.densify(K.fade(x, sr, 0, 0.08), sr, 12);
    },
  });
}

const WORDS = {
  Concrete: ['concrete', 'the corridors and the basement'],
  Tile: ['tile', 'the hallways and the washrooms'],
  Wood: ['wooden boards', 'the auditorium stage'],
  Metal: ['steel', 'gantries, gratings and stairs'],
  Carpet: ['carpet', 'the offices and the library'],
};

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [];
for (const surface of Object.keys(WORDS)) for (const pace of /** @type {const} */ (['walk', 'chase'])) voices.push(step(pace, surface));
