// ProceduralAnimator (Shared/Animation/ProceduralAnimator/init.luau): poses a rig in code from a Profile (data and
// pose functions written in rig axes: X right, Y up, -Z forward, relative to the root part). The web Creature has no
// Motor6Ds to write: a step produces every part's rig-space frame, which the view turns into its bone matrices.
//
// Each step:
//   1. Inputs: {moveState, velocity (world), grounded, lookYaw / lookPitch (world), time}.
//   2. Motion: the root-space velocity is smoothed into speed / heading; acceleration and turning feed lean springs;
//      the lower body yaws toward the travel direction; airborne time, landing, exertion and a breathing cycle.
//   3. Phase: one cycle phase shared by every state, advanced by distance travelled over the blended cycle length
//      (plus time-driven rates and turning on the spot), so gaits stay phase-continuous; foot plants crossed this step
//      become footstep events (the dominant state's spec).
//   4. Base pose: every state with weight > 0 evaluates its pose function into a PoseBuilder (joint entries in rig
//      axes, with FK queries and two-bone IK); state weights are critically damped springs; poses blend by slerp.
//   5. Ground probes plant the feet on uneven floors.
// (The Creature profile aims its own head and has no hand targets, so the look layer and hand IK of the Luau
// animator, which only the player rig uses, are not part of this port.)

import * as THREE from 'three';
import { CFrame, IDENTITY } from './cframe.js';
import { aimRotation, boneRotation, pivot, solveTwoBone, toTransform } from './rig.js';
import { NumberSpring, Signal, angleDelta, approach, clamp, damp, dampNumber, lerp, smoothstep, wrapAngle } from './util.js';

const MAX_DT = 0.1;
const VELOCITY_DAMP = 10;
const LOOK_DAMP = 20;
const MOVE_START = 0.35;
const MOVE_FULL = 2.2;
const HEADING_MIN_SPEED = 0.25;
const TURN_FULL = 3.5;
const TURN_DAMP = 10;
const TELEPORT_YAW = 1.2;
const TURN_STEP_LIMIT = 2;
const TWIST_LIMIT = (40 * Math.PI) / 180;
const TWIST_RELEASE = 9;
const LEAN_SPEED = 7;
const LEAN_DAMPING = 0.7;
const ACCEL_LEAN = 0.012;
const MAX_ACCEL = 60;
const MAX_ACCEL_LEAN = (11 * Math.PI) / 180;
const TURN_LEAN = 0.016;
const MAX_TURN_LEAN = (9 * Math.PI) / 180;
const HIP_YAW_SHARE = 0.6;
const HIP_YAW_MAX = Math.PI / 4;
const HIP_YAW_SPEED = 8;
const BACKWARD_ENTER = (105 * Math.PI) / 180;
const BACKWARD_EXIT = (75 * Math.PI) / 180;
const LATERAL_STRIDE = 0.75;
const AIR_RISE = 9;
const AIR_FALL = 14;
const LANDING_SPEED = 13;
const LANDING_DAMPING = 0.55;
const LANDING_IMPULSE = 0.045;
const MAX_FALL_SPEED = 70;
const EXERTION_RISE = 0.12;
const EXERTION_FALL = 0.05;
const BREATH_RESTED = 0.24;
const BREATH_WINDED = 0.75;
const PROBE_HEIGHT = 2.2;
const PROBE_DEPTH = 4.5;
const GROUND_LIMIT = 1.2;
const GROUND_DAMP = 18;
const MIN_CYCLE = 0.25;
const STEP_MOVE = 0.25;
const STEP_TURN = 0.35;
const WEIGHT_EPSILON = 0.002;
const FORWARD = new THREE.Vector3(0, 0, -1);

/** CFrame.fromEulerAnglesYXZ(pitch, yaw, roll). */
export function euler(pitch, yaw, roll) {
  return CFrame.fromEulerAnglesYXZ(pitch, yaw, roll);
}

/** True when a phase running from `from` to `to` (unwrapped) passes `mark` (mod 1). */
export function crossed(from, to, mark) {
  if (to <= from) return false;
  return Math.floor(to - mark) > Math.floor(from - mark);
}

/**
 * One foot through a gait cycle (0 at contact): planted for the first `duty`, sliding back exactly `stance` studs,
 * then a cycloid swing forward lifting `lift` studs.
 * @returns {{along: number, lift: number, pitch: number, stance: boolean, progress: number}}
 */
