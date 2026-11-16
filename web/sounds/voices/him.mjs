// him.mjs: HIS voice (the player: "Make the sounds of the monster be scary"). Every sound here is made the way film
// and game creatures are: animal and creature recordings played slower (lower and longer, the size of something
// eleven studs tall), layered so that a deep body carries the weight and a slowed snarl carries the texture a small
// speaker can play, everything over 2.5 kHz filtered away (nothing of his is bright: no shrieking treble, no dry
// ticking). His signature is the THROAT: a wet, rough, slowly pulsing rasp (the rattle index the audit measures).
//
//   growl      the deep snarls of monster-snarls slowed under a slowed roar: he has seen you
//   grunt      a short slowed creature grunt with a beast's growl under it
//   rattle     the "he is near" cue: a slowed frog croak and creature burbles, wet and organic
//   sniff      at the locker slits: slowed nose and breath takes
//   breathing  in the ducts: the troll's slowed idle breaths, hollow in the metal
//   vanish     a slowed snarl drawn in backwards and a rush of air, then nothing
//   lunge, screech, the jumpscare, the catch: the attack voices
//   the opening cutscene's three (the crawler's wet clicks, his wet breath) and the mask cracking
//
// What sounds like him is him (spec I1): no recording used here is used by any sound that is not his (the audit).

import * as K from '../kit/index.mjs';
import { recorded, withSub, inSpaceMono } from '../lib/recipe.mjs';

const FAMILY = 'him';
const CRE = 'oga/80-cc0-creature-sfx';
const CRE2 = 'oga/80-cc0-creture-sfx-2';
const SNARLS = 'oga/monster-snarls';
const IMPACT = 'kenney/impact-sounds';

/** The deep snarls (monster-snarls_0 and -2): [file, from, to] of each take, in the recording's seconds. */
const DEEP = [
  [`${SNARLS}/monster-snarls_0.ogg`, 0.13, 1.55],
  [`${SNARLS}/monster-snarls_0.ogg`, 4.91, 6.35],
  [`${SNARLS}/monster-snarls_0.ogg`, 9.69, 11.1],
  [`${SNARLS}/monster-snarls-2_0.ogg`, 0.27, 1.7],
  [`${SNARLS}/monster-snarls-2_0.ogg`, 4.55, 6.0],
];
/** The rough mid snarls (monster-snarls-3 and -5): what a laptop speaker plays of his growl. */
const MID = [
  [`${SNARLS}/monsters-snarls-3_0.ogg`, 12.05, 13.45],
  [`${SNARLS}/monster-snarl-5.ogg`, 4.01, 5.4],
  [`${SNARLS}/monsters-snarls-3_0.ogg`, 2.87, 4.27],
  [`${SNARLS}/monster-snarl-5.ogg`, 8.87, 10.27],
  [`${SNARLS}/monsters-snarls-3_0.ogg`, 6.13, 7.53],
];
/** The attack snarls (monster-snarl-attack). */
const ATTACK = [
  [`${SNARLS}/monster-snarl-attack.ogg`, 0.05, 1.25],
  [`${SNARLS}/monster-snarl-attack.ogg`, 10.51, 11.81],
  [`${SNARLS}/monster-snarl-attack.ogg`, 1.59, 2.93],
  [`${SNARLS}/monster-snarl-attack.ogg`, 12.59, 13.89],
];
const ROAR = 'oga/cc0-deep-monster-roar/monster_roar.flac';
const BEAST = ['silent_beast_growl.mp3', 'silent_beast_growl_1.mp3', 'silent_beast_growl_2.mp3', 'silent_beast_growl_3.mp3'].map((f) => `oga/silent-beast-growls4/${f}`);
const TROLL = 'oga/big-scary-troll-sounds/troll-idle-noises_0.ogg';
/** The troll's idle breaths: [from, to]. */
const TROLL_BREATHS = [[3.89, 5.4], [12.49, 14.0], [21.65, 23.15], [0.2, 1.7], [8.71, 10.2]];
/** His throat's flutter: the soft palate pulsing (Hz, depth), laid on a slowed breath or roar. */
const THROAT = [26, 0.55];

