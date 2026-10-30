// MonsterAIService (MonsterAIService/init.luau): the Creature's brain. The local player is PLAYER; in a co-op run the
// host's game adds the remote players through setRoster (handles with the same reads: root, eye, MoveState, life,
// duct crawl, torch, locker), so it sees, hears, chases and catches every one of them, choosing among them as the
// Roblox brain does among a server's players. A remote catch runs here; its victim's own page plays the moment.
//
// Brain, at GameConfig.ServerTickHz (10 Hz) during a run:
//   perceive  Perception.scan over the player (unless ignored), every noise pulse since the last tick through
//             Hearing.perceive (the Creature's level, its eye, its duct node, the level's VentGraph, the pacing's
//             HearingScale), plus scripted alerts. It remembers the target's last seen or heard position
//             (MemorySeconds), the rooms it heard noises in (Patrol sweeps toward them), a crawler that gave itself
//             away (seen climbing in within SpotWindow, heard making a High / Critical duct noise, spotted through a
//             grate) and a swimmer on the pool level.
//   pace      PacingDirector.tick (chasing, target in sight, nearest player).
//   decide    Brain.decide over a Summary (the transition table); entering a state runs the old state's exit and the
//             new one's enter; the current state updates once per tick.
//   act       the states drive Locomotion, stepped every motion tick (30 Hz) so kinematic motion is smooth.
// Catches go through the JumpscareHandler (Hallway on floors, Vent in ducts, Locker through the locker inspector,
// Underwater through catchGrabbed). While a catch runs the brain leaves the body alone; when it finishes the movement
// is re-synced, the pacing notes the catch (cooldown, Relax) and the Creature withdraws out of sight. A mover that
// stalls for good is put back on its level's patrol network at the nearest waypoint nobody can see, and only while
// nobody can see the Creature either: it never pops in or out in front of the player.
//
// The pool (Level 4 fairness, CreatureConfig.Water). Its swims are capped at the AquaticStalk pace but for a lunge, and
// every lunge is telegraphed (lungeTelegraph: the growl here, the pool's bubbles and ripple ring). In the water it
// takes a swimmer only with the pool grab (no Hallway catch on or from the water). It leaves the pool only through
// its vent route: into a pool grate, then (the ducts giving no way out onto land) on to a land spot nobody can see,
// backing off along the duct first while watched. PoolGraceSeconds after the player first stands in a pool room, and
// GrabRetreatSeconds after any grab (swimming to the far end of the water), it neither sees nor hears the player there.
//
// Levels. activateLevel (Level 1 or later): PacingDirector.noteAirlock (grace), the Creature is moved hidden to that
// level's CreatureSpawn if it is elsewhere, reappears once nobody can see it, and wakes into Patrol WakeDelay seconds
// later. A level controller that acquired it (acquireScripted) keeps it.

import * as THREE from 'three';
import * as Brain from './brain.js';
import { CFrame } from './cframe.js';
import { CreatureConfig, GameConfig, MonsterStates, NoisePriorities, ROOT_HEIGHT, WorldDefaults } from './config.js';
import { CreatureBody } from './body.js';
import * as Hearing from './hearing.js';
import { JumpscareHandler } from './jumpscare.js';
import { Mover } from './locomotion.js';
import { FloorNav } from './nav.js';
import { Pacing, repositionPoint } from './pacing.js';
import * as Perception from './perception.js';
import { Random, Signal, clamp, flatDirection, horizontalDistance, isFiniteNumber, isFiniteVector } from './util.js';
import { buildGraph, nearest as railNearest } from './ventgraph.js';
import { SWIM_DEPTH, clampToWater } from './water.js';
import * as AquaticStalk from './states/aquatic.js';
import * as Dormant from './states/dormant.js';
import * as InvestigateNoise from './states/investigate.js';
import * as Patrol from './states/patrol.js';
import * as Scripted from './states/scripted.js';
import * as Stunned from './states/stunned.js';
import * as VentChase from './states/ventchase.js';
import * as WallChase from './states/wallchase.js';

const STATES = { Dormant, Patrol, InvestigateNoise, WallChase, VentChase, Stunned, AquaticStalk, Scripted };

const TICK = 1 / GameConfig.ServerTickHz;
export const WAKE_DELAY = 4;
const REVEAL_RETRY = 25;
export const SPOT_WINDOW = 3;
const SEEN_ENTER_WINDOW = 1.5;
const VENT_BLOCK_SECONDS = 15;
const SWIMMER_MEMORY = 6;
const GRAB_ARMED_SECONDS = 10;
const GRAB_GRACE = 1;
const CATCH_TIMEOUT = GameConfig.OneShotLead + CreatureConfig.Jumpscare.LungeSeconds + CreatureConfig.Jumpscare.HoldSeconds + 4;
const HEARD_ZONE_TTL = Patrol.HeardTtl;
const NOISE_QUEUE_LIMIT = 64;
const SIGHT_RANGE_LIMIT = 250;
const UNSTICK_MIN = 6;
const POOL_EXIT_MIN = 30; // studs from the player at least, where it comes back onto land from the pool's vent route
const DUCT_SNAP = 1.5;
const EXACT_RANK = Hearing.priorityRank('High');
const DEV_FORCE_SECONDS = 30;
const DEV_HUNT_SECONDS = 45;
const TP_MIN = 18;
const TP_MAX = 60;
const SPOT_PRESET = 'Screech';
const SPOT_VOLUME = 0.75;
const STUN_PRESET = 'Screech';
const MIN_SPEED_SCALE = 0.5;
const MAX_SPEED_SCALE = 2;
const SWIM_STATES = new Set(['Treading', 'Freestyle', 'Underwater', 'Grabbed']);
const LEVEL_ORDER = ['Level0_Basement', 'Level1_Hallways', 'Level2_ScienceHall', 'Level3_Gymnasium', 'Level4_FloodedPool', 'Level5_Roof'];
const RANDOM_SEED = 20251029;

/** The local participant (Roblox's Player); a co-op host's remote players are RemotePlayer handles (setRoster). */
export const PLAYER = Object.freeze({ userId: 1, name: 'Player' });
const LOCAL_ONLY = Object.freeze([PLAYER]);
const NO_REMOTES = Object.freeze([]);

/**
 * A remote player as the co-op host's game presents one to the brain (userId 2 and up).
 * @typedef {Object} RemotePlayer
 * @property {number} userId
 * @property {string} name
 * @property {() => THREE.Vector3|null} root the root centre (null when not in play)
 * @property {() => CFrame|null} rootCFrame facing their look
 * @property {() => string} lifeState
 * @property {() => number} downedCount
 * @property {() => string} moveState
 * @property {() => string} mode 'OnFoot' | 'Vent' | 'Swim'
 * @property {() => boolean} inVent
 * @property {() => boolean} flashlightOn
 * @property {() => string|null} lockerId the locker they hide in
 * @property {(reason: string) => boolean} hasLock
 * @property {() => string} controlLock
 * @property {(kind: string) => boolean} canCatch
 * @property {(on: boolean) => void} setCaught a catch holds them (their page locks the body)
 * @property {(cframe: CFrame) => void} turn their root turned to face the Creature
 * @property {(cue: {kind: string, startAt: number, endsAt: number, face: THREE.Vector3}) => void} catchCue
 * @property {(kind: string) => void} catchAbort
 * @property {(outcome: 'Down'|'Execute', cause: string) => void} catchOutcome
 */

/** 1-based run order of a LevelId (Enums.levelIndex), or 0. */
export function levelIndex(levelId) {
  return LEVEL_ORDER.indexOf(levelId) + 1;
}

/**
 * @typedef {Object} Context the runtime context the states work through (Brain.Context)
 * @property {CreatureBody} body
 * @property {Mover} mover
 * @property {import('./brain.js').LevelInfo|null} level
 * @property {import('./ventgraph.js').Graph|null} graph
 * @property {string} difficulty
 * @property {Random} random
 * @property {() => number} now
 * @property {import('./perception.js').Sighting[]} sightings
 * @property {import('./brain.js').HeardNoise|null} heard
 * @property {Record<string, {at: number, rank: number, position: THREE.Vector3}>} heardZones
 * @property {any} target
 * @property {{player: any, position: THREE.Vector3, at: number}|null} memory
 * @property {string} phase
 * @property {boolean} canHunt
 * @property {{position: THREE.Vector3, rank: number, at: number}|null} investigation
 * @property {boolean} reposition
 * @property {boolean} stateDone
 * @property {boolean} ventBlocked
 * @property {THREE.Vector3|null} stunFrom
 * @property {(state: string) => number} speedOf
 * @property {(player: any) => void} setTarget
 * @property {(player: any) => string|null} catchKind
 * @property {(player: any, kind: string) => boolean} tryCatch
 * @property {(point: THREE.Vector3) => boolean} visible
 * @property {(minDistance: number, maxDistance: number) => THREE.Vector3|null} repositionPoint
 * @property {() => THREE.Vector3[]} playerPositions
 * @property {() => Function|null} lockerInspector
 * @property {() => Function|null} poolGrabber
 * @property {(player: any) => void} noteSpotted
 * @property {(player: any) => boolean} grabArmed
 * @property {(player: any) => void} setGrabbed
 * @property {(player: any) => boolean} inVent
 * @property {(player: any) => import('./ventgraph.js').RailPoint|null} railPointOf
 * @property {(player: any) => string|null} exitGrateOf
 * @property {() => any[]} ventOccupants
 * @property {(id: string) => string} grateState
 * @property {(grate: import('./ventgraph.js').Grate) => CFrame} standPoint
 * @property {(player: any) => boolean} swimming
 * @property {(player: any) => THREE.Vector3|null} rootOf
 * @property {(a: THREE.Vector3, b: THREE.Vector3) => boolean} lineClear
 * @property {(levelId: string, zoneId: string) => Array<{locker: string, front: CFrame}>} lockersIn
 * @property {(locker: string) => any} lockerOccupant
 * @property {(locker: string) => CFrame|null} lockerFront
 * @property {() => THREE.Vector3} creatureEye
 * @property {(player: any) => THREE.Vector3|null} playerEye
 */

