// scares.mjs: the 2D stingers and the chase music (played at the player, not at him), and the static of a
// teleport. None carries his signatures or his recordings (spec I1): when they play he is not where they sound.
// Made the way horror games make their stingers: a real impact (a steel slam, a sheet of metal struck) for the
// attack, a far explosion or a heavy bell slowed until it is a boom for the weight, a slowed scream or a dark
// texture (horror-sfx) for the shriek, everything driven and low-passed so it is loud without being shrill; silence
// after it.

import * as K from '../kit/index.mjs';
import { recorded, withSub } from '../lib/recipe.mjs';

const FAMILY = 'scares';
/** The weight: two recorded explosions far off, slowed into a boom that drops away. */
const BOOM_FAR = 'oga/explosion-somewhere-far/explosion_somewhere_far.mp3';
const BOOM_MUFFLED = 'oga/muffled-distant-explosion/NenadSimic - Muffled Distant Explosion.wav';
/** The dread: TinyWorlds' horror textures (long, dark, unsettled), a part of one slowed. */
const DREAD = ['oga/horror-sfx/horror_effect1.flac', 'oga/horror-sfx/horror_effect2.flac'];
const MW = 'oga/100-cc0-metal-and-wood-sfx';
const SCREAM = 'oga/horror-scream1/scream_horror1_0.mp3';
const WHOOSH = 'oga/wierd-whooshes/weird_whoosh_sounds_-_whoosh_12_0.mp3';
const IMPACT = 'kenney/impact-sounds';

/** Stereo: every layer is panned, so the mix comes back as [left, right]. */
function sting(v) {
  return recorded({ family: FAMILY, group: 'reference', channels: 2, loop: null, space: 'baked', board: 'Scares', first: true, ...v });
}

