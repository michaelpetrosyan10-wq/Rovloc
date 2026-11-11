// creatureApi.js: the ONE adapter between the game and the Creature (src/creature, agent W3). Its API mirrors
// MonsterAIService:
//
//   getState() -> MonsterState            getTarget() -> truthy while it hunts the player
//   stun(seconds, from)                   alert(position, priority)
//   acquireScripted(token) -> handle {moveTo(position, speed?), teleport(cframe), setPose(poseMode), setHidden(bool),
//                                     face(position), release(nextState?), setTarget(target)} | null
//   registerLockerInspector(fn)           fn(lockerId) -> Promise<'Empty' | 'HiddenSafe' | 'Caught'>
//   setSpeedScale(scale)
//   events stateChanged(state, prev), caught(kind), jumpscareFinished(kind, outcome)
//   feed: one stream of everything it does that the game may answer ({kind, at}: State, LookAway, ReachIn, Sniff,
//     TeleportWarning, Stun), for any system to subscribe to
//   ignore(who, seconds) (a respawn's grace), relocateFrom(entry, opts) (a respawn's clearance)
//   activateLevel(levelId) / deactivate()
//
// plus what the level scenes and mechanics read from it, called when the module offers them:
//   getPosition() -> Vector3 (root) / getEye() -> Vector3, isHidden(), getPoseMode(), getVentNode() -> node id | null,
//   playAction(name) (the scene timelines' "creature" track: NeckSnap, DoorSmash, Reveal, Vanish),
//   setDifficulty(name), setCatchHooks({canCatch(kind), outcome(kind) -> 'Down'|'Execute', apply(outcome)}).
// The Tall Man's (Tunnels): events teleportWarning(spot, targetsMe, seconds), revealed(kind), stared(), gaveUp(position,
//   wasMe), grunted(position); reveal(kind) (the reveal scare on this page), notePulled(player), viewState().
//
// createCreatureApi(engine) builds W3's Creature (src/creature/index.js createCreature) on the engine; start() can
// be handed another one (or null) instead. Without one every call is a dormant Creature's answer: acquireScripted
// returns null, so the scenes play their Creature-less versions exactly as the Roblox controllers do when
// AcquireScripted refuses.
//
// The game's side, told to the Creature: beginRun(difficulty) at each run start, bindGame(hooks) with the player's
// life state, duct crawl, grates, fixture doors, locker and level (W3's GameHooks), setCatchHooks for the catches.

import * as THREE from 'three';
import { CreatureConfig, ROOT_HEIGHT } from '../creature/config.js';
import { createCreature } from '../creature/index.js';
import { Signal } from './util.js';

/**
 * The rig measures the level scenes stage with (CreatureConfig): root height over the floor, eye over the root, and
 * the states' base paces (the roof's chase pacing scales WallChase).
 */
export const CreatureMetrics = Object.freeze({
  rootHeight: ROOT_HEIGHT,
  eye: CreatureConfig.EyeHeightAboveRoot,
  speeds: CreatureConfig.Speeds,
});

/**
 * W3's Creature on `engine`, behind the adapter (a dormant stand-in when it cannot be built).
 * @param {any} engine
 * @param {any} [creature] a Creature to use instead (null: none)
 */
export function createCreatureApi(engine, creature) {
  if (creature !== undefined) return new CreatureApi(creature);
  if (engine.creature) return new CreatureApi(engine.creature);
  try {
    return new CreatureApi(createCreature(engine));
  } catch (err) {
    console.error('[game] the Creature could not be built; the run plays without it', err);
    return new CreatureApi(null);
  }
}

/** @typedef {'Empty'|'HiddenSafe'|'Caught'} LockerVerdict */