export class MonsterAI {
  /** @param {import('./env.js').CreatureEnv} env */
  constructor(env) {
    this.env = env;
    this.clock = () => env.now();
    /** (new, old) on every MonsterState change. */
    this.stateChanged = new Signal();
    /** (victim, kind) when a catch starts. */
    this.caught = new Signal();
    /** (victim, kind, outcome) when a catch ends: "Downed", "Executed" or "Aborted". */
    this.jumpscareFinished = new Signal();
    /** (origin, seconds) when a pool lunge is telegraphed (the pool shows the bubbles and the ripple there). */
    this.lungeTelegraph = new Signal();

    this.running = false;
    this.difficulty = 'Standard';
    this.speedScale = 1;
    /** @type {Pacing|null} */
    this.pacing = null;
    this.body = new CreatureBody(env.bodyPhysics());
    /** @type {Mover|null} */
    this.mover = null;
    /** @type {Context|null} */
    this.ctx = null;
    this.creatureLevel = null;
    this.levelInfos = new Map();
    this.graphs = new Map();
    this.navs = new Map();

    this.state = 'Dormant';
    this.stateSince = 0;
    this.current = STATES.Dormant;
    this.lastReason = 'placed';
    this.awake = false;
    this.wakeAt = null;
    this.revealPending = false;
    this.revealAt = 0;
    this.paused = false;
    this.chaseStarted = null;
    this.stunUntil = 0;
    this.ventBlockedUntil = 0;
    this.devHuntUntil = 0;
    this.catching = null;
    this.grabbed = null;
    this.grabbedHeldAt = 0;
    this.scripted = null;
    this.noiseQueue = [];
    this.alerts = [];
    this.lastSeen = new Map();
    this.spotted = new Map();
    this.exitGrates = new Map();
    this.splashArmed = new Map();
    this.swimmerAt = -Infinity;
    this.swimmerPlayer = null;
    /** When the player first stood in a pool room on this level (the pool grace runs from it), or null. */
    this.poolEnteredAt = null;
    /** Until when it retreats to the far end of the water after a grab. */
    this.poolRetreatUntil = -Infinity;
    this.ignored = false;
    this.wasInVent = false;
    this.accumulated = 0;
    this.lockerInspector = null;
    this.poolGrabber = null;
    /** @type {() => RemotePlayer[]} the co-op host's remote players (none when played alone) */
    this.roster = () => NO_REMOTES;
    /** @type {Map<any, boolean>} whether each remote player was in a duct at the last motion tick */
    this.ventSeen = new Map();

    const local = (p) => p === PLAYER || p === null || p === undefined;
    this.jumpscare = new JumpscareHandler({
      now: () => this.now(),
      lifeState: (p) => this._lifeOf(local(p) ? PLAYER : p),
      downedCount: (p) => (local(p) ? env.playerDownedCount() : p.downedCount()),
      down: (p, cause) => (local(p) ? env.downPlayer(cause) : p.catchOutcome('Down', cause)),
      execute: (p, cause) => (local(p) ? env.executePlayer(cause) : p.catchOutcome('Execute', cause)),
      playerRoot: (p) => (local(p) ? env.playerRootCFrame() : p.rootCFrame()),
      caughtLock: (p) => (local(p) ? env.playerHasLock('Jumpscare') : p.hasLock('Jumpscare')),
      controlLock: (p) => {
        if (!local(p)) return p.controlLock();
        return env.playerHasLock('Cutscene') ? 'Cutscene' : env.playerHasLock('Jumpscare') ? 'Jumpscare' : 'None';
      },
      lock: (p) => (local(p) ? env.lockPlayer('Jumpscare') : p.setCaught(true)),
      unlock: (p) => (local(p) ? env.unlockPlayer('Jumpscare') : p.setCaught(false)),
      turnPlayer: (p, cframe) => (local(p) ? env.turnPlayer(cframe) : p.turn(cframe)),
      creature: () => (this.ctx ? { body: this.body, state: this.state } : null),
      faceWorld: () => (this.view ? this.view.faceWorld() : null),
      playLunge: (_kind, startAt) => {
        if (this.view) this.view.playAction('Lunge', startAt);
      },
      victimCue: (cue) => {
        const victim = this.jumpscare.getVictim();
        if (!local(victim)) victim.catchCue(cue);
        else if (this.jumpscareView) this.jumpscareView.start(cue);
      },
      abortCue: (kind) => {
        const victim = this.jumpscare.getVictim();
        if (!local(victim)) victim.catchAbort(kind);
        else if (this.jumpscareView) this.jumpscareView.abort();
      },
      // the sting is the victim's own: a remote victim's page plays it
      play: (name, opts) => (name === 'JumpscareSting' && !local(this.jumpscare.getVictim()) ? null : env.play(name, opts)),
      allowed: (kind, p) => (local(p) ? env.catchAllowed(kind) : p.canCatch(kind)),
      outcome: (kind, p) => (local(p) ? env.catchOutcome(kind) : null),
    });
    this.jumpscare.finished.connect((victim, kind, outcome) => {
      if (this.catching && this.catching.player === victim) this._settleCatch(outcome);
      this.jumpscareFinished.fire(victim, kind, outcome);
    });
    /** @type {import('./view.js').CreatureView|null} set by index.js */
    this.view = null;
    /** @type {import('./jumpscareView.js').JumpscareView|null} set by index.js */
    this.jumpscareView = null;

    env.onNoise((event) => this._onNoise(event));
    env.onSplashCrossed(() => {
      if (this.running) this.splashArmed.set(PLAYER, this.now());
    });
  }

  // ------------------------------------------------------------------ co-op roster

  /** The co-op host's remote players (a function returning RemotePlayer handles; null: none). */
  setRoster(fn) {
    this.roster = typeof fn === 'function' ? fn : () => NO_REMOTES;
  }

  /** Every player the brain knows: the local one, then the remote ones. */
  _players() {
    const remotes = this.roster();
    return remotes.length ? [PLAYER, ...remotes] : LOCAL_ONLY;
  }

  /** The player with a noise's sourceUserId (PLAYER is 1), or null. */
  _playerByUserId(userId) {
    if (userId === null || userId === undefined) return null;
    if (userId === PLAYER.userId) return PLAYER;
    return this.roster().find((p) => p.userId === userId) || null;
  }

  _lifeOf(player) {
    if (player === PLAYER) return this.env.playerLifeState();
    return player && player.lifeState ? player.lifeState() : 'Lobby';
  }

  _moveStateOf(player) {
    if (player === PLAYER) return this.env.playerMoveState();
    return player && player.moveState ? player.moveState() : 'Standing';
  }

  /** A remote player's noise (their page heard it from their own body): queued like a local one. */
  hearRemote(event) {
    this._onNoise(event);
  }

  /** A remote swimmer's splashing crossed the grab threshold (the local one comes through onSplashCrossed). */
  noteSplash(player) {
    if (this.running && player) this.splashArmed.set(player, this.now());
  }

  /** Drops everything remembered about a player who left the run (target, sightings, duct spots, a catch). */
  forgetPlayer(player) {
    const c = this.ctx;
    if (c) {
      if (c.target === player) this._setTarget(null);
      if (c.memory && c.memory.player === player) c.memory = null;
      c.sightings = c.sightings.filter((s) => s.player !== player);
    }
    if (this.swimmerPlayer === player) this.swimmerPlayer = null;
    if (this.grabbed === player) this.grabbed = null;
    for (const map of [this.lastSeen, this.spotted, this.exitGrates, this.splashArmed, this.ventSeen]) map.delete(player);
    if (this.jumpscare.getVictim() === player) this.jumpscare.abort('Left');
  }

  now() {
    return this.clock();
  }

