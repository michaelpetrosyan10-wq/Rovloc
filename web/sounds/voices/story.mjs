// story.mjs: the opening cutscene's cues and the prologue (StoryConfig.luau openingEvents, game/story/prologue.js),
// in the order they play: the last bell of a Friday afternoon, the doors banging open, the music box in the crate,
// the bin lids slamming, nails on metal, screams inside, the fire bell, the shutter crashing down, rain on the lid,
// the bell tolling twelve; in the prologue the chute and the hatch's bolt. His sounds in the cutscene (the crate's
// throat, his breath, the mask cracking) are in him.mjs, the window breaking in glass.mjs.

import * as K from '../kit/index.mjs';
import { recorded, withSub, inSpaceMono, inSpace, ending } from '../lib/recipe.mjs';

const FAMILY = 'story';
const MW = 'oga/100-cc0-metal-and-wood-sfx';
const SFX = 'oga/100-cc0-sfx';
const IMPACT = 'kenney/impact-sounds';
const VSE = 'oga/various-sound-effects';

function cue(v) {
  return recorded({ family: FAMILY, group: 'air', channels: 1, loop: null, space: 'dry', board: 'Story', ...v });
}

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  cue({
    name: 'SchoolBell',
    title: 'The school bell',
    description: 'The last bell of a Friday afternoon, ringing through the building.',
    class: 'bell',
    variants: 1,
    channels: 2,
    space: 'baked',
    loudness: -20,
    // an old bell struck again and again before its ring dies: three struck metal rings, a little apart, in the hall
    layers: () => [
      { src: 'oga/4-metal-dingsrings/ding.1.ogg', from: 0, to: 2.2, rate: 0.9, lp: 3500, trim: true, gain: 0, fadeOut: 0.4 },
      { src: 'oga/4-metal-dingsrings/ding.3.ogg', from: 0, to: 1.8, rate: 0.86, lp: 3500, trim: true, gain: -2, at: 0.32, fadeOut: 0.4 },
      { src: 'oga/4-metal-dingsrings/ding.2.ogg', from: 0, to: 1.6, rate: 0.92, lp: 3500, trim: true, gain: -3, at: 0.71, fadeOut: 0.4 },
    ],
    finish: (ctx, mix) => ending(inSpace(mix, ctx, 'hall', 0.35), ctx.sr, 2.4, 0.6),
  }),
  cue({
    name: 'DoorBang',
    title: 'Doors banging open',
    description: 'The school doors banging open as everyone pours out.',
    class: 'body',
    variants: 2,
    loudness: -18,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${SFX}/door_close_0${[1, 4][i]}.ogg`, rate: 0.75, lp: 2600, trim: true, gain: 0 },
        { src: `${IMPACT}/impactWood_heavy_00${[1, 4][i]}.ogg`, rate: 0.6, lp: 1200, gain: -2 },
        { src: `${SFX}/door_close_0${[3, 2][i]}.ogg`, rate: 0.8, lp: 2400, gain: -5, at: 0.18 },
      ];
    },
    finish: (ctx, mix) => inSpaceMono(mix, ctx, 'outdoor', 0.2),
  }),
  cue({
    name: 'MusicBoxTick',
    title: 'A music-box note',
    description: 'One note of a music box, alone in the dark.',
    class: 'keys',
    variants: 1,
    loudness: -24,
    layers: () => [
      // a steel tine struck by a pin (a struck ring played fast is a music box's comb) over the note itself
      { src: 'oga/4-metal-dingsrings/ding.4.ogg', rate: 1.4, hp: 400, lp: 6000, trim: true, gain: 0, fadeOut: 0.15 },
      { src: 'oga/bell-arpeggio-24/24.wav', from: 0, to: 0.5, rate: 0.75, lp: 4000, trim: true, gain: -4, fadeOut: 0.2 },
    ],
    finish: (ctx, mix) => ending(mix, ctx.sr, 0.58, 0.2),
  }),
  cue({
    name: 'LidSlam',
    title: 'A bin lid slamming',
    description: 'A wheelie bin lid slammed shut over your head.',
    class: 'body',
    repeats: true,
    variants: 4,
    loudness: -17,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${IMPACT}/impactPlate_medium_00${i}.ogg`, rate: 0.6, lp: 2200, trim: true, gain: 0 },
        { src: `${IMPACT}/impactTin_medium_00${i + 1}.ogg`, rate: 0.55, lp: 1800, gain: -4 },
        { src: `${IMPACT}/impactSoft_medium_00${i}.ogg`, rate: 0.6, lp: 900, gain: -2 },
      ];
    },
    finish: (ctx, mix) => K.densify(withSub(mix, ctx.sr, { f0: 66, f1: 48, t60: 0.2, gain: -8 }), ctx.sr, 11),
  }),
  cue({
    name: 'LidCreak',
    title: 'The bin lid creaking',
    description: 'The bin lid lifted a crack on its hinge.',
    class: 'friction',
    variants: 2,
    loudness: -24,
    layers: (variant) => [
      { src: `${VSE}/door_creak_open.wav`, from: [0.1, 0.7][variant - 1], to: [0.9, 1.5][variant - 1], rate: 0.85, lp: 2600, gain: 0, fadeIn: 0.05, fadeOut: 0.2 },
    ],
  }),
  cue({
    name: 'NailsOnMetal',
    title: 'Nails on metal',
    description: 'Something dragging its nails slowly along the side of your bin.',
    class: 'friction',
    variants: 2,
    loudness: -22,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${VSE}/grind_metal.wav`, rate: [0.7, 0.62][i], hp: 200, lp: 2600, gain: 0, fadeIn: 0.15, fadeOut: 0.3 },
        { src: `oga/scrapes/scrape-${[3, 6][i]}.ogg`, rate: 0.7, hp: 200, lp: 2400, gain: -6, at: 0.1, fadeIn: 0.1, fadeOut: 0.3 },
      ];
    },
    finish: (ctx, mix) => ending(mix, ctx.sr, 2.3, 0.4),
  }),
  cue({
    name: 'DistantScream',
    title: 'A scream inside',
    description: 'Somebody screaming somewhere inside the school.',
    class: 'vocal',
    variants: 2,
    loudness: -19,
    layers: (variant) => [
      { src: ['oga/female-high-pitched-scream-sfx/screams_0.ogg', 'oga/girly-scream/wscream_2_0.wav'][variant - 1], rate: [0.86, 0.8][variant - 1], lp: 2400, gain: 0, fadeOut: 0.3 },
      { src: ['oga/girly-scream/wscream_2_0.wav', 'oga/female-high-pitched-scream-sfx/screams_0.ogg'][variant - 1], rate: [0.9, 0.84][variant - 1], lp: 2200, gain: -7, at: 0.15, fadeOut: 0.3 },
    ],
    finish: (ctx, mix) => ending(inSpaceMono(K.butter(mix, ctx.sr, 'lowpass', 2000, 4), ctx, 'hall', 0.75), ctx.sr, 2.4, 0.6),
  }),
  cue({
    name: 'FireBell',
    title: 'The fire bell',
    description: 'The fire bell going off inside, ringing on and on.',
    class: 'spark',
    variants: 1,
    loudness: -20,
    layers: () => [
      { src: 'oga/alarm-2/alarm_0.wav', rate: 0.9, lp: 3000, trim: true, gain: 0 },
      { src: 'oga/short-alarm/alarm_0.ogg', rate: 0.85, lp: 2600, gain: -6, at: 0.2 },
    ],
    finish: (ctx, mix) => ending(inSpaceMono(mix, ctx, 'hall', 0.35), ctx.sr, 2.4, 0.5),
  }),
  cue({
    name: 'ShutterSlam',
    title: 'The shutter crashing down',
    description: 'A steel shutter rattling down its rails and crashing to the ground.',
    class: 'body',
    variants: 1,
    loudness: -16,
    layers: () => [
      // the catch let go, then the shutter rattling down its rails
      { src: 'kenney/rpg-audio/metalLatch.ogg', rate: 0.6, lp: 2400, trim: true, gain: -2 },
      { src: 'oga/chain-winch-sounds/winch - Marker 2.wav', from: 0, to: 1.0, rate: 1.2, lp: 2600, gain: -4, at: 0.06, fadeIn: 0.05, fadeOut: 0.1 },
      { src: `${MW}/metal_slam_01.ogg`, rate: 0.55, lp: 2400, gain: 0, at: 0.8 },
      { src: `${MW}/metal_falling_01.ogg`, from: 0, to: 1.0, rate: 0.7, lp: 2200, gain: -4, at: 0.82, fadeOut: 0.3 },
      { src: `${IMPACT}/impactMetal_medium_004.ogg`, rate: 0.5, lp: 1200, gain: -2, at: 0.8 },
    ],
    finish: (ctx, mix) => ending(withSub(mix, ctx.sr, { f0: 58, f1: 40, t60: 0.4, gain: -8, at: 0.8 }), ctx.sr, 2.4, 0.5),
  }),
  cue({
    name: 'BellToll',
    title: 'The bell tolling',
    description: 'A deep bell tolling midnight.',
    class: 'far',
    variants: 2,
    channels: 2,
    space: 'baked',
    loudness: -20,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `oga/4-metal-dingsrings/ding.${[1, 2][i]}.ogg`, rate: 0.42, lp: 1400, trim: true, gain: 0, pan: -0.2 },
        { src: `oga/4-metal-dingsrings/ding.${[3, 1][i]}.ogg`, rate: 0.28, lp: 900, gain: -6, pan: 0.2 },
      ];
    },
    finish: (ctx, mix) => ending(mix, ctx.sr, 4.6, 1.5),
  }),
  recorded({
    name: 'RainOnLid',
    title: 'Rain on the lid',
    description: 'Rain drumming on the plastic lid just above your head.',
    family: FAMILY,
    group: 'air',
    class: 'friction',
    variants: 1,
    channels: 2,
    loop: { seconds: 10, crossfade: 1.2 },
    space: 'baked',
    loudness: -24,
    board: 'Story',
    layers: () => [
      { src: 'oga/rain-loopable/2.ogg', from: 14, to: 25.5, rate: 0.9, hp: 120, lp: 2400, eq: [['peak', 700, 2, 6]], gain: 0, pan: -0.3 },
      { src: 'oga/rain-loopable/1.ogg', from: 15, to: 26.5, rate: 0.85, hp: 120, lp: 2200, eq: [['peak', 520, 2, 5]], gain: -2, pan: 0.3 },
    ],
  }),
  cue({
    name: 'BoltDrop',
    title: 'A bolt dropping home',
    description: 'A heavy steel bolt dropping into place: you are shut in.',
    class: 'body',
    variants: 2,
    loudness: -18,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: ['oga/door-lock-sounds/DoorLock.wav', 'oga/door-lock-sounds/UnlockDoor.wav'][i], rate: 0.6, lp: 2200, trim: true, gain: 0 },
        { src: `${IMPACT}/impactMetal_medium_00${[0, 2][i]}.ogg`, rate: 0.45, lp: 1200, gain: 0, at: 0.01 },
        { src: `${IMPACT}/impactSoft_medium_00${[1, 3][i]}.ogg`, rate: 0.55, lp: 900, gain: -2, at: 0.01 },
      ];
    },
    finish: (ctx, mix) => K.densify(withSub(mix, ctx.sr, { f0: 62, f1: 44, t60: 0.25, gain: -8, at: 0.01 }), ctx.sr, 11),
  }),
  cue({
    name: 'ChuteSlide',
    title: 'Down the chute',
    description: 'You sliding down a metal chute in the dark, clothes dragging on the steel.',
    class: 'friction',
    variants: 1,
    channels: 1,
    space: 'baked',
    loudness: -20,
    layers: () => [
      { src: 'oga/scrapes/scrape-4.ogg', rate: 0.55, hp: 80, lp: 2000, gain: 0, fadeIn: 0.1 },
      { src: 'oga/scrapes/scrape-8.ogg', rate: 0.5, hp: 80, lp: 1800, gain: -2, at: 1.0, fadeOut: 0.3 },
      { src: 'oga/202-more-sound-effects/Cloth_03.wav', rate: 0.8, lp: 1600, gain: -6, at: 0.2 },
    ],
    finish: (ctx, mix) => ending(K.biquad(mix, ctx.sr, 'peak', 300, 2, 5), ctx.sr, 2.4, 0.5),
  }),
  cue({
    name: 'SpeechMurmur',
    title: 'Voices murmuring',
    description: 'Muffled voices talking somewhere nearby.',
    class: 'friction',
    variants: 3,
    loudness: -26,
    layers: (variant) => [
      { src: 'oga/crowd-shoutingspeaking-ambience/crowd_shouting_0.ogg', from: 3 + 6 * (variant - 1), to: 5 + 6 * (variant - 1), rate: 0.95, hp: 150, lp: 1100, gain: 0, fadeIn: 0.2, fadeOut: 0.4 },
    ],
  }),
];