/** One take of a list as a layer. */
const takeOf = (list, i, layer) => {
  const [src, from, to] = list[((i % list.length) + list.length) % list.length];
  return { src, from, to, ...layer };
};

/** Shared fields of his voices. */
function his(v) {
  return recorded({ family: FAMILY, group: 'reference', channels: 1, loop: null, space: 'dry', board: 'Him', first: true, ...v });
}

/** Everything of his ends dark: a 2.4 kHz low-pass (12 dB/octave twice) over the finished mix. */
const dark = (x, sr, hz = 2400) => K.butter(x, sr, 'lowpass', hz, 4);

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  his({
    name: 'CreatureGrowl',
    title: 'His growl',
    description: 'He has seen you: a deep, wet snarl that rolls on under a slowed roar.',
    class: 'vocal',
    him: ['throat'],
    variants: 4,
    loudness: -15,
    layers: (variant) => {
      const i = variant - 1;
      return [
        takeOf(DEEP, i, { rate: [0.6, 0.66], lp: 2600, gain: 0, fadeOut: 0.35 }),
        takeOf(MID, i, { rate: [0.62, 0.68], hp: 180, lp: 2600, gain: -3, at: 0.03, fadeOut: 0.4 }),
        { src: ROAR, from: 1.2 + i * 0.9, to: 2.6 + i * 0.9, rate: [0.74, 0.8], lp: 700, gain: -6, fadeIn: 0.08, fadeOut: 0.4 },
      ];
    },
    finish: (ctx, mix) => dark(K.fade(mix, ctx.sr, 0, 0.3), ctx.sr),
  }),
  his({
    name: 'CreatureGrunt',
    title: 'His grunt',
    description: 'A short, low grunt in his throat before he looks away.',
    class: 'vocal',
    him: ['throat'],
    variants: 4,
    loudness: -19,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${CRE}/grunt_0${[1, 3, 4, 5][i]}.ogg`, rate: [0.52, 0.58], lp: 2400, flutter: THROAT, gain: 0, fadeOut: 0.15 },
        { src: BEAST[i], from: 0, to: 0.9, rate: [0.7, 0.78], lp: 1400, gain: -5, fadeOut: 0.25 },
        takeOf(MID, i + 1, { rate: 0.62, hp: 200, lp: 2400, gain: -10, env: [[0, 1], [0.6, 1], [0.9, 0]] }),
      ];
    },
    finish: (ctx, mix) => dark(K.fade(mix, ctx.sr, 0, 0.15), ctx.sr),
  }),
  his({
    name: 'CreatureRattle',
    title: 'His rattle',
    description: 'He is near: a low, wet, slowly pulsing rasp deep in his throat.',
    class: 'breath',
    him: ['throat'],
    repeats: true,
    variants: 4,
    loudness: -19,
    layers: (variant) => {
      const i = variant - 1;
      const front = [`${CRE}/burble_01.ogg`, 'oga/mutant-frog/mutant_frog-1.ogg', 'oga/small-dino-raspy-calls/small_dino_raspy_calls.mp3', 'oga/mutant-frog/mutant_frog-2.ogg'][i];
      return [
        { src: front, rate: [0.46, 0.5], lp: 2200, flutter: [24, 0.4], gain: 0, fadeIn: 0.06, fadeOut: 0.25 },
        { src: `oga/frog-croaks/croak_0${[1, 3, 1, 3][i]}${i % 2 ? '' : '_0'}.mp3`, rate: [0.42, 0.48], hp: 90, lp: 1800, gain: -6, at: 0.05, fadeIn: 0.05, fadeOut: 0.2 },
        { src: `${CRE2}/snore_02.ogg`, rate: [0.5, 0.56], lp: 1200, gain: -8, fadeIn: 0.08, fadeOut: 0.2 },
      ];
    },
    finish: (ctx, mix) => dark(K.fade(mix.subarray(0, Math.min(mix.length, Math.round(2.3 * ctx.sr))), ctx.sr, 0, 0.3), ctx.sr, 2200),
  }),
  his({
    name: 'CreatureSniff',
    title: 'Him sniffing',
    description: 'Something sniffing at the slits of your hiding spot: slow, wet, close.',
    class: 'breath',
    him: ['throat'],
    repeats: true,
    variants: 4,
    loudness: -21,
    layers: (variant) => {
      const i = variant - 1;
      return [
        // two short draws of air, the second deeper
        { src: `${CRE}/nose.ogg`, rate: [0.55, 0.6], lp: 2200, gain: -2, fadeIn: 0.03 },
        { src: [`${CRE2}/breath_02.ogg`, `${CRE}/breath.ogg`, `${CRE}/breath.ogg`, `${CRE2}/breath_02.ogg`][i], rate: [0.5 + 0.03 * i, 0.53 + 0.03 * i], flutter: THROAT, lp: 2000, gain: 0, at: [0.42, 0.55], fadeIn: 0.05, fadeOut: 0.12 },
        { src: `${CRE}/burble_0${1 + (i % 2)}.ogg`, from: 0.1, to: 0.5, rate: 0.5, lp: 1100, gain: -12, at: 0.5, fadeIn: 0.06, fadeOut: 0.15 },
      ];
    },
    finish: (ctx, mix) => dark(mix, ctx.sr, 2200),
  }),
  his({
    name: 'VentBreathing',
    title: 'Him breathing in the ducts',
    description: 'Slow, heavy breaths somewhere in the vents, hollow in the metal.',
    class: 'breath',
    him: ['throat'],
    repeats: true,
    variants: 5,
    loudness: -20,
    layers: (variant) => {
      const [from, to] = TROLL_BREATHS[variant - 1];
      return [
        { src: TROLL, from, to, rate: [0.66, 0.72], hp: 60, lp: 2200, flutter: THROAT, gain: 0, fadeIn: 0.12, fadeOut: 0.4 },
        { src: `${CRE2}/snore_02.ogg`, rate: [0.48, 0.54], lp: 1400, gain: -9, at: [0.2, 0.6], fadeIn: 0.1, fadeOut: 0.25 },
      ];
    },
    // the duct: a short metal tube's resonance and a little of its echo
    finish: (ctx, mix) => {
      const { sr } = ctx;
      let x = K.biquad(mix, sr, 'peak', 380 + 40 * ctx.variant, 3, 5);
      x = K.biquad(x, sr, 'peak', 1150, 4, 3);
      x = inSpaceMono(x, ctx, 'corridor', 0.18);
      return dark(K.fade(x.subarray(0, Math.min(x.length, Math.round(2.4 * sr))), sr, 0, 0.4), sr, 2400);
    },
  }),
  his({
    name: 'CreatureVanish',
    title: 'Him vanishing',
    description: 'A snarl drawn in backwards and a rush of air: then nothing.',
    class: 'swell',
    him: ['throat'],
    variants: 2,
    loudness: -18,
    layers: (variant) => {
      const i = variant - 1;
      return [
        takeOf(DEEP, i + 2, { rate: 0.62, reverse: true, lp: 2200, gain: 0, fadeIn: 0.4 }),
        { src: 'oga/air-whoosh/whoosh2_0.wav', from: 0.6 + i, to: 1.9 + i, rate: 0.62, reverse: true, hp: 120, lp: 1600, gain: -4, fadeIn: 0.6, at: 0.15 },
      ];
    },
    // drawn in, and cut off into silence: the last 60 ms fall away
    finish: (ctx, mix) => dark(K.fade(mix, ctx.sr, 0.05, 0.06), ctx.sr),
  }),
  his({
    name: 'Lunge',
    title: 'His lunge',
    description: 'He throws himself at you: a snarl tearing out of him and his weight landing.',
    class: 'vocal',
    him: ['throat'],
    variants: 3,
    loudness: -15,
    layers: (variant) => {
      const i = variant - 1;
      return [
        takeOf(ATTACK, i, { rate: [0.68, 0.74], lp: 2600, drive: 4, gain: 0, fadeOut: 0.3 }),
        { src: `${CRE2}/roar_0${[5, 6, 4][i]}.ogg`, rate: [0.58, 0.64], lp: 1800, gain: -3, at: 0.04, fadeOut: 0.25 },
        { src: `${IMPACT}/impactPunch_heavy_00${(i + 1) % 5}.ogg`, rate: 0.55, lp: 1400, gain: -4, at: 0.32 },
      ];
    },
    finish: (ctx, mix) => dark(withSub(mix, ctx.sr, { f0: 56, f1: 38, t60: 0.5, gain: -8, at: 0.32 }), ctx.sr),
  }),
  his({
    name: 'Screech',
    title: 'His screech',
    description: 'An inhuman howl that carries through the whole school: a roar that tears into a shriek, all of it low.',
    class: 'vocal',
    him: ['throat'],
    variants: 2,
    loudness: -15.3,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${CRE}/scream_0${i + 1}.ogg`, rate: [0.55, 0.6], lp: 2200, flutter: [28, 0.5], gain: -2, fadeOut: 0.3 },
        { src: `oga/7-ghast-sounds/ghast_cries.${[3, 2][i]}.ogg`, from: 0, to: 1.3, rate: 0.6, lp: 2000, flutter: THROAT, gain: -2, fadeOut: 0.4 },
        takeOf(MID, i + 3, { rate: 0.64, hp: 150, lp: 2400, gain: -4, fadeOut: 0.4 }),
        { src: ROAR, from: 0.4 + 1.5 * i, to: 1.9 + 1.5 * i, rate: 0.8, lp: 600, gain: -6, fadeIn: 0.05, fadeOut: 0.4 },
      ];
    },
    finish: (ctx, mix) => dark(K.fade(mix, ctx.sr, 0, 0.35), ctx.sr),
  }),
  his({
    name: 'JumpscareSting',
    title: 'The jumpscare',
    description: 'He has you: a snarl tearing out of him over a roar, everything at once, a drop under it.',
    class: 'stinger',
    him: ['throat'],
    channels: 2,
    space: 'baked',
    variants: 2,
    // the loudest thing there is, but at most 24 dB over the Basement's beds at the output (audio-test): a
    // player who turns the quiet up is never hurt by it
    loudness: -13.3,
    layers: (variant) => {
      const i = variant - 1;
      // the lead's recipe B (the player: "Pick the scariest low ones for Jumpscare do b or c"): a snarl attack over a
      // roar and an attack, driven hard, a sub drop under it (chosen over C by measurement: docs/SOUND.md 4)
      return [
        takeOf(ATTACK, [1, 0][i], { rate: [0.8, 0.86], lp: 2600, drive: 8, flutter: [30, 0.4], gain: 0, pan: -0.15, fadeOut: 0.3 }),
        { src: `${CRE}/roar_02.ogg`, rate: [0.66, 0.72], lp: 2200, drive: 6, flutter: THROAT, gain: -1, pan: 0.15, fadeOut: 0.3 },
        { src: `${CRE2}/attack_0${[3, 2][i]}.ogg`, rate: [0.72, 0.78], lp: 2400, drive: 4, gain: -3, pan: 0, fadeOut: 0.2 },
        { src: ROAR, from: 0.2 + 2 * i, to: 2.0 + 2 * i, rate: 0.78, lp: 500, drive: 6, gain: -3, pan: 0, fadeOut: 0.5 },
      ];
    },
    finish: (ctx, [l, r]) => {
      const { sr } = ctx;
      const out = [l, r].map((c) => dark(K.fade(withSub(c, sr, { f0: 62, f1: 34, drop: 0.35, t60: 1.1, drive: 4, gain: -3 }), sr, 0, 0.4), sr, 2600));
      return /** @type {[Float32Array, Float32Array]} */ (out);
    },
  }),
  his({
    name: 'NeckSnap',
    title: 'The catch',
    description: 'He has caught someone: his weight slams into them and a dull, dry snap, muffled. Never wet.',
    class: 'body',
    him: ['gait'],
    variants: 2,
    loudness: -15,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${IMPACT}/impactPunch_heavy_00${[1, 3][i]}.ogg`, rate: 0.56, lp: 1500, eq: [['lowshelf', 100, 0.8, 4]], gain: 0 },
        { src: `${IMPACT}/impactSoft_heavy_00${[2, 4][i]}.ogg`, rate: 0.5, drive: 8, lp: 900, gain: -6, at: 0.004 },
        { src: `${IMPACT}/impactPunch_medium_00${[0, 2][i]}.ogg`, rate: 0.75, hp: 160, lp: 1600, gain: -1 },
        // the snap: a dry branch cracking, slowed and muffled (as through his shroud)
        { src: `oga/100-cc0-metal-and-wood-sfx/wood_cracking_0${[2, 3][i]}.ogg`, rate: 0.7, lp: 1500, gain: -9, at: 0.16 },
        { src: `kenney/rpg-audio/cloth${[2, 4][i]}.ogg`, rate: 0.5, lp: 1200, gain: -16, at: 0.05 },
      ];
    },
    finish: (ctx, mix) => K.densify(withSub(mix, ctx.sr, { f0: 54, f1: 36, t60: 0.45, gain: -6 }), ctx.sr, 8),
  }),
  his({
    name: 'CrawlerClick',
    title: 'Him in the crate',
    description: 'From inside the crate: a low, wet rasp of his throat.',
    class: 'breath',
    him: ['throat'],
    repeats: true,
    variants: 4,
    loudness: -24,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: TROLL, from: TROLL_BREATHS[i][0], to: TROLL_BREATHS[i][0] + 0.7, rate: [0.5, 0.56], lp: 1400, gain: -3, fadeIn: 0.03, fadeOut: 0.12 },
        { src: `${CRE2}/breath_02.ogg`, rate: 0.5, lp: 1400, flutter: THROAT, gain: -6, at: 0.1, fadeIn: 0.08, fadeOut: 0.1 },
        { src: `${CRE}/burble_0${2 - (i % 2)}.ogg`, from: 0.05 + 0.15 * i, to: 0.6 + 0.1 * i, rate: [0.46, 0.5], lp: 1600, gain: 0, at: 0.06, fadeIn: 0.06, fadeOut: 0.15 },
      ];
    },
    finish: (ctx, mix) => dark(mix, ctx.sr, 1800),
  }),
  his({
    name: 'MaskCrack',
    title: 'His mask cracking',
    description: 'The porcelain mask splitting, and behind it something wet stirring in its throat.',
    class: 'body',
    him: ['throat'],
    variants: 3,
    loudness: -21,
    layers: (variant) => {
      const i = variant - 1;
      return [
        // a ceramic crack, slowed and dulled: a split, never a tick
        { src: `oga/100-cc0-sfx/dishes_0${[1, 3, 4][i]}.ogg`, from: 0, to: 0.35, rate: 0.6, lp: 2200, trim: true, gain: 0, fadeOut: 0.1 },
        { src: `${CRE}/burble_0${1 + (i % 2)}.ogg`, from: 0.1, to: 0.7, rate: 0.48, lp: 1600, flutter: THROAT, gain: -4, at: 0.05, fadeIn: 0.05, fadeOut: 0.2 },
        { src: BEAST[(i + 1) % 4], from: 0, to: 0.6, rate: 0.75, lp: 900, gain: -8, at: 0.08, fadeOut: 0.2 },
      ];
    },
    finish: (ctx, mix) => dark(mix, ctx.sr, 2200),
  }),
  his({
    name: 'WetBreath',
    title: 'His breath, close',
    description: 'A wet, shuddering breath right beside you in the dark.',
    class: 'breath',
    him: ['throat'],
    variants: 2,
    loudness: -19,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${CRE2}/snore_02.ogg`, rate: [0.5, 0.55], lp: 2200, flutter: [26, 0.7], gain: 0, fadeIn: 0.08 },
        { src: `${CRE}/breath.ogg`, rate: [0.5, 0.56], lp: 2000, flutter: THROAT, gain: -3, at: 0.6 + 0.1 * i, fadeIn: 0.06, fadeOut: 0.2 },
        { src: 'oga/ghost-breath/ghostbreath.flac', from: 0.4 + i, to: 1.9 + i, rate: 0.7, lp: 1600, gain: -6, fadeIn: 0.2, fadeOut: 0.4 },
      ];
    },
    finish: (ctx, mix) => dark(K.fade(mix, ctx.sr, 0, 0.25), ctx.sr),
  }),
];