  /** Replaces the time source (tests pass a fake clock; null restores the engine's game clock). */
  setClock(fn) {
    this.clock = fn || (() => this.env.now());
  }

  // ------------------------------------------------------------------ helpers

  _levelInfo(levelId) {
    if (!levelId) return null;
    if (this.levelInfos.has(levelId)) return this.levelInfos.get(levelId);
    const info = Brain.levelInfo(levelId, this.env.meta());
    if (info) this.levelInfos.set(levelId, info);
    return info;
  }

  _graph(levelId) {
    if (!levelId) return null;
    if (this.graphs.has(levelId)) return this.graphs.get(levelId);
    const vents = this.env.meta().vents;
    const graph = vents && vents.graphs ? buildGraph(vents.graphs[levelId], levelId) : null;
    this.graphs.set(levelId, graph);
    return graph;
  }

  _nav(levelId) {
    if (!levelId) return null;
    if (this.navs.has(levelId)) return this.navs.get(levelId);
    const nav = new FloorNav(levelId, this.env.meta(), (doorId) => this.env.doorOpen(doorId));
    this.navs.set(levelId, nav);
    return nav;
  }

  _rootOf(player) {
    if (player === PLAYER) return this.env.playerRoot();
    return player && player.root ? player.root() : null;
  }

  /** Alive or Downed with a character. */
  _playing(player) {
    const s = this._lifeOf(player);
    return (s === 'Alive' || s === 'Downed') && this._rootOf(player) !== null;
  }

  _huntable(player) {
    return !this.ignored && this._playing(player);
  }

  _huntablePlayers() {
    return this._players().filter((p) => this._huntable(p));
  }

  _playingPlayers() {
    return this._players().filter((p) => this._playing(p));
  }

  _swimming(player) {
    if (player === PLAYER) return this.env.playerMode() === 'Swim' || SWIM_STATES.has(this.env.playerMoveState());
    return !!player && !!player.mode && (player.mode() === 'Swim' || SWIM_STATES.has(player.moveState()));
  }

  _inVent(player) {
    if (player === PLAYER) return this.env.playerInVent();
    return !!player && !!player.inVent && player.inVent();
  }

  _railPointOf(player) {
    if (!player || !this._inVent(player)) return null;
    const graph = this.ctx ? this.ctx.graph : null;
    if (!graph) return null;
    if (player === PLAYER) return this.env.playerRailPoint(graph);
    const root = this._rootOf(player);
    return root ? railNearest(graph, root) : null;
  }

  _playerEye(player) {
    const root = this._rootOf(player);
    if (!root) return null;
    return Perception.playerEyeAt(root, this._moveStateOf(player));
  }

  /** The root of the playing player nearest `here`, or null. */
  _nearestRoot(here) {
    let best = null;
    let bestDistance = Infinity;
    for (const p of this._playingPlayers()) {
      const r = this._rootOf(p);
      if (r && r.distanceTo(here) < bestDistance) {
        best = r;
        bestDistance = r.distanceTo(here);
      }
    }
    return best;
  }

  _creatureEye() {
    return Perception.creatureEyeAt(this.body.getCFrame(), this.body.pose);
  }

  _lineClear(from, to) {
    return this.env.lineClear(from, to);
  }

  /** Could the player see the Creature with its root at `point` (its head or its chest)? */
  _visible(point) {
    for (const player of this._playingPlayers()) {
      const eye = this._playerEye(player);
      if (!eye || eye.distanceTo(point) > SIGHT_RANGE_LIMIT) continue;
      for (const lift of [CreatureConfig.EyeHeightAboveRoot.Biped, 0]) {
        if (this._lineClear(eye, new THREE.Vector3(point.x, point.y + lift, point.z))) return true;
      }
    }
    return false;
  }

  _playerEyes() {
    const out = [];
    for (const p of this._playingPlayers()) {
      const eye = this._playerEye(p);
      if (eye) out.push(eye);
    }
    return out;
  }

  /** Root positions the Creature can stand at: every patrol waypoint (under water where the waypoint is). */
  _standingSpots(info) {
    const out = [];
    for (const w of info.waypoints) {
      const p = w.position;
      if (this.mover && this.mover.basinAt(p)) out.push(p.clone());
      else out.push(new THREE.Vector3(p.x, p.y + ROOT_HEIGHT, p.z));
    }
    return out;
  }

  _sees(player) {
    const c = this.ctx;
    return !!c && c.sightings.some((s) => s.player === player);
  }

  /** The room side of a grate opening at floor level, facing the room (its ExitAnchor). */
  _grateStandPoint(grate) {
    const anchor = this.env.grateExitAnchor(grate.id);
    if (anchor) return anchor;
    const world = this.env.meta().worldConfig || {};
    const wall = grate.wall;
    const exitOut = 2;
    const out = wall.position.addScaledVector(wall.lookVector, (world.WallThickness ?? WorldDefaults.WallThickness) / 2 + exitOut);
    const floor = new THREE.Vector3(out.x, wall.y - (world.VentCenterHeight ?? WorldDefaults.VentCenterHeight), out.z);
    const facing = flatDirection(wall.lookVector) || new THREE.Vector3(0, 0, -1);
    return CFrame.lookAt(floor, floor.clone().add(facing));
  }

  /** A floor point for a believed position: a point inside a duct becomes the room side of the nearest grate. */
  _floorPointNear(position) {
    const graph = this.ctx ? this.ctx.graph : null;
    if (!graph || railNearest(graph, position, DUCT_SNAP) === null) return position.clone();
    let best = null;
    let bestDistance = Infinity;
    for (const id of graph.grateIds) {
      const grate = graph.grates[id];
      const d = grate.mouth.distanceTo(position);
      if (d < bestDistance) {
        best = grate;
        bestDistance = d;
      }
    }
    return best ? this._grateStandPoint(best).position : position.clone();
  }

  // ------------------------------------------------------------------ body placement

  _placeBody(cframe) {
    const b = this.body;
    const m = this.mover;
    if (!m) return;
    m.reset('Floor');
    b.face(null);
    b.setAnchored(true);
    b.placeAt(cframe);
    const water = m.basinAt(cframe.position) !== null;
    m.reset(water ? 'Water' : 'Floor');
    if (water) b.setPose('Swim');
    else if (b.pose === 'Swim' || b.pose === 'Quadruped') b.setPose('Biped');
  }

  _hide(seconds) {
    this.body.setHidden(true);
    this.revealPending = true;
    this.revealAt = this.now() + seconds;
  }

  _forgetMind() {
    const c = this.ctx;
    if (c) {
      c.target = null;
      c.memory = null;
      c.investigation = null;
      c.heard = null;
      c.sightings = [];
      c.reposition = false;
      c.stateDone = false;
      for (const k of Object.keys(c.heardZones)) delete c.heardZones[k];
    }
    this.noiseQueue = [];
    this.alerts = [];
    this.spotted.clear();
    this.lastSeen.clear();
    this.swimmerPlayer = null;
    this.swimmerAt = -Infinity;
    this.poolRetreatUntil = -Infinity;
    this.chaseStarted = null;
  }

  /** Moves the Creature onto `levelId` at its CreatureSpawn (hidden until nobody can see it when `conceal`). */
  _relocate(levelId, conceal) {
    const c = this.ctx;
    const m = this.mover;
    if (!c || !m) return;
    const info = this._levelInfo(levelId);
    this.creatureLevel = levelId;
    c.level = info;
    c.graph = this._graph(levelId);
    m.setLevel(c.graph, info ? info.basins : []);
    this.env.setNavLevel(levelId);
    this._forgetMind();
    this.poolEnteredAt = null;
    let spawn = info ? info.spawn : null;
    if (!spawn && info && info.waypoints[0]) spawn = CFrame.at(this._standingSpots(info)[0]);
    if (spawn) this._placeBody(spawn);
    if (conceal) this._hide(REVEAL_RETRY);
  }

  // ------------------------------------------------------------------ the pool (Level 4 fairness)

  /** Whether `p` stands in a pool room (a room holding a basin) of the Creature's level. */
  _inPoolRoomAt(p) {
    const info = this.ctx ? this.ctx.level : null;
    if (!p || !info || info.basins.length === 0) return false;
    if (this.mover && this.mover.basinAt(p)) return true;
    const room = Brain.roomAt(info, p);
    return !!room && room.kind === 'Pool';
  }

  _inPoolRoom(player) {
    return this._swimming(player) || this._inPoolRoomAt(this._rootOf(player));
  }

  /** The pool grace starts the first time a player stands in a pool room on this level. */
  _updatePoolGrace(t) {
    if (this.poolEnteredAt !== null) return;
    if (this._playingPlayers().some((p) => this._inPoolRoom(p))) this.poolEnteredAt = t;
  }

  /** The grace after first entering the pool room, or the retreat after a grab: it leaves the pool room alone. */
  _poolQuiet(t) {
    const grace = this.poolEnteredAt !== null && t < this.poolEnteredAt + CreatureConfig.Water.PoolGraceSeconds;
    return grace || t < this.poolRetreatUntil;
  }

