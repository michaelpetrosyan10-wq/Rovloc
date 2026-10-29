// doors.js: the run's fixture doors (DoorService + DoorMotion + DoorController): the stairwell airlock fire doors, the
// Level 1 hallway gate and ajar classroom door, the roof stairwell door. The only writer of DoorState and of every
// leaf pose.
//
// States: Open = the fully open pose; Closed and Locked = the shut pose (Locked refuses requestOpen, scripts may still
// set it open); Smashed = torn apart, final. Initial: airlock doors Open (built open), the gate Open (rolled up), the
// classroom door Open at its built ajar pose, the roof door Closed (snapped shut silently).
// Motion: a value (openness 0 shut .. 1 open, or smash progress) from `from` to `to` over `seconds` starting
// OneShotLead from now, eased (InOut swings, In for the gate dropping, Linear smashes). The leaves are posed every
// frame from the motion (smooth), the logic steps at 30 Hz: a swing that would touch the player over the next
// LOOKAHEAD seconds stops short ("held") and finishes once the doorway has been clear for CLEAR_SECONDS.
// Leaf poses come from the export's per-leaf attachments: <Leaf>Rest, <Leaf>Open, <Leaf>Smashed, <Leaf>Centre.
// Sounds at the opening's centre: FireDoorSwing + FireDoorLatch (airlocks), DoorCreak + a soft latch (classroom,
// roof), MetalCreak rising and GateSlam landing (the gate), DoorSmash. The gate and the fire doors slamming shut
// emit the DoorSlam noise when they land. Impacts shake the camera with quadratic falloff (DoorController.Impacts):
// the gate slamming down, a fire door latching shut, a door being smashed (just after the smash starts).

import * as THREE from 'three';
import { cfMatrix, smoothstep, Signal } from '../util.js';

const LEAD = 0.2; // GameConfig.OneShotLead
const SMASH_SECONDS = 0.7;
const MIN_SECONDS = 0.12;
const LOOKAHEAD = 0.25;
const SWEEP_SAMPLES = 4;
const SAMPLE_STEP = 0.05;
const BLOCK_MARGIN = 0.2;
const CLEAR_SECONDS = 0.3;
const HELD_RECHECK = 0.1;
const BODY_WIDTH = 3.2;
const BODY_DEPTH = 1.6;
const BODY_HEAD_ROOM = 2.5;
const ROOT_HALF = 1;
const HIP_HEIGHT = 2;
const EPS = 1e-4;
const THROW_HOP = 0.8;
const BUCKLE_HOP = 0.15;
const LIGHT_LATCH_VOLUME = 0.55;

const IMPACTS = { Slam: { radius: 30, amplitude: 2.4, seconds: 0.7 }, Smash: { radius: 34, amplitude: 3.2, seconds: 0.8 },
  Latch: { radius: 12, amplitude: 0.8, seconds: 0.35 } };
const SMASH_IMPACT_DELAY = 0.12;

/** DoorController.impactShake: [degrees, seconds] of an impact `distance` studs from the eye. */
export function impactShake(kind, distance) {
  const spec = IMPACTS[kind];
  if (!spec || !Number.isFinite(distance) || distance >= spec.radius) return [0, 0];
  const falloff = 1 - Math.max(0, distance) / spec.radius;
  return [spec.amplitude * falloff * falloff, spec.seconds];
}

const INITIAL = { Airlock: 'Open', Gate: 'Open', Ajar: 'Open', RoofDoor: 'Closed' };
const TRAVEL = { Airlock: { open: 1.6, close: 1.6 }, Gate: { open: 2.8, close: 0.35 }, Ajar: { open: 1.2, close: 0.9 },
  RoofDoor: { open: 1.2, close: 0.9 } };
const FIXTURE_TYPES = ['AirlockDoor', 'HallwayGate', 'ClassroomDoor', 'RoofStairDoor'];

/** DoorService.plan */
export function planFor(current, next) {
  if (current === 'Smashed' || current === next) return ['Refuse', null];
  if (next === 'Smashed') return ['Smash', null];
  if (next === 'Open') return ['Swing', 1];
  if (current === 'Closed' || current === 'Locked') return ['StateOnly', null];
  return ['Swing', 0];
}

