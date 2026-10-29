// Scenes (Shared/Sequence/Scenes.luau): the scripted level moments as data. The level controllers time their
// authoritative beats from these constants; the scene tracks (sceneCamera, scenePanic, nearSound, movingSound,
// lightScale, roofShake, roofPanic, finaleFocus, finalePanic, finaleFade, creature, sound) are registered by
// sceneTracks.js. Values are identical to the Roblox data; see Scenes.luau's header for the beat-by-beat story.

import * as THREE from 'three';
import { clamp01, lerpFrame, lookAtMatrix, smoothstep } from './util.js';

export const Args = Object.freeze({
  Subject: 'subject', Feet: 'feet', Head: 'head', Focus: 'focus', Glow: 'glow', Spill: 'spill', At: 'at',
  From: 'from', To: 'to', Light1: 'light1', Light2: 'light2', Light3: 'light3', Light4: 'light4',
});

export const Tracks = Object.freeze({
  SubjectCamera: 'sceneCamera', SubjectPanic: 'scenePanic', NearSound: 'nearSound', MovingSound: 'movingSound',
  LightScale: 'lightScale',
});

export const RoofArgs = Object.freeze({ Door: 'door', Head: 'head', Ledge: 'ledge', Subject: 'subject' });

export const RoofTracks = Object.freeze({
  Shake: 'roofShake', Panic: 'roofPanic', Focus: 'finaleFocus', FinalePanic: 'finalePanic', Fade: 'finaleFade',
});

const POUNDS = Object.freeze([1.9, 3.0, 3.55]);
export const RoofDoor = Object.freeze({
  Id: 'L5_DoorSmash', Slam: 0.35, SlamSeconds: 0.35, Stage: 0.8, Pounds: POUNDS, Reveal: 4.1, Smash: 4.6,
  Roar: 4.7, Release: 5.1, Duration: 7, ShakeRadius: 40, PanicRadius: 90,
});

const FLASH1 = 1.0;
const FLASH2 = 4.6;
const MAIN_STRIKE = 0.42;
export const Finale = Object.freeze({
  Id: 'L5_Finale', SkyId: 'L5_FinaleSky', TouchdownId: 'L5_Touchdown',
  Flash1: FLASH1, Reveal: FLASH1 + MAIN_STRIKE, Thunder1: FLASH1 + 1, Flash2: FLASH2, Vanish: FLASH2 + 0.06,
  Hide: FLASH2 + 0.36, Thunder2: FLASH2 + 0.25, FocusIn: FLASH1 + MAIN_STRIKE, FocusHeld: FLASH1 + 1.3,
  FocusOut: FLASH2 + 0.45, FocusRest: FLASH2 + 1.6, RestFocus: 0.35, FadeStart: 6.6, FadeEnd: 8, Land: 8.2,
  Duration: 8.4, RevealLead: 0.25, HideLead: 0.25, FlashIntensity: 1, Settle: 1.6, TouchdownFadeStart: 1,
  TouchdownFadeEnd: 2.4, TouchdownRelease: 2.6, TouchdownDuration: 2.7,
});

const SNAP = 0.42;
const BURST = 2.05;
const GATE_LAND = 3.55;
export const ClassroomScare = Object.freeze({
  Id: 'L1_ClassroomScare', SkippedId: 'L1_GlassStep', Snap: SNAP, Hush: SNAP + 0.5, Burst: BURST, SpillStagger: 0.07,
  Vanish: BURST + 0.1, Hide: BURST + 0.38, CameraEnd: BURST + 0.6, KillLights: BURST + 1.2, GateLand: GATE_LAND,
  SkippedGateLand: 1.1, Relocate: GATE_LAND + 0.4, Duration: GATE_LAND + 1, FaceLead: 0.05, ReleaseMin: 6,
  ReleaseMax: 9, Flinch: 0.75, HushRadius: 70,
});

export const BeatKinds = Object.freeze(['PipeBang', 'BoilerSurge', 'CeilingDrag', 'ChildVoice', 'FallingObject']);
export const BeatIds = Object.freeze({
  PipeBang: ['L0_PipeBang'], BoilerSurge: ['L0_BoilerSurge'], CeilingDrag: ['L0_CeilingDrag'],
  ChildVoice: ['L0_ChildWhisper', 'L0_ChildLaugh'], FallingObject: ['L0_FallingObject'],
});
export const FallImpact = 0;
export const CeilingDragDistance = 16;
export const CeilingDragSeconds = 3.6;
export const SurgeLights = 4;