export function footCycle(footPhase, stance, params) {
  const duty = clamp(params.duty, 0.05, 0.95);
  const p = ((footPhase % 1) + 1) % 1;
  const strike = params.strike || 0;
  const toeOff = params.toeOff || 0;
  if (p < duty) {
    const u = p / duty;
    let pitch;
    if (u < 0.15) pitch = strike * (1 - smoothstep(0, 0.15, u));
    else if (u > 0.6) pitch = toeOff * smoothstep(0.6, 1, u);
    else pitch = 0;
    return { along: stance * (0.5 - u), lift: 0, pitch, stance: true, progress: u };
  }
  const v = (p - duty) / (1 - duty);
  const eased = v - Math.sin(2 * Math.PI * v) / (2 * Math.PI);
  const peak = clamp(params.liftPeak ?? 0.45, 0.1, 0.9);
  const height = v < peak
    ? (params.lift * (1 - Math.cos((Math.PI * v) / peak))) / 2
    : (params.lift * (1 + Math.cos((Math.PI * (v - peak)) / (1 - peak)))) / 2;
  const pitch = lerp(toeOff, strike, smoothstep(0.2, 0.95, v));
  return { along: stance * (eased - 0.5), lift: height, pitch, stance: false, progress: v };
}

/** How far an ankle rises when its foot pitches by `pitch` on the heel (pitch > 0) or the toe (pitch < 0). */
export function ankleLift(pitch, ankle, heel, toe) {
  if (pitch >= 0) return ankle * Math.cos(pitch) + heel * Math.sin(pitch) - ankle;
  return ankle * Math.cos(pitch) + toe * Math.sin(-pitch) - ankle;
}

/** Normalized weighted blend of poses (slerp per joint; a missing joint is identity). */
export function blend(poses, weights, out = new Map()) {
  out.clear();
  let accumulated = 0;
  poses.forEach((pose, index) => {
    const weight = weights[index] || 0;
    if (weight <= 0) return;
    const first = accumulated === 0;
    accumulated += weight;
    if (first) {
      for (const [joint, entry] of pose) out.set(joint, entry);
      return;
    }
    const alpha = weight / accumulated;
    for (const [joint, entry] of pose) out.set(joint, (out.get(joint) || IDENTITY).lerp(entry, alpha));
    for (const [joint, current] of out) if (!pose.has(joint)) out.set(joint, current.lerp(IDENTITY, alpha));
  });
  return out;
}

/** The yaw (MathUtil convention: 0 looks down -Z) of a frame's facing. */
export function yawOf(cframe) {
  return Math.atan2(cframe.r02, cframe.r22);
}

function unitOr(v, fallback) {
  return v.length() > 1e-6 ? v.clone().normalize() : fallback.clone();
}

function buildRigData(map, profile) {
  const limbs = {};
  for (const [name, spec] of Object.entries(profile.limbs)) {
    const up = pivot(map, spec.upper);
    const lo = pivot(map, spec.lower);
    const tip = pivot(map, spec.tip);
    limbs[name] = {
      spec,
      upper: lo.distanceTo(up),
      lower: tip.distanceTo(lo),
      upperRest: unitOr(lo.clone().sub(up), new THREE.Vector3(0, -1, 0)),
      lowerRest: unitOr(tip.clone().sub(lo), new THREE.Vector3(0, -1, 0)),
      bend: unitOr(spec.bend, FORWARD),
    };
  }
  const boneRest = {};
  const boneHint = {};
  for (const joint of map.order) {
    let direction;
    if (joint.children.length > 0) {
      const sum = new THREE.Vector3();
      for (const child of joint.children) sum.add(map.joints[child].pivot);
      direction = sum.divideScalar(joint.children.length).sub(joint.pivot);
    } else {
      direction = map.rest[joint.part1Name].position.sub(joint.pivot);
    }
    boneRest[joint.name] = unitOr(direction, new THREE.Vector3(0, -1, 0));
    boneHint[joint.name] = FORWARD.clone();
  }
  for (const data of Object.values(limbs)) {
    boneHint[data.spec.upper] = data.bend;
    boneHint[data.spec.lower] = data.bend;
  }
  return { map, limbs, boneRest, boneHint };
}

