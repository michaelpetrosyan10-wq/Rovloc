// world.mjs: what a player or a machine does at a place: doors and hinges, lockers, metal, the vents, the traps,
// the breaker, fuses, locks and keys, the generator, pickups, the radar. Real foley (the metal-and-wood and
// breaking packs, a spooky door hinge, door locks, circuit breakers, keys), played a little slower than recorded so
// the school sounds big, old and heavy; small things (pickups, the radar, the keypad) muffled and low.
//
// None of these is his: a door torn apart is a door, not his voice, and nothing here uses a recording of his.

import * as K from '../kit/index.mjs';
import { recorded, withSub, inSpaceMono, ending } from '../lib/recipe.mjs';

const FAMILY = 'world';
const MW = 'oga/100-cc0-metal-and-wood-sfx';
const SFX = 'oga/100-cc0-sfx';
const SFX2 = 'oga/100-cc0-sfx-2';
const BFH = 'oga/75-cc0-breaking-falling-hit-sfx';
const RPG = 'kenney/rpg-audio';
const IMPACT = 'kenney/impact-sounds';
const HINGE = 'oga/creaky-door-hinge-spooky/creaky_door_hinge.wav';
const VSE = 'oga/various-sound-effects';
const LOCKS = 'oga/door-lock-sounds';
const BREAKER = 'oga/sfx-circuit-breaker';
const RANDOM = 'oga/58-random-sound-effects';
const RPGSFX = 'oga/80-cc0-rpg-sfx';

function w(v) {
  return recorded({ family: FAMILY, group: 'world', channels: 1, loop: null, space: 'dry', board: 'Doors and lockers', ...v });
}
const lp = (hz) => (ctx, mix) => K.butter(mix, ctx.sr, 'lowpass', hz, 4);