/** A stereo mix low-passed and faded out (a stinger ends in silence). */
const finishStereo = (hz, fadeOut, sub) => (ctx, [l, r]) => /** @type {[Float32Array, Float32Array]} */ ([l, r].map((c) => {
  let x = sub ? withSub(c, ctx.sr, sub) : c;
  x = K.butter(x, ctx.sr, 'lowpass', hz, 4);
  return K.fade(x, ctx.sr, 0, fadeOut);
}));

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  sting({
    name: 'ChaseSting',
    title: 'The chase begins',
    description: 'He is coming for you: a steel slam and a deep boom that drops away under it.',
    class: 'stinger',
    variants: 2,
    loudness: -15.5,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${MW}/metal_slam_01.ogg`, rate: [0.55, 0.6][i], lp: 3000, drive: 6, gain: 0, pan: -0.2 },
        { src: `${IMPACT}/impactMining_00${[1, 3][i]}.ogg`, rate: 0.45, lp: 900, drive: 4, gain: -2, pan: 0.2 },
        { src: [BOOM_FAR, BOOM_MUFFLED][i], from: 0, to: 2.4, rate: [0.72, 0.66][i], lp: 1500, gain: -1, pan: 0, fadeOut: 0.8 },
        { src: `${MW}/metal_sheet_0${[3, 6][i]}.ogg`, rate: 0.45, hp: 200, lp: 2400, gain: -8, pan: 0.5, at: 0.02 },
      ];
    },
    finish: finishStereo(3200, 0.6, { f0: 58, f1: 32, drop: 0.3, t60: 0.9, gain: -4 }),
  }),
  sting({
    name: 'StareSting',
    title: 'It sees you looking',
    description: 'You looked too long: a struck sheet of steel and a slow, sick boom.',
    class: 'stinger',
    variants: 2,
    loudness: -16.5,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${MW}/metal_sheet_0${[1, 4][i]}.ogg`, rate: 0.5, lp: 2600, drive: 3, gain: 0, pan: 0.3 },
        { src: DREAD[i], from: [16, 6.1][i], to: [18.2, 8.3][i], rate: 0.6, lp: 2000, gain: -1, pan: -0.3, fadeIn: 0.01, fadeOut: 0.8 },
        { src: [BOOM_MUFFLED, BOOM_FAR][i], from: 0, to: 2.6, rate: [0.55, 0.6][i], lp: 600, gain: -1, pan: 0, fadeOut: 0.8 },
        { src: `${IMPACT}/impactMining_00${[0, 2][i]}.ogg`, rate: 0.5, lp: 1000, drive: 4, gain: -3, pan: 0 },
      ];
    },
    finish: finishStereo(2800, 0.7),
  }),
  sting({
    name: 'RevealSting',
    title: 'He appears',
    description: 'He is suddenly there: a steel door hit hard and a scream slowed until it is a howl.',
    class: 'stinger',
    variants: 2,
    loudness: -15.5,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${MW}/metal_close_01.ogg`, rate: [0.55, 0.62][i], lp: 2600, drive: 6, gain: 0, pan: -0.2 },
        { src: SCREAM, from: 1.2 + 2.6 * i, to: 2.8 + 2.6 * i, rate: 0.62, lp: 2400, drive: 3, gain: -3, pan: 0.25, fadeIn: 0.01, fadeOut: 0.5 },
        { src: [BOOM_FAR, BOOM_MUFFLED][i], from: 0, to: 2.4, rate: [0.66, 0.62][i], lp: 1200, gain: 0, pan: 0, fadeOut: 0.8 },
        { src: `${IMPACT}/impactMining_00${[4, 1][i]}.ogg`, rate: 0.42, lp: 800, drive: 4, gain: -3, pan: 0 },
      ];
    },
    finish: finishStereo(2800, 0.6, { f0: 60, f1: 34, drop: 0.25, t60: 0.7, gain: -5 }),
  }),
  sting({
    name: 'FakeoutShriek',
    title: 'A shriek in the hiding spot',
    description: 'You open the hiding spot and something screams in your face: then nothing is there.',
    class: 'stinger',
    variants: 2,
    loudness: -14.5,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: SCREAM, from: 0.6 + 4 * i, to: 2.2 + 4 * i, rate: 0.7, lp: 2800, drive: 5, gain: 0, pan: 0, fadeIn: 0.005, fadeOut: 0.5 },
        { src: `${MW}/metal_open_01.ogg`, rate: 0.6, lp: 2400, drive: 3, gain: -4, pan: -0.3 },
        { src: DREAD[1 - i], from: [9.4, 12.2][i], to: [11.4, 14.2][i], rate: 0.62, lp: 1600, gain: -6, pan: 0.3, fadeIn: 0.01, fadeOut: 0.6 },
        { src: `${IMPACT}/impactMining_00${[2, 0][i]}.ogg`, rate: 0.45, lp: 800, drive: 4, gain: 0, pan: 0 },
      ];
    },
    finish: finishStereo(3000, 0.5, { f0: 62, f1: 38, drop: 0.25, t60: 0.6, gain: -3 }),
  }),
  sting({
    name: 'GiveUpSwell',
    title: 'He gives up the chase',
    description: 'The chase is over: something drawn in, deep and slow, then silence.',
    class: 'swell',
    variants: 2,
    loudness: -20,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${IMPACT}/impactBell_heavy_00${[1, 0][i]}.ogg`, rate: 0.45, reverse: true, lp: 1800, gain: 0, pan: -0.3, fadeIn: 0.3 },
        { src: WHOOSH, from: [9.61, 16.05][i], to: [10.79, 17.37][i], rate: 0.7, reverse: true, lp: 1500, gain: -3, pan: 0.3, fadeIn: 0.3 },
      ];
    },
    finish: finishStereo(2400, 0.08),
  }),
  recorded({
    name: 'HideWarn',
    title: 'A knock on your hiding spot',
    description: 'Something knocks on the locker you are hiding in: you cannot stay much longer.',
    family: FAMILY,
    group: 'reference',
    class: 'body',
    variants: 3,
    channels: 1,
    loop: null,
    space: 'baked',
    first: true,
    loudness: -21,
    board: 'Scares',
    layers: (variant) => {
      const i = variant - 1;
      return [
        // two dull blows on the steel, a beat apart
        { src: `${MW}/metal_hit_0${[1, 3, 5][i]}.ogg`, rate: 0.5, lp: 1800, gain: -2 },
        { src: `${IMPACT}/impactSoft_medium_00${i}.ogg`, rate: 0.6, lp: 900, gain: 0 },
        { src: `${MW}/metal_hit_0${[4, 2, 1][i]}.ogg`, rate: 0.48, lp: 1700, gain: -4, at: [0.42, 0.5] },
        { src: `${IMPACT}/impactSoft_medium_00${i + 1}.ogg`, rate: 0.58, lp: 900, gain: -2, at: [0.42, 0.5] },
      ];
    },
    finish: (ctx, mix) => K.butter(mix, ctx.sr, 'lowpass', 2000, 4),
  }),
  recorded({
    name: 'HideKick',
    title: 'Shoved out',
    description: 'The locker door is kicked in on you and you are thrown out: steel and a body hitting the floor.',
    family: FAMILY,
    group: 'reference',
    class: 'heavy',
    variants: 3,
    channels: 1,
    loop: null,
    space: 'baked',
    first: true,
    loudness: -15.5,
    board: 'Scares',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${IMPACT}/impactMining_00${[0, 2, 4][i]}.ogg`, rate: 0.5, lp: 1200, gain: 0 },
        { src: `${MW}/metal_slam_01.ogg`, rate: [0.5, 0.54, 0.58][i], lp: 2000, gain: 0, at: 0.003 },
        { src: `${IMPACT}/impactWood_heavy_00${i}.ogg`, rate: 0.5, lp: 900, gain: -4, at: 0.28 },
      ];
    },
    finish: (ctx, mix) => K.densify(withSub(K.butter(mix, ctx.sr, 'lowpass', 1400, 4), ctx.sr, { f0: 56, f1: 38, t60: 0.4, gain: -6 }), ctx.sr, 10),
  }),
  recorded({
    name: 'TorchStutter',
    title: 'Your torch stuttering',
    description: 'The bulb of your torch sputtering as it fails: its hum dipping and catching, never in step.',
    family: FAMILY,
    group: 'reference',
    class: 'spark',
    variants: 3,
    channels: 1,
    loop: null,
    space: 'baked',
    // the warning that he is about to be somewhere else: never late on a first visit (the first set)
    first: true,
    loudness: -24,
    board: 'Scares',
    layers: (variant, rng) => {
      const i = variant - 1;
      // the bulb sputtering: its hum dips 5-7 times at uneven gaps (60-140 ms), each dip a different depth and
      // length, the way a failing filament loses contact; never a regular train
      const env = [[0, 1]];
      let t = 0;
      for (let k = rng.int(5, 7); k > 0 && t < 0.7; k--) {
        t += rng.range(0.06, 0.14);
        const depth = rng.range(0.04, 0.3);
        const hold = rng.range(0.015, 0.05);
        env.push([t, 1], [t + 0.008, depth], [t + 0.008 + hold, depth], [t + 0.02 + hold, rng.range(0.7, 1)]);
        t += 0.02 + hold;
      }
      env.push([t + 0.12, 0.9], [t + 0.3, 0]);
      return [
        // the hum: a coil's mains hum (a loop of a second) driven until it buzzes like a dying bulb
        { src: 'oga/electricity-game-sound-pack/shieldloop.wav', rate: [1.0, 1.06, 0.95][i], hp: 80, lp: 2500, drive: 12, gain: 0, env, fadeOut: 0.15 },
        // the filament's buzz: a charging coil's whine, slowed and darkened, under the hum
        { src: 'oga/electricity-game-sound-pack/charge.wav', from: 0.8 + 0.9 * i, to: 1.6 + 0.9 * i, rate: 0.8, lp: 2500, gain: -6, env, fadeOut: 0.15 },
        { src: 'oga/electricity-game-sound-pack/snaploop.wav', from: 0.6 * i, to: 0.5 + 0.6 * i, rate: 0.8, lp: 4000, gain: -14, at: 0.05, fadeOut: 0.1 },
      ];
    },
  }),
  recorded({
    name: 'TeleportHiss',
    title: 'Static rising',
    description: 'Static hissing up out of nothing where he is about to be.',
    family: FAMILY,
    group: 'reference',
    class: 'swell',
    variants: 2,
    channels: 1,
    loop: null,
    space: 'dry',
    first: true,
    loudness: -20,
    board: 'Scares',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: 'oga/static/ScatterNoise1.mp3', from: 2 + 5 * i, to: 4 + 5 * i, rate: 0.7, bend: [[0, 0.8], [1.6, 1.25]], hp: 150, lp: 3000, gain: 0, env: [[0, 0], [1.4, 1], [1.8, 1], [2.3, 0]] },
        { src: 'oga/static/ScatterNoise1.mp3', from: 14 + 6 * i, to: 16.5 + 6 * i, rate: 0.55, hp: 200, lp: 2200, gain: -6, env: [[0, 0], [1.5, 1], [2.3, 0]] },
      ];
    },
  }),
  recorded({
    name: 'ChasePulse',
    title: 'The chase',
    description: 'While he chases you: a deep drum pounding under a low, grinding drone.',
    family: FAMILY,
    group: 'reference',
    class: 'music',
    variants: 1,
    channels: 2,
    loop: { seconds: 10.08, crossfade: 0 },
    space: 'baked',
    first: true,
    loudness: -16,
    board: 'Scares',
    layers: () => {
      const beat = 0.42;
      // the seam falls between two beats (the first lands half a beat in): the rhythm closes on itself
      const first = beat / 2;
      const layers = [];
      for (let k = 0; k < 24; k++) {
        // a heavy beat, a lighter one: the pulse of something running
        const strong = k % 2 === 0;
        layers.push({ src: `${IMPACT}/impactWood_heavy_00${k % 5}.ogg`, rate: strong ? 0.55 : 0.64, lp: 1600, drive: 8, gain: strong ? 0 : -5, at: first + k * beat, pan: 0 });
        if (k % 4 === 0) layers.push({ src: `${IMPACT}/impactMining_00${(k / 4) % 5}.ogg`, rate: 0.45, lp: 900, gain: -6, at: first + k * beat + 0.005, pan: 0 });
      }
      const swell = [[0, 0], [1.5, 1], [3.5, 1], [5, 0]];
      // under the drum, twice a period: a far explosion slowed into a swelling roar, and a dark texture over it
      layers.push({ src: BOOM_FAR, rate: 0.55, lp: 300, gain: 0, at: 0.2, pan: -0.3, env: swell });
      layers.push({ src: BOOM_FAR, rate: 0.52, lp: 300, gain: 0, at: 5.24, pan: 0.3, env: swell });
      layers.push({ src: DREAD[0], from: 14, to: 17.2, rate: 0.62, lp: 900, gain: -9, at: 0.2, pan: -0.4, env: swell });
      layers.push({ src: DREAD[1], from: 3, to: 6.2, rate: 0.62, lp: 900, gain: -9, at: 5.24, pan: 0.4, env: swell });
      layers.push({ src: 'oga/scrapes/scrape-5.ogg', rate: 0.42, hp: 150, lp: 2000, gain: -6, at: 1.68, pan: 0.6, fadeIn: 0.2, fadeOut: 0.4 });
      layers.push({ src: 'oga/scrapes/scrape-7.ogg', rate: 0.42, hp: 150, lp: 2000, gain: -6, at: 6.72, pan: -0.6, fadeIn: 0.2, fadeOut: 0.4 });
      return layers;
    },
  }),
];