/**
 * The pose builder a state's pose function writes into (ProceduralAnimator.PoseBuilder).
 */
export class PoseBuilder {
  constructor(rig) {
    this.rig = rig;
    this.map = rig.map;
    /** @type {Map<string, CFrame>} joint -> entry (rig axes) */
    this.entries = new Map();
    /** @type {Map<string, CFrame>} */
    this.cache = new Map();
    /** @type {Record<string, boolean>} */
    this.planted = {};
  }

  set(joint, entry) {
    this.entries.set(joint, entry);
    this.cache.clear();
  }

  get(joint) {
    return this.entries.get(joint) || IDENTITY;
  }

  /** Rig-space frame of a part under the entries so far. */
  frame(part) {
    const map = this.map;
    if (part === map.rootName) return IDENTITY;
    const cached = this.cache.get(part);
    if (cached) return cached;
    const jointName = map.drivenBy[part];
    if (!jointName) throw new Error(`part ${part} is not jointed to the root`);
    const joint = map.joints[jointName];
    const entry = this.entries.get(jointName) || IDENTITY;
    const frame = this.frame(joint.part0Name).mul(joint.c0).mul(toTransform(joint, entry)).mul(joint.c1Inverse);
    this.cache.set(part, frame);
    return frame;
  }

  /** Rig-space pivot of a joint under the entries so far. */
  pivot(joint) {
    const j = this.map.joints[joint];
    if (!j) throw new Error(`no joint ${joint}`);
    const f = this.frame(j.part0Name).mul(j.c0);
    return new THREE.Vector3(f.x, f.y, f.z);
  }

  /** A part's rotation relative to its rest (rig space). */
  delta(part) {
    const inverse = this.map.restRotationInverse[part];
    if (!inverse) throw new Error(`no part ${part}`);
    return this.frame(part).rotation.mul(inverse);
  }

  /** Two-bone IK for a limb: its tip pivot at `target` with the middle joint toward `pole`. */
  limb(limb, target, pole, tip) {
    const data = this.rig.limbs[limb];
    if (!data) throw new Error(`no limb ${limb}`);
    const spec = data.spec;
    const upperJoint = this.map.joints[spec.upper];
    const origin = this.pivot(spec.upper);
    const solution = solveTwoBone(origin, target, data.upper, data.lower, pole);
    const parentDelta = this.delta(upperJoint.part0Name);
    const upperDelta = boneRotation(data.upperRest, data.bend, solution.mid.clone().sub(origin), solution.bend);
    const lowerDelta = boneRotation(data.lowerRest, data.bend, solution.tip.clone().sub(solution.mid), solution.bend);
    this.entries.set(spec.upper, parentDelta.inverse().mul(upperDelta));
    this.entries.set(spec.lower, upperDelta.inverse().mul(lowerDelta));
    this.entries.set(spec.tip, tip ? lowerDelta.inverse().mul(tip.rotation) : IDENTITY);
    this.cache.clear();
    return solution;
  }

  /** Turns a joint's bone to lie along `direction` (rig space), the smallest rotation unless `hint`. */
  aim(joint, direction, hint) {
    const spec = this.map.joints[joint];
    if (!spec) throw new Error(`no joint ${joint}`);
    const rest = this.rig.boneRest[joint];
    const parentDelta = this.delta(spec.part0Name);
    const delta = hint ? boneRotation(rest, this.rig.boneHint[joint], direction, hint) : aimRotation(rest, direction);
    const previous = this.entries.get(joint);
    const offset = previous ? previous.position : new THREE.Vector3();
    this.entries.set(joint, CFrame.at(offset).mul(parentDelta.inverse().mul(delta)));
    this.cache.clear();
  }

  plant(foot, planted) {
    this.planted[foot] = planted;
  }

  reset() {
    this.entries.clear();
    this.cache.clear();
    this.planted = {};
  }
}

