// sounds.js: the Tall Man's synth presets (Tunnels §3), recipes in the SynthPresets format (engine/audio/presets.js)
// built from the eleven synthesized sources and registered into the engine's preset table when the Creature is built.
//
//   TeleportHiss   the static hiss rising at a teleport's spot through its warning (3D)
//   RevealSting    the loud sting of a teleport reveal or a fake-out (2D, the target's own)
//   FakeoutShriek  the shriek inside a fake-out hiding spot (2D, the one who opened it)
//   StareSting     a held stare caught its attention: the chase starts (2D, the starer's)
//   ChaseSting     the chase music's hit as a chase starts on you (2D)
//   ChasePulse     the chase music layer: a driving low pulse while it chases you (2D loop)
//   GiveUpSwell    the reverse swell as a chase gives up and it dissolves (2D for the chased, else at it)
//   CreatureGrunt  the low grunt before a LookAway (3D)
//   CreatureRattle the low rattle in its throat while it stalks close by (3D)
//   HideWarn       a hiding spot's warning knock at 35 s: you cannot stay much longer (2D)
//   HideKick       shoved out of a hiding spot at 45 s (2D)
//   TorchStutter   the torch's filament crackling as it stutters in a teleport warning (2D)

import { Presets } from '../engine/audio/presets.js';

const EQ = (LowGain, MidGain, HighGain) => ({ kind: 'Equalizer', props: { LowGain, MidGain, HighGain } });
const DIST = (Level) => ({ kind: 'Distortion', props: { Level } });
const VERB = (DecayTime, WetLevel) => ({ kind: 'Reverb', props: { DecayTime, Density: 1, Diffusion: 1, DryLevel: 0, WetLevel } });
const ECHO = (Delay, Feedback, WetLevel) => ({ kind: 'Echo', props: { Delay, DryLevel: 0, Feedback, WetLevel } });
const FLANGE = (Depth, Rate, Mix = 0.5) => ({ kind: 'Flanger', props: { Depth, Mix, Rate } });
const TREM = (Depth, Frequency, Duty = 0.5) => ({ kind: 'Tremolo', props: { Depth, Duty, Frequency } });
const PITCH = (Octave) => ({ kind: 'PitchShift', props: { Octave } });
const COMP = { kind: 'Compressor', props: { Attack: 0.001, GainMakeup: 6, Ratio: 12, Release: 0.25, Threshold: -14 } };

