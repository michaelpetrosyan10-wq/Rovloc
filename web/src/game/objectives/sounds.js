// sounds.js: the floor objectives' synth presets, recipes in the SynthPresets format (engine/audio/presets.js) built
// from the eleven synthesized sources, registered into the engine's preset table at start-up. Every one is a 3D World
// voice (Player for the hand-held ones) with a roll-off sized to how far it should carry; the noise the Creature hears
// is emitted separately (objectives/kit.js), never inferred from a sound.
//
//   ObjFuseClick       a cartridge fuse snapping into its clips            ObjBreakerThrow  the main breaker's clunk and the mains hum
//   ObjKeyJingle       a ring of keys (pickups, the unlock's rattle)       ObjKeysWork      the keys worked in a padlock (loop)
//   ObjPadlockClack    a padlock springing open                            ObjBubbling      the fume hood's mix bubbling and hissing (loop)
//   ObjAcidSizzle      acid eating into steel                              ObjGeneratorPull the pull-start's cord and the sputter catching
//   ObjGeneratorRun    the generator running (loop)                        ObjMotorWhine    the stairwell door motor winding (loop)
//   ObjValveSqueal     a seized valve stem turning (loop)                  ObjBoltSnap      bolt cutters biting through a link
//   ObjChainDrop       a chain slithering off and landing                  ObjLockRattle    a locked padlock / chain rattled (denied)
//   ObjKeypadDenied    the keypad's denied double beep                     ObjKeypadAccept  the keypad's rising accept chirp
//   ObjExitClunk       the stairwell door's lock bolts throwing back       ObjLockerSearch  a locker door eased open to look inside
//   ObjWheelFit        the valve wheel clanking onto its stem              ObjItemPickup    a heavy item taken up (tools, the wheel)

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
  ObjBubbling: {
    bus: 'World', maxVoices: 2, priority: 45, rollOff: { min: 4, max: 60 }, looped: true, repeat: { interval: 0.3, jitter: 0.08 },
    caption: 'Caption.Bubbling', captionText: '[chemicals bubbling]',
    layers: [
      { looped: true, sample: 'Falling', region: { min: 0.1, max: 1.1 }, speed: 2.1, volume: 0.45, effects: [EQ(-30, -4, 6), TREM(0.4, 7)] },
      { sample: 'WaterImpact', region: { min: 0.05, max: 0.15 }, regionJitter: 0.05, speed: { min: 2.2, max: 3.2 }, volume: 0.4,
        volumeJitter: 0.5, grains: { count: { min: 2, max: 5 }, spacing: { min: 0.04, max: 0.1 } }, effects: [EQ(-12, 4, -12), CHORUS(0.5, 2.5)] },
    ],
  },
  ObjAcidSizzle: {
    bus: 'World', maxVoices: 3, priority: 55, rollOff: { min: 6, max: 80 }, caption: 'Caption.AcidSizzle',
    captionText: '[acid sizzling on metal]',
    layers: [
      { duration: 3.2, looped: true, sample: 'Falling', region: { min: 0.1, max: 1.1 }, speed: { min: 2.6, max: 3 }, volume: 0.9,
        envelope: { attack: 0.03, hold: 1.8, release: 1.3 }, effects: [EQ(-30, -2, 8), DIST(0.35)] },
      { duration: 2.8, looped: true, sample: 'Swim', speed: { min: 3, max: 3.4 }, volume: 0.5,
        envelope: { attack: 0.05, hold: 1.6, release: 1.1 }, effects: [EQ(-24, 0, 6), DIST(0.5)] },
      { sample: 'VolumeSlider', speed: 3.2, volume: 0.25, grains: { count: { min: 6, max: 10 }, spacing: { min: 0.05, max: 0.18 } },
        volumeJitter: 0.6, effects: [EQ(-30, 0, 4)] },
    ],
  },
  ObjGeneratorPull: {
    bus: 'World', maxVoices: 2, priority: 70, rollOff: { min: 8, max: 150 },
    layers: [
      { sample: 'Jump', speed: 1.35, volume: 0.8, glide: { time: 0.35, to: 0.7 }, effects: [EQ(-6, 4, 2)] },
      { delay: 0.3, sample: 'Explosion', region: { min: 0, max: 0.09 }, speed: { min: 1.6, max: 2 }, volume: 0.5,
        grains: { count: { min: 5, max: 7 }, spacing: { min: 0.07, max: 0.12 } }, volumeJitter: 0.4, effects: [DIST(0.4), EQ(6, 2, -14)] },
      { delay: 0.85, duration: 0.9, looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 0.42, volume: 0.5,
        envelope: { attack: 0.2, hold: 0.4, release: 0.3 }, glide: { time: 0.6, to: 1.25 }, effects: [TREM(0.6, 14), DIST(0.3)] },
    ],
    space: [VERB(2, -8)],
  },
  ObjGeneratorRun: {
    bus: 'World', maxVoices: 2, priority: 60, rollOff: { min: 8, max: 130 }, looped: true, repeat: { interval: 0.16, jitter: 0.02 },
    caption: 'Caption.Generator', captionText: '[a generator roaring]',
    layers: [
      { looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 0.5, volume: 0.45, effects: [TREM(0.55, 13), DIST(0.35), EQ(6, 2, -14)] },
      { looped: true, sample: 'Falling', region: { min: 0.1, max: 1.1 }, speed: 0.5, volume: 0.35, effects: [EQ(8, -6, -30)] },
      { sample: 'JumpLand', speed: { min: 1.1, max: 1.3 }, volume: 0.22, volumeJitter: 0.3, effects: [EQ(6, 0, -12)] },
    ],
  },
  ObjMotorWhine: {
    bus: 'World', maxVoices: 2, priority: 50, rollOff: { min: 8, max: 120 }, caption: 'Caption.Motor',
    captionText: '[a door motor whining]',
    layers: [
      { looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: 1.05, volume: 0.28, effects: [FLANGE(0.5, 0.35), EQ(-12, 6, -4)] },
      { looped: true, region: { min: 0.02, max: 0.06 }, sample: 'VolumeSlider', speed: 1.58, volume: 0.12, effects: [TREM(0.3, 3), EQ(-18, 4, 0)] },
      { looped: true, sample: 'Falling', region: { min: 0.1, max: 1.1 }, speed: 0.8, volume: 0.18, effects: [EQ(-6, 2, -22)] },
    ],
  },
  ObjValveSqueal: {
    bus: 'World', maxVoices: 2, priority: 50, rollOff: { min: 6, max: 90 }, looped: true, repeat: { interval: 0.95, jitter: 0.15 },
    layers: [
      { duration: 0.8, looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: { min: 0.7, max: 0.85 }, volume: 0.35,
        envelope: { attack: 0.1, hold: 0.3, release: 0.35 }, glide: { time: 0.7, to: 1.35 }, effects: [FLANGE(0.8, 0.6), DIST(0.4)] },
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.1 }, speed: 0.8, volume: 0.4, effects: [EQ(-4, 6, -6), ECHO(0.03, 0.3, -10)] },
    ],
    space: [VERB(2.6, -6)],
  },
  ObjBoltSnap: {
    bus: 'World', maxVoices: 2, priority: 70, rollOff: { min: 8, max: 140 },
    layers: [
      { sample: 'Explosion', region: { min: 0, max: 0.06 }, speed: 2.4, volume: 0.8, effects: [DIST(0.4), EQ(-12, 4, 6)] },
      { delay: 0.01, sample: 'FootstepsPlastic', region: { min: 0, max: 0.05 }, speed: 1.7, volume: 1, effects: [EQ(-8, 6, 6)] },
      { delay: 0.02, sample: 'VolumeSlider', speed: 3.1, volume: 0.4, effects: [EQ(-24, 0, 8), VERB(0.8, -10)] },
    ],
  },
  ObjChainDrop: {
    bus: 'World', maxVoices: 2, priority: 60, rollOff: { min: 8, max: 110 },
    layers: [
      { sample: 'VolumeSlider', speed: { min: 1.8, max: 2.8 }, volume: 0.35, volumeJitter: 0.5,
        grains: { count: { min: 8, max: 12 }, spacing: { min: 0.02, max: 0.06 } }, effects: [EQ(-20, 2, 6), CHORUS(0.4, 5)] },
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.06 }, speed: { min: 1.1, max: 1.6 }, volume: 0.6,
        grains: { count: { min: 4, max: 7 }, spacing: { min: 0.04, max: 0.08 } }, effects: [EQ(-8, 6, 2)] },
      { delay: 0.42, sample: 'JumpLand', speed: 0.9, volume: 0.9, effects: [EQ(6, 2, -8)] },
      { delay: 0.45, sample: 'VolumeSlider', speed: { min: 1.4, max: 2 }, volume: 0.3,
        grains: { count: { min: 3, max: 5 }, spacing: { min: 0.03, max: 0.06 } }, effects: [EQ(-18, 4, 2), VERB(1.2, -10)] },
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
  ObjLockerSearch: {
    bus: 'World', maxVoices: 3, priority: 35, rollOff: { min: 3, max: 30 },
    layers: [
      { duration: 0.9, looped: true, region: { min: 0.01, max: 0.05 }, sample: 'VolumeSlider', speed: { min: 0.3, max: 0.36 }, volume: 0.22,
        envelope: { attack: 0.2, hold: 0.3, release: 0.4 }, glide: { time: 0.8, to: 0.75 }, effects: [FLANGE(0.7, 0.5), DIST(0.2)] },
      { delay: 0.1, sample: 'FootstepsPlastic', region: { min: 0, max: 0.08 }, speed: 0.75, volume: 0.35, effects: [EQ(-4, 4, -8)] },
    ],
  },
  ObjWheelFit: {
    bus: 'World', maxVoices: 2, priority: 55, rollOff: { min: 6, max: 80 },
    layers: [
      { sample: 'JumpLand', speed: 1.05, volume: 1, effects: [EQ(4, 4, -8)] },
      { delay: 0.03, sample: 'FootstepsPlastic', region: { min: 0, max: 0.1 }, speed: 1.1, volume: 0.8,
        grains: { count: { min: 2, max: 3 }, spacing: { min: 0.08, max: 0.14 } }, effects: [EQ(-8, 6, 2), ECHO(0.025, 0.35, -8)] },
      { delay: 0.05, sample: 'VolumeSlider', speed: 0.9, volume: 0.3, effects: [VERB(1.6, -8)] },
    ],
  },
  ObjItemPickup: {
    bus: 'Player', maxVoices: 2, priority: 45,
    layers: [
      { region: { min: 0, max: 0.3 }, sample: 'GetUp', speed: 1.1, volume: 0.45 },
      { delay: 0.06, sample: 'FootstepsPlastic', region: { min: 0, max: 0.06 }, speed: 1.2, volume: 0.45, effects: [EQ(-10, 6, 0)] },
      { delay: 0.08, sample: 'VolumeSlider', speed: 1.3, volume: 0.25, effects: [EQ(-12, 2, 0)] },
    ],
  },
});

/** Adds the objective presets to the engine's table (idempotent; before any of them plays). */
export function registerObjectiveSounds() {
  for (const [name, preset] of Object.entries(ObjectivePresets)) if (!Presets[name]) Presets[name] = preset;
}
