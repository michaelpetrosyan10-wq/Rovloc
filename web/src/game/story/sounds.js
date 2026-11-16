// sounds.js: the story's synth presets (docs/design/game-spec-v2.md 5.5, 2.4), recipes in the SynthPresets format
// (engine/audio/presets.js) built from the eleven synthesized sources, registered into the engine's preset table at
// start-up. None is a noise the Creature hears (I3: a cutscene only shows and sounds); 3D ones are World voices.
// Each preset's bus, roll-off, voice limit and caption are what the game uses; the sound itself is the recorded render
// of the same name (docs/SOUND.md 11, web/sounds/voices/story.mjs and him.mjs), and the recipe below plays only for a
// name that has no file. The recipes:
//
//   SchoolBell     the final bell's long electric ring                 DoorBang      the staff doors' push bars and slam
//   CrawlerClick   porcelain ticks at 3-7 kHz (the mask crawler)       MusicBoxTick  one plucked high note
//   MaskCrack      a dry crack of porcelain                            WetBreath     a long, wet, shuddering breath
//   LidSlam        a bin's rubber lid slammed on steel                  LidCreak      a lid lifted on dry hinges
//   NailsOnMetal   fingertips dragged along a steel lid                 DistantScream a scream far inside the school
//   FireBell       the school's fire bell, far off                      GlassBreak    a window breaking, far off
//   ShutterSlam    a steel lockdown shutter crashing down               BellToll      a struck partial stack on 110 Hz
//   RainOnLid      rain drumming on a steel lid over your head (loop)   BoltDrop      a heavy bolt dropping home
//   ChuteSlide     sliding down a steel chute in the dark               SpeechMurmur  one breathy syllable (the voice's
//                                                                                     fallback when nothing can speak)

import { Presets } from '../../engine/audio/presets.js';

const EQ = (LowGain, MidGain, HighGain) => ({ kind: 'Equalizer', props: { LowGain, MidGain, HighGain } });
const DIST = (Level) => ({ kind: 'Distortion', props: { Level } });
const VERB = (DecayTime, WetLevel) => ({ kind: 'Reverb', props: { DecayTime, Density: 1, Diffusion: 1, DryLevel: 0, WetLevel } });
const ECHO = (Delay, Feedback, WetLevel) => ({ kind: 'Echo', props: { Delay, DryLevel: 0, Feedback, WetLevel } });
const TREM = (Depth, Frequency) => ({ kind: 'Tremolo', props: { Depth, Duty: 0.5, Frequency } });
const CHORUS = (Depth, Rate) => ({ kind: 'Chorus', props: { Depth, Mix: 0.5, Rate } });
const PITCH = (Octave) => ({ kind: 'PitchShift', props: { Octave } });
const COMP = { kind: 'Compressor', props: { Attack: 0.002, GainMakeup: 4, Ratio: 6, Release: 0.15, Threshold: -18 } };

