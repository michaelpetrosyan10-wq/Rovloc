// building.mjs: the school around you: the beds that never stop (each level's drone and the ambience director's
// dread bed), the rain and the thunder, and the building's own events, near and far (a door slamming somewhere, a
// locker rattling, pipes, a phone buzzing in an empty room, something dragged across the floor above). All of it
// from recordings: engine and wind rumbles slowed into the building's breathing, dark ambiences, a basement full of
// drips, the rain and thunder packs. Beds sit far down (at most -34 LUFS) so that every event, and him, stands out.
//
// Spec I1: nothing here may sound like him; no recording here is his, and DreadThumpAbove is one object falling
// and settling, never a step.

import * as K from '../kit/index.mjs';
import { recorded, withSub, inSpaceMono, ending } from '../lib/recipe.mjs';

const FAMILY = 'building';
const RUMBLE = 'oga/underwater-or-space-engine-rumble/underwater_or_space_engine_0.ogg';
const DRIPS = 'oga/dripping-water-loop/atmosbasement.mp3_.flac';
const DUNGEON = 'oga/loopable-dungeon-ambience/dungeon_ambient_1_0.ogg';
const HORROR = 'oga/ambient-horror/ambient_horror_0.ogg';
const LOW = 'oga/low-rumbling/low-rumbling-176033.mp3';
const SPACEWIND = 'oga/space-winds/space-wind_0.mp3';
const DARK = 'oga/dark-ambiences';
const THUNDER = 'oga/rain-long-thunder/rain-thunder.ogg';
const MW = 'oga/100-cc0-metal-and-wood-sfx';
const SFX = 'oga/100-cc0-sfx';
const BFH = 'oga/75-cc0-breaking-falling-hit-sfx';
const IMPACT = 'kenney/impact-sounds';
const VSE = 'oga/various-sound-effects';