/**
 * @typedef {Object} MotionContext
 * @property {import('./rig.js').JointMap} map
 * @property {string} state
 * @property {number} weight
 * @property {number} phase
 * @property {number} cycleLength
 * @property {number} time
 * @property {number} dt
 * @property {number} speed
 * @property {number} moveAmount
 * @property {THREE.Vector3} heading
 * @property {number} hipYaw
 * @property {THREE.Vector3} travel
 * @property {THREE.Vector3} velocity
 * @property {number} verticalSpeed
 * @property {number} leanPitch
 * @property {number} leanRoll
 * @property {number} turnRate
 * @property {number} turnAmount
 * @property {number} airborne
 * @property {number} landing
 * @property {number} exertion
 * @property {number} breath
 * @property {number} lookYaw
 * @property {number} lookPitch
 * @property {number} seed
 * @property {Record<string, number>} ground
 * @property {Record<string, number>} twist
 */

export class Animator {
  /**
   * @param {import('./rig.js').JointMap} map
   * @param {any} profile
   * @param {{seed?: number}} [options]
   */
  constructor(map, profile, options = {}) {
    this.map = map;
    this.profile = profile;
    this.rig = buildRigData(map, profile);
    this.seed = (((options.seed || 0) * 0.6180339887) % 1 + 1) % 1;
    /** (event: {foot, position, state, sprint, volume}) */
    this.footstep = new Signal();
    this.inputs = { moveState: profile.defaultState, velocity: new THREE.Vector3(), grounded: true, lookYaw: 0, lookPitch: 0, time: null };
    this.states = new Map();
    this.stateOrder = [];
    this.blended = new Map();
    /** @type {Record<string, CFrame>} part -> rig-space frame after the last step */
    this.frames = { [map.rootName]: IDENTITY };
    this.pendingFeet = [];
    this.phase = 0;
    this.cycleLength = 1;
    this.clock = 0;
    this.smoothedVelocity = new THREE.Vector3();
    this.verticalSpeed = 0;
    this.heading = FORWARD.clone();
    this.backward = false;
    this.hipYaw = new NumberSpring(0, HIP_YAW_SPEED, 1);
    this.leanPitch = new NumberSpring(0, LEAN_SPEED, LEAN_DAMPING);
    this.leanRoll = new NumberSpring(0, LEAN_SPEED, LEAN_DAMPING);
    this.landing = new NumberSpring(0, LANDING_SPEED, LANDING_DAMPING);
    this.turnRate = 0;
    this.lastYaw = null;
    this.airborne = 0;
    this.airTime = 0;
    this.fallSpeed = 0;
    this.exertion = 0;
    this.breathPhase = this.seed;
    this.lookYaw = 0;
    this.lookPitch = 0;
    this.twist = {};
    this.ground = {};
    for (const foot of Object.keys(profile.feet)) {
      this.twist[foot] = 0;
      this.ground[foot] = 0;
    }
    /** @type {((origin: THREE.Vector3, direction: THREE.Vector3) => THREE.Vector3|null)|null} */
    this.probe = null;
    /** @type {MotionContext} */
    this.ctx = {
      map, state: profile.defaultState, weight: 1, phase: 0, cycleLength: 1, time: 0, dt: 0, speed: 0, moveAmount: 0,
      heading: FORWARD.clone(), hipYaw: 0, travel: FORWARD.clone(), velocity: new THREE.Vector3(), verticalSpeed: 0,
      leanPitch: 0, leanRoll: 0, turnRate: 0, turnAmount: 0, airborne: 0, landing: 0, exertion: 0, breath: 0,
      lookYaw: 0, lookPitch: 0, seed: this.seed, ground: this.ground, twist: this.twist,
    };
    this._runtimeFor(profile.defaultState);
    this._solveFrames();
  }

  /** @param {{moveState?: string, velocity?: THREE.Vector3, grounded?: boolean, lookYaw?: number, lookPitch?: number, time?: number}} patch */
  setInputs(patch) {
    const i = this.inputs;
    if (patch.moveState !== undefined) i.moveState = patch.moveState;
    if (patch.velocity && Number.isFinite(patch.velocity.x)) i.velocity.copy(patch.velocity);
    if (patch.grounded !== undefined) i.grounded = patch.grounded;
    if (Number.isFinite(patch.lookYaw)) i.lookYaw = patch.lookYaw;
    if (Number.isFinite(patch.lookPitch)) i.lookPitch = patch.lookPitch;
    if (patch.time !== undefined) i.time = patch.time;
  }

  setGroundProbe(probe) {
    this.probe = probe || null;
  }