/** DoorMotion.ease */
function ease(kind, t) {
  const x = Math.min(1, Math.max(0, t));
  if (kind === 'InOut') return x * x * (3 - 2 * x);
  if (kind === 'In') return x * x;
  return x;
}

/** DoorMotion.valueAt: [value, done] */
export function valueAt(motion, now) {
  if (now < motion.startAt) return [motion.from, false];
  if (motion.seconds <= 0) return [motion.to, true];
  const t = (now - motion.startAt) / motion.seconds;
  if (t >= 1) return [motion.to, true];
  return [motion.from + (motion.to - motion.from) * ease(motion.ease, t), false];
}

// ------------------------------------------------------------------------------------------------- rotation helpers

const _q = new THREE.Quaternion();
const _q2 = new THREE.Quaternion();
const _qi = new THREE.Quaternion();
const _v = new THREE.Vector3();
const _v2 = new THREE.Vector3();
const _s = new THREE.Vector3();
const _m = new THREE.Matrix4();
const _m2 = new THREE.Matrix4();
const _m3 = new THREE.Matrix4();

/** The rotation part of `m` turned by share t (about its own axis), translation dropped (DoorBuilder.partialRotation). */
function partialRotation(m, t, out) {
  m.decompose(_v, _q, _s);
  return out.makeRotationFromQuaternion(_qi.identity().slerp(_q, t));
}

/** Angle (radians) of a rotation matrix. */
function angleOf(m) {
  m.decompose(_v, _q, _s);
  const w = Math.min(1, Math.abs(_q.w));
  return 2 * Math.acos(w);
}

