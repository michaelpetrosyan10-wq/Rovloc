// Creature (Shared/Animation/ProceduralAnimator/Profiles/Creature.luau, ported and grown for the Tall Man): the
// Creature's animation profile and its one-shot / held action layers.
//
// Every length comes from the rig's JointMap (bone lengths, pivots, the floor, how far the fingers and toes reach from
// the welded detail parts), so the profile follows the rig: the 11-stud shadow figure with the porcelain mask, long
// legs, arms to below the knees and long jointed fingers. Rig axes: X right, Y up, -Z forward, origin at the root.
//
// The body moves wrong on purpose. Its head never bobs with the body: it holds still, then snaps to a new direction
// in a few frames (a saccade tracker; with a target it waits until the target has drifted, then catches up in one
// jerk), cocked at a tilt. Idle bodies stay dead still apart from a slow breath, broken by seeded twitches that are a
// pure function of time. Swinging feet hang before they land; the fingers trail.
//
// States: Dormant (hunched deep, head hanging, a slow shoulder-heave breath), Patrol (the stalk: long, slow,
// bent-kneed strides that hover before they plant, the head tilting, the arms hanging below the knees with the fingers
// trailing), Investigate (lower, neck craned, sniffing pecks, one hand feeling the air), Chase (the lope: long strides
// with a flight phase, a hard lean, the arms swinging low, the head dead level on its target), VentCrawl /
// VentRetreat (the old duct crawl, kept for the legacy vent states), Stunned (both hands raking at the mask,
// staggering on buckling knees), Scripted (neutral, staring at its target). Any upright state hunches under a low ceiling (setHunch: PoseMode Hunched) to about Rig.HunchedHeight.
// Actions: NeckSnap, Lunge (= Jumpscare: it bows to the victim, the long neck reaching down until the mask hangs level
// with their eye about 1.4 studs off, cocked over; the hands come up around their head; the hinge parts a little as the
// mask's slit tears into its maw), LockerRip, DoorSmash, Vanish, Reveal, FadeOut / FadeIn (the teleport's dissolve poses),
// the hinge only ever parting a few degrees (the mask's jagged maw is what shows; mask.js),
// and the held layers Stare (frozen, the head cocking over), LookAway (the head turned down the tunnel) and ReachIn (the
// long arm into a gap toward the look target, fingers splayed, then curling), which run until released.

import * as THREE from 'three';
import { CFrame, IDENTITY } from './cframe.js';
import { CreatureConfig, WorldDefaults } from './config.js';
import { ankleLift, euler, footCycle } from './animator.js';
import { distance as jointDistance, pivot as jointPivot, solveTwoBone } from './rig.js';
import { TAU, angleDelta, clamp, clamp01, damp, dampNumber, lerp, noise as perlin, rad, remapClamped as remap, smoothstep } from './util.js';

const SIDES = ['Left', 'Right'];
const SIGN = { Left: -1, Right: 1 };
const PLANT = { Left: 0, Right: 0.5 };

const names = (suffix) => ({ Left: `Left${suffix}`, Right: `Right${suffix}` });
const HIP = names('Hip');
const ANKLE = names('Ankle');
const SHOULDER = names('Shoulder');
const ELBOW = names('Elbow');
const WRIST = names('Wrist');
const LEG = names('Leg');
const ARM = names('Arm');
const FOOT_PART = names('Foot');
const HAND_PART = names('Hand');
const FINGER_NAMES = ['Index', 'Middle', 'Ring', 'Pinky', 'Thumb'];
const CLAWS = names('Hand');

const ROOT = 'Root';
const WAIST = 'Waist';
const NECK = 'Neck';
const JAW = 'Jaw';
const UPPER = 'UpperTorso';
const HEAD = 'Head';

export const REQUIRED = ['Root', 'Waist', 'Neck', 'Jaw', 'LeftShoulder', 'LeftElbow', 'LeftWrist', 'RightShoulder',
  'RightElbow', 'RightWrist', 'LeftHip', 'LeftKnee', 'LeftAnkle', 'RightHip', 'RightKnee', 'RightAnkle'];

export const States = Object.freeze(['Dormant', 'Patrol', 'Investigate', 'Chase', 'VentCrawl', 'VentRetreat', 'Stunned', 'Scripted']);
export const Actions = Object.freeze(['NeckSnap', 'Lunge', 'LockerRip', 'DoorSmash', 'Vanish', 'Reveal', 'Stare', 'ReachIn',
  'LookAway', 'FadeOut', 'FadeIn', 'Jumpscare']);

const FORWARD = new THREE.Vector3(0, 0, -1);
const DOWN = new THREE.Vector3(0, -1, 0);
const REACH = 0.985;
export const BORE_HALF = WorldDefaults.VentBore / 2;
const BORE_MARGIN = 0.08;
const FLOOR_PAD = 0.05;
const HAND_FLOOR = 0.1;
const NOISE_PERIOD = 4096;
const HUNCH_DROP = 0.55;
const HUNCH_PITCH = rad(20);
const HUNCH_NECK = rad(12);
const HEAD_REST_PITCH = rad(8); // the mask looks this far down at rest (CreatureRigBuilder HEAD_PITCH)
const HUNCH_SPEED = 3.5;
const HAIR_DAMP = 9;
const HAIR_STALE = 0.5;
const HAIR_STRAND = 1.3;
const DRAG_SCALE = 0.045;
const MAX_DRAG = 0.9;

const NECK_LIMITS = { pitchUp: rad(70), pitchDown: rad(75), yaw: rad(95), roll: rad(40) };

const SNAP_TURN = 0.12;
const SNAP_SETTLE = 0.45;
const SNAP_HOLD = 2.4;
const SNAP_RELEASE = 1.3;
const SNAP_WAIST = rad(75);
const LUNGE = CreatureConfig.Jumpscare.LungeSeconds;
const LUNGE_HOLD = CreatureConfig.Jumpscare.HoldSeconds;
const LUNGE_WIND = 0.05; // the flinch back before it strikes ...
const LUNGE_THRUST = 0.2; // ... and the strike: bowed and level with the eye this soon
const LUNGE_RELEASE = 0.5;
const RIP = 1.35;
const SMASH = 0.95;
const VANISH = 0.36;
const REVEAL = 0.75;
export const FADE_OUT = 0.6;
export const FADE_IN = 0.8;
const LOOM_DISTANCE = 1.6; // the jumpscare brings the mask this far from the victim's eye ...
const LOOM_ELEVATION = rad(2); // ... level with it, staring straight into it: it bows, the long neck reaching down
const LOOM_BACK = 2.6; // how far the body may step back off its root to get there
const LOOM_PITCH = rad(8); // the search's steps: the chest bends forward up to LOOM_PITCH x 12 ...
const LOOM_DROP = 0.045; // ... the knees fold up to LOOM_DROP x 10 legs
const LOOM_RESOLVE = 0.25;
const LOOM_TILT = rad(24); // the head cocks over as it snaps in, settling to LOOM_TILT_HOLD
const LOOM_TILT_HOLD = rad(13);
const LUNGE_JAW = rad(1.2); // the hinge parts a little as the slit tears (the tear itself is the mask's: mask.js)

export const ActionDurations = Object.freeze({
  NeckSnap: SNAP_SETTLE + SNAP_HOLD + SNAP_RELEASE,
  Lunge: LUNGE + LUNGE_HOLD + LUNGE_RELEASE,
  Jumpscare: LUNGE + LUNGE_HOLD + LUNGE_RELEASE,
  LockerRip: RIP,
  DoorSmash: SMASH,
  Vanish: VANISH + 0.05,
  Reveal: REVEAL,
  FadeOut: FADE_OUT + 0.1,
  FadeIn: FADE_IN + 0.1,
  Stare: Infinity,
  LookAway: Infinity,
  ReachIn: Infinity,
});
const DURATIONS = ActionDurations;
/** Held actions run until released; this is how long each takes to let go. */
export const HeldRelease = Object.freeze({ Stare: 0.4, LookAway: 0.32, ReachIn: 0.6 });

export const NeckSnapTiming = Object.freeze({ turn: SNAP_TURN, settle: SNAP_SETTLE, hold: SNAP_HOLD, release: SNAP_RELEASE });

const V = (x, y, z) => new THREE.Vector3(x, y, z);

// ---------------------------------------------------------------------------------------------------------------
// Measurements (per rig, cached)
// ---------------------------------------------------------------------------------------------------------------

const measured = new WeakMap();

function cornersOf(cframe, size, into) {
  const hx = size.x / 2;
  const hy = size.y / 2;
  const hz = size.z / 2;
  for (const sx of [-1, 1]) {
    for (const sy of [-1, 1]) {
      for (const sz of [-1, 1]) {
        const c = cframe.point(hx * sx, hy * sy, hz * sz);
        into.min.min(c);
        into.max.max(c);
      }
    }
  }
}

function boundsOf(map, name) {
  const bounds = { min: V(Infinity, Infinity, Infinity), max: V(-Infinity, -Infinity, -Infinity) };
  cornersOf(IDENTITY, map.sizes[name], bounds);
  for (const d of map.details) if (d.bone === name) cornersOf(d.cframe, d.size, bounds);
  return bounds;
}

function boxCorners(frame, box) {
  const out = [];
  for (const x of [box.min.x, box.max.x]) {
    for (const y of [box.min.y, box.max.y]) {
      for (const z of [box.min.z, box.max.z]) out.push(frame.point(x, y, z));
    }
  }
  return out;
}

function hairChains(map) {
  const clumps = new Map();
  for (const name of Object.keys(map.joints)) {
    const m = /^Hair(\d+)_(\d+)$/.exec(name);
    if (!m) continue;
    const key = Number(m[1]);
    if (!clumps.has(key)) clumps.set(key, []);
    clumps.get(key).push({ index: Number(m[2]), joint: name });
  }
  const chains = [];
  for (const key of [...clumps.keys()].sort((a, b) => a - b)) {
    const list = clumps.get(key).sort((a, b) => a.index - b.index);
    const chain = [];
    for (const item of list) {
      const joint = map.joints[item.joint];
      let tip;
      if (joint.children.length > 0) tip = map.joints[joint.children[0]].pivot.clone();
      else {
        const rest = map.rest[joint.part1Name].position;
        tip = rest.clone().add(rest.clone().sub(joint.pivot));
      }
      const along = tip.sub(joint.pivot);
      const length = Math.max(0.1, along.length());
      chain.push({
        joint: item.joint,
        parentPart: joint.part0Name,
        length: length * HAIR_STRAND,
        rest: along.clone().divideScalar(length),
        splay: V(along.x, 0, along.z).divideScalar(length),
      });
    }
    chains.push(chain);
  }
  return chains;
}

/**
 * The jointed fingers of each hand: their joint, the curl axis (rotating the finger toward the palm) and the spread
 * axis (fanning it across the palm), both in rig axes at rest.
 */
