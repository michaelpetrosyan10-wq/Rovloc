// game.js: the game's root (the web counterpart of ServerMain + ClientMain for one player): it owns the systems,
// the match phases (RunLifecycleService), the run's stage and level (LevelDirector over StageConfig: stages.js), the
// run stats (RunStatsService), the scene sequencer (SequenceController) and the control locks (CharacterService.Lock
// reasons), and drives every system at the engine's fixed 30 Hz tick and once per rendered frame.
//
// The run is the stage list: game.stage is the stage being played (a stage id); game.level is the level of the school
// it plays on (the same id) for a stage the school's scripts play, null for one the StandIn plays. advance() leaves
// the stage (cleared) for the next one; after the last the run ends (Match.finishRun).
//
// Systems implement any of: beginRun(run) (forward order), endRun() (reverse order), tick(dt, now), frame(dt, now),
// stageActivated(stage), stageDeactivated(stage), levelActivated(level), levelDeactivated(level),
// phaseChanged(phase, previous).

import * as THREE from 'three';
import { StatKeys } from './config.js';
import { Stages } from './stages.js';
import { S } from './strings/index.js';
import { Sequencer } from './timeline.js';
import { Signal } from './util.js';

/**
 * @typedef {'Title'|'Lobby'|'Countdown'|'Deploying'|'InRun'|'RunEnded'|'Results'|'Resetting'} Phase
 * @typedef {{runId: string, difficulty: string, plan: import('./worldData.js').Plan, routes: Record<string, import('./worldData.js').Route>,
 *   perks: string[], startedAt: number, seed: number, devRun: boolean, slot: number, players: number,
 *   clockFrom: number|null, clockTo: number|null}} Run
 */

export class RunStats {
  constructor() {
    /** @type {Record<string, number>} */
    this.values = {};
    this.reset();
  }

  reset() {
    for (const k of StatKeys) this.values[k] = 0;
  }

  increment(key, amount = 1) {
    this.values[key] = (this.values[key] || 0) + amount;
  }

  get(key) {
    return this.values[key] || 0;
  }
}

export class Game {
  /**
   * @param {import('./env.js').Env} env
   * @param {import('./creatureApi.js').CreatureApi} creature
   * @param {import('./worldData.js').WorldData} world
   * @param {import('./profile.js').Profile} profile
   * @param {import('./ui/nav.js').Nav} nav
   */
  constructor(env, creature, world, profile, nav) {
    this.env = env;
    this.creature = creature;
    this.world = world;
    this.profile = profile;
    this.nav = nav;
    this.seq = new Sequencer();
    this.stats = new RunStats();
    /** @type {Phase} */
    this.phase = 'Title';
    /** @type {Run|null} */
    this.run = null;
    /** the run's stages (meta.stageConfig) and the script of each */
    this.stages = new Stages(world.meta);
    /** @type {string|null} the run's current stage (a stage id) */
    this.stage = null;
    this.stageActive = false;
    /** @type {string|null} the run's current level (LevelDirector): the stage when the school plays it, else null */
    this.level = null;
    this.levelActive = false;
    /** @type {Set<string>} stages marked Cleared this run */
    this.cleared = new Set();
    /** @type {Array<any>} */
    this.systems = [];
    /** @type {Map<string, true>} ControlLock reasons held */
    this.locks = new Map();
    /** @type {Signal<[Phase, Phase]>} */
    this.phaseChanged = new Signal();
    /** @type {Signal<[string]>} */
    this.stageActivated = new Signal();
    /** @type {Signal<[string]>} */
    this.levelActivated = new Signal();
    /** @type {Signal<[string]>} */
    this.levelDeactivated = new Signal();
    /** @type {import('./creatureApi.js').ScriptedHandle|null} the scripted Creature a level scene holds */
    this.creatureHandle = null;
    /** @type {import('./coop/index.js').Coop|null} the co-op room (start.js); inactive when played alone */
    this.coop = null;
    /** the system whose tick / handler is running (co-op mirrors the host's level scenes by it) */
    this.current = null;
  }

  /** Registers a system (in dependency order). */
  add(system) {
    this.systems.push(system);
    return system;
  }

  // ---------------------------------------------------------------------------------------------------- phases

  /** RunLifecycleService.SetPhase (the only writer of the phase). */
  setPhase(phase) {
    if (phase === this.phase) return;
    const previous = this.phase;
    this.phase = phase;
    for (const s of this.systems) if (s.phaseChanged) safe(() => s.phaseChanged(phase, previous), s);
    this.phaseChanged.fire(phase, previous);
  }