export const GymBeatKinds = Object.freeze(['ShowerDrip', 'LockerBang', 'BallBounce']);
export const GymBeatIds = Object.freeze({
  ShowerDrip: ['L3_ShowerDrip'], LockerBang: ['L3_LockerBang', 'L3_LockerRattle'], BallBounce: ['L3_BallBounce'],
});
export const BallBounces = Object.freeze([
  { t: 0, volume: 1.2 }, { t: 0.62, volume: 1.05 }, { t: 1.13, volume: 0.9 }, { t: 1.54, volume: 0.76 },
  { t: 1.87, volume: 0.62 }, { t: 2.13, volume: 0.5 }, { t: 2.33, volume: 0.38 }, { t: 2.48, volume: 0.28 },
  { t: 2.59, volume: 0.2 },
]);

export const FloodlightsId = 'L4_Floodlights';
export const FloodlightArgs = Object.freeze(['flood1', 'flood2', 'flood3', 'flood4', 'flood5', 'flood6', 'flood7',
  'flood8', 'flood9']);
export const FloodlightStagger = 0.11;
export const FloodlightStrike = 1.7;
export const FloodlightSeconds = FloodlightStrike + (FloodlightArgs.length - 1) * FloodlightStagger;

// ---------------------------------------------------------------------------------------------------------------
// Pure camera maths
// ---------------------------------------------------------------------------------------------------------------

/**
 * The stumble offset t seconds into the scene (applied in eye space after the look): a jolt down toward the feet
 * with a lurching roll and a knee-buckle dip, settling by ClassroomScare.Flinch. scale = MotionScale.
 */
export function flinch(t, scale, out = new THREE.Matrix4()) {
  const amount = clamp01(scale);
  if (t <= 0 || t >= ClassroomScare.Flinch || amount <= 0) return out.identity();
  const attack = smoothstep(0, 0.07, t);
  const decay = Math.exp(-5.5 * Math.max(0, t - 0.07));
  const fade = 1 - smoothstep(ClassroomScare.Flinch - 0.15, ClassroomScare.Flinch, t);
  const env = attack * decay * fade * amount;
  const pitch = -((13 * Math.PI) / 180) * env;
  const roll = ((5 * Math.PI) / 180) * env * Math.cos(t * 19);
  const yaw = ((1.6 * Math.PI) / 180) * env * Math.sin(t * 41);
  _eul.set(pitch, yaw, roll, 'XYZ');
  out.makeRotationFromEuler(_eul);
  out.setPosition(0, -0.3 * env, 0);
  return out;
}
const _eul = new THREE.Euler();

/** How far the subject's view is dragged onto the Creature (0 own look .. 1 locked on its face). */
export function pullWeight(t) {
  const start = ClassroomScare.Snap - 0.02;
  if (t <= start) return 0;
  const rise = clamp01((t - start) / 0.32);
  return 1 - (1 - rise) ** 3;
}

/** `eye` (Matrix4) turned toward `target` by `weight`, position kept. */
export function pulled(eye, target, weight, out = new THREE.Matrix4()) {
  const w = clamp01(weight);
  _p.setFromMatrixPosition(eye);
  if (w <= 0 || _p.distanceTo(target) < 1e-3) return out.copy(eye);
  lookAtMatrix(_p, target, _locked);
  return lerpFrame(eye, _locked, w, out);
}
const _p = new THREE.Vector3();
const _locked = new THREE.Matrix4();

// ---------------------------------------------------------------------------------------------------------------
// Timelines
// ---------------------------------------------------------------------------------------------------------------

const key = (t, value, ease, persist) => ({ t, value, ease, persist });
const sound = (arg, preset, t, volume) => ({ kind: 'sound', arg, volume, keys: [key(t, preset)] });