/**
 * @typedef {Object} ScriptedHandle
 * @property {(position: THREE.Vector3, speed?: number) => void} moveTo
 * @property {(cframe: THREE.Matrix4|number[]) => void} teleport
 * @property {(poseMode: 'Biped'|'Hunched'|'Quadruped') => void} setPose
 * @property {(hidden: boolean) => void} setHidden
 * @property {(position: THREE.Vector3) => void} face
 * @property {(nextState?: string) => void} release
 * @property {(target: true|object|null) => void} setTarget its stare: true this page's player, a co-op roster handle
 *   (coop/creature.js handleOf) a teammate, null nobody
 * @property {(name: string) => void} action
 */

export class CreatureApi {
  /** @param {any} creature W3's Creature (or null) */
  constructor(creature) {
    this.c = creature || null;
    this._box = new THREE.Matrix4();
    this._boxInv = new THREE.Matrix4();
    /** @type {Signal<[string, string]>} */
    this.stateChanged = new Signal();
    /** @type {Signal<[string]>} */
    this.caught = new Signal();
    /** @type {Signal<[string, string]>} */
    this.jumpscareFinished = new Signal();
    /** @type {Signal<[THREE.Vector3, boolean, number]>} a teleport's warning: (spot, aimed at this page's player, seconds) */
    this.teleportWarning = new Signal();
    /** @type {Signal<[string]>} this page's player got a reveal scare (kind) */
    this.revealed = new Signal();
    /** @type {Signal<[]>} this page's player's held stare started a chase */
    this.stared = new Signal();
    /** @type {Signal<[THREE.Vector3, boolean]>} a chase gave up and it faded away: (where, it chased this page's player) */
    this.gaveUp = new Signal();
    /** @type {Signal<[THREE.Vector3]>} the grunt before a LookAway */
    this.grunted = new Signal();
    /**
     * The event feed: everything the Creature does that the game may answer, as one stream of {kind, at: game time,
     * ...}: State {state, previous}, LookAway {position} (the grunt), ReachIn {player, spot, due} (when its catch
     * lands), Sniff {spot} (a breath check begins), TeleportWarning {spot, targetsMe, seconds}, Stun {seconds, from}.
     * @type {Signal<[{kind: string, at: number}]>}
     */
    this.feed = new Signal();
    if (this.c) {
      this._bridge('stateChanged', this.stateChanged);
      this._bridge('caught', this.caught);
      this._bridge('jumpscareFinished', this.jumpscareFinished);
      for (const name of ['teleportWarning', 'revealed', 'stared', 'gaveUp', 'grunted']) this._bridge(name, this[name]);
      const feed = new Signal();
      this._bridge('feed', feed);
      feed.connect((e) => this._feed(e.kind, e.kind === 'ReachIn' ? { player: e.player, spot: e.spot, due: e.at }
        : e.kind === 'Sniff' ? { spot: e.spot } : { seconds: e.seconds, from: e.from }));
    }
    this.stateChanged.connect((state, previous) => this._feed('State', { state, previous }));
    this.grunted.connect((position) => this._feed('LookAway', { position }));
    this.teleportWarning.connect((spot, targetsMe, seconds) => this._feed('TeleportWarning', { spot, targetsMe, seconds }));
  }

