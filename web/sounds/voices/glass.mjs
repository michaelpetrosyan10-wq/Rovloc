// glass.mjs: glass SMASHING (the player: "change glass i dont like it right now"; the candidates they heard were
// glass being tapped). Every glass sound here is a real break: a bottle or a pane shattering (75-cc0-breaking, the
// ice-breaking pack, 100-cc0-sfx), its pieces falling and skittering after it, a low thump of the body that hit
// the floor under it, and for the flask the chemical splashing out and fizzing. Glass is the one bright thing in the
// game (its class allows it), but every break is played a little slower than recorded, so it sounds bigger and lower.
//
//   FlaskShatter  the thrown flask: smash, splash, falling shards
//   ChemHiss      the spilled chemical fizzing on the floor (a loop while the puddle lasts)
//   LightBurst    a bulb or a light tube failing: a pop, a spit of electricity, glass falling out of the fitting
//   GlassBreak    a window breaking somewhere inside (the opening cutscene)
//   GlassCrunch   broken glass underfoot
//   FootstepGlass, FootstepSprintGlass   your step on broken glass

import * as K from '../kit/index.mjs';
import { recorded, withSub } from '../lib/recipe.mjs';

const FAMILY = 'glass';
const BFH = 'oga/75-cc0-breaking-falling-hit-sfx';
const ICE = 'oga/ice-breakingshattering';
const SFX = 'oga/100-cc0-sfx';
const SPLASH = 'oga/40-cc0-water-splash-slime-sfx';
const RPG = 'kenney/rpg-audio';

/** The big breaks: a bottle or a pane shattering. */
const SMASH = [`${BFH}/bfh1_glass_breaking_06.ogg`, `${ICE}/LedasLuzta33.ogg`, `${SFX}/glass_04.ogg`, `${BFH}/bfh1_glass_breaking_04.ogg`];
/** The pieces falling after it. */
const PIECES = [`${BFH}/bfh1_glass_falling_02.ogg`, `${BFH}/bfh1_glass_falling_04.ogg`, `${BFH}/bfh1_glass_falling_01.ogg`, `${BFH}/bfh1_glass_falling_03.ogg`];
/** Small breaks (a bulb). */
const SHARDS = [`${BFH}/bfh1_glass_breaking_05.ogg`, `${ICE}/LedasLuzta2.ogg`, `${SFX}/glass_03.ogg`];
/** Crushed glass and grit: [file, from, to] (gritty, not ringing). */
const CRUSH = [
  [`${ICE}/LedasLuzta4.ogg`, 0, 0.42],
  [`${BFH}/bfh1_rock_falling_08.ogg`, 0, 0.3],
  [`${ICE}/LedasLuzta4.ogg`, 0.36, 0.8],
  [`${BFH}/bfh1_rock_breaking_02.ogg`, 0, 0.5],
  [`${BFH}/bfh1_rock_falling_02.ogg`, 0, 0.3],
];
/** Grit under it. */
const GRIT = [`${BFH}/bfh1_glass_falling_04.ogg`, `${BFH}/bfh1_rock_falling_02.ogg`, `${BFH}/bfh1_rock_falling_06.ogg`, `${BFH}/bfh1_glass_falling_04.ogg`, `${BFH}/bfh1_rock_falling_08.ogg`];
const crush = (i, layer) => {
  const [src, from, to] = at(CRUSH, i);
  return { src, from, to, trim: true, ...layer };
};
/** A dull body hitting the floor (the weight under a break). */
const THUD = [`${BFH}/bfh1_hit_01.ogg`, `${BFH}/bfh1_hit_02.ogg`, `${BFH}/bfh1_hit_06.ogg`, `${BFH}/bfh1_hit_12.ogg`];

const at = (list, i) => list[((i % list.length) + list.length) % list.length];