  _runtimeFor(name) {
    const existing = this.states.get(name);
    if (existing) return existing;
    const spec = this.profile.states[name];
    const runtime = {
      name,
      spec,
      weight: new NumberSpring(this.states.size === 0 ? 1 : 0, this.profile.blendSpeed, 1),
      builder: new PoseBuilder(this.rig),
    };
    this.states.set(name, runtime);
    this.stateOrder.push(runtime);
    return runtime;
  }

  _targetState() {
    const name = this.inputs.moveState;
    return this.profile.states[name] ? name : this.profile.defaultState;
  }

  _updateWeights(target, dt) {
    const entering = this.profile.states[target].blendSpeed || this.profile.blendSpeed;
    this._runtimeFor(target);
    let total = 0;
    for (let i = this.stateOrder.length - 1; i >= 0; i--) {
      const runtime = this.stateOrder[i];
      const spring = runtime.weight;
      spring.target = runtime.name === target ? 1 : 0;
      spring.speed = entering;
      spring.step(dt);
      spring.position = clamp(spring.position, 0, 1);
      if (runtime.name !== target && spring.position < WEIGHT_EPSILON) {
        this.states.delete(runtime.name);
        this.stateOrder.splice(i, 1);
        continue;
      }
      total += spring.position;
    }
    if (total <= 0) {
      this.states.get(target).weight.reset(1);
      total = 1;
    }
    let dominant = this.states.get(target);
    for (const runtime of this.stateOrder) if (runtime.weight.position > dominant.weight.position) dominant = runtime;
    return [dominant, total];
  }

  _updateMotion(rootWorld, dt) {
    const local = rootWorld.vectorToObject(this.inputs.velocity);
    if (!Number.isFinite(local.x) || !Number.isFinite(local.y) || !Number.isFinite(local.z)) local.set(0, 0, 0);
    const horizontal = new THREE.Vector3(local.x, 0, local.z);
    const previous = this.smoothedVelocity.clone();
    this.smoothedVelocity.lerp(horizontal, damp(VELOCITY_DAMP, dt));
    this.verticalSpeed = local.y;
    const speed = this.smoothedVelocity.length();
    if (speed > HEADING_MIN_SPEED) this.heading = this.smoothedVelocity.clone().divideScalar(speed);
    const moveAmount = smoothstep(MOVE_START, MOVE_FULL, speed);
    // turning
    const yaw = yawOf(rootWorld);
    let deltaYaw = this.lastYaw !== null ? angleDelta(this.lastYaw, yaw) : 0;
    this.lastYaw = yaw;
    if (Math.abs(deltaYaw) > TELEPORT_YAW) {
      deltaYaw = 0;
      for (const foot of Object.keys(this.twist)) this.twist[foot] = 0;
    }
    if (dt > 0) this.turnRate = dampNumber(this.turnRate, deltaYaw / dt, TURN_DAMP, dt);
    // lean into acceleration and turns
    const accel = dt > 0 ? this.smoothedVelocity.clone().sub(previous).divideScalar(dt) : new THREE.Vector3();
    if (accel.length() > MAX_ACCEL) accel.setLength(MAX_ACCEL);
    const forwardAccel = -accel.z;
    this.leanPitch.target = clamp(-forwardAccel * ACCEL_LEAN, -MAX_ACCEL_LEAN, MAX_ACCEL_LEAN);
    this.leanRoll.target = clamp(-accel.x * ACCEL_LEAN, -MAX_ACCEL_LEAN, MAX_ACCEL_LEAN) +
      clamp(speed * this.turnRate * TURN_LEAN, -MAX_TURN_LEAN, MAX_TURN_LEAN);
    this.leanPitch.step(dt);
    this.leanRoll.step(dt);
    // lower body toward the travel direction (backpedalling past ~105 degrees)
    const angle = Math.atan2(-this.heading.x, -this.heading.z);
    if (this.backward && Math.abs(angle) < BACKWARD_EXIT) this.backward = false;
    else if (!this.backward && Math.abs(angle) > BACKWARD_ENTER) this.backward = true;
    const relative = this.backward ? wrapAngle(angle - Math.PI) : angle;
    this.hipYaw.target = clamp(relative * HIP_YAW_SHARE, -HIP_YAW_MAX, HIP_YAW_MAX) * moveAmount;
    this.hipYaw.step(dt);
    const travel = CFrame.angles(0, -this.hipYaw.position, 0).vectorToWorld(this.heading);
    // airborne and landing
    if (this.inputs.grounded) {
      if (this.airTime > 0.15 && this.fallSpeed > 4) this.landing.impulse(Math.min(this.fallSpeed, MAX_FALL_SPEED) * LANDING_IMPULSE);
      this.airTime = 0;
      this.fallSpeed = 0;
      this.airborne = dampNumber(this.airborne, 0, AIR_FALL, dt);
    } else {
      this.airTime += dt;
      this.fallSpeed = Math.max(this.fallSpeed, -this.verticalSpeed);
      this.airborne = dampNumber(this.airborne, 1, AIR_RISE, dt);
    }
    this.landing.step(dt);
    // look relative to the facing
    const yawTarget = clamp(angleDelta(yaw, this.inputs.lookYaw), -(110 * Math.PI) / 180, (110 * Math.PI) / 180);
    const pitchInput = clamp(this.inputs.lookPitch, -(85 * Math.PI) / 180, (85 * Math.PI) / 180);
    this.lookYaw = dampNumber(this.lookYaw, yawTarget, LOOK_DAMP, dt);
    this.lookPitch = dampNumber(this.lookPitch, pitchInput, LOOK_DAMP, dt);
    const c = this.ctx;
    c.speed = speed;
    c.moveAmount = moveAmount;
    c.heading = this.heading;
    c.hipYaw = this.hipYaw.position;
    c.travel = unitOr(new THREE.Vector3(travel.x, 0, travel.z), FORWARD);
    c.velocity = this.smoothedVelocity;
    c.verticalSpeed = this.verticalSpeed;
    c.leanPitch = this.leanPitch.position;
    c.leanRoll = this.leanRoll.position;
    c.turnRate = this.turnRate;
    c.turnAmount = clamp(Math.abs(this.turnRate) / TURN_FULL, 0, 1);
    c.airborne = this.airborne;
    c.landing = Math.max(0, this.landing.position);
    c.lookYaw = this.lookYaw;
    c.lookPitch = this.lookPitch;
    return deltaYaw;
  }

