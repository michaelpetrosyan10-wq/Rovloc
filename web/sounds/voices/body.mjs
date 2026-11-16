// body.mjs: YOUR body (2D, at you) and what you wear: breathing calm and panicked, the gasp, the heartbeat, the
// parachute. Real breaths (breathing-tired, an exhausted breath recording) and real heartbeats (heartbeat-sounds),
// nothing slowed into a creature: a person, scared, out of breath. None carries his rattle (the audit, spec I1), and
// none of his recordings is here.
//
// The menus close the file: Kenney's interface sounds pitched down an octave and muffled, soft and low.

import * as K from '../kit/index.mjs';
import { recorded, withSub, ending } from '../lib/recipe.mjs';

const FAMILY = 'body';
const TIRED = 'oga/breathing-tired/breathing tired.wav';
const BEAT = 'oga/heartbeat-sounds';
const UI = 'kenney/interface-sounds';

/** The three breaths of breathing-tired (a person out of breath, recorded by its uploader), as [file, from, to]. */
const BREATHS = [[TIRED, 0.05, 1.2], [TIRED, 1.15, 2.4], [TIRED, 2.3, 3.17]];
const breathOf = (i, layer) => {
  const [src, from, to] = BREATHS[i % BREATHS.length];
  return { src, from, to, fadeIn: 0.06, fadeOut: 0.12, ...layer };
};
/** One beat (lub-dub) of each heartbeat recording, as [file, from, to]. */
const SLOW = [[`${BEAT}/heartbeat_slow_0.wav`, 0, 0.6], [`${BEAT}/heartbeat_slow_0.wav`, 0.84, 1.45], ['oga/heartbeat-single-sound/heartbeat.mp3_.flac', 0.03, 0.75], [`${BEAT}/heartbeat_slow_reverb.wav`, 0, 0.62]];
/** The racing heart: the fast takes as they are, a single beat and a slow take played fast, as [file, from, to, rate]. */
const FAST = [[`${BEAT}/heartbeat_fast_0.wav`, 0, 0.42, 0.86], [`${BEAT}/heartbeat_fast_0.wav`, 0.5, 0.97, 1.0], ['oga/heartbeat-single-sound/heartbeat.mp3_.flac', 0.03, 0.75, 1.35], [`${BEAT}/heartbeat_slow_0.wav`, 0.84, 1.45, 1.25]];

function you(v) {
  return recorded({ family: FAMILY, group: 'world', channels: 1, loop: null, space: 'baked', board: 'Your footsteps', first: true, ...v });
}