function classroomScare() {
  const c = ClassroomScare;
  return {
    duration: c.Duration,
    tracks: [
      sound(Args.Feet, 'GlassCrunch', 0, 1.7),
      { kind: Tracks.SubjectCamera, keys: [key(0, 'Flinch'), key(c.CameraEnd, 'Release', undefined, true)] },
      {
        kind: Tracks.SubjectPanic,
        keys: [key(0, 0.35), key(c.Snap, 0.4), key(c.Snap + 0.15, 0.95, 'OutQuad'), key(c.GateLand + 0.4, 0.95),
          key(c.Duration, 0.7, 'InOutSine')],
      },
      { kind: 'creature', keys: [key(c.Snap, 'NeckSnap')] },
      sound(Args.Head, 'NeckSnap', c.Snap, 1.3),
      { kind: Tracks.NearSound, arg: Args.Head, keys: [key(c.Hush, 'ScareHush')] },
      sound(Args.Glow, 'LightBurst', c.Burst, 1.2),
      sound(Args.Spill, 'LightBurst', c.Burst + c.SpillStagger, 0.9),
      sound(Args.Head, 'CreatureVanish', c.Vanish),
    ],
  };
}

function glassStep() {
  const c = ClassroomScare;
  return {
    duration: c.Flinch + 0.5,
    tracks: [
      sound(Args.Feet, 'GlassCrunch', 0, 1.7),
      { kind: Tracks.SubjectCamera, keys: [key(0, 'Flinch'), key(c.Flinch, 'Release', undefined, true)] },
      { kind: Tracks.SubjectPanic, keys: [key(0, 0.35), key(c.Flinch + 0.5, 0.2, 'InOutSine')] },
    ],
  };
}

function surgeTrack(arg, o) {
  return {
    kind: Tracks.LightScale,
    arg,
    keys: [key(0, 1), key(0.25 + o, 1.7, 'OutQuad'), key(0.33 + o, 0.15, 'Step'), key(0.41 + o, 1.4, 'Step'),
      key(0.62 + o, 0.05, 'Step'), key(0.78 + o, 1.2, 'OutQuad'), key(1.1 + o, 0.3, 'InQuad'),
      key(1.18 + o, 0.9, 'Step'), key(1.6 + o, 0.55, 'InOutSine'), key(2.3 + o, 1, 'InOutSine')],
  };
}

function floodlightTrack(arg, o) {
  const keys = [key(0, 0)];
  if (o > 0) keys.push(key(o, 0, 'Step'));
  keys.push(key(0.06 + o, 0.55, 'Step'), key(0.11 + o, 0.02, 'Step'), key(0.24 + o, 0.9, 'Step'),
    key(0.3 + o, 0.08, 'Step'), key(0.42 + o, 0.3, 'OutQuad'), key(0.9 + o, 0.62, 'InOutSine'),
    key(1.15 + o, 1.25, 'OutQuad'), key(FloodlightStrike + o, 1, 'InOutSine'));
  return { kind: Tracks.LightScale, arg, keys };
}

const SHOWER_DROPS = [
  { t: 0, volume: 1 }, { t: 0.58, volume: 0.75 }, { t: 1.02, volume: 0.9 }, { t: 1.66, volume: 0.65 },
  { t: 2.08, volume: 0.85 }, { t: 2.86, volume: 0.6 }, { t: 3.3, volume: 0.8 }, { t: 4.15, volume: 0.55 },
];
const RATTLES = [
  { t: 0, volume: 0.9 }, { t: 0.17, volume: 0.7 }, { t: 0.31, volume: 0.85 }, { t: 0.5, volume: 0.6 },
  { t: 1.35, volume: 0.75 }, { t: 1.5, volume: 0.55 },
];
const hits = (preset, list) => list.map((h) => sound(Args.At, preset, h.t, h.volume));

function doorSmash() {
  const d = RoofDoor;
  const p = d.Pounds;
  const tracks = [
    sound(RoofArgs.Door, 'RoofDoorSlam', d.Slam, 1.2),
    { kind: 'creature', keys: [key(d.Smash, 'DoorSmash')] },
    sound(RoofArgs.Door, 'Screech', d.Roar, 0.9),
    { kind: RoofTracks.Shake, arg: RoofArgs.Door, keys: [key(p[0], 0.6), key(p[1], 0.8), key(p[2], 1.1), key(d.Smash, 2.4)] },
    {
      kind: RoofTracks.Panic,
      arg: RoofArgs.Door,
      keys: [key(0, 0), key(p[0], 0.25, 'OutQuad'), key(p[2], 0.5, 'InOutSine'), key(d.Smash, 0.9, 'OutQuad'),
        key(d.Duration, 0.75, 'InOutSine')],
    },
  ];
  [1.1, 1.3, 1.5].forEach((v, i) => tracks.push(sound(RoofArgs.Door, 'DoorPound', p[i], v)));
  return { duration: d.Duration, tracks };
}