  _advancePhase(dominant, deltaYaw, dt) {
    let cycleWeight = 0;
    let lengthSum = 0;
    let rateSum = 0;
    let turnSum = 0;
    const c = this.ctx;
    for (const runtime of this.stateOrder) {
      const cycle = runtime.spec.cycle;
      const w = runtime.weight.position;
      if (cycle && w > 0) {
        cycleWeight += w;
        lengthSum += w * cycle.length(c.speed, this.map);
        rateSum += w * (cycle.rate || 0);
        turnSum += w * (cycle.turnStep || 0);
      }
    }
    this.pendingFeet.length = 0;
    if (cycleWeight <= 0) {
      c.cycleLength = this.cycleLength;
      return;
    }
    const lateral = Math.abs(c.travel.x);
    this.cycleLength = Math.max(MIN_CYCLE, lengthSum / cycleWeight) * lerp(1, this.profile.lateralStride ?? LATERAL_STRIDE, lateral);
    let travel = c.speed * dt;
    if (c.speed < TURN_STEP_LIMIT) travel += Math.abs(deltaYaw) * (turnSum / cycleWeight) * (1 - c.moveAmount);
    const from = this.phase;
    const to = this.phase + travel / this.cycleLength + (rateSum / cycleWeight) * dt;
    const steps = dominant.spec.footsteps;
    if (steps && c.airborne < 0.5 && (c.moveAmount > STEP_MOVE || c.turnAmount > STEP_TURN)) {
      for (const [foot, mark] of Object.entries(steps.plants)) if (crossed(from, to, mark)) this.pendingFeet.push(foot);
    }
    this.phase = ((to % 1) + 1) % 1;
    c.cycleLength = this.cycleLength;
  }

  _updateExertion(dt) {
    let target = 0;
    let total = 0;
    for (const runtime of this.stateOrder) {
      const w = runtime.weight.position;
      total += w;
      target += w * (runtime.spec.exertion || 0);
    }
    if (total > 0) target /= total;
    target *= Math.max(this.ctx.moveAmount, 0.35);
    this.exertion = approach(this.exertion, target, (target > this.exertion ? EXERTION_RISE : EXERTION_FALL) * dt);
    this.breathPhase += dt * lerp(BREATH_RESTED, BREATH_WINDED, this.exertion);
    this.ctx.exertion = this.exertion;
    this.ctx.breath = Math.sin(2 * Math.PI * this.breathPhase);
  }