function fingerData(map) {
  const out = { Left: [], Right: [] };
  for (const side of SIDES) {
    const hand = map.rest[HAND_PART[side]];
    if (!hand) continue;
    const s = SIGN[side];
    const inward = V(-s, 0, 0);
    for (const name of FINGER_NAMES) {
      const joint = map.joints[side + name];
      if (!joint) continue;
      const part = map.rest[joint.part1Name].position;
      const along = part.clone().sub(joint.pivot);
      if (along.length() < 1e-4) continue;
      along.normalize();
      const curlAxis = along.clone().cross(inward);
      if (curlAxis.length() < 1e-4) continue;
      curlAxis.normalize();
      const spreadAxis = along.clone().cross(curlAxis).normalize();
      const index = FINGER_NAMES.indexOf(name);
      out[side].push({ joint: joint.name, part: joint.part1Name, curlAxis, spreadAxis, fan: index - 1.5, phase: index * 1.3 + s });
    }
  }
  return out;
}

/** The rig measurements the profile works from. @param {import('./rig.js').JointMap} map */
export function measure(map) {
  const cached = measured.get(map);
  if (cached) return cached;
  const bounds = {};
  for (const name of Object.keys(map.sizes)) if (name !== map.rootName && map.rest[name]) bounds[name] = boundsOf(map, name);
  const relativeCorners = (part, joint) => {
    const origin = jointPivot(map, joint);
    return boxCorners(map.rest[part], bounds[part]).map((c) => c.sub(origin));
  };
  const handCorners = {};
  const footCorners = {};
  for (const side of SIDES) {
    handCorners[side] = relativeCorners(HAND_PART[side], WRIST[side]);
    footCorners[side] = relativeCorners(FOOT_PART[side], ANKLE[side]);
  }
  const hip = { Left: jointPivot(map, 'LeftHip'), Right: jointPivot(map, 'RightHip') };
  const thigh = jointDistance(map, 'RightHip', 'RightKnee');
  const shin = jointDistance(map, 'RightKnee', 'RightAnkle');
  const upperArm = jointDistance(map, 'RightShoulder', 'RightElbow');
  const forearm = jointDistance(map, 'RightElbow', 'RightWrist');
  let lowest = Infinity;
  let behind = Infinity;
  let ahead = -Infinity;
  for (const offset of footCorners.Right) {
    lowest = Math.min(lowest, offset.y);
    const along = offset.dot(FORWARD);
    behind = Math.min(behind, along);
    ahead = Math.max(ahead, along);
  }
  const face = map.attachments.FaceFrontAttachment;
  const result = {
    fingers: fingerData(map),
    ground: map.groundY,
    leg: thigh + shin,
    thigh,
    shin,
    upperArm,
    forearm,
    arm: upperArm + forearm,
    hip,
    standHip: hip.Right.y - map.groundY,
    ankle: Math.max(0.05, -lowest),
    toe: Math.max(0.1, ahead),
    heel: Math.max(0.05, -behind),
    faceInHead: face && face.parent === HEAD ? face.cframe : new CFrame(0, 0, -0.4),
    bounds,
    handCorners,
    footCorners,
    hair: hairChains(map),
  };
  measured.set(map, result);
  return result;
}

// ---------------------------------------------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------------------------------------------

function wrapTime(t) {
  return ((t % NOISE_PERIOD) + NOISE_PERIOD) % NOISE_PERIOD;
}

function noise(t, seed) {
  return perlin(wrapTime(t), seed * 7.31 + 0.5, 3.7);
}

function hash01(a, b) {
  const x = Math.sin(((a % 65536) + 65536) % 65536 * 12.9898 + (((b % 4096) + 4096) % 4096) * 78.233) * 43758.5453;
  return x - Math.floor(x);
}

function stepped(t, rate, seed) {
  return hash01(Math.floor(wrapTime(t) * rate), seed) * 2 - 1;
}