  /** While it retreats after a grab: the point of its pool farthest from the player (else null). */
  _poolRetreatPoint() {
    const m = this.mover;
    if (!m || this.now() >= this.poolRetreatUntil || m.getMedium() !== 'Water') return null;
    const here = this.body.getPosition();
    const basin = m.basinAt(here);
    if (!basin) return null;
    const from = this._nearestRoot(here) || here;
    let best = null;
    let bestDistance = -1;
    for (const x of [basin.minX, (basin.minX + basin.maxX) / 2, basin.maxX]) {
      for (const z of [basin.minZ, (basin.minZ + basin.maxZ) / 2, basin.maxZ]) {
        const p = clampToWater(basin, new THREE.Vector3(x, basin.surfaceY - SWIM_DEPTH, z));
        const d = horizontalDistance(p, from);
        if (d > bestDistance) {
          best = p;
          bestDistance = d;
        }
      }
    }
    return best;
  }

  /** A lunge is coming: a low growl at its origin and the pool's bubbles and ripple ring (lungeTelegraph). */
  _telegraph(origin, seconds) {
    this.env.play('CreatureGrowl', { position: origin.clone(), speed: 0.72, volume: 1.2 });
    this.lungeTelegraph.fire(origin.clone(), seconds);
  }

  /** Teleports to the nearest standing spot (>= UNSTICK_MIN away) nobody can see, only while nobody sees it here. */
  _relocateUnseen(landOnly = false) {
    const c = this.ctx;
    const info = c ? c.level : null;
    if (!c || !info) return false;
    const here = this.body.getPosition();
    if (this._visible(here)) return false;
    const spots = this._standingSpots(info).filter((s) => s.distanceTo(here) >= UNSTICK_MIN &&
      !(landOnly && this.mover && this.mover.basinAt(s)));
    // out of the pool's ducts it comes up well away from the player, not round the corner from them
    const point = repositionPoint(spots, this._playerEyes(), here, landOnly ? POOL_EXIT_MIN : 0, Infinity, (p) => this._visible(p));
    if (!point) return false;
    const facing = flatDirection(this.body.getCFrame().lookVector) || new THREE.Vector3(0, 0, -1);
    this._placeBody(CFrame.lookAt(point, point.clone().add(facing)));
    this.unsticks = (this.unsticks || 0) + 1;
    return true;
  }

  // ------------------------------------------------------------------ targets and catches

  _setTarget(player) {
    const c = this.ctx;
    if (!c || c.target === player) return;
    c.target = player;
    if (c.memory && c.memory.player !== player) c.memory = null;
  }

  _canHuntNow() {
    const t = this.now();
    return t < this.devHuntUntil || (this.pacing !== null && this.pacing.canHunt(t));
  }

  _catchKindFor(player) {
    const target = this._rootOf(player);
    if (!this.ctx || !this.mover || !target) return null;
    const here = this.body.getPosition();
    const eye = this._playerEye(player) || target;
    return Brain.catchKind({
      horizontal: horizontalDistance(here, target),
      vertical: Math.abs(here.y - target.y),
      distance: here.distanceTo(target),
      creatureInVent: this.mover.getMedium() === 'Vent',
      targetInVent: this._inVent(player),
      creatureInWater: this.mover.getMedium() === 'Water',
      targetSwimming: this._swimming(player),
      lineClear: this._lineClear(this._creatureEye(), eye),
      playing: this._huntable(player),
      hiding: this._moveStateOf(player) === 'Hiding',
      canHunt: this._canHuntNow(),
      busy: this.catching !== null || this.jumpscare.isBusy(),
      hidden: this.body.hidden,
      stunned: this.now() < this.stunUntil,
    });
  }

  _tryCatch(player, kind) {
    if (!this.mover || this.catching !== null || this.jumpscare.isBusy() || !this._canHuntNow()) return false;
    if (this.ignored || this.now() < this.stunUntil) return false;
    if (!this.jumpscare.catch(player, kind)) return false;
    this.catching = { player, kind, at: this.now() };
    this.mover.stop();
    this.caught.fire(player, kind);
    return true;
  }

  // ------------------------------------------------------------------ states

  _enterState(next, t) {
    const c = this.ctx;
    const previous = this.state;
    if (!c || next === previous) return;
    this.current.exit(c, next);
    if (Brain.isChase(next) && !Brain.isChase(previous)) {
      this.chaseStarted = t;
      if (!this.body.hidden) this.env.play(SPOT_PRESET, { position: this._creatureEye(), volume: SPOT_VOLUME });
    } else if (!Brain.isChase(next)) {
      this.chaseStarted = null;
    }
    if (previous === 'VentChase') {
      if (c.ventBlocked) {
        this.ventBlockedUntil = t + VENT_BLOCK_SECONDS;
        c.ventBlocked = false;
      }
      this.spotted.clear();
    }
    this.state = next;
    this.stateSince = t;
    c.stateDone = false;
    this.current = STATES[next] || STATES.Patrol;
    this.current.enter(c, previous);
    this.stateChanged.fire(next, previous);
  }

  _bestNonCrawler() {
    const c = this.ctx;
    if (!c) return null;
    for (const s of c.sightings) if (!this._inVent(s.player)) return s.player;
    return null;
  }

  _bestCrawler() {
    const c = this.ctx;
    if (!c) return null;
    for (const s of c.sightings) if (this._inVent(s.player)) return s.player;
    return null;
  }

  _remember(player, position, t) {
    const c = this.ctx;
    if (c && c.target === player) c.memory = { player, position: position.clone(), at: t };
  }

  _transition(decision, quarry, t) {
    const c = this.ctx;
    if (!c) return;
    this.lastReason = decision.reason;
    if (decision.reposition) c.reposition = true;
    const next = decision.state;
    if (next === this.state) return;
    if (next === 'WallChase') {
      const target = c.target;
      const chosen = target && this._sees(target) ? target : this._bestNonCrawler();
      this._setTarget(chosen);
      const position = chosen ? this._rootOf(chosen) : null;
      if (chosen && position) this._remember(chosen, position, t);
    } else if (next === 'VentChase') {
      this._setTarget(quarry || this._bestCrawler() || c.target);
    } else if (next === 'AquaticStalk') {
      this._setTarget(this.swimmerPlayer);
    } else if (next === 'InvestigateNoise') {
      const heard = c.heard;
      const memory = c.memory;
      let position;
      let rank = EXACT_RANK;
      const fromNoise = heard !== null && (decision.reason === 'heard' || memory === null);
      if (fromNoise && heard) {
        position = heard.position;
        rank = heard.rank;
      } else if (memory) position = memory.position;
      else position = this.body.getPosition();
      c.investigation = { position: this._floorPointNear(position), rank, at: t };
    }
    this._enterState(next, t);
  }

  _updateTarget(quarry) {
    const c = this.ctx;
    if (!c) return;
    const target = c.target;
    if (this.state === 'WallChase') {
      if (!(target && this._sees(target))) {
        const other = this._bestNonCrawler();
        if (other) this._setTarget(other);
      }
    } else if (this.state === 'VentChase') {
      if (quarry && target === null) this._setTarget(quarry);
    } else if (this.state === 'AquaticStalk') {
      const swimmer = this.swimmerPlayer;
      if (swimmer && target !== swimmer && !(target && this._sees(target))) this._setTarget(swimmer);
    } else if (this.state === 'Patrol' || this.state === 'InvestigateNoise') {
      const best = c.sightings[0];
      this._setTarget(best ? best.player : null);
    } else {
      this._setTarget(null);
    }
  }

  // ------------------------------------------------------------------ senses

  _noteHeard(noise, best, t) {
    const c = this.ctx;
    if (!c) return best;
    if (noise.zoneId) c.heardZones[noise.zoneId] = { at: t, rank: noise.rank, position: noise.position.clone() };
    const source = this._playerByUserId(noise.sourceUserId);
    if (source && this._huntable(source)) {
      if (noise.medium === 'Vent' && noise.rank >= EXACT_RANK && this._inVent(source)) this.spotted.set(source, t);
      if (noise.medium === 'Water' && this._swimming(source)) {
        this.swimmerAt = t;
        this.swimmerPlayer = source;
      }
      this._remember(source, noise.position, t);
    }
    if (best === null || noise.rank > best.rank || (noise.rank === best.rank && noise.strength > best.strength)) return noise;
    return best;
  }