  _updateTwist(dominant, deltaYaw, dt) {
    const planted = dominant.builder.planted;
    for (const foot of Object.keys(this.twist)) {
      const value = this.twist[foot];
      if (planted[foot] && this.ctx.airborne < 0.5) this.twist[foot] = clamp(value - deltaYaw, -TWIST_LIMIT, TWIST_LIMIT);
      else this.twist[foot] = dampNumber(value, 0, TWIST_RELEASE, dt);
    }
  }

  _solveFrames() {
    const frames = this.frames;
    frames[this.map.rootName] = IDENTITY;
    for (const joint of this.map.order) {
      const entry = this.blended.get(joint.name) || IDENTITY;
      frames[joint.part1Name] = frames[joint.part0Name].mul(joint.c0).mul(toTransform(joint, entry)).mul(joint.c1Inverse);
    }
  }

  _emitFootsteps(dominant, rootWorld) {
    const steps = dominant.spec.footsteps;
    if (!steps || this.pendingFeet.length === 0) return;
    const c = this.ctx;
    const volume = steps.volume * clamp(Math.max(c.moveAmount, c.turnAmount * 0.5), 0.3, 1);
    for (const foot of this.pendingFeet) {
      const spec = this.profile.feet[foot];
      const frame = spec ? this.frames[spec.part] : null;
      if (frame) {
        this.footstep.fire({ foot, position: rootWorld.pointToWorld(frame.position), state: dominant.name, sprint: steps.sprint, volume });
      }
    }
  }

  _probeGround(rootWorld, plantShare, dt) {
    const active = this.probe;
    const floorY = rootWorld.point(0, this.map.groundY, 0).y;
    for (const [foot, spec] of Object.entries(this.profile.feet)) {
      let offset = 0;
      const frame = this.frames[spec.part];
      if (active && frame && plantShare > 0.5 && this.ctx.airborne < 0.5) {
        const world = rootWorld.pointToWorld(frame.position);
        const hit = active(new THREE.Vector3(world.x, floorY + PROBE_HEIGHT, world.z), new THREE.Vector3(0, -PROBE_DEPTH, 0));
        if (hit) offset = clamp(hit.y - floorY, -GROUND_LIMIT, GROUND_LIMIT);
      }
      this.ground[foot] = dampNumber(this.ground[foot], offset, GROUND_DAMP, dt);
    }
  }

  /**
   * One step: poses every active state and blends them; `frames` holds every part's rig-space frame afterwards.
   * @param {number} dt @param {CFrame} rootWorld
   */
  step(dt, rootWorld) {
    dt = clamp(dt, 0, MAX_DT);
    const target = this._targetState();
    this.clock += dt;
    const deltaYaw = this._updateMotion(rootWorld, dt);
    const [dominant, total] = this._updateWeights(target, dt);
    this._advancePhase(dominant, deltaYaw, dt);
    this._updateExertion(dt);
    const c = this.ctx;
    c.time = this.inputs.time ?? this.clock;
    c.dt = dt;
    c.phase = this.phase;
    const poses = [];
    const weights = [];
    let plantShare = 0;
    for (const runtime of this.stateOrder) {
      const w = runtime.weight.position;
      if (w <= 0) continue;
      c.state = runtime.name;
      c.weight = w / total;
      runtime.builder.reset();
      runtime.spec.pose(c, runtime.builder);
      poses.push(runtime.builder.entries);
      weights.push(w);
      plantShare += w * (runtime.spec.plantFeet ? 1 : 0);
    }
    plantShare /= total;
    blend(poses, weights, this.blended);
    this._updateTwist(dominant, deltaYaw, dt);
    this._solveFrames();
    this._emitFootsteps(dominant, rootWorld);
    this._probeGround(rootWorld, plantShare, dt);
    this.dominant = dominant.name;
  }

  /** The dominant state. */
  getState() {
    let best = null;
    for (const r of this.stateOrder) if (!best || r.weight.position > best.weight.position) best = r;
    return best ? best.name : this.profile.defaultState;
  }

  /** A part's rig-space frame after the last step. */
  getPartFrame(part) {
    return this.frames[part] || null;
  }
}
