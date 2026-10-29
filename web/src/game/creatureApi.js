// creatureApi.js: the ONE adapter between the game and the Creature (src/creature, agent W3). Its API mirrors
// MonsterAIService:
//
//   getState() -> MonsterState            getTarget() -> truthy while it hunts the player
//   stun(seconds, from)                   alert(position, priority)
//   acquireScripted(token) -> handle {moveTo(position, speed?), teleport(cframe), setPose(poseMode), setHidden(bool),
//                                     face(position), release(nextState?), setTarget(on)} | null
//   registerLockerInspector(fn)           fn(lockerId) -> Promise<'Empty' | 'HiddenSafe' | 'Caught'>
//   registerPoolGrabber(fn)               fn() -> boolean (true when the grab started)
//   setSpeedScale(scale)                  catchGrabbed() -> boolean
//   events stateChanged(state, prev), caught(kind), jumpscareFinished(kind, outcome)
//   activateLevel(levelId) / deactivate()
//
// plus what the level scenes and mechanics read from it, called when the module offers them:
//   getPosition() -> Vector3 (root) / getEye() -> Vector3, isHidden(), getPoseMode(), getVentNode() -> node id | null,
//   playAction(name) (the scene timelines' "creature" track: NeckSnap, DoorSmash, Reveal, Vanish),
//   setDifficulty(name, spec), setCatchHooks({canCatch(kind), outcome(kind) -> 'Down'|'Execute', apply(outcome)}).
//
// The Creature arrives as engine.creature (or the `creature` option of start()). Without one (a build without W3's
// module) every call is a dormant Creature's answer: acquireScripted returns null, so the scenes play their
// Creature-less versions exactly as the Roblox controllers do when AcquireScripted refuses.

import * as THREE from 'three';
import { Signal } from './util.js';

/** @typedef {'Empty'|'HiddenSafe'|'Caught'} LockerVerdict */

/**
 * @typedef {Object} ScriptedHandle
 * @property {(position: THREE.Vector3, speed?: number) => void} moveTo
 * @property {(cframe: THREE.Matrix4|number[]) => void} teleport
 * @property {(poseMode: 'Biped'|'Hunched'|'Quadruped'|'Swim') => void} setPose
 * @property {(hidden: boolean) => void} setHidden
 * @property {(position: THREE.Vector3) => void} face
 * @property {(nextState?: string) => void} release
 * @property {(on: boolean) => void} setTarget
 * @property {(name: string) => void} action
 */

export class CreatureApi {
  /** @param {any} creature W3's Creature (or null) */
  constructor(creature) {
    this.c = creature || null;
    /** @type {Signal<[string, string]>} */
    this.stateChanged = new Signal();
    /** @type {Signal<[string]>} */
    this.caught = new Signal();
    /** @type {Signal<[string, string]>} */
    this.jumpscareFinished = new Signal();
    if (this.c) {
      this._bridge('stateChanged', this.stateChanged);
      this._bridge('caught', this.caught);
      this._bridge('jumpscareFinished', this.jumpscareFinished);
    }
  }

  /** Whether a Creature module is present. */
  available() {
    return !!this.c;
  }

  _bridge(name, signal) {
    const c = this.c;
    const source = c.events ? c.events[name] : c[name];
    const relay = (...args) => signal.fire(...args);
    if (source && typeof source.connect === 'function') source.connect(relay);
    else if (typeof c.on === 'function') c.on(name, relay);
  }

  _call(name, ...args) {
    const c = this.c;
    if (!c || typeof c[name] !== 'function') return undefined;
    try {
      return c[name](...args);
    } catch (err) {
      console.error('[game] creature', name, 'failed', err);
      return undefined;
    }
  }

  // ---------------------------------------------------------------------------------------------------- reads

  /** MonsterState ('Dormant' without a Creature). */
  getState() {
    return this._call('getState') || 'Dormant';
  }

  /** True while it hunts the player. */
  hasTarget() {
    return !!this._call('getTarget');
  }

  /** The root position (null without a Creature or when it reports none). */
  position(out = new THREE.Vector3()) {
    const p = this._call('getPosition');
    return p ? out.copy(p) : null;
  }

  /** The eye (LOS from / to it); falls back to the root raised to a standing head. */
  eye(out = new THREE.Vector3()) {
    const e = this._call('getEye');
    if (e) return out.copy(e);
    const p = this.position(out);
    return p ? p.add(EYE_LIFT) : null;
  }

  isHidden() {
    return !!this._call('isHidden');
  }

  /** The duct node it crawls at (VentGraph node id) or null on a floor. */
  ventNode() {
    return this._call('getVentNode') || null;
  }

  /** Whether it is chasing the player right now (WallChase / VentChase / AquaticStalk with us as its target). */
  chasingPlayer() {
    const s = this.getState();
    return (s === 'WallChase' || s === 'VentChase' || s === 'AquaticStalk') && this.hasTarget();
  }

  // ---------------------------------------------------------------------------------------------------- commands

  stun(seconds, from) {
    this._call('stun', seconds, from);
  }

  /** @param {'Low'|'Normal'|'High'|'Critical'} priority */
  alert(position, priority) {
    this._call('alert', position, priority);
  }

  setSpeedScale(scale) {
    this._call('setSpeedScale', scale);
  }

  catchGrabbed() {
    return !!this._call('catchGrabbed');
  }

  activateLevel(levelId) {
    this._call('activateLevel', levelId);
  }

  deactivate() {
    this._call('deactivate');
  }

  setDifficulty(name, spec) {
    this._call('setDifficulty', name, spec);
  }

  /** The game's side of a catch (who may be caught, what the outcome is, applying it). */
  setCatchHooks(hooks) {
    this._call('setCatchHooks', hooks);
  }

  /** @param {(lockerId: string) => Promise<LockerVerdict>} fn */
  registerLockerInspector(fn) {
    this._call('registerLockerInspector', fn);
  }

  /** @param {() => boolean} fn */
  registerPoolGrabber(fn) {
    this._call('registerPoolGrabber', fn);
  }

  /**
   * Exclusive control for a cutscene (null when there is no Creature or another script / a catch holds it).
   * @param {string} token
   * @returns {ScriptedHandle|null}
   */
  acquireScripted(token) {
    const raw = this._call('acquireScripted', token);
    if (!raw) return null;
    const call = (name, ...args) => {
      const fn = raw[name] || raw[name.charAt(0).toUpperCase() + name.slice(1)];
      if (typeof fn !== 'function') return undefined;
      try {
        return fn.apply(raw, args);
      } catch (err) {
        console.error('[game] scripted creature', name, 'failed', err);
        return undefined;
      }
    };
    return {
      moveTo: (position, speed) => call('moveTo', position, speed),
      teleport: (cframe) => call('teleport', cframe),
      setPose: (pose) => call('setPose', pose),
      setHidden: (hidden) => call('setHidden', hidden),
      face: (position) => call('face', position),
      release: (nextState) => call('release', nextState),
      setTarget: (on) => call('setTarget', on),
      action: (name) => {
        if (typeof raw.action === 'function') call('action', name);
        else this._call('playAction', name);
      },
    };
  }
}

const EYE_LIFT = new THREE.Vector3(0, 3.2, 0);