function finaleTracks(revealed) {
  const f = Finale;
  return [
    { kind: 'sound', volume: 1.3, keys: [key(f.Thunder1, 'Thunder')] },
    { kind: 'sound', volume: 1.5, keys: [key(f.Thunder2, 'Thunder')] },
    { kind: RoofTracks.Fade, hold: true, keys: [key(0, 0), key(f.FadeStart, 0), key(f.FadeEnd, 1, 'InOutSine')] },
    {
      kind: RoofTracks.FinalePanic,
      keys: revealed
        ? [key(0, 0.3), key(f.Reveal, 0.35), key(f.Reveal + 0.3, 0.95, 'OutQuad'), key(f.Hide, 0.95),
          key(f.FadeStart, 0.6, 'InOutSine'), key(f.Duration, 0.4)]
        : [key(0, 0.3), key(f.Flash2, 0.45, 'InOutSine'), key(f.Duration, 0.3, 'InOutSine')],
    },
  ];
}

function finale() {
  const f = Finale;
  const tracks = finaleTracks(true);
  tracks.push({ kind: 'creature', keys: [key(f.Reveal, 'Reveal'), key(f.Vanish, 'Vanish')] });
  tracks.push({ kind: 'sound', volume: 1.1, keys: [key(f.Reveal, 'FinaleSting')] });
  tracks.push({
    kind: RoofTracks.Focus,
    keys: [key(0, 0), key(f.FocusIn, 0), key(f.FocusHeld, 1, 'OutCubic'), key(f.FocusOut, 1),
      key(f.FocusRest, f.RestFocus, 'InOutSine')],
  });
  return { duration: f.Duration, tracks };
}

/** Every scene timeline by id (fresh objects). */
export function timelines() {
  const f = Finale;
  return {
    L0_PipeBang: { duration: 3, tracks: [sound(Args.At, 'PipeBang', 0, 1.2)] },
    L0_BoilerSurge: {
      duration: 2.8,
      tracks: [sound(Args.At, 'BoilerSurge', 0, 1.1), surgeTrack(Args.Light1, 0), surgeTrack(Args.Light2, 0.06),
        surgeTrack(Args.Light3, 0.11), surgeTrack(Args.Light4, 0.17)],
    },
    L0_CeilingDrag: {
      duration: CeilingDragSeconds + 0.2,
      tracks: [{ kind: Tracks.MovingSound, target: 'CeilingDrag', volume: 1.1,
        keys: [key(0, 0), key(CeilingDragSeconds, 1, 'InOutSine')] }],
    },
    L0_ChildWhisper: { duration: 3.6, tracks: [sound(Args.At, 'ChildWhisper', 0, 1)] },
    L0_ChildLaugh: { duration: 2.6, tracks: [sound(Args.At, 'ChildLaugh', 0, 1)] },
    L0_FallingObject: { duration: 2, tracks: [sound(Args.At, 'ObjectFall', FallImpact, 1.2)] },
    L3_ShowerDrip: { duration: 4.8, tracks: hits('ShowerDrip', SHOWER_DROPS) },
    L3_LockerBang: {
      duration: 2.4,
      tracks: [sound(Args.At, 'LockerSlam', 0, 1.2), sound(Args.At, 'LockerSlam', 0.52, 0.55),
        sound(Args.At, 'LockerDoor', 0.86, 0.6)],
    },
    L3_LockerRattle: { duration: 2.2, tracks: hits('LockerDoor', RATTLES) },
    L3_BallBounce: { duration: 3.4, tracks: hits('BallBounce', BallBounces) },
    [ClassroomScare.Id]: classroomScare(),
    [ClassroomScare.SkippedId]: glassStep(),
    [FloodlightsId]: {
      duration: FloodlightSeconds + 0.1,
      tracks: FloodlightArgs.map((arg, i) => floodlightTrack(arg, i * FloodlightStagger)),
    },
    [RoofDoor.Id]: doorSmash(),
    [f.Id]: finale(),
    [f.SkyId]: { duration: f.Duration, tracks: finaleTracks(false) },
    [f.TouchdownId]: {
      duration: f.TouchdownDuration,
      tracks: [{ kind: RoofTracks.Fade, hold: true,
        keys: [key(0, 0), key(f.TouchdownFadeStart, 0), key(f.TouchdownFadeEnd, 1, 'InOutSine')] }],
    },
  };
}