  _sense(t) {
    const c = this.ctx;
    const m = this.mover;
    const p = this.pacing;
    if (!c || !m || !p) return;
    const inVent = m.getMedium() === 'Vent';
    const segment = m.segment();
    const graph = c.graph;
    let ventNodes = null;
    if (inVent && graph) {
      ventNodes = segment ? Perception.segmentNodes(graph, segment) : null;
      if (!ventNodes) ventNodes = Perception.railNodes(graph, this.body.getPosition());
    }
    const viewer = {
      eye: this._creatureEye(),
      facing: this.body.getCFrame().lookVector,
      difficulty: this.difficulty,
      inVent,
      ventNodes,
      aquatic: this.body.pose === 'Swim' || this.state === 'AquaticStalk',
      targetUserId: c.target ? c.target.userId : null,
      raycast: (a, b) => this._lineClear(a, b),
    };
    const observations = [];
    for (const player of this._huntablePlayers()) {
      const eye = this._playerEye(player);
      if (!eye) continue;
      const pv = this._inVent(player);
      const life = this._lifeOf(player);
      observations.push({
        player,
        eye,
        playing: life === 'Alive' || life === 'Downed',
        downed: life === 'Downed',
        moveState: this._moveStateOf(player),
        lit: player === PLAYER ? this.env.playerFlashlightOn() : player.flashlightOn(),
        inVent: pv,
        rail: pv ? this._railPointOf(player) : null,
      });
    }
    const quiet = this._poolQuiet(t);
    const sightings = Perception.scan(viewer, observations).filter((s) => !(quiet && this._inPoolRoom(s.player)));
    c.sightings = sightings;
    for (const s of sightings) {
      this.lastSeen.set(s.player, t);
      const position = this._rootOf(s.player);
      if (position) this._remember(s.player, position, t);
      if (c.level && c.level.basins.length > 0 && this._swimming(s.player)) {
        this.swimmerAt = t;
        this.swimmerPlayer = s.player;
      }
    }
    const listener = {
      position: this._creatureEye(),
      levelId: this.creatureLevel,
      inVent,
      ventNode: m.nearestNode(),
      graph,
      difficulty: this.difficulty,
      occluders: (a, b) => this.env.countOccluders(a, b, 3),
      grateOpen: (id) => {
        const s = this.env.grateState(id);
        return s === 'Open' || s === 'Kicked';
      },
      scale: p.hearingScale(),
    };
    let best = null;
    const events = this.noiseQueue;
    this.noiseQueue = [];
    for (const event of events) {
      if (this.ignored && this._playerByUserId(event.sourceUserId)) continue;
      if (quiet && (event.medium === 'Water' || this._inPoolRoomAt(event.position))) continue;
      const heard = Hearing.perceive(event, listener);
      if (!heard) continue;
      const room = c.level ? Brain.roomAt(c.level, heard.position) : null;
      best = this._noteHeard({
        position: heard.position,
        rank: Hearing.priorityRank(event.priority),
        priority: event.priority,
        medium: event.medium,
        kind: event.kind,
        sourceUserId: event.sourceUserId,
        zoneId: room ? room.id : null,
        strength: heard.strength,
        at: t,
      }, best, t);
    }
    const pending = this.alerts;
    this.alerts = [];
    for (const alert of pending) if (!(quiet && this._inPoolRoomAt(alert.position))) best = this._noteHeard(alert, best, t);
    c.heard = best;
    for (const [zone, heard] of Object.entries(c.heardZones)) if (t - heard.at > HEARD_ZONE_TTL) delete c.heardZones[zone];
    for (const [player, at] of [...this.spotted]) if (t - at > SPOT_WINDOW) this.spotted.delete(player);
  }

  _ventQuarry(t) {
    if (t < this.ventBlockedUntil) return null;
    const c = this.ctx;
    let best = null;
    for (const [player, at] of this.spotted) {
      if (t - at <= SPOT_WINDOW && this._huntable(player) && this._inVent(player)) {
        if (best === null || (c !== null && c.target === player)) best = player;
      }
    }
    return best;
  }

  _nearestPlayerDistance() {
    const here = this.body.getPosition();
    let best = null;
    for (const player of this._huntablePlayers()) {
      const position = this._rootOf(player);
      if (position) {
        const d = position.distanceTo(here);
        if (best === null || d < best) best = d;
      }
    }
    return best;
  }

  _summarize(t) {
    const c = this.ctx;
    const m = this.mover;
    const p = this.pacing;
    const best = c.sightings[0];
    const quarry = this._ventQuarry(t);
    const devHunt = t < this.devHuntUntil;
    const chaseSeconds = this.chaseStarted !== null ? t - this.chaseStarted : 0;
    const level = c.level;
    /** @type {import('./brain.js').Summary} */
    const summary = {
      state: this.state,
      elapsed: t - this.stateSince,
      scripted: this.scripted !== null,
      stunned: t < this.stunUntil,
      awake: this.awake && !this.revealPending,
      catching: this.catching !== null || this.grabbed !== null,
      canHunt: devHunt || p.canHunt(t),
      inVent: m.getMedium() === 'Vent',
      sees: !!best,
      seesInVent: !!best && this._inVent(best.player),
      ventQuarry: quarry !== null,
      heard: c.heard ? c.heard.rank : 0,
      investigating: c.investigation && this.state === 'InvestigateNoise' ? c.investigation.rank : 0,
      memoryAge: c.memory ? t - c.memory.at : null,
      breakChase: this.chaseStarted !== null && !devHunt && p.shouldBreakChase(chaseSeconds),
      swimmer: level !== null && level.basins.length > 0 && t - this.swimmerAt <= SWIMMER_MEMORY,
      inWater: m.getMedium() === 'Water',
      retreating: t < this.poolRetreatUntil,
      stateDone: c.stateDone,
    };
    return [summary, quarry];
  }

  // ------------------------------------------------------------------ upkeep

  _updateReveal(t) {
    if (!this.revealPending) return;
    if (!this._visible(this.body.getPosition())) {
      this.body.setHidden(false);
      this.revealPending = false;
      return;
    }
    if (t >= this.revealAt) {
      // still watched: slip away to a spot nobody sees and appear there, or keep waiting out of sight
      if (this._relocateUnseen()) {
        this.body.setHidden(false);
        this.revealPending = false;
      } else {
        this.revealAt = t + REVEAL_RETRY;
      }
    }
  }

  _updateGrab(t) {
    const victim = this.grabbed;
    const c = this.ctx;
    const p = this.pacing;
    if (!victim || !c || !p) return;
    const holding = this._moveStateOf(victim) === 'Grabbed';
    if (holding) this.grabbedHeldAt = t;
    const life = this._lifeOf(victim);
    if (!(life === 'Alive' || life === 'Downed') || (!holding && t - this.grabbedHeldAt > GRAB_GRACE)) {
      this.grabbed = null;
      p.noteCatch(t);
      c.reposition = true;
      this.poolRetreatUntil = t + CreatureConfig.Water.GrabRetreatSeconds;
      this.splashArmed.delete(victim);
      AquaticStalk.released(c);
    }
  }

  /** A mover that stalled for good (or is shut in the ducts) is moved unseen to a standing spot; the state restarts. */
  _handleMover() {
    const m = this.mover;
    const c = this.ctx;
    if (!m || !c) return;
    const status = m.getStatus();
    if (status === 'Stuck' || (status === 'Failed' && m.getMedium() === 'Vent')) {
      // out of a sealed pool's ducts (its vent route) it comes out on land, unseen
      const landOnly = m.getMedium() === 'Vent' && !!c.level && c.level.basins.some((b) => b.ventExitOnly);
      if (this._relocateUnseen(landOnly)) this.current.enter(c, this.state);
      else if (landOnly && status === 'Failed') {
        // watched in the mouth of the pool's duct: back off along it, out of sight, and move on from there
        const from = this._nearestRoot(this.body.getPosition()) || this.body.getPosition();
        m.reset('Vent');
        m.retreat(from, 4);
      } else m.reset(m.getMedium());
    }
  }

  _settleCatch(outcome) {
    const c = this.ctx;
    const m = this.mover;
    const p = this.pacing;
    const active = this.catching;
    this.catching = null;
    if (!c || !m || !p || !active) return;
    m.reset(m.getMedium());
    if (outcome !== 'Aborted') p.noteCatch(this.now());
    this.devHuntUntil = 0;
    c.reposition = true;
    if (c.target === active.player) {
      this._setTarget(null);
      c.memory = null;
    }
  }

  // ------------------------------------------------------------------ brain tick + motion

  /** Upkeep the game needs every motion tick: vent entry / exit of every player (VentNetworkService.Entered / Exited). */
  _watchVents() {
    for (const player of this._players()) {
      const inVent = this._inVent(player);
      const was = player === PLAYER ? this.wasInVent : this.ventSeen.get(player) === true;
      if (inVent === was) continue;
      if (player === PLAYER) this.wasInVent = inVent;
      else this.ventSeen.set(player, inVent);
      this._ventCrossed(player, inVent);
    }
  }