/** The monster presets (SynthPresets recipes). */
export const MonsterPresets = Object.freeze({
  TeleportHiss: {
    bus: 'Monster', maxVoices: 2, priority: 85, rollOff: { min: 6, max: 70 }, captionText: '[static hissing, rising]',
    layers: [
      { duration: 1.7, looped: true, sample: 'Falling', region: { min: 0.1, max: 1.1 }, speed: 2.8, volume: 0.9,
        envelope: { attack: 1.3, hold: 0.25, release: 0.15 }, glide: { time: 1.6, to: 1.35 },
        effects: [DIST(0.85), TREM(0.8, 19, 0.35), EQ(-30, 0, 6)] },
      { duration: 1.6, looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 0.22, volume: 0.35,
        envelope: { attack: 1.2, hold: 0.3, release: 0.1 }, glide: { time: 1.6, to: 0.4 }, effects: [DIST(0.6), EQ(6, -4, -12)] },
      { delay: 0.3, sample: 'FootstepsPlastic', region: { min: 0, max: 0.3 }, speed: 3, volume: 0.35, volumeJitter: 0.5,
        grains: { count: { min: 6, max: 10 }, spacing: { min: 0.05, max: 0.14 } }, effects: [DIST(0.9), EQ(-24, 2, 6)] },
    ],
  },
  RevealSting: {
    bus: 'Monster', maxVoices: 1, priority: 95, captionText: '[a shrieking sting]',
    duck: [{ attack: 0.01, bus: 'Ambience', gain: 0.15, hold: 0.8, release: 1.4 }, { attack: 0.01, bus: 'World', gain: 0.5, hold: 0.5, release: 1 }],
    layers: [
      { region: { min: 0, max: 0.5 }, sample: 'Explosion', speed: 1.25, volume: 1.2, effects: [DIST(0.6), COMP] },
      { duration: 0.55, looped: true, region: { min: 0.05, max: 0.3 }, sample: 'Ouch', speed: 0.9, volume: 0.8,
        envelope: { attack: 0.004, release: 0.3 }, glide: { time: 0.5, to: 1.35 }, effects: [PITCH(2), DIST(0.8), EQ(-18, 2, 6)] },
      { delay: 0.02, duration: 0.5, looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 1.7, volume: 0.35,
        envelope: { attack: 0.002, release: 0.35 }, effects: [FLANGE(0.9, 7), DIST(0.5)] },
    ],
    space: [VERB(1.6, -6)],
  },
  FakeoutShriek: {
    bus: 'Monster', maxVoices: 1, priority: 90, captionText: '[a shriek inside the hiding spot]',
    duck: [{ attack: 0.02, bus: 'Ambience', gain: 0.2, hold: 0.6, release: 1.2 }],
    layers: [
      { duration: 0.9, looped: true, region: { min: 0.04, max: 0.3 }, sample: 'Ouch', speed: 0.85, volume: 1.1,
        envelope: { attack: 0.01, release: 0.45 }, glide: { time: 0.8, to: 1.5 }, effects: [PITCH(1.8), DIST(0.7), TREM(0.5, 15), EQ(-14, 3, 6)] },
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.1 }, speed: 0.8, volume: 0.9, effects: [EQ(4, 4, -6), ECHO(0.02, 0.35, -8)] },
    ],
    space: [VERB(0.8, -8)],
  },
  StareSting: {
    bus: 'Monster', maxVoices: 1, priority: 90, captionText: '[it sees you looking]',
    duck: [{ attack: 0.02, bus: 'Ambience', gain: 0.3, hold: 0.6, release: 1.2 }],
    layers: [
      { duration: 0.8, looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 0.55, volume: 0.6,
        envelope: { attack: 0.005, hold: 0.2, release: 0.5 }, glide: { time: 0.7, to: 0.5 }, effects: [DIST(0.7), FLANGE(0.8, 2.5), EQ(4, 2, -6)] },
      { region: { min: 0, max: 0.4 }, sample: 'Explosion', speed: 0.8, volume: 0.9, effects: [DIST(0.4), EQ(8, -2, -10), COMP] },
    ],
    space: [VERB(2.2, -6)],
  },
  ChaseSting: {
    bus: 'Ambience', maxVoices: 1, priority: 80,
    layers: [
      { region: { min: 0, max: 0.6 }, sample: 'Explosion', speed: 0.62, volume: 1.1, effects: [DIST(0.35), EQ(9, -4, -14), COMP] },
      { delay: 0.02, duration: 0.7, looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 0.36, volume: 0.45,
        envelope: { attack: 0.01, hold: 0.25, release: 0.4 }, effects: [DIST(0.5), TREM(0.6, 9), EQ(6, 0, -14)] },
    ],
    space: [VERB(1.8, -8)],
  },
  ChasePulse: {
    bus: 'Ambience', maxVoices: 1, priority: 70, looped: true, repeat: { interval: 0.42, jitter: 0 },
    layers: [
      { looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 0.18, volume: 0.32,
        effects: [TREM(0.45, 2.4), DIST(0.3), EQ(8, -6, -26)] },
      { sample: 'JumpLand', speed: { min: 0.36, max: 0.4 }, volume: 1.1, envelope: { attack: 0.003, hold: 0.08, release: 0.18 },
        effects: [EQ(10, -10, -40), COMP] },
      { delay: 0.21, chance: 0.7, sample: 'JumpLand', speed: 0.48, volume: 0.55, envelope: { attack: 0.003, hold: 0.05, release: 0.12 },
        effects: [EQ(8, -10, -40)] },
    ],
  },
  GiveUpSwell: {
    bus: 'Ambience', maxVoices: 1, priority: 75, captionText: '[a swell drawing in, then silence]',
    layers: [
      { duration: 1.4, looped: true, sample: 'Falling', region: { min: 0.1, max: 1.1 }, speed: 0.5, volume: 0.8,
        envelope: { attack: 1.25, hold: 0, release: 0.05 }, glide: { time: 1.3, to: 1.6 }, effects: [FLANGE(0.7, 0.4), EQ(4, 0, -10)] },
      { duration: 1.3, looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 0.2, volume: 0.4,
        envelope: { attack: 1.2, hold: 0, release: 0.05 }, glide: { time: 1.3, to: 0.7 }, effects: [DIST(0.4), EQ(6, -2, -18)] },
    ],
    space: [VERB(3.5, -4)],
  },
  CreatureGrunt: {
    bus: 'Monster', maxVoices: 2, priority: 70, rollOff: { min: 6, max: 60 }, captionText: '[a low grunt]',
    layers: [
      { duration: 0.6, looped: true, region: { min: 0.04, max: 0.3 }, sample: 'Oof', speed: { min: 0.3, max: 0.34 }, volume: 1.2,
        envelope: { attack: 0.05, hold: 0.2, release: 0.3 }, glide: { time: 0.5, to: 0.8 }, effects: [PITCH(0.6), DIST(0.5), EQ(8, -2, -16)] },
      { sample: 'Explosion', region: { min: 0, max: 0.3 }, speed: 0.35, volume: 0.4, effects: [EQ(6, -6, -30)] },
    ],
  },
  CreatureRattle: {
    bus: 'Monster', maxVoices: 2, priority: 55, rollOff: { min: 5, max: 40 },
    layers: [
      { duration: 1.1, looped: true, region: { min: 0.04, max: 0.3 }, sample: 'Oof', speed: { min: 0.26, max: 0.3 }, volume: 0.8,
        envelope: { attack: 0.2, hold: 0.5, release: 0.4 }, effects: [TREM(0.8, 22, 0.4), DIST(0.45), EQ(6, 0, -14)] },
    ],
  },
  HideWarn: {
    bus: 'Body', maxVoices: 1, priority: 70, captionText: '[something knocks on your hiding spot]',
    layers: [
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.1 }, speed: 0.7, volume: 1.8,
        grains: { count: { min: 3, max: 3 }, spacing: { min: 0.22, max: 0.26 } }, effects: [EQ(8, 4, -10), ECHO(0.02, 0.3, -10)] },
      { sample: 'JumpLand', speed: 0.6, volume: 0.9, grains: { count: { min: 3, max: 3 }, spacing: { min: 0.22, max: 0.26 } },
        effects: [EQ(8, 0, -14)] },
    ],
    space: [VERB(1.2, -10)],
  },
  HideKick: {
    bus: 'Body', maxVoices: 1, priority: 75, captionText: '[you are shoved out]',
    layers: [
      { sample: 'JumpLand', speed: 0.7, volume: 1.2, effects: [EQ(6, 2, -10), COMP] },
      { delay: 0.04, sample: 'FootstepsPlastic', region: { min: 0, max: 0.12 }, speed: 0.9, volume: 0.8, effects: [EQ(-2, 6, -4)] },
    ],
  },
  TorchStutter: {
    bus: 'Body', maxVoices: 1, priority: 60,
    layers: [
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.04 }, speed: 2.8, volume: 0.35, volumeJitter: 0.6,
        grains: { count: { min: 6, max: 10 }, spacing: { min: 0.06, max: 0.2 } }, effects: [DIST(0.9), EQ(-30, 2, 8)] },
    ],
  },
});

/** Adds the monster presets to the engine's table (idempotent; before any of them plays). */
export function registerMonsterSounds() {
  for (const [name, preset] of Object.entries(MonsterPresets)) if (!Presets[name]) Presets[name] = preset;
}
