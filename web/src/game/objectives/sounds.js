// sounds.js: the floor objectives' synth presets, recipes in the SynthPresets format (engine/audio/presets.js) built
// from the eleven synthesized sources, registered into the engine's preset table at start-up. Every one is a 3D World
// voice (Player for the hand-held ones) with a roll-off sized to how far it should carry; the noise the Creature hears
// is emitted separately (objectives/kit.js), never inferred from a sound.
//
//   ObjFuseClick       a cartridge fuse snapping into its clips            ObjBreakerThrow  the main breaker's clunk and the mains hum
//   ObjKeyJingle       a ring of keys (pickups, the unlock's rattle)       ObjKeysWork      the keys worked in a padlock (loop)
//   ObjPadlockClack    a padlock springing open                            ObjLockRattle    a locked padlock rattled (denied)
//   ObjKeypadDenied    the keypad's denied double beep                     ObjKeypadAccept  the keypad's rising accept chirp
//   ObjExitClunk       the stairwell door's lock bolts throwing back

import { Presets } from '../../engine/audio/presets.js';

const EQ = (LowGain, MidGain, HighGain) => ({ kind: 'Equalizer', props: { LowGain, MidGain, HighGain } });
const DIST = (Level) => ({ kind: 'Distortion', props: { Level } });
const VERB = (DecayTime, WetLevel) => ({ kind: 'Reverb', props: { DecayTime, Density: 1, Diffusion: 1, DryLevel: 0, WetLevel } });
const ECHO = (Delay, Feedback, WetLevel) => ({ kind: 'Echo', props: { Delay, DryLevel: 0, Feedback, WetLevel } });
const FLANGE = (Depth, Rate, Mix = 0.5) => ({ kind: 'Flanger', props: { Depth, Mix, Rate } });
const TREM = (Depth, Frequency) => ({ kind: 'Tremolo', props: { Depth, Duty: 0.5, Frequency } });
const CHORUS = (Depth, Rate) => ({ kind: 'Chorus', props: { Depth, Mix: 0.5, Rate } });
const COMP = { kind: 'Compressor', props: { Attack: 0.002, GainMakeup: 4, Ratio: 6, Release: 0.15, Threshold: -18 } };