  _ventCrossed(player, inVent) {
    const graph = this.ctx ? this.ctx.graph : null;
    const root = this._rootOf(player);
    let grateId = null;
    if (graph && root) {
      let bestDistance = Infinity;
      for (const id of graph.grateIds) {
        const d = graph.grates[id].mouth.distanceTo(root);
        if (d < bestDistance) {
          bestDistance = d;
          grateId = id;
        }
      }
    }
    if (inVent) {
      const seen = this.lastSeen.get(player);
      if (this.running && seen !== undefined && this.now() - seen <= SEEN_ENTER_WINDOW && this._huntable(player)) {
        this.spotted.set(player, this.now());
      }
    } else if (grateId) {
      this.exitGrates.set(player, grateId);
    }
  }

  /** One brain tick. @param {number} dt */
  step(dt) {
    const c = this.ctx;
    const m = this.mover;
    const p = this.pacing;
    if (!(this.running && c && m && p)) return;
    const t = this.now();
    if (this.paused) {
      this.noiseQueue = [];
      this.alerts = [];
      return;
    }
    const active = this.catching;
    if (active && t - active.at > CATCH_TIMEOUT) {
      if (!this.jumpscare.abort('Timeout')) this._settleCatch('Aborted');
    }
    this._updateGrab(t);
    if (this.scripted) {
      this.noiseQueue = [];
      this.alerts = [];
      return;
    }
    const busy = this.catching !== null;
    if (!busy) this._updateReveal(t);
    this._updatePoolGrace(t);
    m.setWaterSpeedCap(c.speedOf('AquaticStalk'));
    this._sense(t);
    const target = c.target;
    c.phase = p.tick(dt, {
      chasing: Brain.isChase(this.state),
      seesTarget: target !== null && this._sees(target),
      nearestPlayerDistance: this._nearestPlayerDistance(),
    });
    if (!this.awake && this.wakeAt !== null && t >= this.wakeAt) {
      this.awake = true;
      this.wakeAt = null;
    }
    const [summary, quarry] = this._summarize(t);
    c.canHunt = summary.canHunt;
    this._transition(Brain.decide(summary), quarry, t);
    this._updateTarget(quarry);
    if (!busy) {
      this._handleMover();
      this.current.update(c, dt);
    }
  }

  /** One movement step (nothing moves while a catch runs). @param {number} dt */
  stepMotion(dt) {
    const m = this.mover;
    if (!(this.running && m) || this.paused || this.catching !== null) return;
    m.step(dt);
    this.body.stepPhysics(dt);
  }

  /** The 30 Hz game tick: the catch, motion every tick, the brain at ServerTickHz. @param {number} dt */
  tick(dt) {
    if (!this.running) {
      this.accumulated = 0;
      return;
    }
    this.jumpscare.update();
    this._watchVents();
    this.stepMotion(dt);
    this.accumulated += dt;
    if (this.accumulated + 1e-9 < TICK) return;
    const step = this.accumulated;
    this.accumulated = 0;
    this.step(step);
  }

  // ------------------------------------------------------------------ context

  _newContext() {
    const m = this.mover;
    const env = this.env;
    /** @type {Context} */
    const ctx = {
      body: this.body,
      mover: m,
      level: null,
      graph: null,
      difficulty: this.difficulty,
      random: new Random(RANDOM_SEED),
      now: () => this.now(),
      sightings: [],
      heard: null,
      heardZones: {},
      target: null,
      memory: null,
      phase: 'BuildUp',
      canHunt: false,
      investigation: null,
      reposition: false,
      stateDone: false,
      ventBlocked: false,
      stunFrom: null,
      speedOf: (name) => Brain.speedFor(name, this.difficulty) * (name === 'Scripted' ? 1 : this.speedScale),
      setTarget: (player) => this._setTarget(player),
      catchKind: (player) => this._catchKindFor(player),
      tryCatch: (player, kind) => this._tryCatch(player, kind),
      visible: (point) => this._visible(point),
      repositionPoint: (minDistance, maxDistance) => {
        const info = this.ctx ? this.ctx.level : null;
        if (!info) return null;
        return repositionPoint(this._standingSpots(info), this._playerEyes(), this.body.getPosition(), minDistance,
          maxDistance, (p) => this._visible(p));
      },
      playerPositions: () => this._playerEyes(),
      lockerInspector: () => this.lockerInspector,
      poolGrabber: () => this.poolGrabber,
      noteSpotted: (player) => {
        if (this._huntable(player)) this.spotted.set(player, this.now());
      },
      grabArmed: (player) => {
        const at = this.splashArmed.get(player);
        return at !== undefined && this.now() - at <= GRAB_ARMED_SECONDS && !this._poolQuiet(this.now());
      },
      telegraph: (origin, seconds) => this._telegraph(origin, seconds),
      poolRetreat: () => this._poolRetreatPoint(),
      setGrabbed: (player) => {
        this.grabbed = player;
        this.grabbedHeldAt = this.now();
      },
      inVent: (player) => this._inVent(player),
      railPointOf: (player) => this._railPointOf(player),
      exitGrateOf: (player) => this.exitGrates.get(player) || null,
      ventOccupants: () => this._huntablePlayers().filter((p) => this._inVent(p)),
      grateState: (id) => env.grateState(id),
      standPoint: (grate) => this._grateStandPoint(grate),
      swimming: (player) => this._swimming(player),
      rootOf: (player) => this._rootOf(player),
      lineClear: (a, b) => this._lineClear(a, b),
      lockersIn: (levelId, zoneId) => env.lockersIn(levelId, zoneId),
      lockerOccupant: (locker) => {
        if (env.lockerOccupied(locker)) return PLAYER;
        return this.roster().find((p) => p.lockerId() === locker) || null;
      },
      lockerFront: (locker) => env.lockerFront(locker),
      creatureEye: () => this._creatureEye(),
      playerEye: (player) => this._playerEye(player),
    };
    return ctx;
  }

  /** Takes over the Creature for the run: placed at its level's CreatureSpawn, Dormant until that level activates. */
  _attach(levelId) {
    this.mover = new Mover(this.body, {
      computePath: (from, to) => {
        const nav = this._nav(this.creatureLevel);
        return nav ? nav.computePath(from, to) : null;
      },
      clear: (from, to) => this.env.monsterClear(from, to),
    }, {
      state: (id) => this.env.grateState(id),
      standPoint: (grate) => this._grateStandPoint(grate),
      kick: (id) => this.env.forceGrate(id, 'Kicked'),
    }, () => this.now());
    this.ctx = this._newContext();
    let fallback = 'Level1_Hallways';
    if (levelId && levelIndex(levelId) >= 2) fallback = levelId;
    this.state = 'Dormant';
    this.current = STATES.Dormant;
    this.stateSince = this.now();
    this.lastReason = 'placed';
    this.awake = false;
    this.wakeAt = null;
    this.revealPending = false;
    this.body.setHidden(false);
    this._relocate(fallback, false);
    Dormant.enter(this.ctx);
  }

  // ------------------------------------------------------------------ run + levels

  /** The difficulty the next run starts on (the lobby's choice). */
  setDifficulty(name) {
    this.difficulty = name === 'Nightmare' ? 'Nightmare' : 'Standard';
  }

  /** Starts a run (BeginRun): the Creature is placed Dormant at `startLevel`'s spawn (Level 1 for the basement). */
  beginRun(opts = {}) {
    this.running = true;
    this.difficulty = (opts.difficulty ?? this.difficulty) === 'Nightmare' ? 'Nightmare' : 'Standard';
    this.pacing = new Pacing(this.difficulty, this.now());
    this.paused = false;
    this.stunUntil = 0;
    this.ventBlockedUntil = 0;
    this.devHuntUntil = 0;
    this.catching = null;
    this.grabbed = null;
    this.scripted = null;
    this.exitGrates.clear();
    this.splashArmed.clear();
    this.ventSeen.clear();
    this.wasInVent = this.env.playerInVent();
    this.accumulated = 0;
    this._attach(opts.level || null);
  }

  /** Ends the run (EndRun): the catch is called off, the Creature stops and is hidden. */
  endRun() {
    if (this.catching || this.jumpscare.isBusy()) this.jumpscare.abort('RunEnded');
    if (this.jumpscareView) this.jumpscareView.end();
    this.running = false;
    this.scripted = null;
    this.catching = null;
    this.grabbed = null;
    this._forgetMind();
    this.mover = null;
    this.ctx = null;
    this.creatureLevel = null;
    this.pacing = null;
    this.state = 'Dormant';
    this.current = STATES.Dormant;
    this.awake = false;
    this.wakeAt = null;
    this.revealPending = false;
    this.paused = false;
    this.speedScale = 1;
    this.exitGrates.clear();
    this.splashArmed.clear();
    this.lastSeen.clear();
    this.body.setHidden(true);
    this.env.setNavLevel(null);
  }