/** A heartbeat's finish: the chest's thump given the harmonics a laptop speaker can play. */
const chest = (ctx, mix) => {
  let x = K.butter(mix, ctx.sr, 'highpass', 30, 2);
  x = K.biquad(K.biquad(x, ctx.sr, 'peak', 240, 1.2, 7), ctx.sr, 'peak', 600, 1.5, 4);
  return K.densify(x, ctx.sr, 9);
};

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  you({
    name: 'Breathing',
    title: 'Your breathing',
    description: 'You breathing in the dark, trying to stay quiet.',
    class: 'breath',
    repeats: true,
    variants: 3,
    loudness: -28,
    layers: (variant) => [breathOf(variant - 1, { rate: [0.94, 1.0], hp: 220, lp: 2400 })],
  }),
  you({
    name: 'BreathingPanic',
    title: 'Your panicked breathing',
    description: 'You gasping for air, fast and shaking: it is close.',
    class: 'breath',
    repeats: true,
    variants: 3,
    loudness: -25,
    layers: (variant) => {
      const [src, from, to] = BREATHS[(variant + 1) % BREATHS.length];
      return [{ src, from, to: from + Math.min(to - from, 0.95), rate: [1.08, 1.14], hp: 220, lp: 2600, fadeIn: 0.05, fadeOut: 0.1 }];
    },
  }),
  you({
    name: 'BreathExhale',
    title: 'You breathing out',
    description: 'A long, shaky breath out: it has gone.',
    class: 'breath',
    variants: 2,
    loudness: -26,
    layers: (variant) => [breathOf(variant, { rate: 0.88, lp: 2200, fadeOut: 0.3 })],
  }),
  you({
    name: 'Gasp',
    title: 'A gasp',
    description: 'A sharp, frightened intake of breath.',
    class: 'breath',
    variants: 3,
    space: 'dry',
    loudness: -21,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: 'oga/huh/huh.wav', rate: [0.92, 0.86, 0.98][i], lp: 2600, gain: 0, fadeIn: 0.04, fadeOut: 0.08 },
        breathOf([0, 1, 2][i], { to: undefined, rate: 1.2, lp: 2600, gain: -6, env: [[0, 1], [0.4, 1], [0.6, 0]] }),
      ];
    },
  }),
  you({
    name: 'Heartbeat',
    title: 'Your heartbeat',
    description: 'Your heart pounding in your ears.',
    class: 'body',
    repeats: true,
    variants: 4,
    loudness: -24,
    layers: (variant) => {
      const [src, from, to] = SLOW[variant - 1];
      return [{ src, from, to, rate: [0.9, 0.95], lp: 900, trim: true, gain: 0, fadeOut: 0.12 }];
    },
    finish: chest,
  }),
  you({
    name: 'HeartbeatFast',
    title: 'Your heart racing',
    description: 'Your heart hammering: it is right there.',
    class: 'body',
    repeats: true,
    variants: 4,
    loudness: -22,
    layers: (variant) => {
      const [src, from, to, rate] = FAST[variant - 1];
      return [{ src, from, to, rate, hp: 50, lp: 1400, trim: true, gain: 0, fadeOut: 0.08 }];
    },
    finish: chest,
  }),
  recorded({
    name: 'ScareHush',
    title: 'Holding your breath',
    description: 'One hard heartbeat and a breath caught and held.',
    family: FAMILY,
    group: 'air',
    class: 'body',
    variants: 2,
    channels: 1,
    loop: null,
    space: 'baked',
    loudness: -22,
    board: 'Scares',
    layers: (variant) => {
      const i = variant - 1;
      const [src, from, to] = SLOW[i + 1];
      return [
        { src, from, to, rate: 0.85, lp: 900, trim: true, gain: 0, fadeOut: 0.12 },
        breathOf([0, 2][i], { rate: 1.1, lp: 2200, gain: -8, at: 0.05, env: [[0, 1], [0.3, 1], [0.45, 0]] }),
      ];
    },
    finish: chest,
  }),
  // ------------------------------------------------------------------------------------------------ the parachute
  you({
    name: 'PackBuckle',
    title: 'Buckling the pack',
    description: 'The parachute pack strapped on: a buckle snapping shut and webbing pulled tight.',
    class: 'light',
    variants: 2,
    space: 'dry',
    loudness: -26,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: 'oga/small-metal-clasp-open-close-switching/small_metal_clasp.mp3', rate: [0.7, 0.62][i], lp: 2400, trim: true, gain: 0 },
        { src: `kenney/rpg-audio/clothBelt${['', '2'][i]}.ogg`, from: 0, to: 0.5, rate: 0.85, lp: 2200, gain: -4, at: 0.06, fadeOut: 0.1 },
      ];
    },
  }),
  you({
    name: 'CanopyDeploy',
    title: 'The canopy opening',
    description: 'The parachute snapping open above you with a heavy whump of cloth.',
    class: 'body',
    variants: 2,
    space: 'dry',
    loudness: -17,
    layers: (variant) => {
      const i = variant - 1;
      return [
        // the two beats of a big wing, slowed: the canopy's cloth catching the air
        { src: 'oga/dragon-flap-0/dragonflap.wav', from: [0.2, 0.75][i], to: [0.85, 1.6][i], rate: 0.7, lp: 2000, trim: true, gain: 0, fadeOut: 0.3 },
        { src: 'oga/various-sound-effects-0/snd_flap.wav', from: [0, 0.6][i], to: [0.6, 1.24][i], rate: 0.6, lp: 1600, gain: -4, at: 0.02, fadeOut: 0.3 },
      ];
    },
    finish: (ctx, mix) => withSub(mix, ctx.sr, { f0: 64, f1: 46, t60: 0.25, gain: -10 }),
  }),
  you({
    name: 'CanopyFlutter',
    title: 'The canopy fluttering',
    description: 'The parachute cloth snapping and fluttering in the wind above you.',
    class: 'friction',
    repeats: true,
    variants: 4,
    loudness: -24,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: 'oga/various-sound-effects-0/snd_flap.wav', from: 0.3 * i, to: 0.3 * i + 0.6, rate: [0.8, 0.86], lp: 2200, gain: 0, fadeIn: 0.02, fadeOut: 0.15 },
        { src: 'oga/various-sound-effects-0/snd_batwings.wav', from: 0.2 * i, to: 0.2 * i + 0.4, rate: 0.7, lp: 1800, gain: -6, at: 0.1, fadeOut: 0.1 },
      ];
    },
  }),
  you({
    name: 'WindRush',
    title: 'Wind rushing past',
    description: 'Falling: the wind roaring past your ears.',
    class: 'friction',
    variants: 1,
    channels: 2,
    // every layer runs to the render's end (the loop plus its crossfade: 9 s), so the period never thins out before
    // its seam: a layer that stopped short would leave the loop's last moments quieter and pump on every pass
    loop: { seconds: 8, crossfade: 1 },
    loudness: -22,
    layers: () => [
      { src: 'oga/wind-whoosh-loop/wind woosh loop.ogg', rate: 0.65, hp: 60, lp: 2400, gain: 0, pan: -0.5 },
      { src: 'oga/wind/Wind.ogg', rate: 0.7, hp: 60, lp: 2000, gain: -2, pan: 0.5 },
      { src: 'oga/wind/Wind2.ogg', rate: 0.8, hp: 80, lp: 2200, gain: -6, at: 1, pan: 0 },
    ],
  }),
  you({
    name: 'ParachuteLanding',
    title: 'Landing with the parachute',
    description: 'Your feet hitting the ground, a stumble and the canopy settling over you.',
    class: 'body',
    variants: 2,
    space: 'dry',
    loudness: -21,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `oga/jump-landing/Jump ${[2, 3][i]}.wav`, rate: 0.8, lp: 2200, trim: true, gain: 0 },
        { src: 'oga/different-steps-on-wood-stone-leaves-gravel-and-mud/gravel.ogg', rate: 0.8, lp: 2400, gain: -6, at: 0.08 },
        { src: 'oga/various-sound-effects-0/snd_flap.wav', from: 0.6, to: 1.24, rate: 0.6, lp: 1600, gain: -9, at: 0.3, fadeOut: 0.2 },
      ];
    },
    finish: (ctx, mix) => ending(withSub(mix, ctx.sr, { f0: 70, f1: 50, t60: 0.18, gain: -12 }), ctx.sr, 1.6, 0.3),
  }),
  // ------------------------------------------------------------------------------------------------ menus
  ...[
    ['UiClick', 'A menu click', 'A soft, low tap as you choose something.', [`${UI}/select_002.ogg`, `${UI}/switch_001.ogg`, `kenney/rpg-audio/bookPlace1.ogg`]],
    ['UiBack', 'Going back', 'A soft, low knock as you go back.', [`${UI}/back_001.ogg`, `${UI}/back_003.ogg`, `${UI}/close_002.ogg`]],
    ['UiConfirm', 'Confirming', 'A soft, low double knock as you confirm.', [`${UI}/switch_002.ogg`, `${UI}/switch_007.ogg`, `${UI}/switch_005.ogg`]],
  ].map(([name, title, description, files]) => recorded({
    name,
    title,
    description,
    family: FAMILY,
    group: 'world',
    class: 'menu',
    variants: 3,
    channels: 1,
    loop: null,
    space: 'baked',
    // the title screen's first clicks: decoded before the first frame, never silent on a slow first visit
    first: true,
    loudness: -28,
    board: 'Menus',
    layers: (variant) => [{ src: files[variant - 1], rate: 0.5, lp: 1400, trim: true, gain: 0, fadeOut: 0.03 }],
    finish: (ctx, mix) => ending(K.butter(mix, ctx.sr, 'lowpass', 1600, 4), ctx.sr, 0.26, 0.1),
  })),
];