  /** Deploying / InRun: the run is live (damage, traps, airlocks act). */
  live() {
    return this.phase === 'Deploying' || this.phase === 'InRun';
  }

  /** BeginRun on every system in order (RunLifecycleService.BeginRun). */
  beginRun(run) {
    this.run = run;
    this.stats.reset();
    this.cleared.clear();
    this.locks.clear();
    for (const s of this.systems) if (s.beginRun) safe(() => s.beginRun(run), s);
  }

  /** EndRun on every system in reverse order. */
  endRun() {
    this.deactivateStage();
    this.stage = null;
    this.level = null;
    this.env.setCurrentLevel(null);
    for (let i = this.systems.length - 1; i >= 0; i--) {
      const s = this.systems[i];
      if (s.endRun) safe(() => s.endRun(), s);
    }
    this.seq.stopAll();
    for (const reason of [...this.locks.keys()]) this.unlock(reason);
    this.run = null;
  }

  // ---------------------------------------------------------------------------------------------------- stages

  /**
   * LevelDirector.EnterLevel over the stage list: switches to stage `stage` at once (its level when the school plays
   * it) and activates it when the run is InRun. `spawn`: the player is put at their slot's spawn at its entry (entering
   * the school from a stand-in or at the deploy; an airlock's stairs bring them there themselves).
   * @param {string} stage
   * @param {{spawn?: boolean}} [opts]
   */
  enterStage(stage, opts = {}) {
    this.deactivateStage();
    this.stage = stage;
    this.level = this.stages.isLevel(stage) ? stage : null;
    this.env.setCurrentLevel(this.level);
    if (this.level && opts.spawn) this.match.spawnAt(this.level, this.match.slot());
    if (this.phase === 'InRun') this.activateStage();
  }

  /** The stage's activation (every system's stageActivated), then its level's. */
  activateStage() {
    if (this.stageActive || !this.stage) return;
    this.stageActive = true;
    const stage = this.stage;
    for (const s of this.systems) if (s.stageActivated && !this._follows(s)) safe(() => s.stageActivated(stage), s, this);
    this.stageActivated.fire(stage);
    if (this.level) this.activateLevel();
  }

  deactivateStage() {
    this.deactivateLevel();
    if (!this.stageActive || !this.stage) {
      this.stageActive = false;
      return;
    }
    const stage = this.stage;
    this.stageActive = false;
    for (const s of this.systems) if (s.stageDeactivated && !this._follows(s)) safe(() => s.stageDeactivated(stage), s, this);
  }

  /** LevelDirector.MarkCleared + Advance: the stage is cleared and the next one entered; after the last the run ends. */
  advance() {
    if (!this.stage || !this.run) return null;
    const from = this.stage;
    this.cleared.add(from);
    this.match.stageCleared(from);
    const next = this.stages.next(from);
    if (next) this.enterStage(next, { spawn: !this.stages.isLevel(from) });
    else {
      this.deactivateStage();
      this.match.finishRun();
    }
    return next;
  }

  activateLevel() {
    if (this.levelActive || !this.level) return;
    this.levelActive = true;
    const level = this.level;
    for (const s of this.systems) if (s.levelActivated && !this._follows(s)) safe(() => s.levelActivated(level), s, this);
    this.levelActivated.fire(level);
  }

  deactivateLevel() {
    if (!this.levelActive || !this.level) {
      this.levelActive = false;
      return;
    }
    const level = this.level;
    this.levelActive = false;
    for (const s of this.systems) if (s.levelDeactivated && !this._follows(s)) safe(() => s.levelDeactivated(level), s, this);
    this.levelDeactivated.fire(level);
  }

  // ---------------------------------------------------------------------------------------------------- locks

  /** CharacterService.Lock: a ControlLock reason (Trap, Locker, Jumpscare, Cutscene, Respawn, Parachute, Airlock). */
  lock(reason) {
    this.locks.set(reason, true);
    this.env.lock(reason);
  }

  unlock(reason) {
    if (!this.locks.delete(reason)) return;
    this.env.unlock(reason);
  }

  /** The ControlLock the HUD reads ('None' when free); a jumpscare the Creature holds counts too. */
  controlLock() {
    if (this.env.hasLock('Jumpscare')) return 'Jumpscare';
    for (const r of ['Cutscene', 'Respawn', 'Locker', 'Trap', 'Parachute', 'Airlock']) if (this.locks.has(r)) return r;
    for (const r of this.locks.keys()) return r;
    return 'None';
  }