  /** LevelDirector.LevelActivated: grace, relocate hidden to the level's spawn when elsewhere, wake after WakeDelay. */
  activateLevel(levelId) {
    if (!this.running) this.beginRun({ difficulty: this.difficulty, level: levelId });
    const p = this.pacing;
    const c = this.ctx;
    if (!p || !c) return;
    if (levelIndex(levelId) < 2) return; // the basement has no Creature
    const t = this.now();
    p.noteAirlock(t);
    if (this.catching) this.jumpscare.abort('Level');
    this.stunUntil = 0;
    this.grabbed = null;
    if (this.creatureLevel !== levelId) this._relocate(levelId, true);
    else this._forgetMind();
    this.awake = false;
    this.wakeAt = t + WAKE_DELAY;
    this.lastReason = `level ${levelId} activated`;
    if (!this.scripted) this._enterState('Dormant', t);
  }

  // ------------------------------------------------------------------ public API

  getState() {
    return this.state;
  }

  getTarget() {
    return this.ctx ? this.ctx.target : null;
  }

  _applyStun(seconds, from) {
    const c = this.ctx;
    if (!c) return;
    const t = this.now();
    this.stunUntil = Math.max(this.stunUntil, t + Math.max(0, seconds));
    c.stunFrom = from.clone();
    this._setTarget(null);
    this.env.play(STUN_PRESET, { position: this._creatureEye() });
    if (this.state === 'Stunned') Stunned.retreat(c);
    else this._enterState('Stunned', t);
  }

  /** Blinded for `seconds`, stumbling back away from `from`. A catch in progress is called off; not while held / asleep. */
  stun(seconds, from) {
    if (!(this.running && this.ctx) || this.scripted || !this.awake) return;
    if (!isFiniteNumber(seconds) || !isFiniteVector(from)) return;
    if (this.catching) {
      this.jumpscare.abort('Stunned');
      if (this.catching) this._settleCatch('Aborted');
    }
    this._applyStun(seconds, new THREE.Vector3(from.x, from.y, from.z));
  }

  /** Scripted alerts: heard on the next tick like a noise of `priority` at `position` (no falloff, no walls). */
  alert(position, priority) {
    if (!this.running || !isFiniteVector(position) || !NoisePriorities.includes(priority)) return;
    const c = this.ctx;
    const p = new THREE.Vector3(position.x, position.y, position.z);
    const room = c && c.level ? Brain.roomAt(c.level, p) : null;
    this.alerts.push({
      position: p, rank: Hearing.priorityRank(priority), priority, medium: 'Air', kind: 'Scripted', sourceUserId: null,
      zoneId: room ? room.id : null, strength: 1, at: this.now(),
    });
  }

  _nearestPlayerTo(position, predicate) {
    let best = null;
    let bestDistance = Infinity;
    for (const player of this._huntablePlayers()) {
      const root = this._rootOf(player);
      if (root && (!predicate || predicate(player)) && root.distanceTo(position) < bestDistance) {
        best = player;
        bestDistance = root.distanceTo(position);
      }
    }
    return best;
  }

  _releaseScripted(nextState) {
    const c = this.ctx;
    this.scripted = null;
    if (!c) return;
    this.body.face(null);
    if (this.body.hidden) this._hide(REVEAL_RETRY);
    const t = this.now();
    let wanted = nextState && MonsterStates.includes(nextState) && nextState !== 'Scripted' ? nextState : 'Patrol';
    this.awake = wanted !== 'Dormant';
    this.wakeAt = null;
    const here = this.body.getPosition();
    if (wanted === 'WallChase') {
      const victim = this._nearestPlayerTo(here, (pl) => !this._inVent(pl));
      this._setTarget(victim);
      const position = victim ? this._rootOf(victim) : null;
      if (victim && position) this._remember(victim, position, t);
      else wanted = 'Patrol';
    } else if (wanted === 'VentChase') {
      const crawler = this._nearestPlayerTo(here, (pl) => this._inVent(pl));
      if (crawler) {
        this._setTarget(crawler);
        this.spotted.set(crawler, t);
      } else wanted = 'Patrol';
    } else if (wanted === 'InvestigateNoise') {
      const near = this._nearestPlayerTo(here, null);
      const position = near ? this._rootOf(near) : null;
      c.investigation = { position: this._floorPointNear(position || here), rank: EXACT_RANK, at: t };
    } else if (wanted === 'AquaticStalk') {
      if (this.swimmerPlayer === null) wanted = 'Patrol';
    } else if (wanted === 'Stunned') {
      this.stunUntil = Math.max(this.stunUntil, t + GameConfig.StunSeconds);
      c.stunFrom = here.clone().add(this.body.getCFrame().lookVector);
    }
    this.lastReason = 'released';
    this._enterState(wanted, t);
  }

  _makeHandle(token) {
    const live = () => this.running && this.scripted !== null && this.scripted.token === token && this.ctx !== null;
    /** @type {ScriptedHandle} */
    const handle = {
      moveTo: (position, speed) => {
        if (!live() || !this.mover || !isFiniteVector(position)) return;
        const pace = isFiniteNumber(speed) && speed > 0 ? speed : Brain.speedFor('Scripted', this.difficulty);
        this.mover.setSpeed(pace);
        this.body.setWalkSpeed(pace);
        this.mover.goTo(new THREE.Vector3(position.x, position.y, position.z), { arrive: 1 });
      },
      teleport: (cframe) => {
        if (!live()) return;
        const cf = toCFrame(cframe);
        if (!cf || !isFiniteVector(cf.position)) return;
        this._placeBody(cf);
      },
      setPose: (poseMode) => {
        if (!live() || !['Biped', 'Hunched', 'Quadruped', 'Swim'].includes(poseMode)) return;
        this.body.setPose(poseMode);
      },
      setHidden: (hidden) => {
        if (!live()) return;
        this.body.setHidden(hidden === true);
        this.revealPending = false;
      },
      face: (position) => {
        if (!live() || !this.mover || !isFiniteVector(position)) return;
        this.mover.face(new THREE.Vector3(position.x, position.y, position.z).sub(this.body.getPosition()));
      },
      release: (nextState) => {
        if (!live()) return;
        this._releaseScripted(nextState);
      },
      setTarget: (target) => this.setScriptedTarget(token, target),
      playAction: (name, startAt) => (this.view ? this.view.playAction(name, startAt) : false),
    };
    return handle;
  }

  /**
   * Exclusive control for a cutscene: null while another token holds it, during a catch, or without a run; the same
   * token gets its handle back.
   * @param {string} token
   * @returns {ScriptedHandle|null}
   */
  acquireScripted(token) {
    if (!(this.running && this.ctx) || typeof token !== 'string' || token === '') return null;
    const hold = this.scripted;
    if (hold) return hold.token === token ? hold.handle : null;
    if (this.catching) return null;
    const handle = this._makeHandle(token);
    this.scripted = { token, handle };
    this.lastReason = `acquired by ${token}`;
    this._enterState('Scripted', this.now());
    return handle;
  }

  /** While `token` holds the Creature, turns its stare on `target` (the player, or null). */
  setScriptedTarget(token, target) {
    const hold = this.scripted;
    if (!(this.running && this.ctx && hold && hold.token === token)) return false;
    let player = target === PLAYER || target === true ? PLAYER : null;
    if (player === null && target && this.roster().includes(target)) player = target;
    if (target !== null && target !== undefined && player === null) return false;
    this._setTarget(player);
    return true;
  }

  /** Level tuning: every state's pace times `scale` (0.5..2); a pace already set follows at once, in proportion. */
  setSpeedScale(scale) {
    const value = isFiniteNumber(scale) ? clamp(scale, MIN_SPEED_SCALE, MAX_SPEED_SCALE) : 1;
    const previous = this.speedScale;
    if (Math.abs(value - previous) < 1e-6) return;
    this.speedScale = value;
    const m = this.mover;
    if (m && this.scripted === null && this.catching === null && this.state !== 'Scripted') {
      const pace = (this.body.walkSpeed * value) / previous;
      m.setSpeed(pace);
      this.body.setWalkSpeed(pace);
    }
  }

  getSpeedScale() {
    return this.speedScale;
  }

  registerLockerInspector(fn) {
    this.lockerInspector = typeof fn === 'function' ? fn : null;
  }

  registerPoolGrabber(fn) {
    this.poolGrabber = typeof fn === 'function' ? fn : null;
  }

  /** The swimmer being held ran out of air: the Underwater jumpscare instead of drowning. */
  catchGrabbed(player = PLAYER) {
    const c = this.ctx;
    const m = this.mover;
    if (!(this.running && c && m) || this.grabbed !== player) return false;
    if (this.catching !== null || this.jumpscare.isBusy() || this.now() < this.stunUntil) return false;
    if (!this.jumpscare.catch(player, 'Underwater')) return false;
    this.grabbed = null;
    AquaticStalk.released(c);
    this.catching = { player, kind: 'Underwater', at: this.now() };
    m.stop();
    this.caught.fire(player, 'Underwater');
    return true;
  }

  /** Pauses (true) or resumes the brain; a paused Creature stands where it is. */
  setPaused(value) {
    this.paused = !!value;
    if (value && this.mover) this.mover.stop();
  }