/** @type {import('../lib/voices.mjs').Voice[]} */
export const voices = [
  // ------------------------------------------------------------------------------------------------ doors
  w({
    name: 'DoorCreak',
    title: 'A door creaking',
    description: 'A classroom door swinging on old hinges: a long, dry groan.',
    class: 'friction',
    variants: 3,
    first: true,
    loudness: -21,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: HINGE, from: [0.2, 1.5, 2.7][i], to: [1.3, 2.6, 3.8][i], rate: [0.72, 0.78], lp: 2600, gain: 0, fadeIn: 0.05, fadeOut: 0.2 },
        { src: `${RPG}/doorOpen_${1 + (i % 2)}.ogg`, rate: 0.8, lp: 2000, gain: -8, at: 0.1 },
      ];
    },
  }),
  w({
    name: 'DoorSmash',
    title: 'A door torn apart',
    description: 'A door smashed off its frame: splintering wood and a heavy slab hitting the floor.',
    class: 'body',
    variants: 2,
    first: true,
    loudness: -15.5,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${IMPACT}/impactWood_heavy_00${[1, 3][i]}.ogg`, rate: 0.55, lp: 1800, drive: 4, gain: 0 },
        { src: `${MW}/wood_breaking_0${1 + i}.ogg`, rate: 0.7, lp: 3000, gain: -2, at: 0.01 },
        { src: `${BFH}/bfh1_wood_breaking_0${[3, 1][i]}.ogg`, rate: 0.75, lp: 3000, gain: -5, at: 0.12 },
        { src: `${BFH}/bfh1_wood_falling_0${1 + i}.ogg`, rate: 0.6, lp: 1600, gain: -3, at: 0.55 },
      ];
    },
    finish: (ctx, mix) => K.densify(withSub(K.butter(mix, ctx.sr, 'lowpass', 3000, 4), ctx.sr, { f0: 60, f1: 40, t60: 0.5, gain: -6 }), ctx.sr, 12),
  }),
  w({
    name: 'FireDoorLatch',
    title: 'A fire door slamming',
    description: 'A heavy fire door slamming shut, its bar latching with a clank that rings down the corridor.',
    class: 'body',
    variants: 2,
    first: true,
    loudness: -17,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${SFX}/door_close_0${[3, 4][i]}.ogg`, rate: 0.7, lp: 2400, trim: true, gain: 0 },
        { src: `${MW}/metal_close_01.ogg`, rate: [0.6, 0.66][i], lp: 2400, trim: true, gain: -3 },
        { src: `${RPG}/metalLatch.ogg`, rate: 0.7, lp: 2600, gain: -8, at: 0.06 },
      ];
    },
    finish: (ctx, mix) => inSpaceMono(withSub(mix, ctx.sr, { f0: 64, f1: 44, t60: 0.3, gain: -10 }), ctx, 'corridor', 0.2),
  }),
  w({
    name: 'FireDoorSwing',
    title: 'A fire door swinging',
    description: 'A heavy fire door pushed open: its hinge groaning under the weight.',
    class: 'friction',
    variants: 2,
    first: true,
    loudness: -22,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: HINGE, from: [0.5, 2.2][i], to: [2.0, 3.7][i], rate: 0.6, lp: 1800, gain: 0, fadeIn: 0.1, fadeOut: 0.3 },
        { src: `${SFX2}/sfx100v2_air_02.ogg`, rate: 0.7, lp: 1200, gain: -12, fadeIn: 0.2 },
      ];
    },
  }),
  w({
    name: 'GateSlam',
    title: 'A gate slamming',
    description: 'A steel gate slammed shut: a crash of bars and the chain swinging after it.',
    class: 'body',
    variants: 2,
    loudness: -16,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${MW}/metal_slam_01.ogg`, rate: [0.62, 0.68][i], lp: 2600, drive: 3, gain: 0 },
        { src: `${MW}/metal_falling_02.ogg`, rate: 0.7, lp: 2400, gain: -5, at: 0.02 },
        { src: `${RPGSFX}/chain_0${1 + i}.ogg`, rate: 0.75, lp: 2400, gain: -8, at: 0.15 },
      ];
    },
    finish: (ctx, mix) => ending(inSpaceMono(withSub(mix, ctx.sr, { f0: 60, f1: 42, t60: 0.4, gain: -8 }), ctx, 'hall', 0.2), ctx.sr, 2.4, 0.5),
  }),
  // ------------------------------------------------------------------------------------------------ lockers
  w({
    name: 'LockerDoor',
    title: 'A locker door',
    description: 'A steel locker door pulled open or shut: thin metal rattling in its frame.',
    class: 'body',
    variants: 3,
    first: true,
    loudness: -20,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: [`${MW}/metal_open_01.ogg`, `${MW}/metal_close_01.ogg`, `${MW}/metal_open_01.ogg`][i], rate: [0.78, 0.72, 0.68][i], lp: 2400, gain: 0 },
        { src: `${MW}/metal_sheet_0${[2, 5, 6][i]}.ogg`, rate: 0.7, lp: 2200, gain: -6, at: 0.08 },
        { src: `${IMPACT}/impactSoft_medium_00${i + 1}.ogg`, rate: 0.7, lp: 1000, gain: -6 },
      ];
    },
  }),
  w({
    name: 'LockerRip',
    title: 'A locker door torn off',
    description: 'A locker door wrenched off its hinges: metal shrieking low, then crashing to the floor.',
    class: 'body',
    variants: 2,
    loudness: -15.5,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${VSE}/grind_metal.wav`, rate: [0.5, 0.56][i], lp: 2200, drive: 3, trim: true, gain: -2, at: 0.03, fadeOut: 0.2 },
        { src: `${IMPACT}/impactMetal_medium_00${[1, 4][i]}.ogg`, rate: 0.55, lp: 1800, trim: true, gain: -2 },
        { src: `${MW}/metal_slam_01.ogg`, rate: 0.55, lp: 2000, gain: 0, at: 0.3 },
        { src: `${MW}/metal_falling_01.ogg`, from: 0, to: 1.2, rate: 0.75, lp: 2400, gain: -4, at: 0.45, fadeOut: 0.3 },
      ];
    },
    finish: (ctx, mix) => ending(withSub(mix, ctx.sr, { f0: 58, f1: 40, t60: 0.45, gain: -8, at: 0.3 }), ctx.sr, 2.4, 0.5),
  }),
  w({
    name: 'LockerSlam',
    title: 'A locker banging',
    description: 'A locker door banging shut somewhere along the row.',
    class: 'body',
    variants: 3,
    loudness: -18,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${MW}/metal_close_01.ogg`, rate: [0.6, 0.66, 0.72][i], lp: 2400, trim: true, gain: 0 },
        { src: `${MW}/metal_sheet_0${[1, 3, 4][i]}.ogg`, rate: 0.6, lp: 2000, gain: -5, at: 0.01 },
      ];
    },
    finish: (ctx, mix) => inSpaceMono(mix, ctx, 'corridor', 0.25),
  }),
  // ------------------------------------------------------------------------------------------------ metal, vents, traps
  w({
    name: 'MetalCrash',
    title: 'Metal crashing down',
    description: 'A vent grate or a sheet of steel crashing to the floor and clattering to rest.',
    class: 'body',
    variants: 2,
    loudness: -16,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${BFH}/bfh1_metal_falling_0${1 + i}.ogg`, rate: 0.7, lp: 2600, gain: 0 },
        { src: `${MW}/metal_falling_0${1 + i}.ogg`, from: 0, to: 1.3, rate: 0.72, lp: 2400, gain: -3, at: 0.02, fadeOut: 0.3 },
        { src: `${IMPACT}/impactMetal_medium_00${i}.ogg`, rate: 0.5, lp: 1200, gain: 0 },
      ];
    },
    finish: (ctx, mix) => withSub(mix, ctx.sr, { f0: 62, f1: 44, t60: 0.3, gain: -6 }),
  }),
  w({
    name: 'MetalCreak',
    title: 'Metal creaking',
    description: 'Old metal bending under weight: a slow, grinding creak.',
    class: 'friction',
    variants: 3,
    loudness: -22,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `oga/chain-winch-sounds/winch - Marker #${[2, 5, 7][i]}.wav`, from: 0.1, to: 1.3, rate: 0.55, lp: 2000, gain: 0, fadeIn: 0.08, fadeOut: 0.25 },
        { src: `${MW}/metal_spring_0${1 + (i % 2)}.ogg`, rate: 0.45, lp: 1600, gain: -8, at: 0.2 },
      ];
    },
  }),
  w({
    name: 'VentScrape',
    title: 'Scraping inside the walls',
    description: 'Something heavy dragging itself through the ducts: metal scraping, slow and close behind the wall.',
    group: 'reference',
    class: 'friction',
    repeats: true,
    variants: 4,
    first: true,
    loudness: -21,
    board: 'Him',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `oga/scrapes/scrape-${[2, 4, 6, 8][i]}.ogg`, rate: [0.48, 0.54], hp: 80, lp: 1800, gain: 0, fadeIn: 0.05, fadeOut: 0.2 },
        { src: `${MW}/metal_sheet_0${[1, 3, 5, 6][i]}.ogg`, rate: 0.5, lp: 1200, gain: -6, at: [0.1, 0.4] },
      ];
    },
    finish: (ctx, mix) => ending(K.biquad(mix, ctx.sr, 'peak', 420, 3, 4), ctx.sr, 2.3, 0.4),
  }),
  w({
    name: 'VentCrawl',
    title: 'You crawling in a vent',
    description: 'You crawling through a duct: knees and hands on thin metal, the duct booming softly.',
    class: 'friction',
    variants: 1,
    loop: { seconds: 8, crossfade: 0 },
    loudness: -24,
    board: 'Your footsteps',
    layers: () => {
      const layers = [];
      for (let k = 0; k < 12; k++) {
        layers.push({ src: `oga/footsteps-leather-cloth-armor/step_metal${['', ' (2)', ' (4)'][k % 3]}.ogg`, rate: 0.6 + 0.04 * (k % 4), lp: 1600, gain: k % 2 ? -4 : 0, at: 0.3 + k * 0.66 });
        layers.push({ src: `oga/footsteps-leather-cloth-armor/step_cloth${1 + (k % 4)}.ogg`, rate: 0.7, lp: 1400, gain: -6, at: 0.35 + k * 0.66 });
      }
      return layers;
    },
    finish: (ctx, mix) => K.biquad(mix, ctx.sr, 'peak', 380, 3, 5),
  }),
  w({
    name: 'Unscrew',
    title: 'Unscrewing a grate',
    description: 'A screw turning out of a vent grate, a squeal of thread at a time.',
    class: 'friction',
    repeats: true,
    variants: 4,
    loudness: -26,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: 'oga/fantasy-sound-effects-tinysized-sfx/bottle-plastic-lid-unscrew-01.wav', from: 0.05 + 0.3 * i, to: 0.4 + 0.3 * i, rate: 0.7, lp: 2400, gain: 0, fadeIn: 0.01, fadeOut: 0.05 },
        { src: `${MW}/tools_0${[1, 3, 5, 7][i]}.ogg`, from: 0, to: 0.3, rate: 0.6, lp: 2000, gain: -8, fadeOut: 0.1 },
      ];
    },
  }),
  w({
    name: 'TrapSnap',
    title: 'A trap snapping shut',
    description: 'Steel jaws snapping shut: a hard spring and a heavy clank.',
    class: 'body',
    variants: 3,
    first: true,
    loudness: -16,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${MW}/metal_spring_0${1 + (i % 2)}.ogg`, rate: 0.75, lp: 3000, gain: -2 },
        { src: `${IMPACT}/impactMetal_medium_00${i + 2}.ogg`, rate: 0.55, lp: 1800, drive: 3, gain: 0 },
        { src: `${MW}/metal_hit_0${[2, 4, 5][i]}.ogg`, rate: 0.5, lp: 2200, gain: -6, at: 0.01 },
      ];
    },
    finish: (ctx, mix) => K.densify(withSub(mix, ctx.sr, { f0: 66, f1: 46, t60: 0.22, gain: -5 }), ctx.sr, 12),
  }),
  w({
    name: 'BoneCrunch',
    title: 'Caught in the trap',
    description: 'The trap closing on a leg: a dull, dry crack through cloth and a thud. Never wet.',
    class: 'body',
    variants: 2,
    loudness: -18,
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${IMPACT}/impactSoft_medium_00${[3, 4][i]}.ogg`, rate: 0.6, lp: 1200, gain: 0 },
        { src: `${MW}/wood_cracking_0${[1, 4][i]}.ogg`, rate: 0.6, lp: 1300, gain: -4, at: 0.02 },
        { src: 'oga/footsteps-leather-cloth-armor/step_cloth3.ogg', rate: 0.6, lp: 1000, gain: -8 },
      ];
    },
    finish: (ctx, mix) => K.densify(K.butter(mix, ctx.sr, 'lowpass', 1600, 4), ctx.sr, 12),
  }),
  // ------------------------------------------------------------------------------------------------ power and machines
  w({
    name: 'ObjBreakerThrow',
    title: 'The breaker thrown',
    description: 'A heavy breaker lever clanking over and the power coming back with a deep thump.',
    class: 'body',
    variants: 2,
    loudness: -17,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${BREAKER}/switch ${['on', 'off'][i]}.wav`, rate: [0.7, 0.6][i], lp: 2600, trim: true, gain: 0 },
        { src: `${IMPACT}/impactMetal_medium_00${i + 1}.ogg`, rate: 0.5, lp: 1400, trim: true, gain: -1 },
        { src: 'oga/electricity-game-sound-pack/powerup.wav', from: 0, to: 1.6, rate: [0.5, 0.42][i], lp: 900, gain: [-9, -5][i], at: 0.15, fadeOut: 0.4 },
      ];
    },
    finish: (ctx, mix) => ending(K.densify(withSub(mix, ctx.sr, { f0: 56, f1: 40, t60: 0.5, gain: -10, at: 0.02 }), ctx.sr, 12), ctx.sr, 2.4, 0.6),
  }),
  w({
    name: 'ObjExitClunk',
    title: 'The exit unlocking',
    description: 'A heavy lock clunking open: a bolt drawn back inside a steel door.',
    class: 'body',
    variants: 2,
    loudness: -18,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${LOCKS}/UnlockDoor.wav`, rate: [0.6, 0.66][i], lp: 2400, gain: 0 },
        { src: `${RPG}/metalLatch.ogg`, rate: 0.55, lp: 2000, gain: -4, at: 0.12 },
        { src: `${IMPACT}/impactMetal_medium_00${[3, 4][i]}.ogg`, rate: 0.5, lp: 1200, gain: -5, at: 0.14 },
      ];
    },
    finish: (ctx, mix) => withSub(mix, ctx.sr, { f0: 60, f1: 44, t60: 0.25, gain: -12, at: 0.14 }),
  }),
  w({
    name: 'ObjFuseClick',
    title: 'A fuse seated',
    description: 'A fuse pushed home into its holder: a dull, solid snap.',
    class: 'light',
    variants: 3,
    loudness: -26,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `oga/light-switch-turn-on-and-off-sfx-0/light_switch_turn_${['on', 'off', 'on'][i]}.mp3`, rate: [0.6, 0.64, 0.7][i], lp: 1800, gain: 0 },
        { src: `${IMPACT}/impactSoft_medium_00${i}.ogg`, rate: 0.9, lp: 1200, gain: -6 },
      ];
    },
  }),
  w({
    name: 'ObjKeyJingle',
    title: 'Keys picked up',
    description: 'A ring of keys picked up: heavy old keys jingling.',
    class: 'keys',
    variants: 3,
    loudness: -22,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${MW}/keys_0${[2, 5, 4][i]}.ogg`, rate: 0.85, lp: 6000, trim: true, gain: 0 },
        { src: `${RANDOM}/Keys_0${[1, 2, 3][i]}.wav`, rate: 0.8, lp: 5000, gain: -6, at: 0.03 },
      ];
    },
  }),
  w({
    name: 'ObjKeysWork',
    title: 'A key working in a lock',
    description: 'A key turning and catching in a stiff old lock.',
    class: 'friction',
    repeats: true,
    variants: 4,
    loudness: -24,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${VSE}/lock_pick.wav`, from: 0.05 + 0.4 * i, to: 0.42 + 0.4 * i, rate: 0.8, lp: 2600, gain: 0, fadeIn: 0.01, fadeOut: 0.05 },
        { src: `${MW}/keys_0${[1, 3, 4, 7][i]}.ogg`, from: 0, to: 0.3, rate: 0.75, lp: 2400, gain: -8, fadeOut: 0.08 },
      ];
    },
    finish: lp(2000),
  }),
  w({
    name: 'ObjLockRattle',
    title: 'A locked door rattled',
    description: 'A locked door handle yanked and rattled: it will not open.',
    class: 'friction',
    variants: 3,
    loudness: -21,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${LOCKS}/LockedDoorHandleJiggle.wav`, rate: [0.72, 0.78, 0.84][i], lp: 2600, gain: 0 },
        { src: `${SFX}/door_close_0${[1, 3, 4][i]}.ogg`, rate: 0.6, lp: 1600, gain: -10, at: 0.05 },
      ];
    },
  }),
  w({
    name: 'ObjPadlockClack',
    title: 'A padlock opening',
    description: 'A heavy padlock snapping open.',
    class: 'body',
    variants: 3,
    loudness: -22,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${RPGSFX}/lock_0${i + 1}.ogg`, rate: 0.7, lp: 2400, gain: 0 },
        { src: `${IMPACT}/impactMetal_light_00${i}.ogg`, rate: 0.55, lp: 1600, gain: -6, at: 0.01 },
        { src: `${IMPACT}/impactSoft_medium_00${i + 2}.ogg`, rate: 0.6, lp: 900, gain: 0 },
      ];
    },
    finish: (ctx, mix) => withSub(mix, ctx.sr, { f0: 70, f1: 50, t60: 0.12, gain: -8 }),
  }),
  w({
    name: 'ObjKeypadAccept',
    title: 'The keypad accepts',
    description: 'A worn keypad accepting the code: the button, then the lock\'s solenoid pulling back with a thunk.',
    class: 'light',
    variants: 2,
    loudness: -26,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${VSE}/switch_${['on', 'off'][i]}.wav`, rate: [0.7, 0.8][i], lp: 1800, trim: true, gain: -3 },
        { src: [`${LOCKS}/DoorLock.wav`, `${LOCKS}/UnlockDoor.wav`][i], rate: [0.62, 0.7][i], lp: 1800, trim: true, gain: 0, at: [0.1, 0.14][i] },
      ];
    },
  }),
  w({
    name: 'ObjKeypadDenied',
    title: 'The keypad refuses',
    description: 'A worn keypad refusing the code: a low, ugly buzz.',
    class: 'light',
    variants: 2,
    loudness: -26,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: 'oga/ui-sounds-0/Wrong Error.wav', rate: [0.5, 0.56][i], lp: 1600, gain: 0, fadeOut: 0.05 },
        { src: 'oga/electricity-game-sound-pack/shieldloop.wav', from: 0.1 + 0.3 * i, to: 0.4 + 0.3 * i, rate: 1.3, lp: 1200, drive: 8, gain: -6, fadeOut: 0.05 },
      ];
    },
  }),
  w({
    name: 'BoilerHum',
    title: 'The boiler',
    description: 'The old boiler running: a deep, uneven mechanical drone.',
    class: 'friction',
    variants: 1,
    loop: { seconds: 8, crossfade: 0.6 },
    loudness: -26,
    board: 'Power and machines',
    layers: () => [
      { src: 'oga/generator-loop/loop_generator_1.mp3', rate: 0.62, hp: 50, lp: 1200, gain: -4 },
      { src: `${SFX2}/sfx100v2_loop_machine_02.ogg`, rate: 0.75, hp: 90, lp: 2000, gain: 0 },
      { src: `${SFX2}/sfx100v2_loop_machine_01.ogg`, rate: 0.6, hp: 60, lp: 900, gain: -6 },
    ],
  }),
  w({
    name: 'BoilerSurge',
    title: 'The boiler roaring',
    description: 'The boiler surging: steam blasting out and the whole thing roaring and shuddering.',
    class: 'swell',
    variants: 2,
    loudness: -17,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `oga/steam-release-sounds/steam hisses - Marker #${[1, 4][i]}.wav`, rate: 0.6, hp: 120, lp: 2400, gain: 0, fadeIn: 0.15, fadeOut: 0.4 },
        { src: 'oga/generator-loop/loop_generator_1.mp3', from: 0.5, to: 2.0, rate: 0.5, lp: 900, gain: -2, fadeIn: 0.3, fadeOut: 0.4 },
        { src: 'oga/rumble-fx/rumble.flac', from: 2 + 4 * i, to: 4.3 + 4 * i, rate: 1, lp: 400, gain: -4, fadeIn: 0.3, fadeOut: 0.5 },
      ];
    },
    finish: (ctx, mix) => ending(mix, ctx.sr, 2.4, 0.5),
  }),
  w({
    name: 'FluorescentBuzz',
    title: 'A failing light tube',
    description: 'An old light tube buzzing and flickering overhead.',
    class: 'friction',
    variants: 1,
    loop: { seconds: 8, crossfade: 0.6 },
    loudness: -32,
    board: 'Power and machines',
    // the ballast's hum (a coil's mains hum, a loop of a second, driven until it buzzes) laid end to end with
    // overlaps, a crackle now and then
    layers: () => [
      ...Array.from({ length: 9 }, (_, k) => ({ src: 'oga/electricity-game-sound-pack/shieldloop.wav', rate: 1.0 + 0.02 * (k % 3), hp: 90, lp: 2400, drive: 14, gain: k % 4 === 3 ? -3 : 0, at: k * 0.89, fadeIn: 0.12, fadeOut: 0.12 })),
      { src: 'oga/electricity-game-sound-pack/crackleelectricityloop.wav', rate: 0.6, lp: 2400, gain: -10, at: 2.2, fadeIn: 0.02, fadeOut: 0.1 },
      { src: 'oga/electricity-game-sound-pack/crackleelectricityloop.wav', rate: 0.55, lp: 2400, gain: -12, at: 5.6, fadeIn: 0.02, fadeOut: 0.1 },
    ],
  }),
  w({
    name: 'EmfStatic',
    title: 'Static in your torch',
    description: 'Your torch crackling with interference: something is close.',
    class: 'spark',
    repeats: true,
    variants: 4,
    channels: 1,
    space: 'baked',
    loudness: -28,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: 'oga/static/ScatterNoise1.mp3', from: 1 + 3 * i, to: 1.4 + 3 * i, rate: 0.7, hp: 300, lp: 3200, gain: 0, fadeIn: 0.01, fadeOut: 0.08, trim: true },
        { src: 'oga/miscmenu-sci-fi-sounds/walkie static.wav', rate: 0.7 + 0.05 * i, lp: 3000, trim: true, gain: -4 },
      ];
    },
  }),
  // ------------------------------------------------------------------------------------------------ small things
  w({
    name: 'Pickup',
    title: 'Picking something up',
    description: 'You pocket something: a muffled knock of it into your jacket.',
    class: 'light',
    variants: 3,
    channels: 1,
    space: 'baked',
    first: true,
    loudness: -26,
    board: 'Power and machines',
    layers: (variant) => {
      const i = variant - 1;
      return [
        { src: `${RPG}/handleSmallLeather${['', '2', ''][i]}.ogg`, rate: [0.8, 0.9, 0.66][i], lp: 1500, trim: true, gain: 0 },
        { src: `${RPG}/beltHandle${1 + (i % 2)}.ogg`, rate: [0.7, 0.62, 0.8][i], lp: 1400, trim: true, gain: [-6, -3, -9][i], at: 0.03 },
      ];
    },
    finish: lp(1800),
  }),
  w({
    name: 'RadarPing',
    title: 'The radar pinging',
    description: 'Your radar marking something: a soft, low sonar ping where it is.',
    class: 'light',
    variants: 1,
    channels: 1,
    space: 'dry',
    loudness: -27,
    board: 'Power and machines',
    layers: () => [
      { src: 'oga/sonar-ping/sonar_ping_0.mp3', from: 0, to: 0.5, rate: 0.6, lp: 1800, trim: true, gain: 0, fadeOut: 0.25 },
    ],
  }),
  w({
    name: 'RadarEmpty',
    title: 'The radar finds nothing',
    description: 'The radar comes back empty: a dull, dead click.',
    class: 'light',
    variants: 1,
    channels: 1,
    space: 'baked',
    loudness: -28,
    board: 'Power and machines',
    layers: () => [
      { src: `${VSE}/switch_off.wav`, rate: 0.6, lp: 1600, trim: true, gain: 0 },
      { src: `${RPG}/metalClick.ogg`, rate: 0.55, lp: 1400, trim: true, gain: -6, at: 0.04 },
    ],
    finish: (ctx, mix) => ending(mix, ctx.sr, 0.6, 0.15),
  }),
];