  _feed(kind, fields) {
    const clock = this.c && typeof this.c.service === 'object' && this.c.service ? this.c.service.now() : 0;
    this.feed.fire({ kind, at: clock, ...fields });
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

  /** MonsterAIService's read-only view ({running, state, pose, inVent, segment, hidden, levelId, position, eye}). */
  snapshot() {
    return this._call('snapshot') || null;
  }

  /**
   * The CreatureHitbox (CreatureRigBuilder.setHitbox: the pose's box on the root, floor poses standing on the floor,
   * the crouched ones pushed forward), or null when hidden or absent. The pose is the one it stands in
   * (the view contract's poseMode): Hunched under a low lintel or tunnel, where the 11-stud Biped box would reach
   * into the ceiling.
   * @returns {{matrix: THREE.Matrix4, inv: THREE.Matrix4, size: number[]}|null}
   */
  hitbox() {
    const c = this.c;
    const body = c && c.service ? c.service.body : null;
    if (!body || body.hidden || !c.service.running) return null;
    const contract = typeof c.service.viewState === 'function' ? c.service.viewState().poseMode : null;
    const pose = contract === 'Hunched' ? contract : body.pose || 'Biped';
    const size = CreatureConfig.Hitbox[pose] || CreatureConfig.Hitbox.Biped;
    const layout = HITBOX_LAYOUTS[pose] || HITBOX_LAYOUTS.Biped;
    const y = layout.floor ? size[1] / 2 - ROOT_HEIGHT : 0;
    const matrix = body.getCFrame().toMatrix4(this._box).multiply(_offset.makeTranslation(0, y, -layout.forward));
    return { matrix, inv: this._boxInv.copy(matrix).invert(), size };
  }

  /** Whether it is chasing the player right now (WallChase with us as its target). */
  chasingPlayer() {
    return this.getState() === 'WallChase' && this.hasTarget();
  }

  /** The view contract ({state, speed, poseMode, action, actionStartedAt, fade}), or null. */
  viewState() {
    return this._call('viewState') || null;
  }

  /** The reveal scare on this page (a teleport's, a fake-out's). */
  reveal(kind) {
    this._call('reveal', kind);
  }

  /** A teammate pulled `player` out of a hiding spot (no catch for it). */
  notePulled(player) {
    this._call('notePulled', player);
  }

  /**
   * A respawn's grace: `who` (true: this page's player; a co-op roster handle, coop/creature.js handleOf) is not seen,
   * heard or caught for `seconds`.
   */
  ignore(who, seconds) {
    this._call('ignore', who, seconds);
  }

  /**
   * A respawn at `entry` (a floor point): within `walked` studs walked of it, the Creature is moved unwarned and unseen
   * to the nearest land spot at least `walked` walked from it and `clear` from every player; its next teleport at
   * least `teleportDelay` off. {moved, walk, to} (moved false without a Creature).
   * @param {THREE.Vector3} entry
   * @param {{walked: number, clear: number, teleportDelay: number}} opts
   */
  relocateFrom(entry, opts) {
    return this._call('relocateFrom', entry, opts) || { moved: false, walk: null, to: null };
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

  activateLevel(levelId) {
    this._call('activateLevel', levelId);
  }

  deactivate() {
    this._call('deactivate');
  }

  setDifficulty(name) {
    this._call('setDifficulty', name);
  }

  /** BeginRun: the Creature is placed Dormant for a run on `difficulty`. */
  beginRun(difficulty) {
    this._call('setDifficulty', difficulty);
    this._call('beginRun', { difficulty });
  }

  /**
   * The game state the Creature reads (W3's GameHooks: lifeState, downedCount, isInVent, grateState, forceGrate,
   * doorOpen, lockerOccupied, playerLevel).
   * @param {Record<string, Function>} hooks
   */
  bindGame(hooks) {
    this._call('bindGame', hooks);
  }

  /** Dev: a MonsterAIService dev command ("ai patrol", "hunt", "ignoreme"). */
  devCommand(command) {
    return this._call('devCommand', command);
  }

  /** The game's side of a catch (who may be caught, what the outcome is, applying it). */
  setCatchHooks(hooks) {
    this._call('setCatchHooks', hooks);
  }

  /** @param {(lockerId: string) => Promise<LockerVerdict>} fn */
  registerLockerInspector(fn) {
    this._call('registerLockerInspector', fn);
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
      setTarget: (target) => call('setTarget', target === true ? true : target || null),
      action: (name) => {
        if (typeof raw.playAction === 'function') call('playAction', name);
        else this._call('playAction', name);
      },
    };
  }
}

const EYE_LIFT = new THREE.Vector3(0, 3.2, 0);
const HITBOX_LAYOUTS = {
  Biped: { floor: true, forward: 0.35 },
  Hunched: { floor: true, forward: 1.3 },
  Quadruped: { floor: false, forward: 0.9 },
};
const _offset = new THREE.Matrix4();