  /** The Creature's public state (the Roblox attributes: MonsterState, PoseMode, InVent, VentSegmentId, Hidden, ...). */
  snapshot() {
    const m = this.mover;
    const c = this.ctx;
    return {
      running: this.running,
      state: this.state,
      stateSince: this.stateSince,
      reason: this.lastReason,
      pose: this.body.pose,
      inVent: m ? m.getMedium() === 'Vent' : false,
      medium: m ? m.getMedium() : 'Floor',
      segment: m ? m.segment() : null,
      hidden: this.body.hidden,
      levelId: this.creatureLevel,
      targetingPlayer: !!c && c.target === PLAYER,
      targetUserId: c && c.target ? c.target.userId : null,
      grabbed: this.grabbed !== null,
      awake: this.awake,
      catching: this.catching !== null,
      pacing: this.pacing ? this.pacing.snapshot() : null,
      position: this.body.getPosition(),
      eye: this._creatureEye(),
    };
  }

  // ------------------------------------------------------------------ dev commands (DevToolsService: ai, hunt, ignoreme)

  _bringNear() {
    const c = this.ctx;
    const root = this.env.playerRoot();
    const eye = this._playerEye(PLAYER);
    const levelId = this.env.playerLevel();
    if (!c || !root || !eye || !levelId) return 'you need a character on a school level';
    if (levelIndex(levelId) < 2) return 'the Creature never enters the basement';
    if (this.creatureLevel !== levelId) {
      const info = this._levelInfo(levelId);
      this.creatureLevel = levelId;
      c.level = info;
      c.graph = this._graph(levelId);
      this.mover.setLevel(c.graph, info ? info.basins : []);
      this.env.setNavLevel(levelId);
      this._forgetMind();
    }
    const info = c.level;
    if (!info) return `no layout for ${levelId}`;
    const spots = this._standingSpots(info);
    let point = repositionPoint(spots, [eye], root, TP_MIN, TP_MAX, (p) => this._visible(p));
    let note = '';
    if (!point) {
      let bestDistance = Infinity;
      for (const s of spots) {
        const d = s.distanceTo(root);
        if (d >= TP_MIN && d < bestDistance) {
          point = s;
          bestDistance = d;
        }
      }
      note = ' (no hidden spot in range: in sight)';
    }
    if (!point) return `no spot on ${levelId} to bring it to`;
    const facing = flatDirection(root.clone().sub(point)) || new THREE.Vector3(0, 0, -1);
    this._placeBody(CFrame.lookAt(point, point.clone().add(facing)));
    this._wakeForDev();
    this.lastReason = 'ai tp';
    this._enterState('Patrol', this.now());
    return `Creature brought ${point.distanceTo(root).toFixed(0)} studs from you on ${levelId}${note}`;
  }

  _wakeForDev() {
    this.awake = true;
    this.wakeAt = null;
    if (this.revealPending) {
      this.body.setHidden(false);
      this.revealPending = false;
    }
  }

  _force(wanted) {
    const c = this.ctx;
    if (!c) return 'no Creature this run';
    if (this.scripted) return 'a cutscene holds the Creature';
    const t = this.now();
    const root = this.env.playerRoot();
    if (wanted === 'Scripted') return 'Scripted is entered through acquireScripted (cutscenes)';
    if (wanted === 'Dormant') {
      this.awake = false;
      this.wakeAt = null;
      this.lastReason = 'ai Dormant';
      this._enterState('Dormant', t);
      return 'Creature asleep (ai Patrol wakes it)';
    }
    if (wanted === 'Stunned') {
      this._wakeForDev();
      if (!root) return 'you need a character';
      this.stun(GameConfig.StunSeconds, root);
      return `Creature stunned for ${GameConfig.StunSeconds}s`;
    }
    this._wakeForDev();
    if (wanted === 'Patrol') {
      this.devHuntUntil = 0;
      this.lastReason = 'ai Patrol';
      this._enterState('Patrol', t);
      return 'Creature patrolling';
    }
    if (!root) return 'you need a character';
    this.devHuntUntil = t + DEV_FORCE_SECONDS;
    this.lastReason = `ai ${wanted}`;
    if (wanted === 'InvestigateNoise') {
      c.investigation = { position: this._floorPointNear(root), rank: EXACT_RANK, at: t };
      this._enterState('InvestigateNoise', t);
    } else if (wanted === 'WallChase') {
      if (this._inVent(PLAYER)) return 'you are in a vent: use ai VentChase';
      this._setTarget(PLAYER);
      this._remember(PLAYER, root, t);
      this._enterState('WallChase', t);
    } else if (wanted === 'VentChase') {
      if (!this._inVent(PLAYER)) return 'you are not in a vent';
      this._setTarget(PLAYER);
      this.spotted.set(PLAYER, t);
      this._enterState('VentChase', t);
    } else if (wanted === 'AquaticStalk') {
      if (!(c.level && c.level.basins.length > 0)) return 'no pool on this level';
      this.swimmerAt = t;
      this.swimmerPlayer = PLAYER;
      this._setTarget(PLAYER);
      this._enterState('AquaticStalk', t);
    }
    return `Creature ${wanted} (hunting allowed for ${DEV_FORCE_SECONDS}s)`;
  }

  /** The dev panel's commands: "ai [state|pause|resume|tp]", "hunt", "ignoreme". */
  devCommand(command) {
    const words = String(command || '').trim().split(/\s+/).filter(Boolean);
    const head = (words[0] || '').toLowerCase();
    if (!(this.running && this.ctx)) return 'no Creature this run';
    if (head === 'hunt') {
      if (this.ignored) return 'it is ignoring you (ignoreme to stop)';
      const reply = this._force(this._inVent(PLAYER) ? 'VentChase' : 'WallChase');
      this.devHuntUntil = Math.max(this.devHuntUntil, this.now() + DEV_HUNT_SECONDS);
      return reply;
    }
    if (head === 'ignoreme') {
      this.ignored = !this.ignored;
      if (this.ignored && this.ctx.target === PLAYER) {
        this._setTarget(null);
        this.ctx.memory = null;
      }
      this.spotted.delete(PLAYER);
      return this.ignored ? 'the Creature ignores you' : 'the Creature notices you again';
    }
    if (head !== 'ai') return 'usage: ai [state|pause|resume|tp] | hunt | ignoreme';
    const arg = words[1];
    if (!arg) {
      const s = this.pacing ? this.pacing.snapshot() : null;
      const t = this.now();
      return `${this.state} for ${(t - this.stateSince).toFixed(1)}s (${this.lastReason}) | target ${this.ctx.target ? 'you' : 'none'}` +
        ` | pose ${this.body.pose} | ${this.mover.getMedium()}${this.body.hidden ? ', hidden' : ''} | ${this.creatureLevel}` +
        (s ? ` | pacing ${s.phase}, tension ${s.tension.toFixed(2)}` : '') + (this.paused ? ' | PAUSED' : !this.awake ? ' | asleep' : '');
    }
    const word = arg.toLowerCase();
    if (word === 'pause') {
      this.setPaused(true);
      return 'AI paused';
    }
    if (word === 'resume') {
      this.setPaused(false);
      return 'AI resumed';
    }
    if (word === 'tp') return this._bringNear();
    const wanted = MonsterStates.find((s) => s.toLowerCase() === word);
    if (!wanted) return `usage: ai [${MonsterStates.join('|')}|pause|resume|tp]`;
    return this._force(wanted);
  }

  // ------------------------------------------------------------------ noise

  _onNoise(event) {
    if (!this.running) return;
    if (this.noiseQueue.length >= NOISE_QUEUE_LIMIT) this.noiseQueue.shift();
    this.noiseQueue.push(event);
  }
}

/**
 * @typedef {Object} ScriptedHandle
 * @property {(position: {x: number, y: number, z: number}, speed?: number) => void} moveTo
 * @property {(cframe: CFrame|THREE.Matrix4|number[]) => void} teleport
 * @property {(poseMode: 'Biped'|'Hunched'|'Quadruped'|'Swim') => void} setPose
 * @property {(hidden: boolean) => void} setHidden
 * @property {(position: {x: number, y: number, z: number}) => void} face
 * @property {(nextState?: string) => void} release
 * @property {(target: any) => boolean} setTarget turns the held Creature's stare on the player (null clears)
 * @property {(name: string, startAt?: number) => boolean} playAction a one-shot animation layer (NeckSnap, Lunge,
 *   LockerRip, DoorSmash, Vanish, Reveal)
 */

/** A CFrame from a CFrame, a THREE.Matrix4 or 12 Roblox components. */
export function toCFrame(value) {
  if (value instanceof CFrame) return value;
  if (value && value.isMatrix4) return CFrame.fromMatrix4(value);
  if (Array.isArray(value) && value.length >= 12) return CFrame.fromComponents(value);
  if (value && value.x !== undefined && value.y !== undefined && value.z !== undefined) return CFrame.at(value);
  return null;
}
