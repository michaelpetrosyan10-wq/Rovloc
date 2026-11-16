// player-steps.mjs: YOUR footsteps on the eight surfaces, walking and sprinting, and what your body does when it
// lands, slides and leaps. Real footsteps on each surface (Kenney's RPG and impact sets, the leather-and-cloth and
// wood-stone-gravel packs), small and dull: a shoe, never a knock or a click (everything over about 3 kHz is rolled
// away), and far under his (the audit: at least 10 dB at every distance). Sprinting is the same foot landing harder
// and faster, with a scuff.
//
// None of these recordings is in any of his sounds (spec I1: what sounds like him is him).

import * as K from '../kit/index.mjs';
import { recorded, withSub } from '../lib/recipe.mjs';

const FAMILY = 'player-steps';
const RPG = 'kenney/rpg-audio';
const IMPACT = 'kenney/impact-sounds';
const STEPS = 'oga/different-steps-on-wood-stone-leaves-gravel-and-mud';
const ARMOR = 'oga/footsteps-leather-cloth-armor';
const SPLASH = 'oga/40-cc0-water-splash-slime-sfx';

/** The five stone-floor takes of Kenney's RPG set that his footsteps do not use. */
const FLOOR = [2, 4, 5, 7, 8].map((n) => `${RPG}/footstep0${n}.ogg`);

/**
 * Each surface's layers for take `i` (0-4): `fast` is a sprint.
 * @type {Record<string, (i: number, fast: boolean) => import('../lib/recipe.mjs').Layer[]>}
 */
const SURFACE = {
  // the shoe on a slab
  Concrete: (i, fast) => [
    { src: FLOOR[i], rate: fast ? [1.0, 1.06] : [0.92, 0.98], lp: 2600, gain: 0 },
    { src: `${STEPS}/stone01.ogg`, rate: [0.9, 1.0], hp: 200, lp: 2400, gain: -14, at: 0.004 },
  ],
  // glazed tile: harder and shorter, a little ring of the tile
  Tile: (i, fast) => [
    { src: FLOOR[(i + 2) % 5], rate: fast ? [1.1, 1.16] : [1.04, 1.1], lp: 3000, gain: 0 },
    { src: `${STEPS}/stone01.ogg`, rate: [1.0, 1.1], hp: 400, lp: 2800, gain: -9, at: 0.002 },
  ],
  // boards: the hollow of the board under the shoe
  Wood: (i, fast) => [
    { src: `${IMPACT}/impactWood_light_00${i}.ogg`, rate: (fast ? 0.86 : 0.78) * (1 + 0.06 * (i - 2)), lp: 2200, gain: [-2, 0, -4, 1, -1][i] },
    { src: `${STEPS}/wood0${1 + (i % 3)}.ogg`, rate: 0.9 + 0.05 * i, lp: 1800, gain: [0, -4, -1, -6, -2][i], at: 0.003 },
    { src: FLOOR[i], rate: 0.9, hp: 250, lp: 2400, gain: -9, at: 0.006 },
  ],
  // steel grating
  Metal: (i, fast) => [
    // three steps on steel and two light blows on a plate, the plates darker (a sole, never a knock)
    { src: [`${ARMOR}/step_metal.ogg`, `${ARMOR}/step_metal (2).ogg`, `${IMPACT}/impactPlate_light_002.ogg`, `${ARMOR}/step_metal (4).ogg`, `${IMPACT}/impactPlate_light_004.ogg`][i], rate: fast ? [0.92, 0.98] : [0.84, 0.9], lp: [2400, 2400, 1400, 2400, 1400][i], trim: true, gain: 0, at: 0.004 },
    { src: FLOOR[(i + 1) % 5], rate: 0.95, lp: 1600, gain: -5 },
  ],
  // carpet: the weight and the pile
  Carpet: (i, fast) => [
    { src: [`${IMPACT}/footstep_carpet_002.ogg`, `${IMPACT}/footstep_snow_000.ogg`, `${IMPACT}/footstep_snow_004.ogg`, `${IMPACT}/footstep_snow_003.ogg`, `${ARMOR}/step_lth4.ogg`][i], rate: fast ? [0.95, 1.0] : [0.86, 0.92], lp: 1800, gain: 0 },
    { src: `${ARMOR}/step_cloth${1 + (i % 4)}.ogg`, rate: 0.9, lp: 1400, gain: -8 },
  ],
  // grass and earth: the outdoor stretch
  Grass: (i, fast) => [
    { src: `${IMPACT}/footstep_grass_00${i}.ogg`, rate: (fast ? 1.02 : 0.93) * (1 + 0.07 * (i - 2)), lp: 2600, gain: 0 },
    { src: [`${STEPS}/leaves01.ogg`, `${STEPS}/mud02.ogg`, `${STEPS}/leaves02.ogg`, `${STEPS}/gravel.ogg`, `${STEPS}/mud02.ogg`][i], from: 0, to: 0.35, rate: 0.8 + 0.05 * i, lp: 2200, gain: [-8, -6, -9, -12, -5][i] },
  ],
  // shallow water on the floor
  Water: (i, fast) => [
    { src: `${SPLASH}/splash_${['06', '09', '10', '14', '15'][i]}.ogg`, rate: fast ? [0.9, 0.96] : [0.8, 0.86], lp: 2400, trim: true, gain: -1, at: 0.012 },
    { src: FLOOR[i], rate: 0.95, lp: 1800, trim: true, gain: 0 },
  ],
};

