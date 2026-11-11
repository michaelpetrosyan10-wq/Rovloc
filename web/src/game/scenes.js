// Scenes (Shared/Sequence/Scenes.luau): the scripted level moments as data. The level controllers time their
// authoritative beats from these constants; the scene tracks (sceneCamera, scenePanic, nearSound, movingSound,
// lightScale, roofShake, roofPanic, creature, sound) are registered by
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

export const RoofArgs = Object.freeze({ Door: 'door' });

export const RoofTracks = Object.freeze({ Shake: 'roofShake', Panic: 'roofPanic' });

const POUNDS = Object.freeze([1.9, 3.0, 3.55]);
export const RoofDoor = Object.freeze({
  Id: 'L3_DoorSmash', Slam: 0.35, SlamSeconds: 0.35, Stage: 0.8, Pounds: POUNDS, Reveal: 4.1, Smash: 4.6,
  Roar: 4.7, Release: 5.1, Duration: 7, ShakeRadius: 40, PanicRadius: 90,
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

/** Every scene timeline by id (fresh objects). */
export function timelines() {
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
    [ClassroomScare.Id]: classroomScare(),
    [ClassroomScare.SkippedId]: glassStep(),
    [RoofDoor.Id]: doorSmash(),
  };
}