function glass(v) {
  return recorded({ family: FAMILY, group: 'reference', channels: 1, loop: null, space: 'dry', board: 'Glass', ...v });
}

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  glass({
    name: 'FlaskShatter',
    title: 'The flask shattering',
    description: 'The flask you threw smashes: glass bursting, the chemical splashing out, shards skittering away.',
    class: 'glass',
    variants: 4,
    first: true,
    loudness: -17,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: at(SMASH, i), rate: [0.84, 0.9], lp: 9000, gain: 0 },
        { src: at(THUD, i), rate: 0.62, lp: 900, gain: -6, at: 0.006 },
        { src: `${SPLASH}/splash_0${[2, 8, 3, 5][i]}.ogg`, rate: [0.78, 0.84], lp: 5000, gain: -5, at: 0.02 },
        { src: at(PIECES, i), rate: [0.88, 0.95], lp: 9000, gain: -7, at: [0.22, 0.3] },
        { src: at(PIECES, i + 2), rate: [0.8, 0.86], lp: 7000, gain: -12, at: [0.5, 0.6] },
      ];
    },
    finish: (ctx, mix) => withSub(mix, ctx.sr, { f0: 72, f1: 50, t60: 0.2, gain: -12 }),
  }),
  glass({
    name: 'ChemHiss',
    title: 'The chemical fizzing',
    description: 'The spilled chemical eating into the floor: fizzing, bubbling, a thin hiss of fumes.',
    class: 'liquid',
    variants: 1,
    loop: { seconds: 8, crossfade: 0.6 },
    loudness: -27,
    layers: () => [
      { src: `${SPLASH}/loop_bubbles_02.ogg`, from: 0, to: 7.3, rate: 0.85, lp: 4000, gain: 0 },
      { src: `${SPLASH}/loop_bubbles_1.ogg`, from: 0, to: 4.4, rate: 0.9, hp: 300, lp: 5000, gain: -6, at: 4.0 },
      // the fizz: the same bubbling played faster and thinned to its top, like acid working into the tiles
      { src: `${SPLASH}/loop_bubbles_02.ogg`, from: 0.5, to: 7.3, rate: 1.25, hp: 2000, lp: 6000, gain: -10, at: 0.3 },
    ],
  }),
  glass({
    name: 'LightBurst',
    title: 'A light bursting',
    description: 'A bulb gives out: a pop, a spit of electricity, glass falling out of the fitting.',
    class: 'glass',
    variants: 3,
    loudness: -19,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: at(SHARDS, i), rate: [0.8, 0.86], gain: 0 },
        { src: 'oga/electricity-sound-effects-0/spark.wav', rate: [0.7, 0.8], lp: 6000, gain: -8, at: 0.01 },
        // the bulb's dying buzz: a coil's hum driven hard, only its upper harmonics
        { src: 'oga/electricity-game-sound-pack/shieldloop.wav', from: 0.1 * i, to: 0.5 + 0.1 * i, rate: 1.0, hp: 1500, lp: 4000, drive: 14, gain: -22, at: 0.03, fadeOut: 0.2 },
        { src: at(PIECES, i + 1), rate: [0.95, 1.0], gain: -10, at: [0.28, 0.4] },
      ];
    },
    finish: (ctx, mix) => withSub(mix, ctx.sr, { f0: 80, f1: 55, t60: 0.12, gain: -14 }),
  }),
  glass({
    name: 'GlassBreak',
    title: 'Glass breaking inside',
    description: 'A window breaking somewhere inside the school: a crash and its pieces raining down.',
    class: 'glass',
    variants: 2,
    loudness: -18,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: at(SMASH, i + 1), rate: 0.8, lp: 8000, trim: true, gain: 0 },
        { src: at(SMASH, i + 2), rate: 0.88, lp: 7000, gain: -5, at: 0.04 },
        { src: at(THUD, i + 2), rate: 0.55, lp: 800, gain: -6, at: 0.008 },
        { src: at(PIECES, i), rate: 0.85, gain: -8, at: 0.35 },
        { src: at(PIECES, i + 3), rate: 0.8, gain: -11, at: 0.65 },
      ];
    },
  }),
  glass({
    name: 'GlassCrunch',
    title: 'Glass underfoot',
    description: 'Broken glass crunching under a shoe.',
    class: 'crunch',
    repeats: true,
    variants: 5,
    loudness: -22,
    layers: (variant) => {
      const i = variant - 1;
      return [
        crush(i, { rate: [0.78, 0.84], lp: 7000, drive: 6, gain: 0 }),
        { src: at(GRIT, i), rate: 0.9, lp: 5000, gain: -7, at: 0.004 },
      ];
    },
    finish: (ctx, mix) => K.fade(mix, ctx.sr, 0, 0.05),
  }),
  ...[false, true].map((fast) => glass({
    name: `Footstep${fast ? 'Sprint' : ''}Glass`,
    title: `Your footsteps, ${fast ? 'running' : 'walking'}, on broken glass`,
    description: `You ${fast ? 'running' : 'walking'} over broken glass: the shoe and the shards crunching under it.`,
    class: 'crunch',
    repeats: true,
    variants: 5,
    first: true,
    loudness: fast ? -26 : -29,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${RPG}/footstep0${[2, 4, 7, 8, 2][i]}.ogg`, rate: fast ? 1.06 : 1.0, lp: 2600, trim: true, gain: -6 },
        crush(i + 2, { rate: fast ? [0.86, 0.92] : [0.8, 0.86], hp: 500, lp: 6000, drive: 4, gain: 0 }),
        { src: `${BFH}/bfh1_rock_falling_0${[6, 2, 8, 6, 2][i]}.ogg`, rate: 0.85, lp: 4000, gain: -10, at: 0.01 },
      ];
    },
    finish: (ctx, mix) => K.fade(mix, ctx.sr, 0, 0.04),
  })),
];