export class Doors {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Doors';
    this.game = game;
    this.env = game.env;
    /** @type {Map<string, any>} by DoorId */
    this.byId = new Map();
    /** @type {Signal<[any, string, string]>} (door, previous, next) */
    this.stateChanged = new Signal();
    for (const info of game.world.meta.entities) if (FIXTURE_TYPES.includes(info.type)) this._index(info);
  }

  _index(info) {
    const world = this.game.world;
    const kind = info.attributes.DoorKind;
    const leaves = [];
    for (const node of info.nodes) {
      const a = info.attachments;
      if (!a[`${node.path}Rest`]) continue;
      const rest = cfMatrix(a[`${node.path}Rest`]);
      const leaf = {
        name: node.path,
        rest,
        restInv: rest.clone().invert(),
        open: a[`${node.path}Open`] ? cfMatrix(a[`${node.path}Open`]) : null,
        smashed: a[`${node.path}Smashed`] ? cfMatrix(a[`${node.path}Smashed`]) : null,
        centre: a[`${node.path}Centre`] ? cfMatrix(a[`${node.path}Centre`]) : null,
        built: cfMatrix(node.pivot),
        bounds: world.nodeBounds(info.id, node.path),
      };
      leaf.full = leaf.open ? new THREE.Matrix4().multiplyMatrices(leaf.restInv, leaf.open) : null;
      leaves.push(leaf);
    }
    const centre = new THREE.Vector3();
    let n = 0;
    for (const l of leaves) {
      if (l.centre) {
        centre.add(_v.setFromMatrixPosition(l.centre));
        n++;
      }
    }
    if (n) centre.divideScalar(n);
    else centre.set(info.pivot[0], info.pivot[1] + 5, info.pivot[2]);
    const door = {
      id: info.id,
      info,
      kind,
      type: info.type,
      scriptedId: info.attributes.ScriptedId || null,
      level: info.level,
      fromLevel: info.attributes.FromLevel || null,
      toLevel: info.attributes.ToLevel || null,
      leaves,
      centre,
      state: INITIAL[kind] || 'Open',
      openness: 0,
      smash: 0,
      smashFrom: 0,
      motion: null,
      held: false,
      target: 0,
      speed: 1,
      clearSince: null,
      recheckAt: 0,
      landing: null,
      landingAt: null,
      stragglerDeadline: null,
    };
    door.builtOpenness = this._opennessOfBuilt(door);
    this.byId.set(door.id, door);
  }

  _opennessOfBuilt(door) {
    const leaf = door.leaves[0];
    if (!leaf || !leaf.full) return 0;
    const current = _m.multiplyMatrices(leaf.restInv, leaf.built);
    if (door.kind === 'Gate') {
      const travel = _v2.setFromMatrixPosition(leaf.full);
      const len = travel.dot(travel);
      if (len < 1e-8) return 0;
      return Math.min(1, Math.max(0, _v.setFromMatrixPosition(current).dot(travel) / len));
    }
    const full = angleOf(leaf.full);
    if (full < 1e-6) return 0;
    return Math.min(1, Math.max(0, angleOf(current) / full));
  }

  // ---------------------------------------------------------------------------------------------------- lookup

  get(id) {
    return this.byId.get(id) || null;
  }

  /** A door on a level by its ScriptedId (HallwayGate, ClassroomDoor, RoofStairDoor) or DoorId. */
  find(level, id) {
    for (const d of this.byId.values()) if (d.level === level && (d.scriptedId === id || d.id === id)) return d;
    return null;
  }

  /** The airlock doors a level leaves by (FromLevel = level). */
  exitDoors(level) {
    return [...this.byId.values()].filter((d) => d.kind === 'Airlock' && d.fromLevel === level && d.level === level);
  }

  // ---------------------------------------------------------------------------------------------------- poses

  /** A leaf's world frame for a mode at a value (DoorMotion.transforms). */
  leafWorld(door, leaf, mode, value, smashFrom = 0, out = new THREE.Matrix4()) {
    if (mode === 'Smash') {
      const smashed = this._smashedWorld(door, leaf, value, out);
      if (!smashed) return null;
      if (smashFrom > 0 && leaf.full) {
        // the open swing unwinds as the leaf is torn away
        const t = this._openTransform(door, leaf, smashFrom, _m3);
        const share = 1 - ease('InOut', value);
        const partial = lerpTransform(t, share, _m2);
        out.multiply(partial);
      }
      return out;
    }
    const t = this._openTransform(door, leaf, value, _m3);
    if (!t) return null;
    return out.multiplyMatrices(leaf.rest, t);
  }

  _openTransform(door, leaf, openness, out) {
    if (!leaf.full) return null;
    const t = Math.min(1, Math.max(0, openness));
    if (door.kind === 'Gate') {
      _v.setFromMatrixPosition(leaf.full).multiplyScalar(t);
      return out.makeTranslation(_v.x, _v.y, _v.z);
    }
    return partialRotation(leaf.full, t, out);
  }

  _smashedWorld(door, leaf, t, out) {
    if (!leaf.smashed || !leaf.centre) return null;
    const k = Math.min(1, Math.max(0, t));
    const hop = door.kind === 'Airlock' ? BUCKLE_HOP : THROW_HOP;
    const offset = _m.copy(leaf.centre).invert().multiply(leaf.rest); // centre:ToObjectSpace(rest)
    const landed = _m2.copy(leaf.smashed).multiply(_m3.copy(offset).invert());
    const cPos = _v.setFromMatrixPosition(leaf.centre);
    const lPos = _v2.setFromMatrixPosition(landed);
    const dx = lPos.x - cPos.x;
    const dy = lPos.y - cPos.y;
    const dz = lPos.z - cPos.z;
    const outward = 1 - (1 - k) * (1 - k);
    const tip = smoothstep(0, 1, k);
    const px = cPos.x + dx * outward;
    const py = cPos.y + dy * tip + hop * Math.sin(Math.PI * k);
    const pz = cPos.z + dz * outward;
    leaf.centre.decompose(_v, _q, _s);
    landed.decompose(_v2, _q2, _s);
    const rel = _qi.copy(_q).invert().multiply(_q2);
    const partial = new THREE.Quaternion().slerp(rel, tip);
    const rot = _q.clone().multiply(partial);
    out.compose(_v.set(px, py, pz), rot, _s.set(1, 1, 1)).multiply(offset);
    return out;
  }

  _pose(door, mode, value) {
    for (const leaf of door.leaves) {
      const w = this.leafWorld(door, leaf, mode, value, door.smashFrom, _pose);
      if (w) this.env.setNodePivot(door.id, leaf.name, w);
    }
    if (mode === 'Swing') door.openness = value;
    else door.smash = value;
  }

  // ---------------------------------------------------------------------------------------------------- state

  getState(door) {
    return door ? door.state : 'Open';
  }

  isMoving(door) {
    return !!door && (door.motion !== null || door.held);
  }

  /** DoorService.SetState. `seconds` = motion time (default per kind; 0 snaps). */
  setState(door, state, seconds) {
    if (!door) return false;
    const [plan, target] = planFor(door.state, state);
    if (plan === 'Refuse') return false;
    const previous = door.state;
    door.state = state;
    this.env.setEntityAttribute(door.id, 'DoorState', state);
    const duration = Number.isFinite(seconds) ? Math.max(0, seconds) : undefined;
    if (plan === 'Swing') this._swing(door, target, duration);
    else if (plan === 'Smash') this._smash(door, duration);
    this.stateChanged.fire(door, previous, state);
    return true;
  }

  /** The gameplay path (prompts, mechanics): refused while Locked or Smashed. */
  requestOpen(door, seconds) {
    if (!door || door.state === 'Locked' || door.state === 'Smashed') return false;
    return this.setState(door, 'Open', seconds);
  }

  _defaultSeconds(kind, from, to) {
    const travel = TRAVEL[kind] || { open: 1.2, close: 1.2 };
    const full = to > from ? travel.open : travel.close;
    return Math.max(MIN_SECONDS, full * Math.abs(to - from));
  }

  _cancel(door) {
    door.motion = null;
    door.held = false;
    door.clearSince = null;
    this._stopLanding(door);
  }

  _stopLanding(door) {
    if (door.landing) door.landing = null;
    door.landingAt = null;
  }

  _swing(door, target, seconds) {
    this._cancel(door);
    const now = this.env.now();
    const from = door.openness;
    const duration = seconds ?? this._defaultSeconds(door.kind, from, target);
    door.target = target;
    if (duration <= 0 || Math.abs(target - from) <= EPS) {
      this._pose(door, 'Swing', target);
      return;
    }
    door.speed = Math.abs(target - from) / duration;
    const closing = target < from;
    this._begin(door, {
      mode: 'Swing', from, to: target, startAt: now + LEAD, seconds: duration,
      ease: door.kind === 'Gate' && closing ? 'In' : 'InOut',
    }, false);
  }

  _smash(door, seconds) {
    this._cancel(door);
    door.smashFrom = door.openness;
    const duration = seconds ?? SMASH_SECONDS;
    if (duration <= 0) {
      this._pose(door, 'Smash', 1);
      return;
    }
    this._begin(door, { mode: 'Smash', from: 0, to: 1, startAt: this.env.now() + LEAD, seconds: duration, ease: 'Linear' }, false);
  }

  _begin(door, motion, resumed) {
    door.motion = motion;
    door.held = false;
    door.clearSince = null;
    this._cues(door, motion, resumed);
  }

  _cues(door, motion, resumed) {
    const at = door.centre;
    if (motion.mode === 'Smash') {
      this.game.playAt('DoorSmash', at);
      if (motion.seconds > 0) {
        door.landing = { preset: null, volume: 0, impact: 'Smash' };
        door.landingAt = motion.startAt + SMASH_IMPACT_DELAY;
      }
      return;
    }
    const closing = motion.to < motion.from;
    const shuts = closing && motion.to <= EPS;
    if (door.kind === 'Gate') {
      if (shuts) {
        door.landing = { preset: 'GateSlam', volume: 1, impact: 'Slam' };
        door.landingAt = motion.startAt + motion.seconds;
      } else if (!closing && !resumed) this.game.playAt('MetalCreak', at);
      return;
    }
    const fire = door.kind === 'Airlock';
    this.game.playAt(fire ? 'FireDoorSwing' : 'DoorCreak', at);
    if (shuts) {
      door.landing = { preset: 'FireDoorLatch', volume: fire ? 1 : LIGHT_LATCH_VOLUME, impact: fire ? 'Latch' : null };
      door.landingAt = motion.startAt + motion.seconds;
    }
  }

  _land(door, motion) {
    door.motion = null;
    if (motion.mode === 'Swing' && motion.to <= EPS && motion.from > EPS && (door.kind === 'Gate' || door.kind === 'Airlock')) {
      this.game.noise(door.centre, 'DoorSlam');
    }
  }

  // ---------------------------------------------------------------------------------------------------- never crushing

  _bodyBox(outC, outS) {
    const root = this.env.rootPosition(_root);
    const feet = -(HIP_HEIGHT + ROOT_HALF);
    const top = ROOT_HALF + BODY_HEAD_ROOM;
    const yaw = this.env.look().yaw;
    _e.set(0, yaw, 0);
    outC.makeRotationFromEuler(_e);
    outC.setPosition(root.x, root.y + (feet + top) * 0.5, root.z);
    outS.set(BODY_WIDTH, top - feet, BODY_DEPTH);
  }

  _obstructed(door, from, to) {
    if (!this.game.playing()) return false;
    this._bodyBox(_bodyC, _bodyS);
    const samples = Math.max(SWEEP_SAMPLES, Math.ceil(Math.abs(to - from) / SAMPLE_STEP));
    for (let i = 0; i <= samples; i++) {
      const value = from + ((to - from) * i) / samples;
      for (const leaf of door.leaves) {
        if (!leaf.bounds) continue;
        const w = this.leafWorld(door, leaf, 'Swing', value, 0, _leafW);
        if (!w) continue;
        _boxC.multiplyMatrices(w, leaf.bounds.centre);
        _boxS.copy(leaf.bounds.size).addScalar(2 * BLOCK_MARGIN);
        if (boxesOverlap(_boxC, _boxS, _bodyC, _bodyS)) return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------------------------------- run

  beginRun() {
    for (const door of this.byId.values()) {
      this._cancel(door);
      door.state = INITIAL[door.kind] || 'Open';
      door.smash = 0;
      door.smashFrom = 0;
      door.stragglerDeadline = null;
      door.openness = door.builtOpenness;
      if (door.state !== 'Open' && door.openness > EPS) this._pose(door, 'Swing', 0);
      else this._pose(door, 'Swing', door.openness);
      door.target = door.openness;
      this.env.setEntityAttribute(door.id, 'DoorState', door.state);
    }
  }

  endRun() {
    for (const door of this.byId.values()) {
      this._cancel(door);
      door.state = INITIAL[door.kind] || 'Open';
      door.smash = 0;
      door.smashFrom = 0;
      door.stragglerDeadline = null;
      door.openness = door.builtOpenness;
      this._pose(door, 'Swing', door.openness);
    }
  }

  tick(dt, now) {
    for (const door of this.byId.values()) {
      if (door.landing && door.landingAt !== null && now >= door.landingAt) {
        const landing = door.landing;
        if (landing.preset) this.game.playAt(landing.preset, door.centre, { volume: landing.volume });
        if (landing.impact) {
          const [amplitude, seconds] = impactShake(landing.impact, this.env.eye(_eye).distanceTo(door.centre));
          if (amplitude > 0) this.env.shake(amplitude * (this.env.setting('MotionScale') ?? 1), seconds);
        }
        this._stopLanding(door);
      }
      if (door.held) {
        if (now < door.recheckAt) continue;
        door.recheckAt = now + HELD_RECHECK;
        if (this._obstructed(door, door.openness, door.target)) {
          door.clearSince = null;
          continue;
        }
        if (door.clearSince === null) door.clearSince = now;
        else if (now - door.clearSince >= CLEAR_SECONDS) {
          const from = door.openness;
          const duration = Math.max(MIN_SECONDS, Math.abs(door.target - from) / Math.max(door.speed, EPS));
          const closing = door.target < from;
          if (closing && door.target <= EPS) {
            door.landing = { preset: door.kind === 'Gate' ? 'GateSlam' : 'FireDoorLatch',
              volume: door.kind === 'Airlock' || door.kind === 'Gate' ? 1 : LIGHT_LATCH_VOLUME,
              impact: door.kind === 'Gate' ? 'Slam' : door.kind === 'Airlock' ? 'Latch' : null };
            door.landingAt = now + LEAD + duration;
          }
          this._begin(door, { mode: 'Swing', from, to: door.target, startAt: now + LEAD, seconds: duration,
            ease: door.kind === 'Gate' && closing ? 'In' : 'InOut' }, true);
        }
        continue;
      }
      const m = door.motion;
      if (!m || now < m.startAt) continue;
      if (m.mode === 'Swing') {
        const horizon = Math.min(now + LOOKAHEAD, m.startAt + m.seconds);
        const [ahead] = valueAt(m, horizon);
        if (this._obstructed(door, door.openness, ahead)) {
          door.motion = null;
          door.held = true;
          door.clearSince = null;
          door.recheckAt = now + HELD_RECHECK;
          this._stopLanding(door);
          continue;
        }
      }
      const [value, done] = valueAt(m, now);
      this._pose(door, m.mode, value);
      if (done) this._land(door, m);
    }
  }

  frame(dt, now) {
    // render the motions between ticks so the leaves move smoothly at any frame rate
    for (const door of this.byId.values()) {
      const m = door.motion;
      if (!m || now < m.startAt) continue;
      const [value] = valueAt(m, now);
      for (const leaf of door.leaves) {
        const w = this.leafWorld(door, leaf, m.mode, value, door.smashFrom, _pose);
        if (w) this.env.setNodePivot(door.id, leaf.name, w);
      }
    }
  }
}

/** Lerp from identity toward a transform (CFrame.new():Lerp(t, share)). */
function lerpTransform(t, share, out) {
  t.decompose(_v, _q, _s);
  _v.multiplyScalar(share);
  _q2.identity().slerp(_q, share);
  return out.compose(_v, _q2, _one);
}

/** Separating-axis test of two oriented boxes (centre frames + full sizes). */
export function boxesOverlap(a, aSize, b, bSize) {
  const ax = [_ax0.setFromMatrixColumn(a, 0).normalize(), _ax1.setFromMatrixColumn(a, 1).normalize(), _ax2.setFromMatrixColumn(a, 2).normalize()];
  const bx = [_bx0.setFromMatrixColumn(b, 0).normalize(), _bx1.setFromMatrixColumn(b, 1).normalize(), _bx2.setFromMatrixColumn(b, 2).normalize()];
  const ha = [aSize.x / 2, aSize.y / 2, aSize.z / 2];
  const hb = [bSize.x / 2, bSize.y / 2, bSize.z / 2];
  const offset = _off.setFromMatrixPosition(b).sub(_tmp.setFromMatrixPosition(a));
  const axes = [...ax, ...bx];
  for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) axes.push(new THREE.Vector3().crossVectors(ax[i], bx[j]));
  for (const axis of axes) {
    const len = axis.length();
    if (len < 1e-6) continue;
    axis.divideScalar(len);
    const ra = ha[0] * Math.abs(ax[0].dot(axis)) + ha[1] * Math.abs(ax[1].dot(axis)) + ha[2] * Math.abs(ax[2].dot(axis));
    const rb = hb[0] * Math.abs(bx[0].dot(axis)) + hb[1] * Math.abs(bx[1].dot(axis)) + hb[2] * Math.abs(bx[2].dot(axis));
    if (Math.abs(offset.dot(axis)) > ra + rb) return false;
  }
  return true;
}

const _pose = new THREE.Matrix4();
const _leafW = new THREE.Matrix4();
const _boxC = new THREE.Matrix4();
const _boxS = new THREE.Vector3();
const _bodyC = new THREE.Matrix4();
const _bodyS = new THREE.Vector3();
const _root = new THREE.Vector3();
const _eye = new THREE.Vector3();
const _e = new THREE.Euler();
const _one = new THREE.Vector3(1, 1, 1);
const _ax0 = new THREE.Vector3();
const _ax1 = new THREE.Vector3();
const _ax2 = new THREE.Vector3();
const _bx0 = new THREE.Vector3();
const _bx1 = new THREE.Vector3();
const _bx2 = new THREE.Vector3();
const _off = new THREE.Vector3();
const _tmp = new THREE.Vector3();