/** The story's presets (SynthPresets recipes). */
export const StoryPresets = Object.freeze({
  SchoolBell: {
    bus: 'World', maxVoices: 1, priority: 60, caption: 'Caption.SchoolBell', captionText: '[the school bell rings]',
    layers: [
      { duration: 2.6, looped: true, region: { min: 0.02, max: 0.03 }, sample: 'VolumeSlider', speed: 1.35, volume: 0.42,
        envelope: { attack: 0.02, hold: 2.2, release: 0.35 }, effects: [TREM(0.9, 24), DIST(0.25), EQ(-14, 6, 2)] },
      { duration: 2.6, looped: true, region: { min: 0.02, max: 0.03 }, sample: 'VolumeSlider', speed: 2.7, volume: 0.18,
        envelope: { attack: 0.02, hold: 2.2, release: 0.35 }, effects: [TREM(0.9, 24), EQ(-20, 2, 4)] },
    ],
    space: [VERB(2.2, -8)],
  },
  DoorBang: {
    bus: 'World', maxVoices: 2, priority: 55, rollOff: { min: 8, max: 120 }, caption: 'Caption.DoorBang',
    captionText: '[doors bang open]',
    layers: [
      { sample: 'JumpLand', speed: 0.62, volume: 1.4, effects: [EQ(6, 2, -8), COMP] },
      { delay: 0.05, sample: 'FootstepsPlastic', region: { min: 0, max: 0.1 }, speed: 0.9, volume: 0.8, effects: [DIST(0.3), EQ(-4, 6, 0)] },
      { delay: 0.18, sample: 'JumpLand', speed: 0.7, volume: 0.9, effects: [EQ(4, 0, -10)] },
    ],
    space: [VERB(1.4, -10)],
  },
  CrawlerClick: {
    bus: 'World', maxVoices: 3, priority: 50, rollOff: { min: 2, max: 30 }, caption: 'Caption.CrawlerClick',
    captionText: '[faint clicking]',
    layers: [
      { sample: 'VolumeSlider', speed: { min: 3.6, max: 4.6 }, volume: 0.35, volumeJitter: 0.4,
        grains: { count: { min: 3, max: 6 }, spacing: { min: 0.04, max: 0.11 } }, effects: [EQ(-30, -4, 8)] },
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.03 }, speed: { min: 2.6, max: 3.2 }, volume: 0.3,
        grains: { count: { min: 2, max: 4 }, spacing: { min: 0.05, max: 0.12 } }, effects: [EQ(-24, 2, 6)] },
    ],
  },
  MusicBoxTick: {
    bus: 'World', maxVoices: 1, priority: 60, rollOff: { min: 3, max: 40 }, caption: 'Caption.MusicBoxTick',
    captionText: '[a single music-box note]',
    layers: [
      { duration: 1.4, looped: true, region: { min: 0.02, max: 0.03 }, sample: 'VolumeSlider', speed: 3.2, volume: 0.3,
        envelope: { attack: 0.003, hold: 0.02, release: 1.3 }, effects: [EQ(-30, -2, 4), CHORUS(0.15, 3)] },
    ],
    space: [VERB(2.6, -6)],
  },
  MaskCrack: {
    bus: 'World', maxVoices: 3, priority: 65, rollOff: { min: 4, max: 60 }, caption: 'Caption.MaskCrack',
    captionText: '[porcelain cracks]',
    layers: [
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.05 }, speed: { min: 1.9, max: 2.3 }, volume: 1.1,
        grains: { count: { min: 2, max: 3 }, spacing: { min: 0.02, max: 0.05 } }, effects: [DIST(0.4), EQ(-12, 4, 8)] },
      { delay: 0.01, sample: 'JumpLand', speed: 1.8, volume: 0.4, effects: [EQ(-8, 4, 2)] },
    ],
  },
  WetBreath: {
    bus: 'World', maxVoices: 1, priority: 60, rollOff: { min: 4, max: 50 }, caption: 'Caption.WetBreath',
    captionText: '[a wet, shuddering breath]',
    layers: [
      { duration: 1.8, looped: true, region: { min: 0.1, max: 0.9 }, sample: 'Falling', speed: 0.62, volume: 0.6,
        envelope: { attack: 0.5, hold: 0.6, release: 0.7 }, effects: [TREM(0.6, 9), EQ(4, -2, -14)] },
      { delay: 0.2, duration: 1.4, looped: true, region: { min: 0, max: 0.3 }, sample: 'Ouch', speed: 0.5, volume: 0.2,
        envelope: { attack: 0.3, hold: 0.5, release: 0.6 }, effects: [EQ(-6, 2, -10)] },
    ],
  },
  LidSlam: {
    bus: 'World', maxVoices: 4, priority: 60, rollOff: { min: 6, max: 90 }, caption: 'Caption.LidSlam',
    captionText: '[a bin lid slams]',
    layers: [
      { sample: 'JumpLand', speed: { min: 0.55, max: 0.65 }, volume: 1.5, effects: [EQ(8, 0, -10), COMP] },
      { delay: 0.01, sample: 'FootstepsPlastic', region: { min: 0, max: 0.14 }, speed: 0.7, volume: 0.9, effects: [DIST(0.35), EQ(-2, 6, -2)] },
    ],
    space: [VERB(0.9, -12)],
  },
  LidCreak: {
    bus: 'World', maxVoices: 2, priority: 50, rollOff: { min: 4, max: 50 },
    layers: [
      { duration: 0.9, looped: true, region: { min: 0.02, max: 0.04 }, sample: 'VolumeSlider', speed: 0.42, volume: 0.35,
        envelope: { attack: 0.15, hold: 0.4, release: 0.3 }, effects: [TREM(0.7, 16), DIST(0.3), EQ(-12, 6, -4)] },
    ],
  },
  NailsOnMetal: {
    bus: 'World', maxVoices: 1, priority: 70, rollOff: { min: 3, max: 40 }, caption: 'Caption.NailsOnMetal',
    captionText: '[nails scrape along metal]',
    layers: [
      { duration: 1.9, looped: true, region: { min: 0.02, max: 0.05 }, sample: 'VolumeSlider', speed: 1.8, volume: 0.32,
        envelope: { attack: 0.1, hold: 1.4, release: 0.4 }, effects: [TREM(0.5, 21), DIST(0.45), EQ(-20, 4, 6)] },
      { duration: 1.9, looped: true, region: { min: 0, max: 0.2 }, sample: 'FootstepsPlastic', speed: 2.4, volume: 0.25,
        envelope: { attack: 0.1, hold: 1.4, release: 0.4 }, effects: [EQ(-20, 2, 8)] },
    ],
  },
  DistantScream: {
    bus: 'World', maxVoices: 2, priority: 55, rollOff: { min: 30, max: 260 }, caption: 'Caption.DistantScream',
    captionText: '[a scream inside the school]',
    layers: [
      { duration: 1.3, looped: true, region: { min: 0, max: 0.3 }, sample: 'Ouch', speed: { min: 0.92, max: 1.08 }, volume: 0.7,
        envelope: { attack: 0.06, hold: 0.7, release: 0.5 }, effects: [PITCH(1.3), EQ(-16, 4, -14)] },
    ],
    space: [VERB(2.8, -4)],
  },
  FireBell: {
    bus: 'World', maxVoices: 1, priority: 55, rollOff: { min: 20, max: 220 }, caption: 'Caption.FireBell',
    captionText: '[a fire bell rings inside]',
    layers: [
      { duration: 4.6, looped: true, region: { min: 0.02, max: 0.03 }, sample: 'VolumeSlider', speed: 1.7, volume: 0.32,
        envelope: { attack: 0.05, hold: 4.0, release: 0.5 }, effects: [TREM(1, 18), DIST(0.35), EQ(-14, 4, -6)] },
    ],
    space: [VERB(2.2, -6)],
  },
  GlassBreak: {
    bus: 'World', maxVoices: 2, priority: 55, rollOff: { min: 20, max: 200 }, caption: 'Caption.GlassBreak',
    captionText: '[glass breaks]',
    layers: [
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.2 }, speed: 2.6, volume: 0.7,
        grains: { count: { min: 5, max: 8 }, spacing: { min: 0.02, max: 0.07 } }, effects: [EQ(-18, 2, 8)] },
      { sample: 'VolumeSlider', speed: { min: 3.2, max: 4.4 }, volume: 0.3,
        grains: { count: { min: 6, max: 10 }, spacing: { min: 0.03, max: 0.09 } }, effects: [EQ(-24, 0, 6)] },
    ],
    space: [VERB(1.8, -6)],
  },
  ShutterSlam: {
    bus: 'World', maxVoices: 2, priority: 80, rollOff: { min: 12, max: 200 }, caption: 'Caption.ShutterSlam',
    captionText: '[a steel shutter crashes down]',
    duck: [{ attack: 0.01, bus: 'Ambience', gain: 0.4, hold: 0.8, release: 1.4 }],
    layers: [
      { duration: 0.5, looped: true, region: { min: 0, max: 0.3 }, sample: 'FootstepsPlastic', speed: 1.3, volume: 0.6,
        envelope: { attack: 0.05, hold: 0.35, release: 0.1 }, effects: [DIST(0.4), EQ(-6, 4, 2)] },
      { delay: 0.48, sample: 'Explosion', region: { min: 0, max: 0.5 }, speed: 0.95, volume: 1.4, effects: [DIST(0.4), EQ(6, 2, -8), COMP] },
      { delay: 0.5, sample: 'JumpLand', speed: 0.5, volume: 1.4, effects: [EQ(8, 0, -12)] },
    ],
    space: [VERB(2.4, -6), ECHO(0.18, 0.25, -12)],
  },
  BellToll: {
    // the opening's twelve tolls 0.3 s apart (game-spec-v2 2.4): six ring at once, each let go 1.8 s into its ring
    bus: 'World', maxVoices: 6, priority: 75, caption: 'Caption.BellToll', captionText: '[the bell tolls]',
    layers: [
      { duration: 8, looped: true, region: { min: 0.02, max: 0.03 }, sample: 'VolumeSlider', speed: 0.36, volume: 0.5,
        envelope: { attack: 0.004, hold: 0.1, release: 7.8 }, effects: [EQ(6, 0, -18)] },
      { duration: 6, looped: true, region: { min: 0.02, max: 0.03 }, sample: 'VolumeSlider', speed: 0.86, volume: 0.22,
        envelope: { attack: 0.004, hold: 0.05, release: 5.9 }, effects: [EQ(-6, 2, -10), CHORUS(0.2, 1.2)] },
      { duration: 3, looped: true, region: { min: 0.02, max: 0.03 }, sample: 'VolumeSlider', speed: 1.62, volume: 0.1,
        envelope: { attack: 0.003, hold: 0.02, release: 2.9 }, effects: [EQ(-12, 0, -4)] },
      { sample: 'JumpLand', speed: 0.4, volume: 0.6, effects: [EQ(6, -2, -16)] },
    ],
    space: [VERB(4.5, -4)],
  },
  RainOnLid: {
    bus: 'Ambience', maxVoices: 1, priority: 30, looped: true, repeat: { interval: 0.09, jitter: 0.05 },
    layers: [
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.03 }, speed: { min: 2.4, max: 3.4 }, volume: 0.12, volumeJitter: 0.6,
        effects: [EQ(-10, 4, 2)] },
      { chance: 0.5, sample: 'VolumeSlider', speed: { min: 1.4, max: 2.2 }, volume: 0.05, volumeJitter: 0.6, effects: [EQ(-20, 2, 0)] },
    ],
  },
  BoltDrop: {
    bus: 'World', maxVoices: 1, priority: 80, rollOff: { min: 8, max: 120 }, caption: 'Caption.BoltDrop',
    captionText: '[a heavy bolt drops home]',
    layers: [
      { sample: 'FootstepsPlastic', region: { min: 0, max: 0.08 }, speed: 0.8, volume: 1.2, effects: [DIST(0.35), EQ(-2, 6, 0)] },
      { delay: 0.04, sample: 'JumpLand', speed: 0.55, volume: 1.2, effects: [EQ(6, 0, -10), COMP] },
    ],
    space: [VERB(1.6, -8)],
  },
  ChuteSlide: {
    bus: 'Body', maxVoices: 1, priority: 60,
    layers: [
      { duration: 1.5, looped: true, region: { min: 0, max: 1 }, sample: 'Falling', speed: 1.4, volume: 0.5,
        envelope: { attack: 0.1, hold: 1.0, release: 0.4 }, effects: [DIST(0.25), EQ(-6, 4, -6)] },
      { duration: 1.5, looped: true, region: { min: 0, max: 0.3 }, sample: 'FootstepsPlastic', speed: 0.6, volume: 0.3,
        envelope: { attack: 0.1, hold: 1.0, release: 0.4 }, effects: [EQ(2, 4, -8)] },
      { delay: 1.45, sample: 'JumpLand', speed: 0.8, volume: 1.1, effects: [EQ(4, 2, -6)] },
    ],
  },
  SpeechMurmur: {
    bus: 'World', maxVoices: 6, priority: 70, rollOff: { min: 4, max: 60 },
    layers: [
      { duration: 0.2, looped: true, region: { min: 0.1, max: 0.5 }, sample: 'Falling', speed: { min: 1.6, max: 2.1 }, volume: 0.5,
        envelope: { attack: 0.03, hold: 0.08, release: 0.09 }, effects: [EQ(-14, 8, -10)] },
      { duration: 0.18, looped: true, region: { min: 0.05, max: 0.2 }, sample: 'Ouch', speed: { min: 0.7, max: 0.9 }, volume: 0.25,
        envelope: { attack: 0.03, hold: 0.06, release: 0.09 }, effects: [EQ(-10, 6, -12)] },
    ],
  },
});

/** Adds the story's presets to the engine's table (idempotent; before any of them plays). */
export function registerStorySounds() {
  for (const [name, preset] of Object.entries(StoryPresets)) if (!Presets[name]) Presets[name] = preset;
}