function yawed(v, angle) {
  if (angle === 0) return v.clone();
  const c = Math.cos(angle);
  const s = Math.sin(angle);
  return V(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}

function shiftBody(pose, offset) {
  pose.set(ROOT, CFrame.at(offset).mul(pose.get(ROOT)));
}

function prone(pitch, yaw, roll) {
  return CFrame.angles(0, yaw, 0).mul(CFrame.angles(0, 0, roll)).mul(CFrame.angles(pitch, 0, 0));
}

function lowestUnder(pose, m, part) {
  let lowest = Infinity;
  for (const c of boxCorners(pose.frame(part), m.bounds[part])) lowest = Math.min(lowest, c.y);
  return lowest;
}

function extentOf(corners, rotation, sideSign) {
  let lowest = Infinity;
  let outward = -Infinity;
  for (const offset of corners) {
    const turned = rotation.pointToWorld(offset);
    lowest = Math.min(lowest, turned.y);
    outward = Math.max(outward, turned.x * sideSign);
  }
  return [lowest, outward];
}

function faceFrame(pose, m) {
  return pose.frame(HEAD).mul(m.faceInHead);
}

function outCubic(x) {
  const u = 1 - clamp01(x);
  return 1 - u * u * u;
}

function outBack(x, c) {
  const u = clamp01(x) - 1;
  return 1 + (c + 1) * u * u * u + c * u * u;
}

function impulse(elapsed, rise, decay) {
  if (elapsed < 0) return 0;
  if (elapsed < rise) return smoothstep(0, rise, elapsed);
  return Math.exp(-(elapsed - rise) * decay);
}

function envelope(elapsed, duration, fadeIn, fadeOut) {
  if (elapsed < 0 || elapsed > duration) return 0;
  const inside = fadeIn > 0 ? smoothstep(0, fadeIn, elapsed) : 1;
  const outside = fadeOut > 0 ? 1 - smoothstep(duration - fadeOut, duration, elapsed) : 1;
  return Math.min(inside, outside);
}

function swingAlong(cycle, stance, hover, hold) {
  if (cycle.stance || (hover <= 0 && (hold || 0) <= 0)) return cycle.along;
  const wait = clamp(hold || 0, 0, 0.9);
  const v = clamp01((cycle.progress - wait) / (1 - wait));
  const cycloid = v - Math.sin(TAU * v) / TAU;
  return stance * (lerp(cycloid, outCubic(v), hover) - 0.5);
}

// ---------------------------------------------------------------------------------------------------------------
// Per-rig runtime: actions, hunch, focus, gaze, hair
// ---------------------------------------------------------------------------------------------------------------

const runtimes = new WeakMap();

function runtimeOf(map) {
  let r = runtimes.get(map);
  if (r) return r;
  r = {
    actions: [],
    hunch: 0,
    hunchTarget: 0,
    focused: false,
    stamp: null,
    gaze: {
      yaw: 0, pitch: 0, roll: 0, fromYaw: 0, fromPitch: 0, fromRoll: 0, toYaw: 0, toPitch: 0, toRoll: 0,
      moveStart: -Infinity, moveDuration: 0.1, nextAt: -Infinity, count: 0,
    },
    hair: {},
    serial: 0,
    /** @type {THREE.Vector3|null} rig-space point the Jumpscare / ReachIn aim at (the view's look target) */
    target: null,
  };
  runtimes.set(map, r);
  return r;
}

const SACCADE_THRESHOLD = rad(7);
const SACCADE_BASE = 0.06;
const SACCADE_PER_RADIAN = 0.07;
const FOCUS_DWELL_MIN = 0.18;
const FOCUS_DWELL_MAX = 0.6;
const SCAN_DWELL_MIN = 1.1;
const SCAN_DWELL_MAX = 3.6;
const SCAN_YAW = rad(68);
const SCAN_PITCH_UP = rad(10);
const SCAN_PITCH_DOWN = rad(24);
const TILT = rad(16);

function updateGaze(runtime, ctx) {
  const g = runtime.gaze;
  const t = ctx.time;
  const u = g.moveDuration > 0 ? clamp01((t - g.moveStart) / g.moveDuration) : 1;
  const e = outCubic(u);
  g.yaw = lerp(g.fromYaw, g.toYaw, e);
  g.pitch = lerp(g.fromPitch, g.toPitch, e);
  g.roll = lerp(g.fromRoll, g.toRoll, e);
  if (u < 1) return;
  const seed = ctx.seed * 1000;
  let targetYaw;
  let targetPitch;
  let dwellMin;
  let dwellMax;
  if (runtime.focused) {
    targetYaw = ctx.lookYaw;
    targetPitch = ctx.lookPitch;
    dwellMin = FOCUS_DWELL_MIN;
    dwellMax = FOCUS_DWELL_MAX;
  } else {
    const pick = g.count + 1;
    targetYaw = (hash01(pick, seed + 1) * 2 - 1) * SCAN_YAW + ctx.lookYaw * 0.3;
    targetPitch = lerp(-SCAN_PITCH_DOWN, SCAN_PITCH_UP, hash01(pick, seed + 2));
    dwellMin = SCAN_DWELL_MIN;
    dwellMax = SCAN_DWELL_MAX;
  }
  const offYaw = Math.abs(angleDelta(g.yaw, targetYaw));
  const offPitch = Math.abs(targetPitch - g.pitch);
  const drifted = runtime.focused && Math.max(offYaw, offPitch) > SACCADE_THRESHOLD;
  if (!drifted && t < g.nextAt) return;
  g.count += 1;
  const pick = g.count;
  g.fromYaw = g.yaw;
  g.fromPitch = g.pitch;
  g.fromRoll = g.roll;
  g.toYaw = targetYaw;
  g.toPitch = targetPitch;
  let tilt = (hash01(pick, seed + 3) * 2 - 1) * TILT;
  if (hash01(pick, seed + 4) < 0.25) tilt = (tilt >= 0 ? 1 : -1) * TILT * 1.9;
  g.toRoll = tilt;
  g.moveStart = t;
  g.moveDuration = SACCADE_BASE + SACCADE_PER_RADIAN * Math.max(offYaw, offPitch);
  g.nextAt = t + lerp(dwellMin, dwellMax, hash01(pick, seed + 5));
}

function stepRuntime(runtime, ctx) {
  if (runtime.stamp === ctx.time) return;
  runtime.stamp = ctx.time;
  runtime.hunch = dampNumber(runtime.hunch, runtime.hunchTarget, HUNCH_SPEED, ctx.dt);
  updateGaze(runtime, ctx);
  for (let i = runtime.actions.length - 1; i >= 0; i--) {
    const run = runtime.actions[i];
    if (run.startAt === null) run.startAt = ctx.time;
    if (run.sign === 0) run.sign = ctx.lookYaw < -0.2 ? -1 : 1;
    const released = run.releaseAt !== null && run.releaseAt !== undefined && ctx.time - run.releaseAt > (HeldRelease[run.name] ?? 0);
    if (ctx.time - run.startAt > DURATIONS[run.name] || released) runtime.actions.splice(i, 1);
  }
}

const TWITCH_SLOT = 1.6;

/** Seeded twitches, a pure function of time: [envelope 0..1, kind 0..1, sign] of the strongest recent twitch. */
export function twitchAt(t, seed, chance) {
  let best = 0;
  let kind = 0;
  let sign = 1;
  const slot = Math.floor(t / TWITCH_SLOT);
  for (let back = 0; back <= 2; back++) {
    const s = slot - back;
    if (hash01(s, seed + 11) < chance) {
      const at = (s + hash01(s, seed + 12) * 0.8) * TWITCH_SLOT;
      const value = impulse(t - at, 0.045, 5.5);
      if (value > best) {
        best = value;
        kind = hash01(s, seed + 13);
        sign = hash01(s, seed + 14) < 0.5 ? -1 : 1;
      }
    }
  }
  return [best, kind, sign];
}

// ---------------------------------------------------------------------------------------------------------------
// Head, jaw and hair
// ---------------------------------------------------------------------------------------------------------------

function headTo(pose, desired, free) {
  const parent = pose.delta(UPPER);
  let relative = parent.inverse().mul(desired.rotation);
  if (!free) {
    const [rx, ry, rz] = relative.toEulerAnglesYXZ();
    relative = euler(clamp(rx, -NECK_LIMITS.pitchDown, NECK_LIMITS.pitchUp), clamp(ry, -NECK_LIMITS.yaw, NECK_LIMITS.yaw),
      clamp(rz, -NECK_LIMITS.roll, NECK_LIMITS.roll));
  }
  pose.set(NECK, CFrame.at(pose.get(NECK).position).mul(relative));
}

function lookRotation(yaw, pitch, roll) {
  return euler(pitch, yaw, roll);
}

function setJaw(pose, open) {
  pose.set(JAW, CFrame.angles(-Math.max(0, open), 0, 0));
}

function jawOpen(pose) {
  const [rx] = pose.get(JAW).toEulerAnglesXYZ();
  return -rx;
}

function clampTip(pivotPoint, direction, length, floor, bore) {
  let d = direction.clone();
  const lowest = floor + FLOOR_PAD;
  if (pivotPoint.y + d.y * length < lowest) {
    const y = clamp((lowest - pivotPoint.y) / length, -1, 1);
    const fl = V(d.x, 0, d.z);
    const horizontal = fl.length() > 1e-3 ? fl.normalize() : V(0, 0, 1);
    d = horizontal.multiplyScalar(Math.sqrt(Math.max(0, 1 - y * y))).add(V(0, y, 0));
  }
  if (bore) {
    const limit = BORE_HALF - BORE_MARGIN - 0.06;
    const tip = pivotPoint.clone().addScaledVector(d, length);
    const clamped = V(clamp(tip.x, -limit, limit), clamp(tip.y, -limit, limit), tip.z);
    if (clamped.distanceTo(tip) > 1e-4) {
      const toward = clamped.sub(pivotPoint);
      const reach = toward.length();
      if (reach < length) toward.add(V(0, 0, Math.sqrt(Math.max(0, length * length - reach * reach))));
      d = toward.length() > 1e-4 ? toward.normalize() : d;
    }
  }
  return d;
}

function hair(ctx, pose, m, style, floor) {
  if (m.hair.length === 0) return;
  const runtime = runtimeOf(ctx.map);
  let dynamics = runtime.hair[ctx.state];
  if (!dynamics || ctx.time - dynamics.stamp > HAIR_STALE || ctx.time < dynamics.stamp) {
    dynamics = { stamp: ctx.time, directions: {} };
    runtime.hair[ctx.state] = dynamics;
  }
  const dt = Math.max(0, ctx.time - dynamics.stamp);
  dynamics.stamp = ctx.time;
  const motion = V(ctx.velocity.x, ctx.verticalSpeed, ctx.velocity.z);
  const drag = motion.multiplyScalar(-DRAG_SCALE);
  if (drag.length() > MAX_DRAG) drag.setLength(MAX_DRAG);
  const facing = faceFrame(pose, m).lookVector;
  let back = V(-facing.x, 0, -facing.z);
  back = back.length() > 1e-3 ? back.normalize() : V(0, 0, 1);
  const headDelta = pose.delta(HEAD);
  const t = wrapTime(ctx.time);
  m.hair.forEach((chain, ci) => {
    const chainIndex = ci + 1;
    chain.forEach((segment, si) => {
      const segmentIndex = si + 1;
      const carried = pose.delta(segment.parentPart).pointToWorld(segment.rest);
      const splay = headDelta.pointToWorld(segment.splay);
      const fall = DOWN.clone().add(V(splay.x, 0, splay.z).multiplyScalar(1.4)).normalize();
      const hang = fall.clone().lerp(back.clone().add(V(0, 0.15, 0)).normalize(), style.stream);
      const stiffness = segmentIndex === 1 ? 0.4 : 0.22;
      const phase = chainIndex * 1.37 + segmentIndex * 0.6;
      const sway = V(perlin(t * 0.7, phase, ctx.seed * 3), 0, perlin(t * 0.6, phase + 9.1, ctx.seed * 3))
        .multiplyScalar(style.sway * segmentIndex);
      const keep = (1 - style.gravity) * stiffness;
      let desired = carried.multiplyScalar(keep).addScaledVector(hang, 1 - keep).addScaledVector(drag, segmentIndex).add(sway);
      desired = desired.length() > 1e-4 ? desired.normalize() : hang;
      const previous = dynamics.directions[segment.joint];
      let direction = previous ? previous.clone().lerp(desired, damp(HAIR_DAMP, dt)) : desired.clone();
      direction = direction.length() > 1e-4 ? direction.normalize() : desired;
      direction = clampTip(pose.pivot(segment.joint), direction, segment.length, floor, style.bore);
      dynamics.directions[segment.joint] = direction;
      pose.aim(segment.joint, direction);
    });
  });
}

// ---------------------------------------------------------------------------------------------------------------
// Limbs
// ---------------------------------------------------------------------------------------------------------------

/** The lowest point of a hand with its fingers under the pose. */
function handLowest(pose, m, side) {
  let lowest = lowestUnder(pose, m, HAND_PART[side]);
  for (const f of m.fingers[side]) if (m.bounds[f.part]) lowest = Math.min(lowest, lowestUnder(pose, m, f.part));
  return lowest;
}

/**
 * Poses one hand's fingers: `curl` toward the palm (negative opens them back), `spread` fanning them apart, `wave` a
 * slow ripple running across them (seconds `t`), the thumb following at half.
 */
function fingers(pose, m, side, curl, spread, wave = 0, t = 0) {
  for (const f of m.fingers[side]) {
    const thumb = f.fan > 2;
    const c = (thumb ? 0.5 : 1) * curl + wave * Math.sin(t * 2.3 + f.phase);
    const a = thumb ? spread * 0.5 : spread * f.fan * 0.5;
    pose.set(f.joint, CFrame.fromAxisAngle(f.curlAxis, c).mul(CFrame.fromAxisAngle(f.spreadAxis, a)));
  }
}

function clawsAbove(pose, m, side, floor) {
  for (let i = 0; i < 4; i++) {
    const deficit = floor + HAND_FLOOR - handLowest(pose, m, side);
    if (deficit <= 0) return;
    const bend = Math.min(rad(40), (deficit / Math.max(0.5, m.forearm)) * 1.15);
    pose.set(ELBOW[side], euler(bend, 0, 0).mul(pose.get(ELBOW[side])));
    pose.set(SHOULDER[side], euler(bend * 0.35, 0, 0).mul(pose.get(SHOULDER[side])));
  }
}

function boreExcess(point, radius) {
  const limit = BORE_HALF - BORE_MARGIN - radius;
  return Math.max(0, Math.abs(point.x) - limit) + Math.max(0, Math.abs(point.y) - limit);
}

function limbInBore(pose, limb, upperJoint, upper, lower, target, poles, radius, tip) {
  const origin = pose.pivot(upperJoint);
  let best = poles[0];
  let bestExcess = Infinity;
  for (const pole of poles) {
    const excess = boreExcess(solveTwoBone(origin, target, upper, lower, pole).mid, radius);
    if (excess < bestExcess - 1e-6) {
      best = pole;
      bestExcess = excess;
      if (excess <= 0) break;
    }
  }
  pose.limb(limb, target, best, tip);
}

// ---------------------------------------------------------------------------------------------------------------
// Upright gaits
// ---------------------------------------------------------------------------------------------------------------

function gaitAt(style, speed, m) {
  const leg = m.leg;
  const duty = style.duty(speed);
  const drop = style.drop(speed) * leg;
  const reach = REACH * leg;
  const height = m.standHip - m.ankle - drop + style.bob * leg;
  const frontHeight = height - ankleLift(style.strike, m.ankle, m.heel, m.toe);
  const backHeight = height - ankleLift(style.toeOff, m.ankle, m.heel, m.toe);
  const front = Math.sqrt(Math.max(0, reach * reach - frontHeight * frontHeight));
  const back = Math.sqrt(Math.max(0, reach * reach - backHeight * backHeight));
  const stance = Math.max(0.05, Math.min(style.stride(speed) * leg, front + back));
  const lowest = stance / 2 - back;
  const highest = front - stance / 2;
  const centre = lowest < highest ? clamp(style.bias * leg, lowest, highest) : (front - back) / 2;
  return { duty, stance, centre, drop, lift: style.lift(speed) * leg };
}

function cycleFor(style, turnStep) {
  return {
    length: (speed, map) => {
      const gait = gaitAt(style, speed, measure(map));
      return gait.stance / gait.duty;
    },
    turnStep,
  };
}

const NO_EXTRA = { drop: 0, pitch: 0, root: null, waist: null };

function upright(ctx, pose, m, style, extra) {
  const leg = m.leg;
  const move = ctx.moveAmount;
  const idle = 1 - move;
  const speed = ctx.speed;
  const phase = ctx.phase;
  const gait = gaitAt(style, speed, m);
  const stance = gait.duty * ctx.cycleLength * move;
  const centre = gait.centre * move;
  const turnLift = ctx.turnAmount * 0.55 * (1 - move);
  const lift = gait.lift * Math.max(move, turnLift);
  const drop = lerp(style.idleDrop * leg, gait.drop, move) + extra.drop;
  const midStance = gait.duty / 2;
  const bobCentre = remap(gait.duty, 0.6, 0.42, 0, midStance);
  // pelvis
  const bob = -style.bob * leg * move * Math.cos(2 * TAU * (phase - bobCentre));
  const sway = -style.sway * leg * move * Math.cos(TAU * (phase - midStance));
  const height = -drop + bob - ctx.landing;
  const lean = style.lean(speed) * move;
  const oscillation = Math.cos(TAU * phase);
  const pelvisYaw = ctx.hipYaw - style.pelvisYaw * move * oscillation;
  const chestYaw = style.chestYaw * move * oscillation;
  const pelvisRoll = -style.pelvisRoll * move * Math.cos(TAU * (phase - midStance));
  let pelvis = new CFrame(sway, height, 0).mul(euler(-lean * 0.4 + ctx.leanPitch * 0.4, pelvisYaw, pelvisRoll + ctx.leanRoll * 0.5));
  if (extra.root) pelvis = CFrame.at(extra.root.position).mul(pelvis).mul(extra.root.rotation);
  pose.set(ROOT, pelvis);
  const breathe = ctx.breath * style.breath * (1 + 1.5 * ctx.exertion);
  const chestPitch = -(lean * 0.6 + lerp(style.idleHunch, style.hunch, move) + extra.pitch);
  const chest = euler(chestPitch + ctx.leanPitch * 0.6 + breathe, chestYaw - pelvisYaw, -pelvisRoll * 0.6 + ctx.leanRoll * 0.5);
  pose.set(WAIST, extra.waist ? extra.waist.mul(chest) : chest);
  // legs
  const width = lerp(style.idleWidth, style.width, move);
  for (const side of SIDES) {
    const s = SIGN[side];
    const cycle = footCycle(phase - PLANT[side], stance, {
      duty: gait.duty, lift, liftPeak: style.liftPeak, strike: style.strike * move, toeOff: style.toeOff * move,
    });
    const along = swingAlong(cycle, stance, style.hover);
    const hip = m.hip[side];
    const stagger = -s * style.idleStagger * leg * 0.5 * idle;
    const flatPos = V(hip.x * width, 0, stagger).addScaledVector(ctx.travel, along + centre);
    const position = yawed(yawed(flatPos, ctx.hipYaw), ctx.twist[side]);
    const y = m.ground + m.ankle + cycle.lift + ctx.ground[side] + ankleLift(cycle.pitch, m.ankle, m.heel, m.toe);
    const yaw = ctx.hipYaw + ctx.twist[side] - s * style.toeOut;
    const pole = yawed(V(s * style.kneeOut, 0, -1), yaw);
    pose.limb(LEG[side], V(position.x, y, position.z), pole, euler(cycle.pitch, yaw, 0));
    pose.plant(side, cycle.stance || cycle.lift < 0.01 * leg);
  }
  return { lean, move, chestPitch };
}

function curve(fromSpeed, toSpeed, a, b) {
  return (speed) => remap(speed, fromSpeed, toSpeed, a, b);
}

function constant(value) {
  return () => value;
}

const STALK = {
  idleDrop: 0.02, idleWidth: 1.1, idleStagger: 0.08, duty: curve(2, 10, 0.7, 0.6), drop: curve(2, 10, 0.1, 0.16),
  stride: curve(0, 10, 0.55, 1.0), lift: curve(0, 10, 0.05, 0.08), lean: curve(0, 10, rad(2), rad(6)), bias: 0.02,
  bob: 0.006, sway: 0.014, pelvisYaw: rad(5), pelvisRoll: rad(3), chestYaw: rad(4), width: 1.0, strike: rad(4),
  toeOff: rad(-30), liftPeak: 0.3, toeOut: rad(7), kneeOut: 0.4, hover: 0.92, hunch: rad(8), idleHunch: rad(6),
  breath: rad(0.8),
};

const CREEP = {
  ...STALK, idleDrop: 0.17, drop: curve(2, 14, 0.17, 0.23), duty: curve(2, 14, 0.64, 0.52), stride: curve(0, 14, 0.5, 1.3),
  lean: curve(0, 14, rad(6), rad(13)), hunch: rad(24), idleHunch: rad(26), kneeOut: 0.6,
};

const CHASE = {
  idleDrop: 0.1, idleWidth: 1.05, idleStagger: 0.12, duty: curve(8, 20, 0.4, 0.32), drop: curve(8, 20, 0.17, 0.21),
  stride: constant(1.6), lift: curve(8, 20, 0.12, 0.18), lean: curve(6, 20, rad(14), rad(26)), bias: -0.04, bob: 0.028,
  sway: 0.01, pelvisYaw: rad(10), pelvisRoll: rad(4), chestYaw: rad(12), width: 0.85, strike: rad(6), toeOff: rad(-45),
  liftPeak: 0.34, toeOut: rad(5), kneeOut: 0.3, hover: 0.3, hunch: rad(8), idleHunch: rad(10), breath: rad(2),
};

const STAGGER = {
  idleDrop: 0.15, idleWidth: 1.45, idleStagger: 0.2, duty: constant(0.62), drop: constant(0.18), stride: curve(0, 5, 0.25, 0.6),
  lift: constant(0.12), lean: constant(rad(4)), bias: 0, bob: 0.02, sway: 0.06, pelvisYaw: rad(9), pelvisRoll: rad(7),
  chestYaw: rad(6), width: 1.4, strike: rad(2), toeOff: rad(-20), liftPeak: 0.4, toeOut: rad(14), kneeOut: 0.7, hover: 0,
  hunch: rad(8), idleHunch: rad(8), breath: rad(3),
};

const DORMANT = { ...STALK, idleDrop: 0.27, idleWidth: 1.3, idleStagger: 0.08, idleHunch: rad(44), hunch: rad(40), kneeOut: 0.55, breath: 0 };

const NEUTRAL = {
  ...STALK, idleDrop: 0.035, idleWidth: 1, idleStagger: 0, idleHunch: 0, hunch: rad(4), drop: curve(2, 16, 0.08, 0.18),
  hover: 0.4, kneeOut: 0.25, breath: rad(0.6),
};

// ---------------------------------------------------------------------------------------------------------------
// Arms (upright)
// ---------------------------------------------------------------------------------------------------------------

const HANG = {
  hang: rad(-3), swing: rad(9), pitch: rad(-2), elbow: rad(-6), elbowSwing: 0.2, out: rad(6), sway: rad(2), wrist: rad(-4),
  curl: rad(6), trail: rad(-12), spread: rad(5),
};
const STILL_ARMS = { ...HANG, sway: 0, elbow: rad(-6) };

function plumb(body) {
  return -body.chestPitch + body.lean * 0.4;
}

function hangArms(ctx, pose, m, style, body) {
  const move = body.move;
  const idle = 1 - move;
  for (const side of SIDES) {
    const s = SIGN[side];
    const legForward = Math.cos(TAU * (ctx.phase - PLANT[side] - 0.08));
    const swing = -style.swing * move * legForward;
    const drag = Math.sin(TAU * (ctx.phase - PLANT[side] - 0.2)) * move;
    const drift = idle * style.sway * noise(ctx.time * 0.31, ctx.seed * 13 + s);
    const pitch = lerp(style.hang, style.pitch, move) + swing + drift + plumb(body) * 0.9;
    pose.set(SHOULDER[side], euler(pitch, s * rad(4), s * (style.out + idle * rad(1.5) * ctx.breath)));
    pose.set(ELBOW[side], euler(style.elbow + style.elbowSwing * Math.max(0, swing), 0, 0));
    pose.set(WRIST[side], euler(style.wrist + rad(10) * drag, 0, -s * rad(6)));
    // the long fingers trail: opened back as the hand swings forward, a slow ripple through them at rest
    const trail = (style.trail ?? 0) * move * Math.max(0, -legForward);
    fingers(pose, m, side, (style.curl ?? rad(8)) + trail, style.spread ?? rad(4), rad(4) * idle, ctx.time + s);
    clawsAbove(pose, m, side, m.ground);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// States: upright
// ---------------------------------------------------------------------------------------------------------------

const UPRIGHT_HAIR = { gravity: 0.55, stream: 0, sway: 0.05, bore: false };

function finishUpright(ctx, pose, m) {
  applyActions(ctx, pose, m);
  hair(ctx, pose, m, UPRIGHT_HAIR, m.ground);
}

function hunchExtra(ctx) {
  const hunch = runtimeOf(ctx.map).hunch;
  if (hunch <= 1e-3) return NO_EXTRA;
  return { drop: HUNCH_DROP * hunch, pitch: HUNCH_PITCH * hunch, root: null, waist: null };
}

/** Under a low ceiling the head hangs lower on the neck (the gaze still finds its target). */
function hunchHead(ctx) {
  return -HUNCH_NECK * runtimeOf(ctx.map).hunch;
}

function waistFollow(ctx, pose, share) {
  const g = runtimeOf(ctx.map).gaze;
  pose.set(WAIST, euler(g.pitch * share * 0.5, g.yaw * share, 0).mul(pose.get(WAIST)));
}

function trackHead(ctx, pose, extraPitch, extraRoll) {
  const g = runtimeOf(ctx.map).gaze;
  headTo(pose, lookRotation(g.yaw, g.pitch + extraPitch, g.roll + extraRoll));
}

function dormant(ctx, pose) {
  const m = measure(ctx.map);
  const t = ctx.time;
  const body = upright(ctx, pose, m, DORMANT, NO_EXTRA);
  const breath = Math.sin(TAU * 0.16 * wrapTime(t) + ctx.seed * 5);
  const heave = Math.max(0, breath);
  const [twitch, kind, sign] = twitchAt(t, ctx.seed * 100, 0.32);
  pose.set(WAIST, euler(rad(2.5) * breath, 0, 0).mul(pose.get(WAIST)));
  for (const side of SIDES) {
    const s = SIGN[side];
    const hitch = kind > 0.66 && sign === s ? twitch : 0;
    pose.set(SHOULDER[side], new CFrame(0, 0.07 * heave + 0.12 * hitch, 0.02 * heave)
      .mul(euler(rad(16) + plumb(body) * 0.8 + rad(4) * heave, s * rad(6), s * (rad(4) + rad(2) * heave))));
    pose.set(ELBOW[side], euler(rad(12) + rad(8) * hitch, 0, 0));
    const spasm = kind > 0.33 && kind <= 0.66 && sign === s ? twitch : 0;
    pose.set(WRIST[side], euler(rad(14) - rad(35) * spasm, 0, -s * rad(8)));
    clawsAbove(pose, m, side, m.ground);
  }
  const jerk = kind <= 0.33 ? twitch : twitch * 0.25;
  headTo(pose, lookRotation(sign * rad(18) * jerk, -rad(52) + rad(3) * breath, rad(9) + sign * rad(26) * jerk));
  setJaw(pose, 0);
  for (const side of SIDES) fingers(pose, m, side, rad(20) + rad(10) * heave, rad(6), rad(3), t);
  finishUpright(ctx, pose, m);
}

function patrol(ctx, pose) {
  const m = measure(ctx.map);
  const body = upright(ctx, pose, m, STALK, hunchExtra(ctx));
  waistFollow(ctx, pose, 0.25);
  hangArms(ctx, pose, m, HANG, body);
  const [twitch, kind, sign] = twitchAt(ctx.time, ctx.seed * 100 + 7, 0.18 * (1 - body.move));
  if (kind > 0.5) {
    const side = sign > 0 ? 'Right' : 'Left';
    pose.set(SHOULDER[side], new CFrame(0, 0.1 * twitch, 0).mul(pose.get(SHOULDER[side])));
  }
  // the stalk: the head rolls slowly over to one side and back as it walks
  const tilt = rad(17) * Math.sin(TAU * wrapTime(ctx.time) / 6.5 + ctx.seed * 4) * (0.4 + 0.6 * body.move);
  trackHead(ctx, pose, hunchHead(ctx), tilt + (kind <= 0.5 ? sign * rad(24) * twitch : 0));
  setJaw(pose, 0);
  finishUpright(ctx, pose, m);
}

function investigate(ctx, pose) {
  const m = measure(ctx.map);
  const body = upright(ctx, pose, m, CREEP, hunchExtra(ctx));
  waistFollow(ctx, pose, 0.2);
  hangArms(ctx, pose, m, HANG, body);
  const t = ctx.time;
  const feel = noise(t * 0.4, ctx.seed * 3);
  pose.set(SHOULDER.Right, euler(rad(38) + plumb(body) * 0.6 + rad(8) * feel, rad(-10), rad(14) + rad(5) * noise(t * 0.5, 4)));
  pose.set(ELBOW.Right, euler(rad(62) + rad(10) * noise(t * 0.7, 5), 0, 0));
  pose.set(WRIST.Right, euler(rad(28) + rad(14) * Math.max(0, noise(t * 1.3, 6)), 0, rad(-12)));
  clawsAbove(pose, m, 'Right', m.ground);
  const burst = Math.max(0, Math.sin((TAU * wrapTime(t)) / 2.3 + ctx.seed));
  const peck = burst * Math.max(0, Math.sin(TAU * 5.5 * wrapTime(t))) ** 2;
  fingers(pose, m, 'Right', rad(-6) + rad(30) * Math.max(0, noise(t * 0.9, 7)), rad(10), rad(9), t);
  pose.set(NECK, new CFrame(0, -0.02, -0.22 - 0.07 * peck));
  trackHead(ctx, pose, -rad(24) + rad(6) * peck + hunchHead(ctx), rad(8) * Math.sin((TAU * wrapTime(t)) / 3.1));
  setJaw(pose, 0);
  finishUpright(ctx, pose, m);
}

function chase(ctx, pose) {
  const m = measure(ctx.map);
  const body = upright(ctx, pose, m, CHASE, hunchExtra(ctx));
  waistFollow(ctx, pose, 0.15);
  const t = ctx.time;
  const move = body.move;
  for (const side of SIDES) {
    const s = SIGN[side];
    // the arms swing low and long against the legs, hanging forward of the body with the lean
    const legForward = Math.cos(TAU * (ctx.phase - PLANT[side]));
    const jitter = noise(t * 2.7, ctx.seed * 11 + s * 3);
    const swing = -rad(34) * legForward * move;
    pose.set(SHOULDER[side], euler(plumb(body) * 0.85 + rad(8) * move + swing + rad(5) * jitter, s * rad(4), s * (rad(10) + rad(4) * jitter)));
    pose.set(ELBOW[side], euler(rad(14) + rad(16) * Math.max(0, -legForward) * move, 0, 0));
    pose.set(WRIST[side], euler(rad(-14) * move + rad(8) * jitter, 0, -s * rad(8)));
    fingers(pose, m, side, rad(-10) + rad(22) * Math.max(0, legForward) * move, rad(14), rad(6), t * 2 + s);
    clawsAbove(pose, m, side, m.ground);
  }
  trackHead(ctx, pose, rad(2) * move + hunchHead(ctx), 0);
  setJaw(pose, 0);
  finishUpright(ctx, pose, m);
}

function stunned(ctx, pose) {
  const m = measure(ctx.map);
  const t = ctx.time;
  const seed = ctx.seed * 19;
  const thrash = (rate, offset) => noise(t * rate, seed + offset);
  const buckle = Math.max(0, thrash(0.9, 1) - 0.15) * 1.6;
  upright(ctx, pose, m, STAGGER, {
    drop: 0.55 * buckle,
    pitch: rad(6) * buckle,
    root: new CFrame(0.25 * thrash(0.8, 5), 0, 0.2 * thrash(0.7, 6)).mul(euler(0, rad(10) * thrash(1.1, 7), rad(8) * thrash(1.4, 8))),
    waist: euler(rad(14) * thrash(1.7, 2) - rad(10), rad(26) * thrash(1.3, 3), rad(14) * thrash(1.9, 4)),
  });
  const g = runtimeOf(ctx.map).gaze;
  headTo(pose, lookRotation(
    g.yaw * 0.3 + rad(40) * thrash(2.8, 10) + rad(9) * stepped(t, 9, seed + 20),
    rad(18) * thrash(2.2, 11) + rad(10),
    rad(30) * thrash(2.5, 12),
  ));
  const face = faceFrame(pose, m);
  for (const side of SIDES) {
    const s = SIGN[side];
    const rake = (wrapTime(t) * 2.4 + (s > 0 ? 0.5 : 0)) % 1;
    const down = smoothstep(0.1, 0.75, rake);
    const offset = V(s * (0.32 + 0.1 * thrash(3, 9 + s)), 0.35 - 0.75 * down, -0.3 + 0.15 * down);
    pose.limb(ARM[side], face.pointToWorld(offset), face.vectorToWorld(V(s, -0.6, 0.35)), null);
    pose.set(WRIST[side], euler(rad(30) + rad(30) * down, 0, 0).mul(pose.get(WRIST[side])));
  }
  setJaw(pose, rad(2) + rad(3) * Math.max(0, thrash(4, 13)));
  for (const side of SIDES) fingers(pose, m, side, rad(35) + rad(25) * thrash(3.3, 14 + SIGN[side]), rad(18), 0, 0);
  finishUpright(ctx, pose, m);
}

function scripted(ctx, pose) {
  const m = measure(ctx.map);
  const body = upright(ctx, pose, m, NEUTRAL, hunchExtra(ctx));
  waistFollow(ctx, pose, 0.2);
  hangArms(ctx, pose, m, STILL_ARMS, body);
  trackHead(ctx, pose, hunchHead(ctx), 0);
  setJaw(pose, 0);
  finishUpright(ctx, pose, m);
}

// ---------------------------------------------------------------------------------------------------------------
// States: the duct crawl
// ---------------------------------------------------------------------------------------------------------------

function crawlCycle(style) {
  return { length: () => style.stride / style.duty, turnStep: 0.9 };
}

const CRAWL_PLANT = { LeftHand: 0, Right: 0.07, RightHand: 0.5, Left: 0.57 };
const BORE_HAIR = { gravity: 0.75, stream: 0.35, sway: 0.03, bore: true };
const QUADRUPED = new Set(['VentCrawl', 'VentRetreat']);
const HEAD_PARTS = [HEAD, JAW];
const BODY_PARTS = ['LowerTorso', UPPER];
const FIT_STEP = rad(5);

function spanOf(pose, m, parts) {
  let top = -Infinity;
  let bottom = Infinity;
  let right = -Infinity;
  let left = Infinity;
  for (const part of parts) {
    for (const c of boxCorners(pose.frame(part), m.bounds[part])) {
      top = Math.max(top, c.y);
      bottom = Math.min(bottom, c.y);
      right = Math.max(right, c.x);
      left = Math.min(left, c.x);
    }
  }
  return [top, bottom, right, left];
}

function headInBore(pose, m, limit) {
  for (let i = 0; i < 12; i++) {
    const [top, bottom, right, left] = spanOf(pose, m, HEAD_PARTS);
    let turn;
    if (right > limit) turn = CFrame.angles(0, 0, FIT_STEP);
    else if (left < -limit) turn = CFrame.angles(0, 0, -FIT_STEP);
    else if (top > limit) turn = CFrame.angles(-FIT_STEP, 0, 0);
    else if (bottom < -limit) turn = CFrame.angles(FIT_STEP, 0, 0);
    else return;
    headTo(pose, turn.mul(pose.delta(HEAD)), true);
  }
}

const ARM_POLES = {};
const LEG_POLES = {};
for (const side of SIDES) {
  const s = SIGN[side];
  ARM_POLES[side] = [V(s * 0.75, 1, -0.15), V(s * 1, 0.55, 0), V(s * 0.35, 1, 0.3), V(s * 1, 0.1, 0.4), V(0, 1, 0.6)];
  LEG_POLES[side] = [V(s * 0.8, 1, -0.3), V(s * 1, 0.4, -0.2), V(s * 0.5, 1, 0.2), V(s * 1, -0.2, 0), V(0, 1, -0.6)];
}

function crawl(ctx, pose, style, thrash) {
  const m = measure(ctx.map);
  const floor = -BORE_HALF;
  const limit = BORE_HALF - BORE_MARGIN;
  const move = ctx.moveAmount;
  const t = ctx.time;
  const seed = ctx.seed * 23;
  const direction = ctx.heading.z > 0.3 ? -1 : 1;
  const phase = ctx.phase;
  const hold = style.stutter * 0.5 * (stepped(t, 7, seed) * 0.5 + 0.5);
  const stance = style.duty * ctx.cycleLength * move;
  const oscillation = Math.sin(TAU * phase);
  // body: face down, low and level, the spine snaking with the gait
  const roll = style.roll * move * oscillation;
  const wave = style.spine * move * Math.sin(TAU * (phase + 0.12));
  const jolt = style.stutter * move * stepped(t, 11, seed + 1);
  pose.set(ROOT, prone(-Math.PI / 2 + rad(2) + rad(3) * jolt, wave * 0.5, roll));
  pose.set(WAIST, euler(style.chestRise + ctx.breath * rad(1.4), -roll * 0.5, -wave));
  const hips = pose.pivot(HIP.Left).add(pose.pivot(HIP.Right)).divideScalar(2);
  const shoulders = pose.pivot(SHOULDER.Left);
  shiftBody(pose, V(0, floor + style.hipHeight - hips.y + 0.05 * jolt, -style.shoulderZ - shoulders.z + 0.08 * jolt));
  // head: low and forward, peering from under the brow
  const g = runtimeOf(ctx.map).gaze;
  headTo(pose, lookRotation(
    g.yaw * 0.55 + thrash * rad(35) * noise(t * 3.4, seed + 3),
    style.face + g.pitch * 0.4 + thrash * rad(10) * noise(t * 2.6, seed + 4),
    g.roll * 1.3 + thrash * rad(25) * noise(t * 2.9, seed + 5),
  ), true);
  const ceiling = BORE_HALF - BORE_MARGIN;
  const [top] = spanOf(pose, m, HEAD_PARTS);
  if (top > ceiling) {
    const [, belly] = spanOf(pose, m, BODY_PARTS);
    const drop = Math.min(top - ceiling, Math.max(0, belly - (floor + BORE_MARGIN)));
    if (drop > 0) shiftBody(pose, V(0, -drop, 0));
  }
  headInBore(pose, m, ceiling);
  // arms: walking on the claws beside the head, elbows up toward the ceiling corners
  const [tap, , tapSide] = twitchAt(t, ctx.seed * 100 + 31, 0.3 * (1 - move));
  for (const side of SIDES) {
    const s = SIGN[side];
    const cycle = footCycle(phase - CRAWL_PLANT[CLAWS[side]], stance, { duty: style.duty, lift: style.handLift * move, liftPeak: 0.35 });
    if (tapSide === s && tap > 0) cycle.lift += 0.3 * tap;
    const along = swingAlong(cycle, stance, style.hover, hold);
    const lifted = style.handLift > 0 ? clamp01(cycle.lift / style.handLift) : 0;
    const hand = CFrame.angles(0, 0, s * rad(14)).mul(CFrame.angles(style.clawTip + rad(30) * lifted, 0, 0));
    const [lowest, outward] = extentOf(m.handCorners[side], hand, s);
    const shoulder = pose.pivot(SHOULDER[side]);
    let wrist = V(s * Math.min(style.handOut, limit - outward), floor + FLOOR_PAD - lowest + cycle.lift, shoulder.z - style.reach - direction * along);
    const clawing = side === 'Right' ? thrash : 0;
    if (clawing > 0) {
      const face = faceFrame(pose, m);
      const rake = (wrapTime(t) * 2.2) % 1;
      const target = face.pointToWorld(V(s * 0.32, 0.3 - 0.6 * smoothstep(0.1, 0.8, rake), -0.35));
      wrist = wrist.lerp(target, clawing);
    }
    limbInBore(pose, ARM[side], SHOULDER[side], m.upperArm, m.forearm, wrist, ARM_POLES[side], 0.24, hand);
    pose.plant(CLAWS[side], cycle.stance);
  }
  // legs: splayed, the knees up the walls, the feet pushing off on their toes behind
  for (const side of SIDES) {
    const s = SIGN[side];
    const cycle = footCycle(phase - CRAWL_PLANT[side], stance, { duty: style.duty, lift: style.footLift * move, liftPeak: 0.4 });
    const along = swingAlong(cycle, stance, style.hover, hold);
    const foot = euler(style.toeTip, s * rad(28), 0);
    const [lowest, outward] = extentOf(m.footCorners[side], foot, s);
    const hip = pose.pivot(HIP[side]);
    const ankle = V(s * Math.min(style.footOut, limit - outward), floor + FLOOR_PAD - lowest + cycle.lift, hip.z + style.footBack - direction * along);
    limbInBore(pose, LEG[side], HIP[side], m.thigh, m.shin, ankle, LEG_POLES[side], 0.3, foot);
    pose.plant(side, cycle.stance);
  }
  setJaw(pose, rad(2.5) + rad(2) * Math.max(0, oscillation) * move + thrash * rad(5));
  applyActions(ctx, pose, m);
  headInBore(pose, m, ceiling);
  hair(ctx, pose, m, BORE_HAIR, floor);
}

const VENT = {
  duty: 0.56, stride: 1.9, handLift: 0.32, footLift: 0.22, reach: 1.05, handOut: 1.2, footBack: 1.0, footOut: 1.15,
  hipHeight: 0.85, shoulderZ: 1.9, chestRise: rad(9), spine: rad(9), roll: rad(4), face: rad(-8), clawTip: rad(35),
  toeTip: rad(-62), stutter: 0.15, hover: 0.7,
};
const RETREAT = { ...VENT, duty: 0.62, stride: 1.2, stutter: 1, hover: 0.3, face: rad(-12) };

function ventCrawl(ctx, pose) {
  crawl(ctx, pose, VENT, 0);
}

function ventRetreat(ctx, pose) {
  const claw = smoothstep(0.2, 0.6, Math.max(0, noise(ctx.time * 0.5, ctx.seed * 29)));
  crawl(ctx, pose, RETREAT, claw);
}

// ---------------------------------------------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------------------------------------------

/** How far round the snap has turned: 0 (base pose) .. 1 (facing straight behind). */
export function snapProgress(elapsed) {
  if (elapsed < 0) return 0;
  if (elapsed < SNAP_TURN) return outBack(elapsed / SNAP_TURN, 1.2);
  const holdEnd = SNAP_SETTLE + SNAP_HOLD;
  if (elapsed < holdEnd) return 1;
  const steps = 3;
  const u = clamp01((elapsed - holdEnd) / SNAP_RELEASE) * steps;
  const k = Math.floor(u);
  return 1 - clamp01((k + smoothstep(0.35, 0.75, u - k)) / steps);
}

function snapShudder(elapsed) {
  if (elapsed < SNAP_TURN || elapsed > SNAP_SETTLE) return 0;
  const u = elapsed - SNAP_TURN;
  return rad(3.5) * Math.exp(-u * 9) * Math.sin(TAU * 17 * u);
}

function neckSnap(ctx, pose, _m, elapsed, run) {
  const s = snapProgress(elapsed);
  if (s <= 0) return;
  const sign = run.sign;
  const shudder = snapShudder(elapsed);
  const [rx, ry, rz] = pose.delta(HEAD).toEulerAnglesYXZ();
  if (!QUADRUPED.has(ctx.state)) {
    const stoop = pose.get(WAIST).lerp(IDENTITY, 0.5 * Math.min(s, 1));
    pose.set(WAIST, euler(0, sign * (SNAP_WAIST * s + shudder * 0.5), 0).mul(stoop));
  }
  const hold = smoothstep(SNAP_TURN, SNAP_SETTLE + 0.4, elapsed) * s;
  headTo(pose, euler(lerp(rx, rad(-4), s), lerp(ry, sign * Math.PI, s) + shudder, lerp(rz, sign * rad(11), hold)), true);
  setJaw(pose, lerp(jawOpen(pose), rad(3), hold));
}

function blendJoints(pose, joints, weight, solve) {
  if (weight <= 0) return;
  const saved = {};
  for (const j of joints) saved[j] = pose.get(j);
  solve();
  if (weight >= 1) return;
  for (const j of joints) pose.set(j, saved[j].lerp(pose.get(j), weight));
}

const ARM_JOINTS = {
  Left: [SHOULDER.Left, ELBOW.Left, WRIST.Left],
  Right: [SHOULDER.Right, ELBOW.Right, WRIST.Right],
};

/** The look target in rig space (the victim's eye for a jumpscare), else a point ahead at standing eye height. */
function targetPoint(ctx, m, fallbackAhead) {
  const t = runtimeOf(ctx.map).target;
  if (t) return t;
  return V(0, m.ground + 4.6, -fallbackAhead);
}

/** Drops the pelvis by `drop` with the feet kept where they are (the knees bend). */
function crouch(pose, m, drop) {
  if (drop <= 1e-3) return;
  const feet = {};
  for (const side of SIDES) feet[side] = { at: pose.pivot(ANKLE[side]), turn: pose.delta(FOOT_PART[side]) };
  shiftBody(pose, V(0, -drop, 0));
  for (const side of SIDES) {
    const s = SIGN[side];
    pose.limb(LEG[side], feet[side].at, V(s * 0.35, 0, -1), feet[side].turn);
  }
}

/** Aims the head (the face frame's look) at a rig-space point, past the neck limits. */
function aimHead(pose, m, point, roll) {
  // the face sits off the skull's pivot, so turning moves it: aim, then aim again from where it went
  for (let i = 0; i < 3; i++) {
    const aim = point.clone().sub(faceFrame(pose, m).position);
    if (aim.length() < 1e-3) return;
    headTo(pose, lookRotation(Math.atan2(-aim.x, -aim.z), Math.atan2(aim.y, Math.hypot(aim.x, aim.z)) + HEAD_REST_PITCH, roll), true);
  }
}

/**
 * How it bows to a victim's eye at `target`: the crouch (studs), the chest's bend (radians) and the step back off its
 * root (studs) that hang its mask, aimed at the eye, LOOM_DISTANCE in front of it and level with it (the jumpscare's
 * camera then sits between them, looking level into the mask). A coarse search, then a finer one round the best.
 */
function loomSolve(pose, m, target) {
  const saved = [ROOT, WAIST, NECK].map((j) => pose.get(j));
  const restore = () => [ROOT, WAIST, NECK].forEach((j, k) => pose.set(j, saved[k]));
  const evaluate = (drop, pitch) => {
    restore();
    shiftBody(pose, V(0, -drop, 0));
    pose.set(WAIST, euler(-pitch, 0, 0).mul(saved[1]));
    aimHead(pose, m, target, 0);
    let face = faceFrame(pose, m).position;
    // it steps back off its root (up to LOOM_BACK) so the mask hangs in front of the eye, not past it; stepping moves
    // the aim, so it is measured again after
    const rise0 = face.y - target.y;
    const want = Math.sqrt(Math.max(LOOM_DISTANCE * LOOM_DISTANCE - rise0 * rise0, 0.04));
    const back = clamp(want - (face.z - target.z), 0, LOOM_BACK);
    if (back > 0.01) {
      shiftBody(pose, V(0, 0, back));
      aimHead(pose, m, target, 0);
      face = faceFrame(pose, m).position;
    }
    const rise = face.y - target.y;
    const horizontal = Math.hypot(face.x - target.x, face.z - target.z);
    const distance = Math.hypot(horizontal, rise);
    const elevation = Math.atan2(rise, horizontal);
    const score = (distance - LOOM_DISTANCE) ** 2 + 2 * (elevation - LOOM_ELEVATION) ** 2 + 0.004 * pitch + 0.006 * drop + 0.01 * back;
    return { drop, pitch, back, score };
  };
  let best = { drop: 0, pitch: 0, back: 0, score: Infinity };
  const dropStep = m.leg * LOOM_DROP;
  for (let i = 0; i <= 10; i += 2) {
    for (let k = 0; k <= 12; k += 2) {
      const r = evaluate(dropStep * i, LOOM_PITCH * k);
      if (r.score < best.score) best = r;
    }
  }
  const coarse = best;
  for (let i = -1; i <= 1; i++) {
    for (let k = -1; k <= 1; k++) {
      if (i === 0 && k === 0) continue;
      const drop = clamp(coarse.drop + dropStep * i, 0, dropStep * 10);
      const pitch = clamp(coarse.pitch + LOOM_PITCH * k, 0, LOOM_PITCH * 12);
      const r = evaluate(drop, pitch);
      if (r.score < best.score) best = r;
    }
  }
  restore();
  return best;
}

function lunge(ctx, pose, m, elapsed, run) {
  const weight = envelope(elapsed, DURATIONS.Lunge, LUNGE_WIND * 0.6, LUNGE_RELEASE);
  if (weight <= 0) return;
  const recoil = smoothstep(0, LUNGE_WIND, elapsed) * (1 - smoothstep(LUNGE_WIND, LUNGE_WIND + 0.08, elapsed));
  const thrust = elapsed < LUNGE_WIND ? 0 : outBack((elapsed - LUNGE_WIND) / LUNGE_THRUST, 1.6);
  const strike = clamp01(thrust);
  // a jolt as the slit tears, a violent shudder through the hold
  const jolt = impulse(elapsed - 0.36, 0.03, 9);
  const tremor = smoothstep(LUNGE, LUNGE + 0.1, elapsed) * stepped(ctx.time, 24, run.seed) * (1 + 1.5 * smoothstep(0.85, 1.0, elapsed) * (1 - smoothstep(1.25, 1.45, elapsed)));
  const bore = QUADRUPED.has(ctx.state);
  const target = targetPoint(ctx, m, 4.2);
  // it bows to the victim: the knees fold, the chest bends far forward, the long neck reaching down until the mask
  // hangs level with their eye
  if (!bore) {
    // solved on each state's base pose before the bow (the animator blends states, each posing the actions on its own
    // base), again every LOOM_RESOLVE seconds (the base pose may change under it)
    run.looms ||= {};
    let loom = run.looms[ctx.state];
    if (!loom || ctx.time - loom.at > LOOM_RESOLVE) {
      loom = loomSolve(pose, m, target);
      loom.at = ctx.time;
      run.looms[ctx.state] = loom;
    }
    const k = Math.min(thrust, 1.08) * weight;
    shiftBody(pose, V(0, 0, loom.back * k));
    crouch(pose, m, loom.drop * k);
    pose.set(WAIST, euler(-loom.pitch * k + rad(8) * recoil * weight + rad(3) * jolt * weight, 0, rad(2) * tremor * weight).mul(pose.get(WAIST)));
  }
  // the mask stares straight into the victim's eye, cocked over as it snaps in, trembling through the hold
  const tilt = run.sign * lerp(LOOM_TILT, LOOM_TILT_HOLD, smoothstep(0.15, 0.6, elapsed)) * strike;
  const [rx, ry, rz] = pose.delta(HEAD).toEulerAnglesYXZ();
  aimHead(pose, m, target, tilt + rad(4) * tremor + run.sign * rad(6) * jolt);
  const [ax, ay, az] = pose.delta(HEAD).toEulerAnglesYXZ();
  headTo(pose, euler(lerp(rx, ax - rad(10) * recoil, weight), lerp(ry, ay, weight), lerp(rz, az, weight)), true);
  // the hands come up around the victim's head, the long fingers spread, curling as it holds
  const face = faceFrame(pose, m);
  for (const side of SIDES) {
    const s = SIGN[side];
    blendJoints(pose, ARM_JOINTS[side], weight, () => {
      const shoulder = pose.pivot(SHOULDER[side]);
      // beside the mask, just outside its outline and a little in front of it: the long fingers frame it, closing in
      let goal = face.pointToWorld(V(s * lerp(1.05, 0.95, strike), lerp(-0.7, -0.12, strike) - 0.3 * recoil, -lerp(0.0, 0.12, strike)));
      const reach = goal.clone().sub(shoulder);
      if (reach.length() > m.arm * 0.97) goal = shoulder.clone().addScaledVector(reach.normalize(), m.arm * 0.97);
      if (bore) {
        const lim = BORE_HALF - BORE_MARGIN - 0.3;
        goal = V(clamp(goal.x, -lim, lim), clamp(goal.y, -lim, lim), goal.z);
        limbInBore(pose, ARM[side], SHOULDER[side], m.upperArm, m.forearm, goal, ARM_POLES[side], 0.24, null);
      } else {
        // the elbows up over the head like a mantis, so the forearms come down past the mask's sides, not across it
        pose.limb(ARM[side], goal, face.vectorToWorld(V(s * 0.45, 1, 0.35)), null);
      }
      pose.set(WRIST[side], euler(-rad(20) * strike, -s * rad(18) * strike, 0).mul(pose.get(WRIST[side])));
    });
    fingers(pose, m, side, lerp(rad(-14), rad(38), smoothstep(LUNGE, LUNGE + 0.6, elapsed)) * weight, rad(22) * weight, rad(6) * weight, ctx.time * 4);
  }
  // the hinge parts a little as the slit tears (the jagged maw is the mask's own: mask.js maskFx)
  const tear = elapsed < 0.36 ? 0 : 0.35 + 0.65 * smoothstep(0.36, 0.78, elapsed);
  const open = LUNGE_JAW * tear + rad(1) * tremor;
  setJaw(pose, lerp(jawOpen(pose), open, weight));
}

/** A held action's weight: in over `fadeIn` seconds, out over its HeldRelease once released. */
function heldWeight(ctx, run, fadeIn) {
  let w = smoothstep(0, fadeIn, ctx.time - run.startAt);
  if (run.releaseAt !== null && run.releaseAt !== undefined) w *= 1 - smoothstep(0, HeldRelease[run.name] || 0.3, ctx.time - run.releaseAt);
  return w;
}

function stare(ctx, pose, m, elapsed, run) {
  const w = heldWeight(ctx, run, 0.22);
  if (w <= 0) return;
  // frozen: the chest still and leaning a little toward what it stares at, the head cocking slowly over with a
  // jolt at the start, the fingers flexing
  const cock = run.sign * (rad(31) * (1 - Math.exp(-elapsed * 1.4)) + rad(9) * impulse(elapsed, 0.04, 7));
  pose.set(WAIST, euler(-rad(5) * w, 0, 0).mul(pose.get(WAIST)));
  const current = pose.delta(HEAD);
  const desired = lookRotation(ctx.lookYaw, ctx.lookPitch - rad(3), cock);
  headTo(pose, current.lerp(desired, w));
  for (const side of SIDES) {
    const flex = 0.5 + 0.5 * Math.sin(elapsed * 1.25 + SIGN[side] * 1.7);
    fingers(pose, m, side, (rad(4) + rad(30) * flex) * w, rad(12) * w, 0, 0);
  }
}

function lookAway(ctx, pose, m, elapsed, run) {
  const w = heldWeight(ctx, run, 0.45);
  if (w <= 0) return;
  // the head turns away down the tunnel (the chest helps), a slow drift while it looks
  const drift = rad(6) * Math.sin(elapsed * 0.9);
  pose.set(WAIST, euler(0, run.sign * rad(28) * w, 0).mul(pose.get(WAIST)));
  const current = pose.delta(HEAD);
  const away = lookRotation(run.sign * rad(112) + drift, rad(4), -run.sign * rad(9));
  headTo(pose, current.lerp(away, w));
}

function reachIn(ctx, pose, m, elapsed, run) {
  const w = heldWeight(ctx, run, 0.3);
  if (w <= 0) return;
  const target = targetPoint(ctx, m, 3);
  const lean = smoothstep(0, 0.7, elapsed);
  const push = smoothstep(0.45, 1.7, elapsed);
  const grab = smoothstep(1.6, 2.2, elapsed);
  const search = Math.sin(elapsed * 2.6) * (1 - grab);
  // the chest leans and turns toward the gap
  const chest = pose.frame(UPPER).position;
  const flat = V(target.x - chest.x, 0, target.z - chest.z);
  const turn = flat.length() > 1e-3 ? Math.atan2(-flat.x, -flat.z) : 0;
  const down = clamp(Math.atan2(chest.y - target.y, Math.max(flat.length(), 0.5)), 0, rad(55));
  pose.set(WAIST, euler(-(rad(8) + down * 0.6) * lean * w, clamp(turn, -rad(40), rad(40)) * 0.6 * lean * w, 0).mul(pose.get(WAIST)));
  // the right arm slides into the gap, the long fingers splayed, then curling shut
  blendJoints(pose, ARM_JOINTS.Right, w, () => {
    const shoulder = pose.pivot(SHOULDER.Right);
    const toward = target.clone().sub(shoulder);
    const distance = toward.length();
    const reach = Math.min(distance, m.arm * 0.98);
    const into = shoulder.clone().addScaledVector(toward.normalize(), lerp(reach * 0.5, reach, push))
      .add(V(0.05 * search, 0.04 * search, 0));
    pose.limb(ARM.Right, into, V(1, -0.2, 0.4), null);
    pose.set(WRIST.Right, euler(-rad(12) * push, 0, rad(10) * search).mul(pose.get(WRIST.Right)));
  });
  fingers(pose, m, 'Right', lerp(rad(-18), rad(62), grab) * w, rad(24) * (1 - grab) * w, rad(10) * (1 - grab) * w, elapsed * 3);
  // the head tips toward the gap, cocked
  const current = pose.delta(HEAD);
  const aim = target.clone().sub(faceFrame(pose, m).position);
  const yaw = Math.atan2(-aim.x, -aim.z);
  const pitch = Math.atan2(aim.y, Math.hypot(aim.x, aim.z));
  headTo(pose, current.lerp(lookRotation(yaw, pitch, run.sign * rad(20)), w * 0.8));
}

function fadeOut(ctx, pose, m, elapsed, run) {
  const u = clamp01(elapsed / FADE_OUT);
  const w = smoothstep(0, 0.1, elapsed) * (elapsed <= FADE_OUT + 0.1 ? 1 : 0);
  if (w <= 0) return;
  // it rises as it goes: the chest lifts, the head tips back and away, the arms drift up and out, fingers splayed
  pose.set(WAIST, euler(rad(12) * u * w, 0, 0).mul(pose.get(WAIST)));
  for (const side of SIDES) {
    const s = SIGN[side];
    pose.set(SHOULDER[side], euler(rad(22) * u * w, 0, s * rad(24) * u * w).mul(pose.get(SHOULDER[side])));
    pose.set(ELBOW[side], euler(-rad(10) * u * w, 0, 0).mul(pose.get(ELBOW[side])));
    fingers(pose, m, side, rad(-20) * u * w, rad(30) * u * w, 0, 0);
  }
  const current = pose.delta(HEAD);
  headTo(pose, current.lerp(lookRotation(ctx.lookYaw * 0.5 + run.sign * rad(20), rad(32), run.sign * rad(16)), u * w));
  glitch(pose, ctx.time, run.seed, 0.3 * u * w, true);
}

function fadeIn(ctx, pose, m, elapsed, run) {
  const u = clamp01(elapsed / FADE_IN);
  const fold = 1 - smoothstep(0.05, 0.85, u);
  if (elapsed > FADE_IN + 0.1) return;
  // it forms folded over, unfolds upward, and the head comes up last, snapping onto its target
  crouch(pose, m, m.leg * 0.22 * fold);
  pose.set(WAIST, euler(-rad(40) * fold, 0, 0).mul(pose.get(WAIST)));
  for (const side of SIDES) {
    const s = SIGN[side];
    pose.set(SHOULDER[side], euler(rad(18) * fold, 0, s * rad(6) * fold).mul(pose.get(SHOULDER[side])));
    fingers(pose, m, side, rad(45) * fold, rad(10) * fold, 0, 0);
  }
  const current = pose.delta(HEAD);
  const hang = lookRotation(ctx.lookYaw * 0.3, -rad(60), run.sign * rad(25));
  const snap = smoothstep(0.82, 0.92, u);
  headTo(pose, current.lerp(hang, (1 - snap) * smoothstep(0, 0.1, elapsed)));
  glitch(pose, ctx.time, run.seed, 0.4 * fold, true);
}

function lockerRip(ctx, pose, m, elapsed) {
  const weight = envelope(elapsed, RIP, 0.15, 0.4);
  if (weight <= 0 || QUADRUPED.has(ctx.state)) return;
  const reach = smoothstep(0, 0.35, elapsed);
  const brace = smoothstep(0.35, 0.55, elapsed);
  const rip = smoothstep(0.55, 0.72, elapsed);
  pose.set(WAIST, euler((rad(-18) * reach + rad(16) * brace) * weight, rad(-42) * rip * weight, rad(-8) * rip * weight).mul(pose.get(WAIST)));
  const [rx, ry, rz] = pose.delta(HEAD).toEulerAnglesYXZ();
  headTo(pose, euler(rx, lerp(ry, rad(-25), rip * weight), lerp(rz, rad(18), rip * weight)));
  const chest = pose.frame(UPPER);
  for (const side of SIDES) {
    const s = SIGN[side];
    blendJoints(pose, ARM_JOINTS[side], weight, () => {
      const shoulder = pose.pivot(SHOULDER[side]);
      const grip = shoulder.clone().add(chest.vectorToWorld(V(-s * 0.3, -0.5, -m.arm * 0.72)));
      const pulled = shoulder.clone().add(chest.vectorToWorld(V(s * 0.2 + 0.9, -0.7, -m.arm * 0.35)));
      pose.limb(ARM[side], grip.lerp(pulled, rip), chest.vectorToWorld(V(s, -0.5, 0.2)), null);
      pose.set(WRIST[side], euler(rad(50) * brace, 0, 0).mul(pose.get(WRIST[side])));
    });
  }
  setJaw(pose, rad(6) * rip * weight + rad(1.5));
}

function doorSmash(ctx, pose, m, elapsed) {
  const weight = envelope(elapsed, SMASH, 0.1, 0.35);
  if (weight <= 0 || QUADRUPED.has(ctx.state)) return;
  const wind = smoothstep(0, 0.3, elapsed);
  const smash = smoothstep(0.3, 0.42, elapsed);
  pose.set(WAIST, euler((rad(10) * wind - rad(20) * smash) * weight, (rad(-32) * wind + rad(44) * smash) * weight, rad(-6) * wind * weight)
    .mul(pose.get(WAIST)));
  blendJoints(pose, ARM_JOINTS.Right, weight, () => {
    const shoulder = pose.pivot(SHOULDER.Right);
    const raised = shoulder.clone().add(V(0.4, m.arm * 0.5, m.arm * 0.3));
    const struck = shoulder.clone().add(V(-0.5, -0.2, -m.arm * 0.85));
    const target = shoulder.clone().lerp(raised, wind).lerp(struck, smash);
    pose.limb(ARM.Right, target, V(1, 0.2, 0.6), null);
  });
  blendJoints(pose, ARM_JOINTS.Left, weight * 0.8, () => {
    const shoulder = pose.pivot(SHOULDER.Left);
    pose.limb(ARM.Left, shoulder.clone().add(V(0.5, -m.arm * 0.15, -m.arm * 0.6)), V(-1, -0.4, 0.3), null);
  });
  setJaw(pose, rad(6) * smash * weight + rad(1.5));
}

const GLITCH_JOINTS = [NECK, WAIST, SHOULDER.Left, SHOULDER.Right, ELBOW.Left, ELBOW.Right, WRIST.Left, WRIST.Right];

function glitch(pose, t, seed, amount, limbs) {
  if (amount <= 0) return;
  GLITCH_JOINTS.forEach((joint, i) => {
    const index = i + 1;
    if (!limbs && joint !== NECK) return;
    const scale = joint === NECK ? 1.4 : joint === WAIST ? 0.6 : 1;
    const pitch = stepped(t, 26, seed + index * 3) * rad(28) * scale * amount;
    const yaw = stepped(t, 23, seed + index * 3 + 1) * rad(34) * scale * amount;
    const roll = stepped(t, 29, seed + index * 3 + 2) * rad(26) * scale * amount;
    pose.set(joint, euler(pitch, yaw, roll).mul(pose.get(joint)));
  });
  const jaw = Math.max(0, stepped(t, 31, seed + 40)) * rad(40) * amount;
  pose.set(JAW, CFrame.angles(-jaw, 0, 0).mul(pose.get(JAW)));
}

function vanish(ctx, pose, _m, elapsed, run) {
  const amount = smoothstep(0, 0.06, elapsed) * (elapsed <= VANISH ? 1 : 0);
  glitch(pose, ctx.time, run.seed, amount * (0.6 + 0.4 * smoothstep(0.1, VANISH, elapsed)), !QUADRUPED.has(ctx.state));
  const wrench = smoothstep(VANISH * 0.65, VANISH, elapsed) * amount;
  pose.set(NECK, euler(rad(-10) * wrench, run.sign * rad(55) * wrench, run.sign * rad(40) * wrench).mul(pose.get(NECK)));
}

function reveal(ctx, pose, _m, elapsed, run) {
  glitch(pose, ctx.time, run.seed, 1 - smoothstep(0, 0.28, elapsed), !QUADRUPED.has(ctx.state));
  const jerk = impulse(elapsed - 0.34, 0.03, 9);
  const cock = elapsed > 0.32 ? Math.max(jerk, 1 - smoothstep(0.38, REVEAL, elapsed)) : 0;
  pose.set(NECK, euler(rad(6) * cock, run.sign * rad(14) * cock, run.sign * rad(34) * cock).mul(pose.get(NECK)));
}

const ACTIONS = {
  NeckSnap: neckSnap,
  Lunge: lunge,
  Jumpscare: lunge,
  LockerRip: lockerRip,
  DoorSmash: doorSmash,
  Vanish: vanish,
  Reveal: reveal,
  Stare: stare,
  LookAway: lookAway,
  ReachIn: reachIn,
  FadeOut: fadeOut,
  FadeIn: fadeIn,
};

function applyActions(ctx, pose, m) {
  for (const run of runtimeOf(ctx.map).actions) {
    if (run.startAt === null) continue;
    const elapsed = ctx.time - run.startAt;
    if (elapsed >= 0 && elapsed <= DURATIONS[run.name]) ACTIONS[run.name](ctx, pose, m, elapsed, run);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------------------------------------------

function posed(fn) {
  return (ctx, pose) => {
    stepRuntime(runtimeOf(ctx.map), ctx);
    fn(ctx, pose);
  };
}

const states = {
  Dormant: { pose: posed(dormant), cycle: cycleFor(DORMANT, 1), footsteps: { plants: PLANT, volume: 0.4, sprint: false }, blendSpeed: 4, plantFeet: true },
  Patrol: { pose: posed(patrol), cycle: cycleFor(STALK, 1.4), footsteps: { plants: PLANT, volume: 1, sprint: false }, blendSpeed: 6, plantFeet: true, exertion: 0.1 },
  Investigate: { pose: posed(investigate), cycle: cycleFor(CREEP, 1.3), footsteps: { plants: PLANT, volume: 0.8, sprint: false }, blendSpeed: 6, plantFeet: true, exertion: 0.25 },
  Chase: { pose: posed(chase), cycle: cycleFor(CHASE, 1.4), footsteps: { plants: PLANT, volume: 1.25, sprint: true }, blendSpeed: 9, plantFeet: true, exertion: 1 },
  VentCrawl: { pose: posed(ventCrawl), cycle: crawlCycle(VENT), footsteps: { plants: CRAWL_PLANT, volume: 0.55, sprint: false }, blendSpeed: 14, exertion: 0.6 },
  VentRetreat: { pose: posed(ventRetreat), cycle: crawlCycle(RETREAT), footsteps: { plants: CRAWL_PLANT, volume: 0.65, sprint: false }, blendSpeed: 14, exertion: 1 },
  Stunned: { pose: posed(stunned), cycle: cycleFor(STAGGER, 1.6), footsteps: { plants: PLANT, volume: 0.9, sprint: false }, blendSpeed: 10, plantFeet: true, exertion: 1 },
  Scripted: { pose: posed(scripted), cycle: cycleFor(NEUTRAL, 1.3), footsteps: { plants: PLANT, volume: 0.9, sprint: false }, blendSpeed: 7, plantFeet: true },
};

/** The Creature's animation profile. */
export const Profile = Object.freeze({
  name: 'Creature',
  rootPart: 'HumanoidRootPart',
  required: REQUIRED,
  limbs: {
    LeftArm: { upper: 'LeftShoulder', lower: 'LeftElbow', tip: 'LeftWrist', bend: V(0, 0, 1) },
    RightArm: { upper: 'RightShoulder', lower: 'RightElbow', tip: 'RightWrist', bend: V(0, 0, 1) },
    LeftLeg: { upper: 'LeftHip', lower: 'LeftKnee', tip: 'LeftAnkle', bend: V(0, 0, -1) },
    RightLeg: { upper: 'RightHip', lower: 'RightKnee', tip: 'RightAnkle', bend: V(0, 0, -1) },
  },
  feet: {
    Left: { part: 'LeftFoot', limb: 'LeftLeg' },
    Right: { part: 'RightFoot', limb: 'RightLeg' },
    LeftHand: { part: 'LeftHand', limb: 'LeftArm' },
    RightHand: { part: 'RightHand', limb: 'RightArm' },
  },
  states,
  defaultState: 'Dormant',
  blendSpeed: 7,
  lateralStride: 0.8,
});

export function isState(name) {
  return States.includes(name);
}

export function isAction(name) {
  return typeof name === 'string' && DURATIONS[name] !== undefined;
}

const STATE_ALIASES = Object.freeze({
  Patrol: 'Patrol', Stalk: 'Patrol', Teleport: 'Patrol', HidingResponse: 'Patrol',
  InvestigateNoise: 'Investigate', Investigate: 'Investigate', Search: 'Investigate',
  WallChase: 'Chase', VentChase: 'Chase', Chase: 'Chase', Stunned: 'Stunned', Scripted: 'Scripted', Dormant: 'Dormant',
});

/**
 * The profile state for the Creature's situation: body shape (PoseMode, InVent) first, then the AI state. Knows
 * today's MonsterStates and the behaviour's newer names (Stalk, Investigate, Search, Chase, HidingResponse, Teleport);
 * anything else with "Chase" in it lopes, with "Search" / "Investigat" in it searches.
 */
export function resolveState(monsterState, poseMode, inVent) {
  if (poseMode === 'Quadruped' || inVent === true) return monsterState === 'Stunned' ? 'VentRetreat' : 'VentCrawl';
  if (poseMode === 'Stunned') return 'Stunned';
  if (monsterState === 'Scripted' && poseMode === 'Hunched') return 'Dormant';
  const known = STATE_ALIASES[monsterState];
  if (known) return known;
  const name = String(monsterState || '');
  if (/chase/i.test(name)) return 'Chase';
  if (/search|investigat/i.test(name)) return 'Investigate';
  if (/stun/i.test(name)) return 'Stunned';
  return 'Dormant';
}

/** How far the body ducks for a PoseMode (Hunched: about Rig.HunchedHeight, the 9-stud hitbox). */
export function hunchFor(poseMode) {
  return poseMode === 'Hunched' ? 1 : 0;
}

/** Starts `name` at animator clock `startAt` (null: its next step); replaying restarts it. */
export function playAction(map, name, startAt) {
  if (DURATIONS[name] === undefined) return false;
  if (startAt !== null && startAt !== undefined && !Number.isFinite(startAt)) return false;
  const runtime = runtimeOf(map);
  runtime.actions = runtime.actions.filter((r) => r.name !== name);
  runtime.serial += 1;
  runtime.actions.push({ name, startAt: startAt ?? null, sign: 0, seed: runtime.serial * 97 + name.length, releaseAt: null });
  return true;
}

/** Ends `name` (every action when null) at once. */
export function stopAction(map, name) {
  const runtime = runtimeOf(map);
  runtime.actions = runtime.actions.filter((r) => name !== null && name !== undefined && r.name !== name);
}

/** Lets a held action (Stare, LookAway, ReachIn) go over its HeldRelease from `at`; any other action ends at once. */
export function releaseAction(map, name, at) {
  const runtime = runtimeOf(map);
  if (HeldRelease[name] === undefined) {
    stopAction(map, name);
    return;
  }
  for (const run of runtime.actions) if (run.name === name && (run.releaseAt === null || run.releaseAt === undefined)) run.releaseAt = at;
}

/** Whether `name` is a held action (it runs until released). */
export function isHeld(name) {
  return HeldRelease[name] !== undefined;
}

/** The rig-space point the Jumpscare and ReachIn aim at (null: their defaults). @param {THREE.Vector3|null} point */
export function setLookTarget(map, point) {
  const runtime = runtimeOf(map);
  if (!point) runtime.target = null;
  else if (runtime.target) runtime.target.copy(point);
  else runtime.target = point.clone();
}

export function activeActions(map) {
  return runtimeOf(map).actions.map((r) => r.name);
}

export function actionStart(map, name) {
  const run = runtimeOf(map).actions.find((r) => r.name === name);
  return run ? run.startAt : null;
}

export function setHunch(map, amount) {
  if (Number.isFinite(amount)) runtimeOf(map).hunchTarget = clamp01(amount);
}

export function setFocus(map, focused) {
  runtimeOf(map).focused = focused;
}