/** A stereo bed: 2D, a seamless loop (decoded in the background: a level's bed fades in over seconds anyway). */
function bed(v) {
  return recorded({ family: FAMILY, group: 'air', class: 'bed', variants: 1, channels: 2, space: 'baked', board: 'The building', ...v });
}
/** A positional event of the building. */
function event(v) {
  return recorded({ family: FAMILY, group: 'air', channels: 1, loop: null, space: 'dry', board: 'The building', ...v });
}
const dark = (hz) => (ctx, mix) => (Array.isArray(mix) ? /** @type {[Float32Array, Float32Array]} */ (mix.map((c) => K.butter(c, ctx.sr, 'lowpass', hz, 4))) : K.butter(mix, ctx.sr, 'lowpass', hz, 4));

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  // ------------------------------------------------------------------------------------------------ beds
  bed({
    name: 'DroneBasement',
    title: 'The Basement',
    description: 'The basement breathing: a deep engine-like rumble in the walls and water dripping in the dark.',
    loop: { seconds: 12, crossfade: 1.5 },
    loudness: -35,
    layers: () => [
      { src: RUMBLE, from: 10, to: 22.5, rate: 0.85, lp: 600, gain: 0, pan: -0.4 },
      { src: RUMBLE, from: 40, to: 52.5, rate: 0.82, lp: 600, gain: -1, pan: 0.4 },
      { src: DRIPS, from: 0, to: 14, rate: 0.9, hp: 150, lp: 3000, gain: -8, pan: 0.2 },
    ],
    finish: dark(1600),
  }),
  bed({
    name: 'DroneHallways',
    title: 'The Hallways',
    description: 'The empty hallways at night: a low, hollow air moving through the building.',
    loop: { seconds: 12, crossfade: 1.5 },
    loudness: -36,
    layers: () => [
      { src: DUNGEON, from: 10, to: 22.5, rate: 0.85, lp: 900, gain: 0, pan: -0.35 },
      { src: DUNGEON, from: 40, to: 52.5, rate: 0.8, lp: 900, gain: -1, pan: 0.35 },
      { src: SPACEWIND, from: 5, to: 17, rate: 0.7, hp: 100, lp: 1200, gain: -10, pan: 0 },
    ],
    finish: dark(1400),
  }),
  bed({
    name: 'DroneLobby',
    title: 'The lobby',
    description: 'The lobby: a low rumble and the wind outside the doors.',
    loop: { seconds: 12, crossfade: 1.5 },
    loudness: -37,
    layers: () => [
      { src: LOW, from: 0, to: 12.5, rate: 0.95, hp: 30, lp: 700, gain: 0, pan: -0.3 },
      { src: LOW, from: 10, to: 22.5, rate: 0.9, hp: 30, lp: 700, gain: -1, pan: 0.3 },
      { src: SPACEWIND, from: 20, to: 32, rate: 0.75, hp: 120, lp: 1400, gain: -8, pan: 0 },
    ],
    finish: dark(1400),
  }),
  bed({
    name: 'DroneRoof',
    title: 'The roof',
    description: 'The roof at night: wind gusting over the edge, the city rumbling far below.',
    loop: { seconds: 12, crossfade: 2 },
    loudness: -34,
    layers: () => [
      { src: SPACEWIND, from: 30, to: 42, rate: 0.85, hp: 60, lp: 1400, gain: 0, pan: -0.5 },
      { src: 'oga/wind/Wind.ogg', rate: 0.6, hp: 60, lp: 1300, gain: -3, pan: 0.5, at: 0.5 },
      { src: 'oga/wind/Wind2.ogg', rate: 0.62, hp: 60, lp: 1300, gain: -4, pan: 0.2, at: 5.5 },
      { src: LOW, from: 12, to: 24.5, rate: 0.9, lp: 500, gain: -6, pan: 0 },
    ],
    finish: dark(1500),
  }),
  bed({
    name: 'DreadBedBasement',
    title: 'Dread in the Basement',
    description: 'Under everything in the basement: a dark, uneasy pressure that comes and goes.',
    loop: { seconds: 14, crossfade: 1.5 },
    loudness: -38,
    // the dark-ambiences laid end to end with overlaps, slowed
    layers: () => [1, 5, 2, 3, 4, 1, 5].map((n, k) => ({ src: `${DARK}/ambience-${n}.${n === 1 ? 'flac' : 'wav'}`, rate: 0.75, lp: 1200, gain: k % 2 ? -3 : 0, at: k * 2.0, pan: k % 2 ? 0.4 : -0.4, fadeIn: 0.6, fadeOut: 0.8 })),
    finish: dark(1300),
  }),
  bed({
    name: 'DreadBedHallways',
    title: 'Dread in the Hallways',
    description: 'Under everything in the hallways: a far-off groaning hum that never quite stops.',
    loop: { seconds: 12, crossfade: 1.5 },
    loudness: -38,
    layers: () => [
      { src: HORROR, from: 0, to: 11, rate: 0.85, hp: 40, lp: 1200, gain: 0, pan: -0.3 },
      { src: HORROR, from: 10, to: 21, rate: 0.8, hp: 40, lp: 1200, gain: -2, pan: 0.3 },
    ],
    finish: dark(1300),
  }),
  recorded({
    name: 'Rain',
    title: 'Rain',
    description: 'Heavy rain outside, drumming on the roof and the ground.',
    family: FAMILY,
    group: 'air',
    class: 'friction',
    variants: 1,
    channels: 2,
    loop: { seconds: 12, crossfade: 1.5 },
    space: 'baked',
    loudness: -28,
    board: 'The building',
    layers: () => [
      { src: 'oga/rain-loopable/2.ogg', from: 0, to: 13.5, rate: 1, hp: 80, lp: 2600, gain: 0, pan: -0.5 },
      { src: 'oga/rain-loopable/1.ogg', from: 5, to: 18.5, rate: 0.9, hp: 80, lp: 2200, gain: -3, pan: 0.5 },
    ],
    finish: dark(2400),
  }),
  // ------------------------------------------------------------------------------------------------ weather and far events
  recorded({
    name: 'Thunder',
    title: 'Thunder',
    description: 'Thunder breaking over the school and rolling away.',
    family: FAMILY,
    group: 'air',
    class: 'far',
    variants: 2,
    channels: 2,
    loop: null,
    space: 'baked',
    loudness: -18,
    board: 'The building',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: THUNDER, from: [21.95, 30.07][i], to: [26.6, 33.0][i], rate: 0.9, hp: 25, lp: 1600, trim: true, gain: 0, pan: -0.3, fadeOut: 0.8 },
        { src: 'oga/muffled-distant-explosion/NenadSimic - Muffled Distant Explosion.wav', rate: 0.7, lp: 600, gain: -4, pan: 0.3, fadeOut: 0.8 },
      ];
    },
    finish: (ctx, mix) => ending(dark(1500)(ctx, mix), ctx.sr, 4.8, 1.2),
  }),
  recorded({
    name: 'DistantThunder',
    title: 'Distant thunder',
    description: 'Thunder far away, a long low roll.',
    family: FAMILY,
    group: 'air',
    class: 'far',
    variants: 2,
    channels: 2,
    loop: null,
    space: 'baked',
    loudness: -25,
    board: 'The building',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: THUNDER, from: [22.4, 31.0][i], to: [27.2, 33.6][i], rate: 0.75, hp: 25, lp: 900, gain: 0, pan: 0.3, fadeIn: 0.15, fadeOut: 1 },
        { src: 'oga/explosion-somewhere-far/explosion_somewhere_far.mp3', rate: 0.6, lp: 500, gain: -6, pan: -0.3, fadeOut: 1 },
      ];
    },
    finish: (ctx, mix) => ending(dark(900)(ctx, mix), ctx.sr, 4.8, 1.5),
  }),
  recorded({
    name: 'FarRumble',
    title: 'A far rumble',
    description: 'Something huge shifting deep in the building: a low rumble, then quiet.',
    family: FAMILY,
    group: 'air',
    class: 'far',
    variants: 2,
    channels: 2,
    loop: null,
    space: 'baked',
    loudness: -28,
    board: 'The building',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: LOW, from: [2, 14][i], to: [6.5, 18.5][i], rate: 0.8, lp: 500, gain: 0, pan: -0.3, fadeIn: 0.6, fadeOut: 1.2 },
        { src: 'oga/cave-in/cave_in_-_starninjas_0.ogg', rate: 0.5, lp: 600, gain: -4, pan: 0.3, at: 0.3, fadeIn: 0.3, fadeOut: 1 },
      ];
    },
    finish: (ctx, mix) => ending(dark(800)(ctx, mix), ctx.sr, 4.8, 1.2),
  }),
  event({
    name: 'DistantGroan',
    title: 'The building groaning',
    description: 'Old timber and steel groaning somewhere in the structure.',
    class: 'friction',
    variants: 2,
    loudness: -24,
    layers: (variant) => {
      const i = variant - 1;
      return [
        // a hinge's long groan and a board's squeak, slowed until they are the structure itself
        [{ src: 'oga/creaky-door-hinge-spooky/creaky_door_hinge.wav', from: 1.0, to: 2.5, rate: 0.42, lp: 1200, gain: 0, fadeIn: 0.2, fadeOut: 0.4 },
          { src: 'oga/100-cc0-metal-and-wood-sfx/wood_squeak_01.ogg', rate: 0.4, lp: 1200, gain: 0, fadeIn: 0.1, fadeOut: 0.3 }][i],
        { src: `oga/chain-winch-sounds/winch - Marker #${[8, 9][i]}.wav`, from: 0.2, to: 1.2, rate: 0.4, lp: 900, gain: -6, at: 0.3, fadeIn: 0.2, fadeOut: 0.3 },
      ];
    },
    finish: (ctx, mix) => ending(inSpaceMono(mix, ctx, 'hall', 0.3), ctx.sr, 2.4, 0.6),
  }),
  event({
    name: 'Drip',
    title: 'A drip',
    description: 'Water dripping into a puddle in the dark.',
    class: 'liquid',
    repeats: true,
    variants: 4,
    loudness: -30,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: [`${SFX}/plop_01.ogg`, 'oga/40-cc0-water-splash-slime-sfx/bubble_03.ogg', 'oga/40-cc0-water-splash-slime-sfx/bubble_02.ogg', `${SFX}/plop_01.ogg`][i], rate: [0.8, 0.72, 0.9, 0.62][i], lp: 3000, trim: true, gain: 0 },
        { src: 'oga/40-cc0-water-splash-slime-sfx/splash_12.ogg', from: 0, to: 0.25, rate: 1.2, hp: 600, lp: 4000, gain: -14, at: 0.01 },
      ];
    },
    finish: (ctx, mix) => ending(inSpaceMono(mix, ctx, 'basement', 0.3), ctx.sr, 1.8, 0.5),
  }),
  event({
    name: 'DripStinger',
    title: 'A drip echoing',
    description: 'One drip, loud in the silence, echoing away.',
    class: 'liquid',
    variants: 2,
    loudness: -26,
    layers: (variant) => [
      { src: `${SFX}/plop_0${variant}.ogg`, rate: 0.6, lp: 2600, trim: true, gain: 0 },
      { src: 'oga/40-cc0-water-splash-slime-sfx/splash_12.ogg', from: 0, to: 0.3, rate: 1.0, hp: 500, lp: 3500, gain: -12, at: 0.01 },
    ],
    finish: (ctx, mix) => inSpaceMono(mix, ctx, 'basement', 0.55),
  }),
  // ------------------------------------------------------------------------------------------------ the dread director's events
  event({
    name: 'DreadDoorSlam',
    title: 'A door slamming far off',
    description: 'A door slams somewhere far off in the building.',
    class: 'body',
    variants: 3,
    loudness: -20,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `kenney/rpg-audio/doorClose_${[1, 3, 4][i]}.ogg`, rate: 0.68, lp: 1800, trim: true, gain: 0 },
        { src: `${IMPACT}/impactWood_heavy_00${[2, 4, 0][i]}.ogg`, rate: 0.55, lp: 900, gain: 0 },
      ];
    },
    finish: (ctx, mix) => ending(inSpaceMono(mix, ctx, 'hall', 0.35), ctx.sr, 2.4, 0.6),
  }),
  event({
    name: 'DreadLockerRattle',
    title: 'A locker rattling',
    description: 'A locker door rattling in its frame somewhere down the row, as if something brushed past.',
    class: 'friction',
    variants: 2,
    loudness: -22,
    layers: (variant) => {
      const i = variant - 1;
      return [0, 1, 2, 3].map((k) => ({ src: `${MW}/metal_sheet_0${[2, 5, 4, 1][(k + i) % 4]}.ogg`, rate: 0.62 + 0.04 * k, lp: 2000, trim: true, gain: -2 * k, at: k * [0.11, 0.14][i] }));
    },
    finish: (ctx, mix) => inSpaceMono(mix, ctx, 'corridor', 0.3),
  }),
  event({
    name: 'DreadMetalGroan',
    title: 'Metal groaning in the walls',
    description: 'Something metal inside the walls bending and groaning.',
    class: 'friction',
    variants: 2,
    loudness: -22,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${VSE}/grind_metal.wav`, rate: [0.32, 0.36][i], lp: 1200, gain: 0, fadeIn: 0.3, fadeOut: 0.5 },
        { src: `oga/chain-winch-sounds/winch - Marker #${[3, 6][i]}.wav`, from: 0.2, to: 1.6, rate: 0.35, lp: 900, gain: -4, at: 0.2, fadeIn: 0.3, fadeOut: 0.4 },
      ];
    },
    finish: (ctx, mix) => ending(mix, ctx.sr, 2.4, 0.6),
  }),
  event({
    name: 'DreadPACrackle',
    title: 'The speakers crackling',
    description: 'The school\'s speakers crackle into life with nobody there, then cut out.',
    class: 'spark',
    variants: 2,
    loudness: -24,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: 'oga/radio-death-sound/radio_death.flac', from: [0.2, 2.2][i], to: [1.6, 3.6][i], rate: 0.85, hp: 300, lp: 3200, trim: true, gain: 0, fadeOut: 0.06 },
        // the amplifier's mains hum under the static
        { src: 'oga/electricity-game-sound-pack/shieldloop.wav', rate: [1.0, 0.94][i], hp: 100, lp: 1500, drive: 6, gain: -10, fadeOut: 0.06 },
      ];
    },
    finish: (ctx, mix) => ending(inSpaceMono(mix, ctx, 'hall', 0.25), ctx.sr, 2.4, 0.6),
  }),
  event({
    name: 'DreadPhoneBuzz',
    title: 'A phone buzzing',
    description: 'A phone vibrating on a desk in an empty room.',
    class: 'friction',
    variants: 2,
    loudness: -24,
    layers: (variant) => [
      { src: 'oga/202-more-sound-effects/Phone1.wav', rate: [0.9, 0.82][variant - 1], lp: 2400, trim: true, gain: 0 },
    ],
    finish: (ctx, mix) => inSpaceMono(mix, ctx, 'room', 0.25),
  }),
  event({
    name: 'DreadThumpAbove',
    title: 'A thump above',
    description: 'Something heavy falls on the floor above you and rolls to a stop.',
    class: 'body',
    variants: 2,
    loudness: -22,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${IMPACT}/impactWood_heavy_00${[1, 3][i]}.ogg`, rate: 0.6, lp: 500, trim: true, gain: 0 },
        { src: `${BFH}/bfh1_wood_falling_0${[1, 2][i]}.ogg`, rate: 0.6, lp: 450, gain: -6, at: 0.18 },
      ];
    },
    finish: (ctx, mix) => K.densify(withSub(mix, ctx.sr, { f0: 58, f1: 42, t60: 0.3, gain: -8 }), ctx.sr, 10),
  }),
  event({
    name: 'CeilingDrag',
    title: 'Something dragged above',
    description: 'Something heavy dragged across the floor above you, scraping.',
    class: 'friction',
    repeats: true,
    variants: 4,
    loudness: -22,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `oga/scrapes/scrape-${[1, 3, 5, 7][i]}.ogg`, rate: [0.55, 0.6], lp: 700, gain: 0, fadeIn: 0.08, fadeOut: 0.2 },
        { src: `${VSE}/floor_creak${1 + (i % 3)}.wav`, from: 0, to: 1.0, rate: 0.7, lp: 900, gain: -6, fadeOut: 0.2 },
      ];
    },
    finish: (ctx, mix) => ending(mix, ctx.sr, 1.6, 0.3),
  }),
  // ------------------------------------------------------------------------------------------------ scripted events
  event({
    name: 'DoorPound',
    title: 'Pounding on a steel door',
    description: 'Something hammering on a steel door, three heavy blows.',
    class: 'body',
    variants: 2,
    loudness: -17,
    layers: (variant) => {
      const i = variant - 1;
      return [0, 1, 2].flatMap((k) => [
        { src: 'oga/ingame-samples-audio/DoorPunch_0.wav', rate: 0.62 + 0.03 * k, lp: 1800, trim: true, gain: -2 * k, at: k * [0.42, 0.5][i] },
        { src: `oga/10-impactshield-blocks/impact.${[3, 5, 9][k]}.ogg`, rate: 0.55, lp: 1200, trim: true, gain: -4 - 2 * k, at: k * [0.42, 0.5][i] },
      ]);
    },
    finish: (ctx, mix) => ending(inSpaceMono(mix, ctx, 'corridor', 0.25), ctx.sr, 2.4, 0.5),
  }),
  event({
    name: 'ObjectFall',
    title: 'Something falling',
    description: 'Something knocked off a shelf, clattering across the floor.',
    class: 'body',
    variants: 3,
    loudness: -20,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${IMPACT}/impactSoft_medium_00${i}.ogg`, rate: 0.55, lp: 900, trim: true, gain: 0 },
        { src: [`${BFH}/bfh1_falling_04.ogg`, `${BFH}/bfh1_metal_falling_03.ogg`, `${MW}/wood_falling_05.ogg`][i], rate: 0.7, lp: 2200, trim: true, gain: -3, at: 0.002 },
      ];
    },
    finish: (ctx, mix) => inSpaceMono(withSub(K.butter(mix, ctx.sr, 'lowpass', 2600, 4), ctx.sr, { f0: 70, f1: 50, t60: 0.18, gain: -6 }), ctx, 'room', 0.25),
  }),
  event({
    name: 'PipeBang',
    title: 'A pipe banging',
    description: 'A pipe banging somewhere in the dark, ringing down its length.',
    class: 'body',
    variants: 3,
    loudness: -19,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${BFH}/bfh1_metal_hit_0${[2, 3, 6][i]}.ogg`, rate: 0.5, lp: 2000, trim: true, gain: 0 },
        { src: `oga/4-metal-dingsrings/ding.${[4, 3, 2][i]}.ogg`, from: 0, to: 1.0, rate: 0.45, lp: 1400, gain: -8, fadeOut: 0.4 },
        { src: `${IMPACT}/impactMetal_medium_00${i}.ogg`, rate: 0.45, lp: 1000, gain: 0 },
      ];
    },
    finish: (ctx, mix) => ending(inSpaceMono(withSub(mix, ctx.sr, { f0: 64, f1: 46, t60: 0.2, gain: -10 }), ctx, 'basement', 0.35), ctx.sr, 2.4, 0.6),
  }),
  event({
    name: 'RoofDoorSlam',
    title: 'The wind slamming a door',
    description: 'A gust catches the roof door and slams it shut.',
    class: 'body',
    variants: 2,
    loudness: -17,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${SFX}/door_close_0${[2, 1][i]}.ogg`, rate: 0.62, lp: 2200, trim: true, gain: 0 },
        { src: `${IMPACT}/impactWood_heavy_00${[0, 4][i]}.ogg`, rate: 0.5, lp: 900, gain: -3 },
        // the gust that slammed it, still blowing past
        { src: 'oga/short-wind-sound/short wind sound.wav', from: 0.5, to: 1.6, rate: 0.7, hp: 150, lp: 1200, gain: -20, at: 0.05, fadeIn: 0.15, fadeOut: 0.3 },
      ];
    },
    finish: (ctx, mix) => ending(K.densify(withSub(mix, ctx.sr, { f0: 58, f1: 42, t60: 0.25, gain: -13 }), ctx.sr, 12), ctx.sr, 2.4, 0.6),
  }),
  event({
    name: 'ChildLaugh',
    title: 'A child laughing',
    description: 'A small giggle in the dark, where no child should be.',
    class: 'vocal',
    variants: 2,
    loudness: -22,
    layers: (variant) => [
      { src: 'oga/tiny-creatures-sounds/laugh.ogg', rate: [1.16, 1.08][variant - 1], lp: 2200, gain: 0, fadeIn: 0.02, fadeOut: 0.2 },
    ],
    // far down a hall: most of what reaches you is the room
    finish: (ctx, mix) => ending(inSpaceMono(mix, ctx, 'hall', 0.8), ctx.sr, 2.4, 0.6),
  }),
  event({
    name: 'ChildWhisper',
    title: 'A child whispering',
    description: 'A child whispering something you cannot make out.',
    class: 'breath',
    variants: 2,
    loudness: -26,
    layers: (variant) => {
      const order = variant === 1 ? [1, 3, 2, 4] : [2, 4, 1, 3];
      return order.map((n, k) => ({ src: `oga/dialog-vocal-samples/whisper_${n}.ogg`, rate: 0.9, hp: 200, lp: 2600, gain: -k, at: 0.05 + k * 0.33, fadeIn: 0.15, fadeOut: 0.08 }));
    },
    finish: (ctx, mix) => inSpaceMono(mix, ctx, 'room', 0.35),
  }),
];