const WORDS = {
  Concrete: 'concrete',
  Tile: 'tile',
  Wood: 'wooden boards',
  Metal: 'a steel grating',
  Carpet: 'carpet',
  Grass: 'grass and earth',
  Water: 'shallow water',
};

/**
 * @param {string} surface
 * @param {boolean} fast
 */
function step(surface, fast) {
  return recorded({
    name: `Footstep${fast ? 'Sprint' : ''}${surface}`,
    title: `Your footsteps, ${fast ? 'running' : 'walking'}, on ${WORDS[surface]}`,
    description: fast ? `You running on ${WORDS[surface]}: quick, harder steps.` : `You walking on ${WORDS[surface]}: small, dull steps.`,
    family: FAMILY,
    group: 'reference',
    class: 'light',
    repeats: true,
    variants: 5,
    channels: 1,
    loop: null,
    space: 'dry',
    first: true,
    loudness: fast ? -27 : -30,
    board: 'Your footsteps',
    layers: (variant) => {
      const i = variant - 1;
      const layers = SURFACE[surface](i, fast);
      // a sprint drags the sole off the floor after it lands
      if (fast) layers.push({ src: `${ARMOR}/step_lth${[1, 2, 33, 4, 1][i]}.ogg`, rate: 1.1, hp: 300, lp: 2400, gain: -14, at: 0.05 });
      return layers;
    },
    finish: (ctx, mix) => K.fade(mix, ctx.sr, 0, 0.04),
  });
}

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [];
for (const surface of Object.keys(SURFACE)) for (const fast of [false, true]) voices.push(step(surface, fast));

voices.push(
  recorded({
    name: 'HardLanding',
    title: 'A hard landing',
    description: 'You drop from a height and land hard: both feet and your body taking it.',
    family: FAMILY,
    group: 'reference',
    class: 'body',
    variants: 4,
    channels: 1,
    loop: null,
    space: 'dry',
    loudness: -22,
    board: 'Your footsteps',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: [`oga/jump-landing/Jump 1.wav`, `oga/jump-landing/Jump 2.wav`, `oga/jump-landing/Jump 3.wav`, 'oga/75-cc0-breaking-falling-hit-sfx/bfh1_hit_06.ogg'][i], rate: [0.86, 0.92], hp: 100, lp: 2400, trim: true, gain: 0 },
        { src: FLOOR[i], rate: 0.95, lp: 2400, trim: true, gain: [-2, -5, -3, -6][i] },
        { src: `${IMPACT}/impactSoft_medium_00${i}.ogg`, rate: 0.75, hp: 90, lp: 1400, gain: -4, at: 0.003 },
        { src: FLOOR[(i + 3) % 5], rate: 0.85, lp: 2000, gain: -6, at: 0.012 },
        { src: `${ARMOR}/step_cloth${1 + i}.ogg`, rate: 0.8, lp: 1600, gain: -10, at: 0.03 },
      ];
    },
    finish: (ctx, mix) => withSub(mix, ctx.sr, { f0: 72, f1: 52, t60: 0.18, gain: -14 }),
  }),
  recorded({
    name: 'SlideScrape',
    title: 'Your slide',
    description: 'You slide along the floor: shoes and clothes dragging.',
    family: FAMILY,
    group: 'reference',
    class: 'friction',
    variants: 4,
    channels: 1,
    loop: null,
    space: 'dry',
    loudness: -25,
    board: 'Your footsteps',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `oga/scrapes/scrape-${1 + i}.ogg`, from: 0, to: 0.9, rate: [0.8, 0.86], hp: 120, lp: 2200, gain: 0, fadeIn: 0.02, fadeOut: 0.25 },
        { src: `${ARMOR}/step_cloth${4 - i}.ogg`, rate: 0.7, lp: 1500, gain: -6 },
      ];
    },
  }),
  recorded({
    name: 'LeapWhoosh',
    title: 'Your leap',
    description: 'You leap a gap: air rushing past your ears.',
    family: FAMILY,
    group: 'reference',
    class: 'swell',
    variants: 3,
    channels: 1,
    loop: null,
    space: 'dry',
    loudness: -26,
    board: 'Your footsteps',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `oga/18-random-video-game-sound-effects/${['whoosh.wav', 'whoosh2.wav', 'whoosh.wav'][i]}`, rate: [0.5, 0.56], lp: 2000, gain: 0, fadeIn: 0.12, fadeOut: 0.2 },
        { src: `oga/swishes-sound-pack/swish-${[7, 9, 4][i]}.wav`, rate: 0.45, lp: 1800, gain: -6, at: 0.1, fadeIn: 0.08 },
      ];
    },
  }),
);