/** The objective presets (SynthPresets recipes). */
export const ObjectivePresets = Object.freeze({
  ObjFuseClick: {
    bus: 'World', maxVoices: 3, priority: 45, rollOff: { min: 4, max: 45 },
    layers: [
      { sample: 'VolumeSlider', speed: { min: 2.4, max: 2.8 }, volume: 0.45, effects: [EQ(-20, 2, 6)] },
      { delay: 0.03, sample: 'FootstepsPlastic', region: { min: 0, max: 0.06 }, speed: 1.9, volume: 0.8, effects: [EQ(-10, 6, 4)] },
      { delay: 0.05, sample: 'JumpLand', speed: 1.7, volume: 0.35, effects: [EQ(-6, 2, -6)] },
    ],
  },
  ObjBreakerThrow: {
    bus: 'World', maxVoices: 2, priority: 75, rollOff: { min: 10, max: 160 }, caption: 'Caption.Breaker',
    captionText: '[a heavy breaker clanks over]',
    duck: [{ attack: 0.01, bus: 'Ambience', gain: 0.6, hold: 0.4, release: 1 }],
    layers: [
      { sample: 'JumpLand', speed: { min: 0.48, max: 0.55 }, volume: 1.5, effects: [EQ(8, 0, -12), COMP] },
      { delay: 0.01, sample: 'Explosion', region: { min: 0, max: 0.22 }, speed: 1.3, volume: 0.7, effects: [DIST(0.3), EQ(4, -2, -10)] },
      { delay: 0.04, sample: 'FootstepsPlastic', region: { min: 0, max: 0.2 }, speed: 2.2, volume: 0.6,
        grains: { count: { min: 2, max: 4 }, spacing: { min: 0.02, max: 0.05 } }, effects: [DIST(0.5), EQ(-18, 2, 6), ECHO(0.015, 0.35, -8)] },
      { delay: 0.25, duration: 3.6, looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 0.16, volume: 0.45,
        envelope: { attack: 0.5, hold: 1.4, release: 1.6 }, effects: [TREM(0.25, 6), EQ(6, 2, -24)] },
    ],
    space: [VERB(2.4, -6)],
  },
  ObjKeyJingle: {
    bus: 'Player', maxVoices: 3, priority: 45, rollOff: { min: 3, max: 40 },
    layers: [
      { sample: 'VolumeSlider', speed: { min: 2.6, max: 3.6 }, volume: 0.32, volumeJitter: 0.4,
        grains: { count: { min: 5, max: 8 }, spacing: { min: 0.025, max: 0.07 } }, effects: [EQ(-24, 0, 6), CHORUS(0.3, 4)] },
      { delay: 0.02, sample: 'FootstepsPlastic', region: { min: 0, max: 0.05 }, speed: { min: 2.2, max: 2.6 }, volume: 0.35,
        grains: { count: { min: 2, max: 4 }, spacing: { min: 0.04, max: 0.09 } }, effects: [EQ(-20, 4, 8)] },
    ],
  },
  ObjKeysWork: {
    bus: 'World', maxVoices: 2, priority: 45, rollOff: { min: 4, max: 50 }, looped: true, repeat: { interval: 0.42, jitter: 0.1 },
    layers: [
      { sample: 'VolumeSlider', speed: { min: 2.4, max: 3.4 }, volume: 0.3, volumeJitter: 0.4,
        grains: { count: { min: 3, max: 6 }, spacing: { min: 0.03, max: 0.08 } }, effects: [EQ(-24, 0, 6), CHORUS(0.3, 4)] },
      { chance: 0.6, sample: 'FootstepsPlastic', region: { min: 0, max: 0.08 }, speed: { min: 1.2, max: 1.5 }, volume: 0.45,
        effects: [EQ(-12, 6, 2), FLANGE(0.4, 4)] },
    ],
  },
  ObjPadlockClack: {
    bus: 'World', maxVoices: 2, priority: 55, rollOff: { min: 4, max: 60 },
    layers: [
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.07 }, speed: 1.35, volume: 0.9, effects: [EQ(-6, 6, 2)] },
      { delay: 0.04, sample: 'JumpLand', speed: 1.5, volume: 0.5, effects: [EQ(-4, 4, -4)] },
      { delay: 0.05, sample: 'VolumeSlider', speed: 1.9, volume: 0.35, effects: [EQ(-18, 2, 4), VERB(0.6, -12)] },
    ],
  },
  ObjLockRattle: {
    bus: 'World', maxVoices: 2, priority: 40, rollOff: { min: 3, max: 35 },
    layers: [
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.06 }, speed: { min: 1.3, max: 1.6 }, volume: 0.7,
        grains: { count: { min: 3, max: 5 }, spacing: { min: 0.05, max: 0.08 } }, effects: [EQ(-10, 6, 2), FLANGE(0.4, 6)] },
      { sample: 'VolumeSlider', speed: { min: 1.9, max: 2.4 }, volume: 0.25,
        grains: { count: { min: 3, max: 4 }, spacing: { min: 0.05, max: 0.08 } }, effects: [EQ(-20, 2, 4)] },
    ],
  },
  ObjKeypadDenied: {
    bus: 'World', maxVoices: 2, priority: 40, rollOff: { min: 3, max: 35 },
    layers: [
      { duration: 0.16, looped: true, region: { min: 0.02, max: 0.026 }, sample: 'VolumeSlider', speed: 0.75, volume: 0.35,
        envelope: { attack: 0.005, hold: 0.12, release: 0.03 }, effects: [EQ(-12, 4, -6), DIST(0.2)] },
      { delay: 0.22, duration: 0.16, looped: true, region: { min: 0.02, max: 0.026 }, sample: 'VolumeSlider', speed: 0.62, volume: 0.35,
        envelope: { attack: 0.005, hold: 0.12, release: 0.03 }, effects: [EQ(-12, 4, -6), DIST(0.2)] },
    ],
  },
  ObjKeypadAccept: {
    bus: 'World', maxVoices: 2, priority: 50, rollOff: { min: 4, max: 50 },
    layers: [
      { duration: 0.1, looped: true, region: { min: 0.02, max: 0.026 }, sample: 'VolumeSlider', speed: 1.4, volume: 0.32,
        envelope: { attack: 0.005, hold: 0.07, release: 0.02 }, effects: [EQ(-18, 4, 0)] },
      { delay: 0.12, duration: 0.18, looped: true, region: { min: 0.02, max: 0.026 }, sample: 'VolumeSlider', speed: 1.9, volume: 0.32,
        envelope: { attack: 0.005, hold: 0.12, release: 0.04 }, effects: [EQ(-18, 4, 0), VERB(0.5, -12)] },
    ],
  },
  ObjExitClunk: {
    bus: 'World', maxVoices: 2, priority: 80, rollOff: { min: 12, max: 200 }, caption: 'Caption.ExitUnlock',
    captionText: '[a heavy lock clunks open]',
    duck: [{ attack: 0.01, bus: 'Ambience', gain: 0.55, hold: 0.5, release: 1 }],
    layers: [
      { sample: 'JumpLand', speed: { min: 0.42, max: 0.48 }, volume: 1.6, effects: [EQ(9, -2, -16), COMP] },
      { delay: 0.02, sample: 'Explosion', region: { min: 0, max: 0.3 }, speed: 1.15, volume: 0.7, effects: [DIST(0.25), EQ(5, -2, -10)] },
      { delay: 0.05, sample: 'FootstepsPlastic', region: { min: 0, max: 0.12 }, speed: 1.4, volume: 0.8,
        grains: { count: { min: 2, max: 3 }, spacing: { min: 0.06, max: 0.1 } }, effects: [EQ(-12, 6, 4), ECHO(0.03, 0.3, -8)] },
    ],
    space: [VERB(2.8, -5)],
  },
});

/** Adds the objective presets to the engine's table (idempotent; before any of them plays). */
export function registerObjectiveSounds() {
  for (const [name, preset] of Object.entries(ObjectivePresets)) if (!Presets[name]) Presets[name] = preset;
}