  // ---------------------------------------------------------------------------------------------------- helpers

  /** Notify: a toast with a Strings line. */
  notify(key, ...args) {
    this.env.toast(S(key, ...args));
  }

  /** A 3D cue (AudioService.PlayAt). */
  playAt(preset, position, opts = {}) {
    return this.env.play(preset, { ...opts, position: position.clone ? position.clone() : new THREE.Vector3(...position) });
  }

  /** NoiseAndDirectorService.Emit on the run's level. */
  noise(position, kind, opts = {}) {
    if (!this.live()) return null;
    return this.env.emitNoise(position, kind, { level: this.level || undefined, source: 'player', ...opts });
  }

  /**
   * The player's eye as the levels see it (LevelKit.eyeOf): the root plus the MoveState's eye height. Tick state, the
   * same at any frame rate and the same rule the host applies to a teammate's pose; never the camera (env.eye() is the
   * drawn eye: it follows the body interpolated between ticks, and is for the view, the hands and the throw).
   */
  eye(out = new THREE.Vector3()) {
    const env = this.env;
    env.rootPosition(out);
    out.y += env.eyeHeight(env.moveState());
    return out;
  }

  /** The route `level` is left by this run (worldData Route: exit vestibule, doors, checkpoint, lock), or null. */
  route(level) {
    return this.world.route(level, this.run ? this.run.routes : null);
  }

  /** The zone (room or duct chase) the player's root stands in (ZoneService ZoneId), or null. */
  zoneId() {
    const z = this.env.zoneAt(this.env.rootPosition(_root));
    return z ? z.id : null;
  }

  /** The floor under the player (LevelKit.feetOf). */
  feet(out = new THREE.Vector3()) {
    return this.env.feetPosition(out);
  }

  /** LevelKit.seenBy for the one player: within `range` of the eye with a clear line. */
  seen(point, range = 250) {
    if (!this.playing()) return false;
    const eye = this.eye(_eye);
    if (eye.distanceTo(point) > range) return false;
    return this.env.lineClear(eye, point, { ignoreEntities: false });
  }

  /** Alive or Downed in a live run. */
  playing() {
    const s = this.life ? this.life.state : 'Lobby';
    return this.live() && (s === 'Alive' || s === 'Downed');
  }

  /** Alive in a live run (co-op: the player whose action is being applied, coop.actor). */
  alive() {
    if (this.coop && this.coop.actor) return this.live() && this.coop.actorLife() === 'Alive';
    return this.live() && this.life && this.life.state === 'Alive';
  }

  /** Whether the action being applied is this page's own player's (co-op replays a teammate's on every page). */
  actorIsLocal() {
    return !this.coop || this.coop.actorIsLocal();
  }

  /**
   * The players a level's scene can happen to: [{id, local, eye, root, zone, inVent, life}] for everyone in play (co-op,
   * on the host: the whole squad; alone: the player, while playing).
   */
  subjects() {
    if (this.coop) return this.coop.runNet.subjects();
    if (!this.playing()) return [];
    return [{ id: null, local: true, eye: this.eye(new THREE.Vector3()), root: this.env.rootPosition(new THREE.Vector3()),
      zone: this.zoneId(), inVent: !!(this.vents && this.vents.inVent()), life: this.life.state }];
  }

  /** Could anyone in play see `point` (co-op: every player, on the host; alone: seen())? */
  seenByAnyone(point, range = 250) {
    if (this.coop && this.coop.active) return this.coop.runNet.seenByAnyone(point, range);
    return this.seen(point, range);
  }

  // ---------------------------------------------------------------------------------------------------- drive

  tick(dt) {
    const now = this.env.now();
    for (const s of this.systems) if (s.tick && !this._follows(s)) safe(() => s.tick(dt, now), s, this);
    this.seq.update(now);
  }

  frame(dt) {
    const now = this.env.now();
    this.nav.update(dt);
    for (const s of this.systems) if (s.frame) safe(() => s.frame(dt, now), s, this);
  }

  /** Co-op: on a client a host-run system (the level scenes) does not decide anything itself; the host's results come. */
  _follows(system) {
    return !!system.hostOnly && !!this.coop && this.coop.isClient();
  }
}

const _eye = new THREE.Vector3();
const _root = new THREE.Vector3();

function safe(fn, system, game) {
  const before = game ? game.current : null;
  if (game) game.current = system;
  try {
    fn();
  } catch (err) {
    console.error(`[game] ${system && system.name ? system.name : 'system'} failed`, err);
  } finally {
    if (game) game.current = before;
  }
}
