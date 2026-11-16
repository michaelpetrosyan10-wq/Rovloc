// MonsterAI: the Creature's brain ("the Tall Man", Tunnels design §2.2-§2.4). The local player is PLAYER; in a co-op
// run the host's game adds the remote players through setRoster (handles with the same reads: root, eye, look,
// MoveState, life, duct crawl, torch, hiding spot), so it sees, hears, chases, teleports to and catches every one of
// them. A remote catch runs here; its victim's own page plays the moment.
//
// Brain, at GameConfig.ServerTickHz (10 Hz) during a run:
//   watch     every player's trail (where they came from: the teleport's "behind"), speed, life (a fresh Downed blocks
//             teleports for Teleport.AfterCatch), hiding (someone it saw within Hiding.SeenWindow climbing into a
//             spot: the saw-you-hide rule) and stare (looking straight at its head for Stare.Seconds starts a chase).
//   perceive  Perception.scan over the players (unless ignored; nothing while it is hidden or fading), every noise pulse
//             since the last tick through Hearing.perceive (the pacing's HearingScale), plus scripted alerts. It
//             remembers the target's last seen or heard position, the rooms it heard noises in (the Stalk leans toward
//             them) and who was loud lately (a teleport target weighs more).
//   pace      Pacing.tick (chasing, target in sight, nearest player).
//   decide    Brain.decide over a Summary (the transition table); entering a state runs the old state's exit and the
//             new one's enter; the current state updates once per tick (not while a catch or a warp runs).
//   act       the states drive Locomotion, stepped every motion tick (30 Hz) so kinematic motion is smooth.
//
// States: Dormant, Patrol (the Stalk, 7), InvestigateNoise (9), WallChase (the Chase, 16.5: ChaseLost s without sight
// -> Search, MaxChase s -> it gives up and fades out), Search (the hiding spots near the last seen point, 12..18 s),
// HidingResponse (it saw them hide: LookAways, ReachIn at 30 s), Teleport (warning, FadeIn, stare, stalk), Stunned
// and Scripted. Nothing outside Scripted moves faster than CreatureConfig.SpeedCap.
//
// Warps: every FadeOut / FadeIn relocation (a teleport, a chase giving up, a concealed Creature revealing itself)
// runs through one machine (this.warp): FadeOut (FadeOutSeconds; the catch and the senses off) -> Hidden (placed at the destination; waits until no player can see it there, or picks another spot) ->
// Warning (teleports only: WarningSeconds, the teleportWarning signal: lights, torch, hiss) -> FadeIn (FadeInSeconds)
// -> Stare (teleports only: StareSeconds, the reveal check). The brain holds its state while a warp runs.
//
// THE VIEW CONTRACT (R <-> A, design §5). The creature view reads, every frame, from snapshot() (and viewState()):
//   state            the MonsterState above
//   speed            the root's measured horizontal speed, studs/s (0 standing, 7 stalking, 16.5 chasing)
//   poseMode         'Biped' | 'Hunched' (under a low lintel or tunnel, or about to walk under one: the clearance at
//                    its root or along its way just ahead below HunchBelow; or sniffing at a hiding spot) | 'Stunned'. The brain's eye is this pose's eye.
//   action           'Stare' | 'ReachIn' | 'LookAway' | 'FadeOut' | 'FadeIn' | 'Jumpscare' | null
//   actionStartedAt  the game clock (service.now()) when that action began
//   fade             0..1, how visible it is (FadeOut 1 -> 0 over 0.6 s, hidden 0, FadeIn 0 -> 1 over 0.8 s)
// A co-op client's puppet (game/coop/creature.js) publishes the same fields from the host's state.
//
// Catches go through the JumpscareHandler (Hallway on floors, Locker through a ReachIn). While a catch runs the brain leaves the body alone; when it finishes the movement is re-synced, the
// pacing notes the catch (cooldown, Relax) and the Creature withdraws out of sight. A mover that stalls for good is put
// back at the nearest standing spot nobody can see, and only while nobody can see the Creature either.
//
// The presence layer (docs/MONSTER.md 15-19, presence.js / beats.js): the Director above the brain keeps a menace per
// player and, once a second while it patrols and may hunt, hands it a search hint near the focus player (walked there,
// or an approach teleport first when the walk is long: warned like every teleport), a presence beat (Peek, Glimpse,
// Shadow, PassBy: their own states) or nothing; the patrol's next loop is the one passing closest to the focus player.
// The senses add the torch's glow (a lit torch's spot seen from GlowRange is looked into, like a heard noise) and
// standing still in the dark (sight x StillDarkFactor); the chase runs on along the way its quarry fled (the pursuit),
// to the website's cap (Presence.Chase); a teleport lands ahead of a moving target first and a sighting within
// StalkSight after it starts a chase.
//
// Levels. activateLevel (every level, the basement too): Pacing.noteAirlock (grace), the Creature is moved hidden to that
// level's CreatureSpawn if it is elsewhere, fades in once nobody can see it, and wakes into Patrol WakeDelay seconds
// later; the first teleport waits FloorGrace + Teleport.FirstAfterGrace. A level controller that acquired it
// (acquireScripted: the spawn hold, a scene) keeps it.

import * as THREE from 'three';
import * as Brain from './brain.js';
import { CFrame } from './cframe.js';
import {
  CreatureConfig, GameConfig, MonsterStates, NoisePriorities, ROOT_HEIGHT, WorldDefaults, creatureMetrics, difficultySpec,
} from './config.js';
import { BODY_RADIUS, CreatureBody } from './body.js';
import * as Hearing from './hearing.js';
import { JumpscareHandler } from './jumpscare.js';
import { Mover } from './locomotion.js';
import { FloorNav } from './nav.js';
import { Pacing, repositionPoint } from './pacing.js';
import * as Perception from './perception.js';
import { planBeat } from './beats.js';
import { Director, presenceConfig } from './presence.js';
import { Random, Signal, clamp, clamp01, flatDirection, horizontalDistance, isFiniteNumber, isFiniteVector } from './util.js';
import { buildGraph, nearest as railNearest } from './ventgraph.js';
import { WorldConfig } from '../engine/config.js';
import * as Dormant from './states/dormant.js';
import * as Glimpse from './states/glimpse.js';
import * as HidingResponse from './states/hiding.js';
import * as InvestigateNoise from './states/investigate.js';
import * as PassBy from './states/passby.js';
import * as Patrol from './states/patrol.js';
import * as Peek from './states/peek.js';
import * as Scripted from './states/scripted.js';
import * as Search from './states/search.js';
import * as Shadow from './states/shadow.js';
import * as Stunned from './states/stunned.js';
import * as Teleport from './states/teleport.js';
import * as WallChase from './states/wallchase.js';

const STATES = { Dormant, Patrol, InvestigateNoise, WallChase, Search, HidingResponse, Teleport, Stunned, Scripted, Peek,
  Glimpse, Shadow, PassBy };

const TICK = 1 / GameConfig.ServerTickHz;
const T = CreatureConfig.Teleport;
const H = CreatureConfig.Hiding;
export const WAKE_DELAY = 4;
const CATCH_TIMEOUT = GameConfig.OneShotLead + CreatureConfig.Jumpscare.LungeSeconds + CreatureConfig.Jumpscare.HoldSeconds + 4;
const HEARD_ZONE_TTL = Patrol.HeardTtl;
const NOISE_QUEUE_LIMIT = 64;
const SIGHT_RANGE_LIMIT = 250;
const UNSTICK_MIN = 6;
const DUCT_SNAP = 1.5;
const EXACT_RANK = Hearing.priorityRank('High');
const DEV_FORCE_SECONDS = 30;
const DEV_HUNT_SECONDS = 45;
const TP_MIN = 18;
const TP_MAX = 60;
const SPOT_PRESET = 'Screech';
const SPOT_VOLUME = 0.75;
const STUN_PRESET = 'Screech';
const GRUNT_PRESET = 'CreatureGrunt';
const MIN_SPEED_SCALE = 0.5;
const MAX_SPEED_SCALE = 2;
const LEVEL_ORDER = WorldConfig.LevelOrder;
const RANDOM_SEED = 20251029;
const TRAIL_SECONDS = 15;
const TRAIL_EVERY = 0.5;
const TRAIL_SKIP = 1; // the last second of a trail is not "behind" yet
const PLAYER_FLOOR = 3; // a player's root centre over the floor
const PULL_STARTLE = 1.2; // a teammate's pull-out startles it this long (blind)
const PULL_MEMORY = 2.5;
const TELEPORT_RETRY = 4;
const SAMPLE_SPACING = 5;
const TUNNEL_KINDS = new Set(['Corridor', 'Tunnel', 'Gallery', 'Hallway']); // not keep-rooms
const FOLLOWING_BEATS = new Set(['Peek', 'Glimpse', 'Shadow']); // beats it plays watching its player (getTarget)
const WARP_WAIT = 3; // a spot still in view this long after it was picked is swapped for another
const WARP_GIVE_UP = 12; // hidden this long: any spot out of sight will do
const STAGE_LIFTS = [-1, 0, 1]; // the walker's body (its root box) from the root: a catch's staging step clears it
const SPEED_DAMP = 10;
const LOUD_RANK = 3;
const NEAR_EYE = 8; // a point this close to a player's eye counts as in their view
const GLOW_LIFT = 0.3; // the torch's lit spot, pulled this far back off the surface toward the player
const GLOW_RANK = Hearing.priorityRank('Normal');
const FAR = 1e4; // a rank's offset: what is not ahead of a player sorts after everything that is
const PURSUIT_TRIES = 8; // the pursuit's candidates walked (best first)

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
 * @property {() => THREE.Vector3} [look] their view direction (unit; from their pose's yaw and pitch)
 * @property {() => string} lifeState
 * @property {() => number} downedCount
 * @property {() => string} moveState
 * @property {() => string} mode 'OnFoot' | 'Vent'
 * @property {() => boolean} inVent
 * @property {() => boolean} flashlightOn
 * @property {() => string|null} lockerId the hiding spot they are in
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
 * @typedef {Object} Context the runtime context the states work through
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
 * @property {THREE.Vector3|null} searchFrom
 * @property {{player: any, spot: string, front: CFrame, since: number}|null} hiding
 * @property {any} teleportPlan
 * @property {boolean} reposition
 * @property {boolean} stateDone
 * @property {THREE.Vector3|null} stunFrom
 * @property {(state: string) => number} speedOf
 * @property {(player: any) => void} setTarget
 * @property {(player: any) => string|null} catchKind
 * @property {(player: any, kind: string) => boolean} tryCatch
 * @property {(player: any, spot: string) => void} reachIn
 * @property {(point: THREE.Vector3) => boolean} visible
 * @property {() => ((point: THREE.Vector3) => boolean)|null} reachable which points it can walk to from where it stands
 * @property {(minDistance: number, maxDistance: number) => THREE.Vector3|null} repositionPoint
 * @property {() => THREE.Vector3[]} playerPositions
 * @property {() => Function|null} lockerInspector
 * @property {(player: any) => boolean} inVent
 * @property {(player: any) => boolean} playing
 * @property {(player: any) => boolean} isHiding
 * @property {(player: any) => string|null} hideSpotOf
 * @property {(point: THREE.Vector3, radius: number) => Array<{id: string, kind: string, front: CFrame}>} hideSpotsNear
 * @property {(spot: string) => any} hideSpotOccupant
 * @property {(spot: string) => CFrame|null} hideSpotFront
 * @property {(player: any) => boolean} pulledOut
 * @property {(player: any) => boolean} bodyClear
 * @property {(player: any) => THREE.Vector3|null} rootOf
 * @property {(p: THREE.Vector3) => THREE.Vector3} floorPointNear
 * @property {(a: THREE.Vector3, b: THREE.Vector3) => boolean} lineClear
 * @property {(direction: THREE.Vector3|null) => void} setLookAway
 * @property {(front: CFrame) => THREE.Vector3} lookAwayDirection
 * @property {() => void} grunt
 * @property {(plan: any) => boolean} startTeleport
 * @property {() => boolean} warping
 * @property {() => THREE.Vector3} creatureEye
 * @property {(player: any) => THREE.Vector3|null} playerEye
 * @property {any} presence the presence layer's numbers for the run's difficulty (presence.js presenceConfig)
 * @property {{point: THREE.Vector3, player: any, at: number}|null} hint the director's search hint (Patrol walks to it)
 * @property {any} beatPlan the beat the director handed over (beats.js), while it plays
 * @property {boolean} beatReached the beat's player has seen it or had it within Beats.ReachWalk walked
 * @property {string|null} beatDue the beat to enter this tick
 * @property {() => THREE.Vector3|null} patrolNear where the director's focus player stands (the next loop's pull)
 * @property {(base: number) => number} paceOf a pace with the difficulty's multiplier and the level's scale, capped
 * @property {(player: any, degrees: number) => boolean} lookedAt the player's view is on its head (a clear line)
 * @property {(player: any) => number} walkTo its walking distance to the player
 * @property {(player: any) => THREE.Vector3[]} trailOf where the player has been, oldest first
 * @property {(player: any) => number} speedOfPlayer the player's measured speed
 * @property {(memory: any) => THREE.Vector3|null} pursuitPoint where the pursuit runs on to from the last seen point
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
    /** (spot: floor point, target, seconds) a teleport's warning starts: the lights there flicker, a hiss rises. */
    this.teleportWarning = new Signal();
    /** (target, kind) the target looked at it as it formed (or a hiding spot's fake-out): their reveal scare. */
    this.revealed = new Signal();
    /** (player) someone's held stare started a chase (their sting). */
    this.stared = new Signal();
    /** (player|null, position) a chase ran out and it faded away (the give-up swell). */
    this.gaveUp = new Signal();
    /** (position) the low grunt before a LookAway. */
    this.grunted = new Signal();
    /** ({kind, ...}) what it is about to do that the game may answer: ReachIn {player, spot, at} (the catch's time),
     * Sniff {spot} (a breath check at a hiding spot begins), Stun {seconds, from} */
    this.feed = new Signal();

    this.metrics = creatureMetrics(env.meta());
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
    this.paused = false;
    this.chaseStarted = null;
    this.chaseSeenAt = 0;
    this.stunUntil = 0;
    this.devHuntUntil = 0;
    this.catching = null;
    this.pendingReach = null;
    this.scripted = null;
    this.noiseQueue = [];
    this.alerts = [];
    this.lastSeen = new Map();
    this.ignored = false;
    /** @type {Map<any, number>} player -> the time until which it ignores them (a respawn's grace) */
    this.graceUntil = new Map();
    this.accumulated = 0;
    this.lockerInspector = null;
    /** @type {() => RemotePlayer[]} the co-op host's remote players (none when played alone) */
    this.roster = () => NO_REMOTES;
    /** @type {Map<any, any>} per player: trail, speed, stare, hiding and life last seen */
    this.records = new Map();
    // the view contract
    this.action = null;
    this.actionAt = 0;
    this.speedMeasured = 0;
    this.lastRoot = null;
    this.lastPlacements = 0;
    /** The head room it walks under now (and just ahead): Hunched below CreatureConfig.HunchBelow. */
    this.clearance = Infinity;
    // warps, teleports, the hiding rule
    this.warp = null;
    this.lookAway = null;
    this.stareTrigger = null;
    this.hideWatch = null;
    this.pulled = new Map();
    this.startleUntil = -Infinity;
    this.lastSeenAny = 0;
    this.teleportReadyAt = Infinity;
    this.nextTeleportTry = 0;
    this.lastTeleportTarget = null;
    this.lastCatchAt = -Infinity;
    this.lastDownAt = -Infinity;
    this.teleports = 0;
    this.creatureLit = false;
    this.unsticks = 0;
    // the presence layer (beginRun)
    this.presence = null;
    /** @type {Director|null} */
    this.director = null;
    this.directAt = 0;
    this.approaches = 0;
    this.beats = 0;
    this.searchAfterChase = false;
    this.graceEndsAt = 0;
    /** @type {Map<any, number>} player -> its walking distance to them, read once a director Interval */
    this.walks = new Map();
    /** @type {Map<any, number>} player -> when their torch's glow was last looked for */
    this.glowAt = new Map();
    /** @type {Map<any, number>} player -> how far it has noticed them (0..1: 1 starts a chase) */
    this.awareness = new Map();

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
      stage: (from, to) => this._stageTo(from, to),
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

  _torchOf(player) {
    if (player === PLAYER) return this.env.playerFlashlightOn();
    return !!player && !!player.flashlightOn && player.flashlightOn();
  }

  /** A player's view direction (unit). */
  _lookOf(player) {
    if (player === PLAYER) return this.env.playerLookVector().clone();
    if (player && player.look) {
      const l = player.look();
      if (l) return l.clone();
    }
    const cf = player && player.rootCFrame ? player.rootCFrame() : null;
    return cf ? cf.lookVector.clone() : new THREE.Vector3(0, 0, -1);
  }

  /** The hiding spot a player is in (id), or null. */
  _hideSpotOf(player) {
    if (player === PLAYER) return this.env.playerHideSpot();
    return player && player.lockerId ? player.lockerId() || null : null;
  }

  /** A remote player's noise (their page heard it from their own body): queued like a local one. */
  hearRemote(event) {
    this._onNoise(event);
  }

  /** A teammate pulled `player` out of their hiding spot (the THRESHOLD throw): no catch for it; it is startled. */
  notePulled(player) {
    if (!this.running || !player) return;
    const t = this.now();
    this.pulled.set(player, t);
    const c = this.ctx;
    if (this.state === 'HidingResponse' && c && c.hiding && c.hiding.player === player) this.startleUntil = t + PULL_STARTLE;
  }

  /** Drops everything remembered about a player who left the run (target, sightings, a catch). */
  forgetPlayer(player) {
    const c = this.ctx;
    if (c) {
      if (c.target === player) this._setTarget(null);
      if (c.memory && c.memory.player === player) c.memory = null;
      c.sightings = c.sightings.filter((s) => s.player !== player);
      if (c.hiding && c.hiding.player === player) c.stateDone = true;
    }
    if (this.hideWatch && this.hideWatch.player === player) this.hideWatch = null;
    if (this.lastTeleportTarget === player) this.lastTeleportTarget = null;
    if (this.pendingReach && this.pendingReach.player === player) this.pendingReach = null;
    for (const map of [this.lastSeen, this.records, this.pulled, this.graceUntil, this.walks, this.glowAt, this.awareness]) {
      map.delete(player);
    }
    if (this.director) this.director.forget(player);
    if (c && c.hint && c.hint.player === player) c.hint = null;
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
    const nav = new FloorNav(levelId, this.env.meta(), (doorId) => this.env.doorOpen(doorId), this.metrics);
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
    return !this._ignores(player) && this._playing(player);
  }

  /** Whether it ignores `player`: the dev's ignoreme (everyone), or their respawn's grace (unseen, unheard, uncaught). */
  _ignores(player) {
    if (this.ignored) return true;
    const until = this.graceUntil.get(player);
    return until !== undefined && this.now() < until;
  }

  /**
   * A respawn's grace: `player` (PLAYER, or a co-op roster handle) is not seen, heard or caught for `seconds`; a hunt
   * or a memory of them is dropped at once.
   */
  ignore(player, seconds) {
    if (!player || !(seconds > 0)) return;
    this.graceUntil.set(player, this.now() + seconds);
    if (this.director) this.director.encounter(player, this.now());
    const c = this.ctx;
    if (!c) return;
    if (c.target === player) this._setTarget(null);
    if (c.memory && c.memory.player === player) c.memory = null;
    c.sightings = c.sightings.filter((s) => s.player !== player);
    if (this.pendingReach && this.pendingReach.player === player) this.pendingReach = null;
  }

  /**
   * A respawn at `entry` (a floor point): when it stands within `walked` studs walked of it, it is moved, unwarned and
   * unseen, to the nearest land spot at least `walked` walked from the entry, `clear` from every player and out of
   * everyone's sight, and its next teleport is at least `teleportDelay` off. Returns {moved, walk, to}.
   * @param {THREE.Vector3} entry
   * @param {{walked: number, clear: number, teleportDelay: number}} opts
   */
  relocateFrom(entry, opts) {
    const c = this.ctx;
    const info = c ? c.level : null;
    const nav = info ? this._nav(info.levelId) : null;
    if (!c || !info || !nav || this.scripted || !this.running) return { moved: false, walk: null, to: null };
    const t = this.now();
    this.teleportReadyAt = Math.max(this.teleportReadyAt, t + opts.teleportDelay);
    const here = this.body.getPosition();
    const feet = (p) => new THREE.Vector3(p.x, p.y - ROOT_HEIGHT, p.z);
    const walk = nav.pathLength(entry, feet(here));
    if (walk >= opts.walked) return { moved: false, walk, to: null };
    const roots = this._players().map((p) => this._rootOf(p)).filter(Boolean);
    let best = null;
    for (const spot of this._landSpots(info)) {
      if (roots.some((r) => horizontalDistance(r, spot) < opts.clear)) continue;
      const w = nav.pathLength(entry, feet(spot));
      if (!(w >= opts.walked) || !Number.isFinite(w) || (best && w >= best.walk)) continue;
      if (this._visible(spot)) continue;
      best = { spot, walk: w };
    }
    if (!best) return { moved: false, walk, to: null };
    if (this.catching) this.jumpscare.abort('Respawn');
    this._cancelWarp();
    this.pendingReach = null;
    this.lookAway = null;
    const toward = this._nearestRoot(best.spot);
    const facing = (toward && flatDirection(toward.clone().sub(best.spot))) || new THREE.Vector3(0, 0, -1);
    this._placeBody(CFrame.lookAt(best.spot, best.spot.clone().add(facing)));
    this.body.setHidden(false);
    this._forgetMind();
    return { moved: true, walk, to: best.spot.clone(), toWalk: best.walk };
  }

  _huntablePlayers() {
    return this._players().filter((p) => this._huntable(p));
  }

  _playingPlayers() {
    return this._players().filter((p) => this._playing(p));
  }

  _inVent(player) {
    if (player === PLAYER) return this.env.playerInVent();
    return !!player && !!player.inVent && player.inVent();
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

  /**
   * Its eye: where the rig's eyes are in the pose it stands in (the contract's poseMode): hunched under a low lintel
   * or a tunnel's ceiling. Standing, the Tall Man's eyes are 10.3 studs up, inside the ceiling of a 10-stud tunnel: the
   * brain sees, is stared at and catches from where its mask really is.
   */
  _creatureEye() {
    return Perception.creatureEyeAt(this.body.getCFrame(), this._poseMode(), this.metrics.eyeHeights);
  }

  /** How high its head stands over a root at `point` on land: hunched where the head room there is low. */
  _headLift(point) {
    const eyes = this.metrics.eyeHeights;
    const nav = this._nav(this.creatureLevel);
    return nav && nav.clearanceAt(point) < CreatureConfig.HunchBelow ? eyes.Hunched : eyes.Biped;
  }

  _lineClear(from, to) {
    return this.env.lineClear(from, to);
  }

  /** Could a player see the Creature with its root at `point` (its head or its chest): any clear line, any facing. */
  _visible(point) {
    const head = this._headLift(point);
    for (const player of this._playingPlayers()) {
      const eye = this._playerEye(player);
      if (!eye || eye.distanceTo(point) > SIGHT_RANGE_LIMIT) continue;
      for (const lift of [head, 0]) {
        if (this._lineClear(eye, new THREE.Vector3(point.x, point.y + lift, point.z))) return true;
      }
    }
    return false;
  }

  /**
   * Whether a player sees the Creature with its root at `point`: inside their view cone (Teleport.ViewHalfAngle of
   * their look) with a clear line to its head or its chest, or right at their eye.
   */
  _inViewOfAnyone(point) {
    const head = this._headLift(point);
    for (const player of this._playingPlayers()) {
      const eye = this._playerEye(player);
      if (!eye) continue;
      const look = this._lookOf(player);
      for (const lift of [head, 0]) {
        const q = new THREE.Vector3(point.x, point.y + lift, point.z);
        const d = eye.distanceTo(q);
        if (d <= NEAR_EYE) return true;
        if (d > SIGHT_RANGE_LIMIT) continue;
        if (Perception.stareAngle(eye, look, q) <= T.ViewHalfAngle && this._lineClear(eye, q)) return true;
      }
    }
    return false;
  }

  /** The straight distance from `point` to the nearest playing player's root (Infinity with none). */
  _nearestPlayerDistanceTo(point) {
    let best = Infinity;
    for (const p of this._playingPlayers()) {
      const r = this._rootOf(p);
      if (r) best = Math.min(best, r.distanceTo(point));
    }
    return best;
  }

  _playerEyes() {
    const out = [];
    for (const p of this._playingPlayers()) {
      const eye = this._playerEye(p);
      if (eye) out.push(eye);
    }
    return out;
  }

  /** Root positions the Creature can stand at: every patrol waypoint. */
  _standingSpots(info) {
    return info.waypoints.map((w) => new THREE.Vector3(w.position.x, w.position.y + ROOT_HEIGHT, w.position.z));
  }

  /** Root positions over the whole floor: the waypoints, then the nav's lattice. */
  _landSpots(info) {
    const out = this._standingSpots(info);
    const nav = this._nav(info.levelId);
    if (nav) for (const s of nav.samplePoints(SAMPLE_SPACING)) out.push(new THREE.Vector3(s.position.x, s.position.y + ROOT_HEIGHT, s.position.z));
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

  /** The hiding spots of its level within `radius` of `point`: [{id, kind, front}]. */
  _hideSpotsNear(point, radius) {
    if (!this.creatureLevel) return [];
    return this.env.hideSpots(this.creatureLevel).filter((s) => s.front.position.distanceTo(point) <= radius);
  }

  _hideSpotFront(id) {
    if (!this.creatureLevel) return null;
    const spot = this.env.hideSpots(this.creatureLevel).find((s) => s.id === id);
    return spot ? spot.front : null;
  }

  /** Who hides in `spot` (the local player or a remote one), or null. */
  _hideSpotOccupant(spot) {
    if (this.env.hideSpotOccupied(spot)) return PLAYER;
    return this.roster().find((p) => p.lockerId && p.lockerId() === spot) || null;
  }

  /**
   * The bodies see each other: chest to chest (never a catch through a wall). `through` is the hiding spot a ReachIn
   * reaches into: its own door and shell are no wall (the catch tears its door off).
   */
  _bodyClear(player, through = null) {
    const root = this._rootOf(player);
    if (!root) return false;
    const here = this.body.getPosition();
    const a = new THREE.Vector3(here.x, here.y + 1, here.z);
    const b = new THREE.Vector3(root.x, root.y + 0.5, root.z);
    return through ? this.env.lineClear(a, b, { ignoreEntity: through }) : this._lineClear(a, b);
  }

  _record(player) {
    let r = this.records.get(player);
    if (!r) {
      r = { trail: [], trailAt: -Infinity, last: null, lastAt: 0, speed: 0, travel: null, stare: 0, hiding: false, life: null,
        loudAt: -Infinity };
      this.records.set(player, r);
    }
    return r;
  }

  /** The level the Creature is on holds this player (a room of it under their feet). */
  _onLevel(player) {
    const root = this._rootOf(player);
    const nav = this._nav(this.creatureLevel);
    if (!root || !nav) return false;
    const room = nav.roomAt(root);
    return !!room && Math.abs(root.y - PLAYER_FLOOR - room.floorY) < 8;
  }

  // ------------------------------------------------------------------ the view contract

  _setAction(name) {
    if (this.action === name && name !== null) return;
    this.action = name;
    this.actionAt = this.now();
  }

  /** How visible it is (the contract's fade): the warp's FadeOut / FadeIn ramps, 0 hidden, 1 shown. */
  _fade(t) {
    const w = this.warp;
    if (w) {
      if (w.phase === 'FadeOut') return clamp01(1 - (t - w.phaseAt) / T.FadeOutSeconds);
      if (w.phase === 'FadeIn') return clamp01((t - w.phaseAt) / T.FadeInSeconds);
      if (w.phase === 'Hidden' || w.phase === 'Warning') return 0;
    }
    return this.body.hidden ? 0 : 1;
  }

  _poseMode() {
    if (this.state === 'Stunned') return 'Stunned';
    if (this.body.pose === 'Hunched') return 'Hunched';
    return this.clearance < CreatureConfig.HunchBelow ? 'Hunched' : 'Biped';
  }

  /**
   * The fields the creature view animates (the R <-> A contract, see the header): {state, speed, poseMode, action,
   * actionStartedAt, fade}.
   */
  viewState() {
    return {
      state: this.state,
      speed: this.speedMeasured,
      poseMode: this._poseMode(),
      action: this.action,
      actionStartedAt: this.actionAt,
      fade: this._fade(this.now()),
    };
  }

  // ------------------------------------------------------------------ body placement

  _placeBody(cframe) {
    const b = this.body;
    const m = this.mover;
    if (!m) return;
    m.reset();
    b.face(null);
    b.setAnchored(true);
    b.placeAt(cframe);
    if (b.pose === 'Quadruped') b.setPose('Biped');
    this.clearance = this._headroom(cframe.position);
  }

  /** Hidden where it stands until nobody can see it there; then it fades in (a "Reveal" warp). */
  _hide() {
    this._startWarp({ kind: 'Reveal', startHidden: true, to: this.body.getCFrame(), pick: () => this._unseenSpot(0) });
  }

  _forgetMind() {
    const c = this.ctx;
    if (c) {
      c.target = null;
      c.memory = null;
      c.investigation = null;
      c.searchFrom = null;
      c.hiding = null;
      c.teleportPlan = null;
      c.heard = null;
      c.sightings = [];
      c.reposition = false;
      c.stateDone = false;
      c.hint = null;
      c.beatPlan = null;
      c.beatReached = false;
      c.beatDue = null;
      for (const k of Object.keys(c.heardZones)) delete c.heardZones[k];
    }
    this.noiseQueue = [];
    this.alerts = [];
    this.lastSeen.clear();
    this.records.clear();
    this.pulled.clear();
    this.hideWatch = null;
    this.stareTrigger = null;
    this.pendingReach = null;
    this.lookAway = null;
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
    this.env.setNavLevel(levelId);
    this._forgetMind();
    this._cancelWarp();
    let spawn = info ? info.spawn : null;
    if (!spawn && info && info.waypoints[0]) spawn = CFrame.at(this._standingSpots(info)[0]);
    if (spawn) this._placeBody(spawn);
    // concealed: it fades in once nobody can see it (a script holding it decides that itself)
    if (conceal) {
      if (this.scripted) this.body.setHidden(true);
      else this._hide();
    }
  }

  // ------------------------------------------------------------------ warps (FadeOut / FadeIn relocations)

  /**
   * Starts a warp: {kind: 'Teleport'|'GiveUp'|'Reveal', to?: CFrame, pick?: () => CFrame|null, warning?, stare?,
   * plan?, startHidden?}. The destination is `to`, else what `pick` returns (asked again when it stays in view).
   */
  _startWarp(opts) {
    const t = this.now();
    this.warp = {
      kind: opts.kind,
      phase: opts.startHidden ? 'Hidden' : 'FadeOut',
      phaseAt: t,
      startedAt: t,
      to: opts.to || null,
      pick: opts.pick || null,
      warning: !!opts.warning,
      stare: !!opts.stare,
      plan: opts.plan || null,
      retries: 0,
      placed: false,
      revealed: false,
      pickedAt: opts.to ? t : -Infinity,
    };
    this.lookAway = null;
    if (this.mover) this.mover.stop();
    if (opts.startHidden) {
      this.body.setHidden(true);
      this._setAction(null);
    } else {
      this.body.setHidden(false);
      this._setAction('FadeOut');
    }
  }

  _cancelWarp() {
    if (!this.warp) return;
    this.warp = null;
    if (this.action === 'FadeOut' || this.action === 'FadeIn' || this.action === 'Stare') this._setAction(null);
  }

  /** Whether the Creature may appear at `cframe` now: nobody sees the spot, nobody within MinStraight of it. */
  _clearToAppear(cframe, kind) {
    const p = cframe.position;
    if (this._nearestPlayerDistanceTo(p) < T.MinStraight) return false;
    if (kind === 'Teleport') return !this._inViewOfAnyone(p);
    return !this._visible(p);
  }

  /** One warp step (every motion tick). */
  _stepWarp(t) {
    const w = this.warp;
    if (!w) return;
    if (w.phase === 'FadeOut') {
      if (t - w.phaseAt < T.FadeOutSeconds) return;
      this.body.setHidden(true);
      this._setAction(null);
      w.phase = 'Hidden';
      w.phaseAt = t;
      return;
    }
    if (w.phase === 'Hidden') {
      if (!w.to) {
        // a destination: the warp's own pick (throttled), or once this has gone on too long any spot out of sight
        const late = t - w.startedAt > WARP_GIVE_UP;
        if (!late && w.pick && t - w.pickedAt >= WARP_WAIT) {
          w.to = w.pick();
          w.pickedAt = t;
        }
        if (!w.to && late && t - w.pickedAt >= 1) {
          w.to = this._unseenSpot(T.MinStraight);
          w.pickedAt = t;
          w.warning = false;
          w.stare = false;
        }
        if (!w.to) return;
        w.placed = false;
        w.phaseAt = t;
      }
      if (!w.placed) {
        this._placeBody(w.to);
        w.placed = true;
      }
      if (!this._clearToAppear(w.to, w.kind)) {
        // still watched there: another spot shortly
        if (t - w.phaseAt >= WARP_WAIT) w.to = null;
        return;
      }
      if (w.warning) {
        w.phase = 'Warning';
        w.phaseAt = t;
        const floor = w.to.position.clone();
        floor.y -= ROOT_HEIGHT;
        this.teleportWarning.fire(floor, w.plan ? w.plan.target : null, T.WarningSeconds);
        return;
      }
      this._beginFadeIn(t);
      return;
    }
    if (w.phase === 'Warning') {
      if (t - w.phaseAt < T.WarningSeconds) return;
      if (!this._clearToAppear(w.to, w.kind)) {
        // watched now: another spot (and another warning), or after Retries any spot out of sight, unannounced
        w.retries += 1;
        if (w.retries > T.Retries) {
          w.warning = false;
          w.stare = false;
          w.to = this._unseenSpot(T.MinStraight);
        } else {
          w.to = w.pick ? w.pick() : null;
        }
        w.pickedAt = t;
        w.placed = false;
        w.phase = 'Hidden';
        w.phaseAt = t;
        return;
      }
      this._beginFadeIn(t);
      return;
    }
    if (w.phase === 'FadeIn') {
      if (w.stare) this._checkReveal(w);
      if (t - w.phaseAt < T.FadeInSeconds) return;
      if (w.stare) {
        w.phase = 'Stare';
        w.phaseAt = t;
        this._setAction('Stare');
        return;
      }
      this._endWarp();
      return;
    }
    if (w.phase === 'Stare') {
      this._checkReveal(w);
      const target = w.plan ? w.plan.target : null;
      const root = target ? this._rootOf(target) : null;
      if (root) this.body.face(root.clone().sub(this.body.getPosition()));
      if (t - w.phaseAt >= T.StareSeconds || this.stareTrigger !== null) this._endWarp();
    }
  }

  _beginFadeIn(t) {
    const w = this.warp;
    this.body.setHidden(false);
    w.phase = 'FadeIn';
    w.phaseAt = t;
    this._setAction('FadeIn');
    const target = w.plan ? w.plan.target : null;
    const root = target ? this._rootOf(target) : null;
    if (root) this.body.face(root.clone().sub(this.body.getPosition()));
  }

  _endWarp() {
    const w = this.warp;
    this.warp = null;
    // the stare after a teleport: it has looked its target in the eye (a clear line within StalkSight)
    if (w && w.kind === 'Teleport' && w.stare && w.plan && w.plan.target) {
      const eye = this._playerEye(w.plan.target);
      const head = this._creatureEye();
      if (eye && eye.distanceTo(head) <= this.presence.Teleport.StalkSight && this._lineClear(head, eye)) {
        this.awareness.set(w.plan.target, 1);
      }
    }
    if (this.action === 'FadeIn' || this.action === 'Stare' || this.action === 'FadeOut') this._setAction(null);
    this.body.setHidden(false);
    if (this.mover) this.mover.reset();
    if (w && w.kind === 'Teleport') this.lastSeenAny = Math.max(this.lastSeenAny, this.now());
  }

  /** The target looks at it as it forms (within Stare.RevealHalfAngle, a clear line): their reveal scare, once. */
  _checkReveal(w) {
    if (w.revealed || !w.plan) return;
    const target = w.plan.target;
    const eye = this._playerEye(target);
    if (!eye || !this._playing(target)) return;
    const head = this._creatureEye();
    if (eye.distanceTo(head) > T.MaxWalk * 2) return;
    if (Perception.stareAngle(eye, this._lookOf(target), head) > CreatureConfig.Stare.RevealHalfAngle) return;
    if (!this._lineClear(eye, head)) return;
    w.revealed = true;
    this.revealed.fire(target, 'Teleport');
  }

  /** A root CFrame out of everyone's sight at least `minDistance` from them (nearest to it first), or null. */
  _unseenSpot(minDistance) {
    const info = this.ctx ? this.ctx.level : null;
    if (!info) return null;
    const here = this.body.getPosition();
    const point = repositionPoint(this._landSpots(info), this._playerEyes(), here, minDistance, Infinity,
      (p) => this._visible(p));
    if (!point) return null;
    const toward = this._nearestRoot(point);
    const facing = (toward && flatDirection(toward.clone().sub(point))) || flatDirection(this.body.getCFrame().lookVector) ||
      new THREE.Vector3(0, 0, -1);
    return CFrame.lookAt(point, point.clone().add(facing));
  }

  /** A chase that ran out: it fades out where it stands and comes back far from everyone, out of sight. */
  _giveUp(t) {
    const c = this.ctx;
    if (!c) return;
    const target = c.target;
    this.gaveUp.fire(target, this.body.getPosition().clone());
    this._setTarget(null);
    c.memory = null;
    c.reposition = false;
    const g = CreatureConfig.GiveUp;
    this._startWarp({
      kind: 'GiveUp',
      pick: () => {
        const info = c.level;
        if (!info) return null;
        const here = this.body.getPosition();
        const point = repositionPoint(this._landSpots(info), this._playerEyes(), here, g.MinDistance, g.MaxDistance,
          (p) => this._visible(p));
        return point ? CFrame.lookAt(point, point.clone().add(flatDirection(here.clone().sub(point)) || new THREE.Vector3(0, 0, -1))) : null;
      },
    });
    const [low] = difficultySpec(this.difficulty).teleportCooldown;
    this.teleportReadyAt = Math.max(this.teleportReadyAt, t + low / 2);
  }

  // ------------------------------------------------------------------ teleports

  /** The teleport is due now: every §2.3 condition holds and a plan (target, spot) exists (ctx.teleportPlan). */
  _teleportDue(t) {
    const c = this.ctx;
    const m = this.mover;
    if (!c || !m || !c.level || this.state !== 'Patrol' || this.warp) return false;
    if (t < this.teleportReadyAt || t < this.nextTeleportTry) return false;
    if (t - this.lastSeenAny < T.UnseenSeconds) return false;
    if (t < this.lastCatchAt + T.AfterCatch || t < this.lastDownAt + T.AfterCatch) return false;
    if (this.env.teleportBlocked()) return false;
    const plan = this._planTeleport();
    if (!plan) {
      this.nextTeleportTry = t + TELEPORT_RETRY;
      return false;
    }
    c.teleportPlan = plan;
    return true;
  }

  /** The players a teleport may go for: hunted, on its level, on foot (not hiding or in a duct). */
  _teleportTargets() {
    return this._huntablePlayers().filter((p) => !this._inVent(p) &&
      this._moveStateOf(p) !== 'Hiding' && this._onLevel(p));
  }

  /** The target (weighted) and the spot for a teleport, or null. */
  _planTeleport() {
    const c = this.ctx;
    const nav = this._nav(this.creatureLevel);
    if (!c || !nav) return null;
    const targets = this._teleportTargets();
    if (!targets.length) return null;
    const t = this.now();
    const weights = targets.map((p) => {
      const root = this._rootOf(p);
      let isolated = true;
      for (const other of this._playingPlayers()) {
        const r = other === p ? null : this._rootOf(other);
        if (r && root && r.distanceTo(root) <= T.Isolated) isolated = false;
      }
      if (this._playingPlayers().length < 2) isolated = false;
      const loud = t - this._record(p).loudAt <= T.LoudWindow;
      return Teleport.targetWeight({ isolated, loud, lastTarget: p === this.lastTeleportTarget });
    });
    const target = Teleport.pickWeighted(targets, weights, c.random.nextNumber());
    const spot = target ? this._teleportSpot(target, nav) : null;
    return spot ? { target, ...spot } : null;
  }

  /** The spot near `target` (§2.3 placement), or null. */
  _teleportSpot(target, nav) {
    const c = this.ctx;
    const root = this._rootOf(target);
    if (!c || !root) return null;
    const room = nav.roomAt(root);
    if (!room) return null;
    const feet = new THREE.Vector3(root.x, room.floorY, root.z);
    const keepRoom = TUNNEL_KINDS.has(room.kind) ? null : room.id;
    const rec = this._record(target);
    const trail = rec.trail.filter((e) => this.now() - e.t >= TRAIL_SKIP).map((e) => e.p);
    const look = this._lookOf(target);
    const candidates = this._teleportCandidates(nav);
    const buckets = { Behind: [], Ahead: [], Side: [] };
    // a target on the move is cut off ahead of where they will be when it may appear (they run on toward it through
    // the warning): CutOffMin..CutOffMax walked past the way they cover meanwhile
    const P = this.presence.Teleport;
    const lead = this._lead(target);
    const reach = lead > 0 ? Math.max(T.MaxWalk, P.CutOffMax + lead) : T.MaxWalk;
    for (const cand of candidates) {
      const p = cand.position;
      if (Math.abs(p.y - room.floorY) > 6) continue;
      if (horizontalDistance(p, root) > reach + 0.5) continue;
      if (keepRoom && cand.room === keepRoom) continue;
      const appear = new THREE.Vector3(p.x, p.y + ROOT_HEIGHT, p.z);
      if (this._nearestPlayerDistanceTo(appear) < T.MinStraight) continue;
      const walk = nav.pathLength(feet, p);
      if (walk < T.MinWalk || walk > reach) continue;
      const side = Teleport.classify(p, root, trail, look, rec.travel);
      if (lead > 0 && side === 'Ahead') {
        if (walk < P.CutOffMin + lead) continue;
      } else if (walk > T.MaxWalk) continue;
      if (this._inViewOfAnyone(appear)) continue;
      buckets[side].push({ appear, walk, lead: lead > 0 && side === 'Ahead' ? lead : 0 });
    }
    // ahead of the way they go first (the cut-off: turn, sidestep or hide), else behind them
    const cutOff = c.random.nextNumber() < this.presence.Teleport.CutOffShare;
    const order = cutOff ? ['Ahead', 'Side', 'Behind'] : ['Behind', 'Ahead', 'Side'];
    for (const kind of order) {
      const list = buckets[kind];
      if (!list.length) continue;
      const chosen = list[Math.floor(c.random.nextNumber() * list.length)];
      const facing = flatDirection(root.clone().sub(chosen.appear)) || new THREE.Vector3(0, 0, -1);
      return { spot: CFrame.lookAt(chosen.appear, chosen.appear.clone().add(facing)), side: kind, walk: chosen.walk,
        lead: chosen.lead };
    }
    return null;
  }

  /**
   * Teleport candidates: the tunnel maps' meta.teleportPoints[level] ({pos, facings, region, zone} on the tunnel
   * centrelines) when present, else the nav's lattice over today's rooms. [{position (floor), room}]
   */
  _teleportCandidates(nav) {
    const meta = this.env.meta();
    const level = this.creatureLevel;
    const own = meta.teleportPoints && Array.isArray(meta.teleportPoints[level]) ? meta.teleportPoints[level] : null;
    if (own && own.length) {
      if (!this.teleportPointCache || this.teleportPointCache.level !== level) {
        const list = [];
        for (const x of own) {
          if (!x || !Array.isArray(x.pos) || x.pos.length < 3) continue;
          const at = new THREE.Vector3(x.pos[0], x.pos[1], x.pos[2]);
          const room = nav.roomAt(at);
          if (!room) continue; // a crawlway, or off the walkable floor
          const zone = typeof x.zone === 'string' ? x.zone.split(':').pop() : null;
          list.push({ position: new THREE.Vector3(at.x, room.floorY, at.z), room: zone || room.id });
        }
        this.teleportPointCache = { level, list };
      }
      if (this.teleportPointCache.list.length) return this.teleportPointCache.list;
    }
    return nav.samplePoints(SAMPLE_SPACING);
  }

  /** Teleport.enter: the warp to the planned spot (FadeOut here, the warning there, FadeIn, the stare). */
  _startTeleport(plan) {
    const c = this.ctx;
    if (!c || !plan || this.warp) return false;
    const t = this.now();
    const [low, high] = difficultySpec(this.difficulty).teleportCooldown;
    this.teleportReadyAt = t + c.random.nextNumber(low, high);
    this.lastTeleportTarget = plan.target;
    this.teleports += 1;
    this._startWarp({
      kind: 'Teleport',
      to: plan.spot,
      warning: true,
      stare: true,
      plan,
      pick: () => {
        const nav = this._nav(this.creatureLevel);
        const again = nav && this._playing(plan.target) ? this._teleportSpot(plan.target, nav) : null;
        return again ? again.spot : null;
      },
    });
    return true;
  }

  /**
   * The director's approach (docs/MONSTER.md 15.3): a spot ApproachMin..ApproachMax walked from `target` (past their
   * lead, and only ahead, when they are on the move: _lead), at least Teleport.MinStraight from everyone and in nobody's
   * view; {target, spot, walk, side: 'Approach', lead} or null.
   */
  _planApproach(target) {
    const c = this.ctx;
    const nav = this._nav(this.creatureLevel);
    const root = target ? this._rootOf(target) : null;
    if (!c || !nav || !root) return null;
    const room = nav.roomAt(root);
    if (!room) return null;
    const D = this.presence.Director;
    const feet = new THREE.Vector3(root.x, room.floorY, root.z);
    // a target on the move is approached only ahead of their way (behind them they are gone before it has formed),
    // the band lying past the way they cover before it may appear
    const lead = this._lead(target);
    const way = this._wayOf(target);
    const leadOf = (p) => (lead > 0 && this._ahead(way, root, p) >= D.AheadDot ? lead : 0);
    const pool = [];
    for (const cand of this._teleportCandidates(nav)) {
      const p = cand.position;
      if (Math.abs(p.y - room.floorY) > 6) continue;
      if (lead > 0 && leadOf(p) === 0) continue;
      const flat = horizontalDistance(p, root);
      if (flat > D.ApproachMax + leadOf(p) || flat < T.MinStraight) continue;
      pool.push(p);
    }
    // ahead of the way they go first (they come upon it from afar), then nearest the band's middle; a seeded pick
    // among the first few that pass
    const mid = (D.ApproachMin + D.ApproachMax) / 2;
    const rank = (p) => (this._ahead(way, root, p) >= D.AheadDot ? 0 : FAR) +
      Math.abs(horizontalDistance(p, root) - mid - leadOf(p));
    pool.sort((a, b) => rank(a) - rank(b));
    const ok = [];
    for (const p of pool.slice(0, D.ApproachTries)) {
      const appear = new THREE.Vector3(p.x, p.y + ROOT_HEIGHT, p.z);
      if (this._nearestPlayerDistanceTo(appear) < T.MinStraight) continue;
      const walk = nav.pathLength(feet, p) - leadOf(p);
      if (walk < D.ApproachMin || walk > D.ApproachMax) continue;
      if (this._inViewOfAnyone(appear)) continue;
      ok.push({ appear, walk: walk + leadOf(p), lead: leadOf(p) });
    }
    if (!ok.length) return null;
    const chosen = ok[Math.floor(c.random.nextNumber() * Math.min(ok.length, 3))];
    // it forms facing away from them: an approach is heard and glimpsed, never a stare
    const facing = flatDirection(chosen.appear.clone().sub(root)) || new THREE.Vector3(0, 0, -1);
    return { target, spot: CFrame.lookAt(chosen.appear, chosen.appear.clone().add(facing)), walk: chosen.walk, side: 'Approach',
      lead: chosen.lead };
  }

  /** The approach teleport: the warp with the warning (lights, hiss, the target's torch), no stare; it patrols on. */
  _startApproach(plan) {
    if (!plan || this.warp) return false;
    this.approaches += 1;
    this._startWarp({
      kind: 'Teleport',
      to: plan.spot,
      warning: true,
      stare: false,
      plan,
      pick: () => {
        const again = this._playing(plan.target) ? this._planApproach(plan.target) : null;
        return again ? again.spot : null;
      },
    });
    return true;
  }

  /** Teleports to the nearest standing spot (>= UNSTICK_MIN away) nobody can see, only while nobody sees it here. */
  _relocateUnseen() {
    const c = this.ctx;
    const info = c ? c.level : null;
    if (!c || !info) return false;
    const here = this.body.getPosition();
    if (this._visible(here)) return false;
    const spots = this._standingSpots(info).filter((s) => s.distanceTo(here) >= UNSTICK_MIN);
    const point = repositionPoint(spots, this._playerEyes(), here, 0, Infinity, (p) => this._visible(p));
    if (!point) return false;
    const facing = flatDirection(this.body.getCFrame().lookVector) || new THREE.Vector3(0, 0, -1);
    this._placeBody(CFrame.lookAt(point, point.clone().add(facing)));
    this.unsticks += 1;
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
      reach: this.metrics.reach,
      targetInVent: this._inVent(player),
      lineClear: this._lineClear(this._creatureEye(), eye),
      bodyClear: this._bodyClear(player),
      playing: this._huntable(player),
      hiding: this._moveStateOf(player) === 'Hiding',
      canHunt: this._canHuntNow(),
      busy: this.catching !== null || this.jumpscare.isBusy(),
      hidden: this.body.hidden,
      stunned: this.now() < this.stunUntil,
      warping: this.warp !== null,
    });
  }

  /**
   * A catch's staging step (jumpscare.js facePair) from root `from` to `to`, cut short where its body (the walker's
   * radius) would meet the Monster geometry: the look's spacing eases it back from a close victim, and that step must
   * never put the root in or behind a wall (the rig's bow steps back the rest on screen).
   * @param {CFrame} from @param {CFrame} to @returns {CFrame}
   */
  _stageTo(from, to) {
    const a = from.position;
    const b = to.position;
    const length = Math.hypot(b.x - a.x, b.z - a.z);
    if (length < 1e-3) return to;
    const dir = new THREE.Vector3((b.x - a.x) / length, 0, (b.z - a.z) / length);
    let free = length;
    for (const lift of STAGE_LIFTS) {
      const hit = this.env.monsterRay(new THREE.Vector3(a.x, a.y + lift, a.z), dir, length + BODY_RADIUS);
      if (hit !== null) free = Math.min(free, Math.max(0, hit - BODY_RADIUS));
    }
    if (free >= length - 1e-3) return to;
    return to.withPosition(new THREE.Vector3(a.x + dir.x * free, b.y, a.z + dir.z * free));
  }

  _tryCatch(player, kind) {
    if (!this.mover || this.catching !== null || this.jumpscare.isBusy() || !this._canHuntNow()) return false;
    if (this._ignores(player) || this.now() < this.stunUntil || this.warp) return false;
    if (!this.jumpscare.catch(player, kind)) return false;
    this.catching = { player, kind, at: this.now() };
    this.lastCatchAt = this.now();
    this.mover.stop();
    this.lookAway = null;
    this._setAction('Jumpscare');
    this.caught.fire(player, kind);
    return true;
  }

  /** The ReachIn: the action now, the Locker catch ReachInLead later (if it still may). */
  _reachIn(player, spot) {
    if (this.pendingReach || this.catching) return;
    this.lookAway = null;
    this._setAction('ReachIn');
    this.pendingReach = { player, spot, at: this.now() + H.ReachInLead };
    this.feed.fire({ kind: 'ReachIn', player, spot, at: this.pendingReach.at });
  }

  _stepReach(t) {
    const r = this.pendingReach;
    if (!r || t < r.at) return;
    this.pendingReach = null;
    // never through a wall: nothing but the spot it reaches into stands between its chest and theirs
    const ok = this._playing(r.player) && this._bodyClear(r.player, r.spot) && this._tryCatch(r.player, 'Locker');
    if (!ok && this.action === 'ReachIn') this._setAction(null);
  }

  // ------------------------------------------------------------------ states

  _enterState(next, t) {
    const c = this.ctx;
    const previous = this.state;
    if (!c || next === previous) return;
    // the director's encounters: a chase on someone (as it starts and as it ends), a beat that reached its player
    const played = Brain.BEATS.has(previous) && c.beatPlan && c.beatReached ? c.beatPlan.target : null;
    this.current.exit(c, next);
    if (this.director) {
      if (played) this.director.encounter(played, t);
      if ((Brain.isChase(next) || Brain.isChase(previous)) && c.target) this.director.encounter(c.target, t);
    }
    if (Brain.BEATS.has(next)) this.beats += 1;
    // the back-off after a chase: its search over, a breather (Relax) and a withdraw
    if (previous === 'Search' && this.searchAfterChase && next === 'Patrol' && this.pacing) {
      this.pacing.noteBreather(t);
      c.reposition = true;
    }
    if (next === 'Search') this.searchAfterChase = Brain.isChase(previous) || previous === 'HidingResponse';
    if (Brain.isChase(next) && !Brain.isChase(previous)) {
      this.chaseStarted = t;
      this.chaseSeenAt = t;
      if (!this.body.hidden) this.env.play(SPOT_PRESET, { position: this._creatureEye(), volume: SPOT_VOLUME });
    } else if (!Brain.isChase(next)) {
      this.chaseStarted = null;
    }
    if (this.action === 'LookAway' || this.action === 'ReachIn') this._setAction(null);
    this.lookAway = null;
    this.state = next;
    this.stateSince = t;
    c.stateDone = false;
    this.current = STATES[next] || STATES.Patrol;
    this.current.enter(c, previous);
    this.stateChanged.fire(next, previous);
  }

  _bestSeen() {
    const c = this.ctx;
    return c && c.sightings.length ? c.sightings[0].player : null;
  }

  /** The target's last known place (and the way it saw them run, for the chase's pursuit). */
  _remember(player, position, t, travel = null) {
    const c = this.ctx;
    if (c && c.target === player) c.memory = { player, position: position.clone(), at: t, travel };
  }

  _transition(decision, t) {
    const c = this.ctx;
    if (!c) return;
    this.lastReason = decision.reason;
    if (decision.reposition) c.reposition = true;
    const next = decision.state;
    if (next === this.state) {
      if (next === 'WallChase' && this.stareTrigger && !this._sees(c.target)) this._chase(this.stareTrigger, t);
      return;
    }
    if (decision.giveUp) this._giveUp(t);
    if (next === 'WallChase') {
      const chosen = this.stareTrigger || (c.target && this._sees(c.target) ? c.target : this._bestSeen());
      this._chase(chosen, t);
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
    } else if (next === 'Search') {
      const watched = c.hiding;
      if (c.memory) c.searchFrom = this._floorPointNear(c.memory.position);
      else if (watched) c.searchFrom = HidingResponse.standPoint(watched.front);
      else c.searchFrom = this.body.getPosition().clone();
    } else if (next === 'HidingResponse') {
      c.hiding = this.hideWatch;
      this.hideWatch = null;
      if (c.hiding) {
        this._setTarget(c.hiding.player);
        const front = c.hiding.front.position;
        c.memory = { player: c.hiding.player, position: front.clone(), at: t };
      }
    }
    this._enterState(next, t);
  }

  _chase(player, t) {
    this._setTarget(player);
    const position = player ? this._rootOf(player) : null;
    if (player && position) this._remember(player, position, t);
    this.chaseSeenAt = t;
  }

  _updateTarget() {
    const c = this.ctx;
    if (!c) return;
    const target = c.target;
    if (this.state === 'WallChase') {
      if (!(target && this._sees(target))) {
        const other = this._bestSeen();
        if (other) this._setTarget(other);
      }
    } else if (this.state === 'Patrol' || this.state === 'InvestigateNoise' || this.state === 'Search') {
      const best = c.sightings[0];
      this._setTarget(best ? best.player : null);
    } else if (this.state !== 'HidingResponse' && this.state !== 'Teleport') {
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
      if (noise.rank >= LOUD_RANK) this._record(source).loudAt = t;
      this._remember(source, noise.position, t);
    }
    if (best === null || noise.rank > best.rank || (noise.rank === best.rank && noise.strength > best.strength)) return noise;
    return best;
  }

  /** Every player's trail, speed, life, hiding (the saw-you-hide rule) and stare. */
  _watchPlayers(t, dt) {
    const c = this.ctx;
    if (!c) return;
    const visible = !this.body.hidden && this._fade(t) >= 0.5;
    const head = this._creatureEye();
    const canStare = visible && this.awake && this.state !== 'Dormant' && this.state !== 'Scripted' &&
      this.state !== 'Stunned' && this.catching === null && this._canHuntNow();
    if (canStare) this.creatureLit = this.env.litAt(new THREE.Vector3(head.x, head.y - 2, head.z), CreatureConfig.Senses.LitIrradiance);
    for (const player of this._players()) {
      const r = this._record(player);
      const root = this._rootOf(player);
      const life = this._lifeOf(player);
      if (r.life !== null && r.life !== 'Downed' && life === 'Downed') this.lastDownAt = t;
      r.life = life;
      if (!root) {
        r.stare = 0;
        continue;
      }
      // speed and trail
      if (r.last) {
        const step = Math.hypot(root.x - r.last.x, root.z - r.last.z);
        const span = Math.max(1e-3, t - r.lastAt);
        const v = step < 12 ? step / span : 0;
        r.speed += (v - r.speed) * clamp01(dt * 6);
        if (step > 0.05 && step < 12) r.travel = new THREE.Vector3(root.x - r.last.x, 0, root.z - r.last.z).normalize();
        else if (r.speed < 0.5) r.travel = null;
      }
      r.last = root.clone();
      r.lastAt = t;
      if (t - r.trailAt >= TRAIL_EVERY) {
        r.trailAt = t;
        r.trail.push({ t, p: root.clone() });
        while (r.trail.length && t - r.trail[0].t > TRAIL_SECONDS) r.trail.shift();
      }
      // the saw-you-hide rule
      const hiding = this._moveStateOf(player) === 'Hiding';
      if (hiding && !r.hiding) this._noteHid(player, t);
      r.hiding = hiding;
      // the stare
      if (!canStare || hiding || !this._huntable(player) || this._inVent(player) || life !== 'Alive') {
        r.stare = 0;
        continue;
      }
      const eye = this._playerEye(player);
      const looker = { eye, look: this._lookOf(player), torch: this._torchOf(player) };
      if (eye && Perception.staring(looker, head, this.creatureLit, (a, b) => this._lineClear(a, b))) {
        r.stare += dt;
        if (r.stare >= CreatureConfig.Stare.Seconds && this.stareTrigger === null) {
          r.stare = 0;
          this.stareTrigger = player;
          this.lastSeenAny = t;
          this.stared.fire(player);
        }
      } else r.stare = 0;
    }
  }

  /** `player` just got into a hiding spot: it saw them do it when it saw them within Hiding.SeenWindow. */
  _noteHid(player, t) {
    const c = this.ctx;
    if (!c || !this.awake || this.warp || this.catching || this.scripted || t < this.stunUntil) return;
    if (this.state === 'Dormant' || this.state === 'Stunned' || this.state === 'HidingResponse') return;
    if (!this._huntable(player) || !this._canHuntNow()) return;
    const seenAt = this.lastSeen.get(player);
    if (seenAt === undefined || t - seenAt > H.SeenWindow) return;
    const spot = this._hideSpotOf(player);
    const front = spot ? this._hideSpotFront(spot) : null;
    if (!spot || !front) return;
    this.hideWatch = { player, spot, front, since: t };
  }

  /**
   * Noticing (docs/MONSTER.md 17.3): a player in sight fills their awareness by dt / NoticeSeconds x how far they stand
   * into its range past NoticeNear (at once within it); out of sight it drains at NoticeDecay a second.
   */
  _notice(sightings, dt) {
    const X = this.presence.Detection;
    const full = Perception.fullRange(this.difficulty);
    for (const player of this._players()) {
      const s = sightings.find((x) => x.player === player);
      const a = this.awareness.get(player) || 0;
      if (s) {
        const share = clamp01((s.distance - X.NoticeNear) / Math.max(1e-6, full - X.NoticeNear));
        const time = X.NoticeSeconds * share;
        this.awareness.set(player, time > 1e-6 ? Math.min(1, a + dt / time) : 1);
      } else if (a > 0) this.awareness.set(player, Math.max(0, a - X.NoticeDecay * dt));
    }
  }

  /** Whether it has noticed `player` (their awareness full). */
  _noticed(player) {
    return (this.awareness.get(player) || 0) >= 1;
  }

  _sense(t, dt) {
    const c = this.ctx;
    const m = this.mover;
    const p = this.pacing;
    if (!c || !m || !p) return;
    const blind = this.body.hidden || this.warp !== null || t < this.startleUntil;
    const viewer = {
      eye: this._creatureEye(),
      facing: this.lookAway || this.body.getCFrame().lookVector,
      blindPeripheral: this.lookAway !== null,
      stillDark: this.presence.Detection.StillDarkFactor,
      difficulty: this.difficulty,
      targetUserId: c.target ? c.target.userId : null,
      raycast: (a, b) => this._lineClear(a, b),
    };
    const observations = [];
    if (!blind) {
      for (const player of this._huntablePlayers()) {
        const eye = this._playerEye(player);
        if (!eye) continue;
        const life = this._lifeOf(player);
        const root = this._rootOf(player);
        observations.push({
          player,
          eye,
          playing: life === 'Alive' || life === 'Downed',
          downed: life === 'Downed',
          moveState: this._moveStateOf(player),
          torch: this._torchOf(player),
          lit: !!root && this.env.litAt(new THREE.Vector3(root.x, root.y + 1, root.z), CreatureConfig.Senses.LitIrradiance),
          moving: this._record(player).speed > CreatureConfig.Senses.MovingSpeed,
          inVent: this._inVent(player),
        });
      }
    }
    const sightings = Perception.scan(viewer, observations);
    c.sightings = sightings;
    this._notice(sightings, dt);
    if (sightings.length) this.lastSeenAny = t;
    for (const s of sightings) {
      this.lastSeen.set(s.player, t);
      if (s.player === c.target) this.chaseSeenAt = t;
      const position = this._rootOf(s.player);
      const rec = this._record(s.player);
      const running = rec.travel && rec.speed > CreatureConfig.Senses.MovingSpeed ? rec.travel.clone() : null;
      if (position) this._remember(s.player, position, t, running);
    }
    const listener = {
      position: this._creatureEye(),
      levelId: this.creatureLevel,
      inVent: false,
      ventNode: null,
      graph: c.graph,
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
      const source = this._playerByUserId(event.sourceUserId);
      if (source && this._ignores(source)) continue;
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
    if (!blind) {
      for (const glow of this._torchGlow(t, viewer)) {
        const room = c.level ? Brain.roomAt(c.level, glow.spot) : null;
        best = this._noteHeard({
          position: glow.spot, rank: GLOW_RANK, priority: 'Normal', medium: 'Air', kind: 'TorchGlow',
          sourceUserId: glow.player.userId, zoneId: room ? room.id : null, strength: 1, at: t,
        }, best, t);
      }
    }
    const pending = this.alerts;
    this.alerts = [];
    for (const alert of pending) best = this._noteHeard(alert, best, t);
    c.heard = best;
    for (const [zone, heard] of Object.entries(c.heardZones)) if (t - heard.at > HEARD_ZONE_TTL) delete c.heardZones[zone];
    for (const [player, at] of [...this.pulled]) if (t - at > PULL_MEMORY) this.pulled.delete(player);
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
    const p = this.pacing;
    const devHunt = t < this.devHuntUntil;
    // a sighting starts a chase once it has noticed them (always while it hunts them already)
    const hunting = Brain.isChase(this.state) || this.state === 'HidingResponse';
    let sees = c.sightings.some((s) => hunting || this._noticed(s.player));
    // the stalk after a teleport: a player it has noticed within StalkSight is chased
    if (this.state === 'Teleport' && Teleport.stalking(c)) {
      sees = c.sightings.some((s) => s.distance <= this.presence.Teleport.StalkSight && this._noticed(s.player));
    }
    // a beat plays to be seen: only a player within Beats.Near (or a stare) starts a chase; a player who comes within
    // Beats.BreakOff (straight) ends it, and it withdraws
    if (Brain.BEATS.has(this.state) && this.state !== 'PassBy') {
      sees = c.sightings.some((s) => s.distance <= this.presence.Beats.Near);
      if (!c.stateDone && this._nearestPlayerDistanceTo(this.body.getPosition()) < this.presence.Beats.BreakOff) {
        c.stateDone = true;
        c.reposition = true;
      }
    }
    const chaseSeconds = this.chaseStarted !== null ? t - this.chaseStarted : 0;
    const canHunt = devHunt || p.canHunt(t);
    /** @type {import('./brain.js').Summary} */
    const summary = {
      state: this.state,
      elapsed: t - this.stateSince,
      scripted: this.scripted !== null,
      stunned: t < this.stunUntil,
      awake: this.awake,
      catching: this.catching !== null || this.pendingReach !== null,
      warping: this.warp !== null,
      canHunt,
      sees,
      stared: this.stareTrigger !== null,
      hidingWatch: this.hideWatch !== null,
      heard: c.heard ? c.heard.rank : 0,
      investigating: c.investigation && this.state === 'InvestigateNoise' ? c.investigation.rank : 0,
      chaseSeconds: devHunt ? 0 : chaseSeconds,
      // the loss clock waits while it runs to the last place it saw them and on along their way
      lostSeconds: this.state === 'WallChase' && !WallChase.running(c) ? t - this.chaseSeenAt : 0,
      maxChase: this.presence.Chase.CapSeconds,
      chaseLost: this.presence.Chase.LostSeconds,
      teleportDue: false,
      beatDue: c.beatDue,
      stateDone: c.stateDone,
    };
    c.beatDue = null;
    if (this.state === 'Patrol' && canHunt && this.awake && !summary.sees && !summary.stared && !summary.hidingWatch &&
      !summary.heard && !summary.catching && !summary.warping && !summary.stunned && !summary.scripted) {
      summary.teleportDue = this._teleportDue(t);
    }
    return summary;
  }

  // ------------------------------------------------------------------ the director (docs/MONSTER.md 15)

  /** Its feet: the floor under its root. */
  _feet() {
    const p = this.body.getPosition();
    return new THREE.Vector3(p.x, p.y - ROOT_HEIGHT, p.z);
  }

  /** A player's feet on its nav (their room's floor), or null. */
  _playerFeet(player) {
    const root = this._rootOf(player);
    const nav = this._nav(this.creatureLevel);
    if (!root || !nav) return null;
    const room = nav.roomAt(root) || nav.nearestRoom(root);
    return new THREE.Vector3(root.x, room ? room.floorY : root.y - PLAYER_FLOOR, root.z);
  }

  /** Whether `player` sees it now: shown, within Director.SeenRange, inside SeenHalfAngle of their look, a clear line. */
  _seenBy(player) {
    const D = this.presence.Director;
    if (this.body.hidden || this._fade(this.now()) < 0.5) return false;
    const eye = this._playerEye(player);
    if (!eye || this._moveStateOf(player) === 'Hiding' || this._inVent(player)) return false;
    const look = this._lookOf(player);
    const cone = Math.cos((D.SeenHalfAngle * Math.PI) / 180);
    for (const q of [this._creatureEye(), this.body.getPosition()]) {
      const dx = q.x - eye.x;
      const dz = q.z - eye.z;
      if (Math.hypot(dx, q.y - eye.y, dz) > D.SeenRange) continue;
      const fl = Math.hypot(look.x, look.z);
      const d = Math.hypot(dx, dz);
      if (fl < 1e-6 || d < 1e-6) continue;
      if ((look.x * dx + look.z * dz) / (fl * d) < cone) continue;
      if (this._lineClear(eye, q)) return true;
    }
    return false;
  }

  /**
   * Once a Director.Interval: every player's walking distance and menace; then, while it patrols, may hunt and has
   * nobody in sight or earshot, the focus player's order: a beat (ctx.beatDue, ctx.beatPlan), a search hint (ctx.hint,
   * an approach teleport first when the walk there is longer than ApproachWalk) or nothing.
   */
  _direct(t) {
    const c = this.ctx;
    const d = this.director;
    const nav = this._nav(this.creatureLevel);
    if (!c || !d || !nav || !c.level || !this.awake || this.scripted || t < this.directAt) return;
    const D = this.presence.Director;
    this.directAt = t + D.Interval;
    const feet = this._feet();
    const readings = [];
    const candidates = [];
    for (const player of this._huntablePlayers()) {
      if (!this._onLevel(player)) continue;
      const at = this._playerFeet(player);
      const walk = at ? nav.pathLength(feet, at) : Infinity;
      this.walks.set(player, walk);
      const sees = this._seenBy(player);
      readings.push({ player, walk, sees, chased: this.state === 'WallChase' && c.target === player });
      // a beat reaches its player once they see it or it comes within Beats.ReachWalk walked of them
      if (Brain.BEATS.has(this.state) && c.beatPlan && c.beatPlan.target === player &&
        (sees || walk <= this.presence.Beats.ReachWalk)) c.beatReached = true;
      if (this._moveStateOf(player) !== 'Hiding' && !this._inVent(player)) candidates.push(player);
    }
    d.update(t, D.Interval, readings);
    const focus = d.focus(t, candidates);
    if (!focus || this.state !== 'Patrol' || this.warp || !this._canHuntNow() || c.sightings.length > 0 || c.heard) return;
    const walk = this.walks.get(focus);
    const order = d.order(t, focus, walk);
    if (order === 'Beat') {
      const plan = this._planBeat(focus, walk);
      d.beat(t, plan !== null);
      if (plan) {
        c.beatPlan = plan;
        c.beatReached = false;
        c.beatDue = plan.kind;
        c.hint = null;
      }
    } else if (order === 'Hint') this._hint(focus, t);
  }

  /** The director's search hint for `player` (and the approach teleport when the walk there is too long). */
  _hint(player, t) {
    const c = this.ctx;
    const d = this.director;
    const D = this.presence.Director;
    const nav = this._nav(this.creatureLevel);
    const at = this._playerFeet(player);
    d.hinted(t);
    if (!c || !nav || !at) return;
    const here = this._feet();
    const reachable = nav.reachable(here);
    const way = this._wayOf(player);
    const pool = nav.samplePoints(SAMPLE_SPACING).map((x) => x.position).filter((p) => Math.abs(p.y - at.y) < 6 &&
      horizontalDistance(p, at) >= D.HintMin * 0.5 && horizontalDistance(p, at) <= D.HintMax);
    const rank = (p) => (this._ahead(way, at, p) >= D.AheadDot ? 0 : FAR) + horizontalDistance(p, here);
    pool.sort((a, b) => rank(a) - rank(b));
    let point = null;
    for (const p of pool.slice(0, D.HintTries)) {
      const walk = nav.pathLength(at, p);
      if (walk < D.HintMin || walk > D.HintMax || !reachable(p)) continue;
      if (this._inViewOfAnyone(new THREE.Vector3(p.x, p.y + ROOT_HEIGHT, p.z))) continue;
      point = p.clone();
      break;
    }
    if (!point) return;
    const far = nav.pathLength(here, point);
    if (far > D.ApproachWalk && d.approachReady(t) && this._approachAllowed(t)) {
      const plan = this._planApproach(player);
      if (plan && this._startApproach(plan)) d.approached(t);
    }
    c.hint = { point, player, at: t };
  }

  /**
   * How far a player on the move gets before a warp planned now may appear (its FadeOut and Warning): their speed x
   * that time; 0 for one who is not moving.
   */
  _lead(player) {
    const rec = this._record(player);
    if (!rec.travel || rec.speed <= CreatureConfig.Senses.MovingSpeed) return 0;
    return rec.speed * (T.FadeOutSeconds + T.WarningSeconds);
  }

  /** The way a player goes (their travel), else the way they look (flat, unit), or null. */
  _wayOf(player) {
    const rec = this._record(player);
    return rec.travel ? rec.travel.clone() : flatDirection(this._lookOf(player));
  }

  /** The cosine between `way` and the flat way from `from` to `p` (0 without a way). */
  _ahead(way, from, p) {
    const d = horizontalDistance(p, from);
    if (!way || d < 1e-6) return 0;
    return ((p.x - from.x) * way.x + (p.z - from.z) * way.z) / d;
  }

  /** The teleport's gates for an approach: past the floor's grace, not right after a catch or a fall, not blocked. */
  _approachAllowed(t) {
    if (t < this.graceEndsAt) return false;
    if (t < this.lastCatchAt + T.AfterCatch || t < this.lastDownAt + T.AfterCatch) return false;
    return !this.env.teleportBlocked();
  }

  /** A presence beat for `player` (beats.js; `beats`: the Beats numbers, the dev's one-beat weights), or null. */
  _planBeat(player, walk, beats = this.presence.Beats) {
    const c = this.ctx;
    const nav = this._nav(this.creatureLevel);
    if (!c || !nav) return null;
    const viewers = [];
    for (const p of this._playingPlayers()) {
      if (!this._onLevel(p)) continue;
      const eye = this._playerEye(p);
      const feet = this._playerFeet(p);
      if (!eye || !feet) continue;
      const rec = this._record(p);
      const facing = flatDirection(this._lookOf(p)) || new THREE.Vector3(0, 0, -1);
      viewers.push({ player: p, eye, feet, facing, travel: rec.travel ? rec.travel.clone() : null, speed: rec.speed });
    }
    const viewer = viewers.find((v) => v.player === player);
    if (!viewer) return null;
    const B = beats;
    const D = this.presence.Director;
    const level = this.creatureLevel;
    const headAt = (floor) => {
      const root = new THREE.Vector3(floor.x, floor.y + ROOT_HEIGHT, floor.z);
      return root.setY(root.y + this._headLift(root));
    };
    const geo = {
      samples: nav.samplePoints(SAMPLE_SPACING).map((x) => x.position),
      from: this._feet(),
      walk: (a, b) => nav.pathLength(a, b),
      seen: (floor) => this._visible(new THREE.Vector3(floor.x, floor.y + ROOT_HEIGHT, floor.z)),
      headSeenBy: (v, floor) => {
        const head = headAt(floor);
        return v.eye.distanceTo(head) <= D.SeenRange && this._lineClear(v.eye, head);
      },
      viewers,
      hideWalk: (feet) => {
        let best = Infinity;
        for (const spot of this.env.hideSpots(level)) {
          const front = spot.front.position;
          if (horizontalDistance(front, feet) > B.HideWalk || Math.abs(front.y - feet.y) > 6) continue;
          best = Math.min(best, nav.pathLength(feet, front));
        }
        return best;
      },
      cornered: (feet) => nav.waysOut(feet) < 2,
      roll: () => c.random.nextNumber(),
    };
    return planBeat(geo, B, viewer, walk);
  }

  /**
   * Where its pursuit runs on to: of the floor points within 0.6 x Chase.Pursuit of the point Chase.Pursuit along their
   * travel from the last seen point, the farthest along it (less half its distance off that point) that it can walk to
   * within 1.5 x Chase.Pursuit; null when none.
   */
  _pursuitPoint(memory) {
    const nav = this._nav(this.creatureLevel);
    if (!nav || !memory || !memory.travel) return null;
    const from = memory.position;
    const room = nav.roomAt(from) || nav.nearestRoom(from);
    const start = new THREE.Vector3(from.x, room ? room.floorY : from.y, from.z);
    const reach = this.presence.Chase.Pursuit;
    const ahead = start.clone().addScaledVector(memory.travel, reach);
    const ranked = [];
    for (const x of nav.samplePoints(SAMPLE_SPACING)) {
      const p = x.position;
      if (Math.abs(p.y - start.y) > 6 || horizontalDistance(p, ahead) > reach * 0.6) continue;
      const along = (p.x - start.x) * memory.travel.x + (p.z - start.z) * memory.travel.z;
      if (along > SAMPLE_SPACING) ranked.push({ p, score: along - horizontalDistance(p, ahead) * 0.5 });
    }
    ranked.sort((a, b) => b.score - a.score);
    for (const r of ranked.slice(0, PURSUIT_TRIES)) {
      if (nav.pathLength(start, r.p) <= reach * 1.5) return r.p.clone();
    }
    return null;
  }

  /**
   * The torch's glow (docs/MONSTER.md 17): every Detection.GlowEvery, each lit torch it does not see its holder by: the
   * spot the beam lights (Detection.Beam ahead of their eye, or the first surface) seen from its eye inside its cone,
   * within Detection.GlowRange (x the difficulty's sight multiplier), with a clear line: [{player, spot}].
   */
  _torchGlow(t, viewer) {
    const c = this.ctx;
    const X = this.presence.Detection;
    const out = [];
    for (const player of this._huntablePlayers()) {
      if (!this._torchOf(player) || this._moveStateOf(player) === 'Hiding' || this._inVent(player)) continue;
      if (c.sightings.some((s) => s.player === player)) continue;
      if (t - (this.glowAt.get(player) ?? -Infinity) < X.GlowEvery) continue;
      this.glowAt.set(player, t);
      const eye = this._playerEye(player);
      const look = this._lookOf(player);
      if (!eye || look.lengthSq() < 1e-6) continue;
      const dir = look.clone().normalize();
      const hit = this.env.monsterRay(eye, dir, X.Beam);
      const spot = eye.clone().addScaledVector(dir, Math.max(0, (hit ?? X.Beam) - GLOW_LIFT));
      const range = X.GlowRange * difficultySpec(this.difficulty).sightRangeMultiplier;
      if (spot.distanceTo(viewer.eye) > range) continue;
      if (!Perception.inViewCone(viewer.eye, viewer.facing, spot, CreatureConfig.Senses.SightHalfAngle, 0)) continue;
      if (!this._lineClear(viewer.eye, spot)) continue;
      out.push({ player, spot });
    }
    return out;
  }

  // ------------------------------------------------------------------ upkeep

  /** A mover that stalled for good is moved unseen to a standing spot; the state restarts. */
  _handleMover() {
    const m = this.mover;
    const c = this.ctx;
    if (!m || !c) return;
    if (m.getStatus() !== 'Stuck') return;
    // moved, a state starts over; a beat, a teleport's stalk or a hiding watch (its plan tied to where it stood:
    // entered again, the teleport would replay its warp and warning at the same spot, the watch walk back into the
    // same stall for as long as the hider stays in) is over
    if (this._relocateUnseen()) {
      if (Brain.BEATS.has(this.state) || this.state === 'Teleport' || this.state === 'HidingResponse') c.stateDone = true;
      else this.current.enter(c, this.state);
    } else m.reset();
  }

  _settleCatch(outcome) {
    const c = this.ctx;
    const m = this.mover;
    const p = this.pacing;
    const active = this.catching;
    this.catching = null;
    if (this.action === 'Jumpscare' || this.action === 'ReachIn') this._setAction(null);
    if (!c || !m || !p || !active) return;
    m.reset();
    const t = this.now();
    if (outcome !== 'Aborted') {
      p.noteCatch(t);
      this.lastCatchAt = t;
    }
    if (this.director) this.director.encounter(active.player, t, outcome !== 'Aborted');
    this.devHuntUntil = 0;
    c.reposition = true;
    if (c.target === active.player) {
      this._setTarget(null);
      c.memory = null;
    }
  }

  // ------------------------------------------------------------------ brain tick + motion

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
    this._stepReach(t);
    if (this.scripted) {
      this.noiseQueue = [];
      this.alerts = [];
      return;
    }
    this._watchPlayers(t, dt);
    this._sense(t, dt);
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
    this._direct(t);
    const summary = this._summarize(t);
    c.canHunt = summary.canHunt;
    this._transition(Brain.decide(summary), t);
    this._updateTarget();
    this.stareTrigger = null;
    if (this.hideWatch && this.state !== 'HidingResponse' && t - this.hideWatch.since > H.SeenWindow) this.hideWatch = null;
    if (this.catching === null && this.pendingReach === null && this.warp === null) {
      this._handleMover();
      this.current.update(c, dt);
    }
  }

  /** One movement step (nothing moves while a catch runs). @param {number} dt */
  stepMotion(dt) {
    const m = this.mover;
    if (!(this.running && m) || this.paused) return;
    const t = this.now();
    if (this.catching === null && this.scripted === null) this._stepWarp(t);
    // it stands still while it fades out, is gone, or forms (a warp), and while a catch plays
    if (this.catching === null && this.warp === null) {
      m.step(dt);
      this.body.stepPhysics(dt);
    }
    // the contract's speed (a teleport reads as still) and the head room (Hunched under a low lintel)
    const root = this.body.getPosition();
    if (this.lastRoot && this.body.placements === this.lastPlacements && dt > 0) {
      const v = Math.hypot(root.x - this.lastRoot.x, root.z - this.lastRoot.z) / dt;
      this.speedMeasured += (v - this.speedMeasured) * clamp01(dt * SPEED_DAMP);
    } else this.speedMeasured = 0;
    if (this.speedMeasured < 0.05) this.speedMeasured = 0;
    this.lastRoot = root.clone();
    this.lastPlacements = this.body.placements;
    this.clearance = this._headroom(root);
  }

  /**
   * The head room it walks under (the contract's poseMode, and its eye, hunch below CreatureConfig.HunchBelow): the
   * lowest nav clearance at its root and along its planned route, HEAD_LEAD + its pace x HUNCH_LEAD_SECONDS ahead
   * (FloorNav.headroomAlong, the rule a co-op client's puppet shares), so it is down before its head reaches a lintel or
   * a tunnel's ceiling. Infinity off the floor.
   */
  _headroom(root) {
    const m = this.mover;
    const nav = m ? this._nav(this.creatureLevel) : null;
    if (!nav) return Infinity;
    return nav.headroomAlong(root, m.routeAhead(), this.body.walkSpeed);
  }

  /** The 30 Hz game tick: the catch, motion every tick, the brain at ServerTickHz. @param {number} dt */
  tick(dt) {
    if (!this.running) {
      this.accumulated = 0;
      return;
    }
    this.jumpscare.update();
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
      searchFrom: null,
      hiding: null,
      teleportPlan: null,
      reposition: false,
      stateDone: false,
      stunFrom: null,
      speedOf: (name) => {
        const base = Brain.speedFor(name, this.difficulty);
        return name === 'Scripted' ? base : Math.min(CreatureConfig.SpeedCap, base * this.speedScale);
      },
      setTarget: (player) => this._setTarget(player),
      catchKind: (player) => this._catchKindFor(player),
      tryCatch: (player, kind) => this._tryCatch(player, kind),
      reachIn: (player, spot) => this._reachIn(player, spot),
      visible: (point) => this._visible(point),
      reachable: () => this._reachableTest(),
      repositionPoint: (minDistance, maxDistance) => {
        const info = this.ctx ? this.ctx.level : null;
        if (!info) return null;
        return repositionPoint(this._standingSpots(info), this._playerEyes(), this.body.getPosition(), minDistance,
          maxDistance, (p) => this._visible(p));
      },
      playerPositions: () => this._playerEyes(),
      lockerInspector: () => (this.lockerInspector ? (spot) => {
        this.feed.fire({ kind: 'Sniff', spot });
        return this.lockerInspector(spot);
      } : null),
      inVent: (player) => this._inVent(player),
      playing: (player) => this._huntable(player),
      isHiding: (player) => this._moveStateOf(player) === 'Hiding',
      hideSpotOf: (player) => this._hideSpotOf(player),
      hideSpotsNear: (point, radius) => this._hideSpotsNear(point, radius),
      hideSpotOccupant: (spot) => this._hideSpotOccupant(spot),
      hideSpotFront: (spot) => this._hideSpotFront(spot),
      pulledOut: (player) => this.pulled.has(player),
      bodyClear: (player) => this._bodyClear(player),
      rootOf: (player) => this._rootOf(player),
      floorPointNear: (p) => this._floorPointNear(p),
      lineClear: (a, b) => this._lineClear(a, b),
      setLookAway: (direction) => {
        this.lookAway = direction ? direction.clone() : null;
        if (direction) this._setAction('LookAway');
        else if (this.action === 'LookAway') this._setAction(null);
      },
      lookAwayDirection: (front) => this._lookAwayDirection(front),
      grunt: () => {
        const at = this._creatureEye();
        env.play(GRUNT_PRESET, { position: at, volume: 1 });
        this.grunted.fire(at.clone());
      },
      startTeleport: (plan) => this._startTeleport(plan),
      warping: () => this.warp !== null,
      creatureEye: () => this._creatureEye(),
      playerEye: (player) => this._playerEye(player),
      presence: this.presence,
      hint: null,
      beatPlan: null,
      beatReached: false,
      beatDue: null,
      patrolNear: () => {
        const toward = this.director ? this.director.leaning() : null;
        return toward && this._playing(toward) ? this._playerFeet(toward) : null;
      },
      paceOf: (base) => Math.min(CreatureConfig.SpeedCap,
        base * difficultySpec(this.difficulty).creatureSpeedMultiplier * this.speedScale),
      lookedAt: (player, degrees) => {
        const eye = this._playerEye(player);
        const head = this._creatureEye();
        if (!eye || eye.distanceTo(head) > this.presence.Director.SeenRange) return false;
        return Perception.stareAngle(eye, this._lookOf(player), head) <= degrees && this._lineClear(eye, head);
      },
      walkTo: (player) => {
        const nav = this._nav(this.creatureLevel);
        const at = this._playerFeet(player);
        return nav && at ? nav.pathLength(this._feet(), at) : Infinity;
      },
      trailOf: (player) => this._record(player).trail.map((e) => e.p),
      speedOfPlayer: (player) => this._record(player).speed,
      pursuitPoint: (memory) => this._pursuitPoint(memory),
    };
    return ctx;
  }

  /**
   * Which points it can walk to from where it stands now (through the portals open now): a test (point) => boolean,
   * or null without a floor to walk.
   */
  _reachableTest() {
    const nav = this.mover ? this._nav(this.creatureLevel) : null;
    return nav ? nav.reachable(this.body.getPosition()) : null;
  }

  /** Down the tunnel, away from the spot it watches: the more open of its two sides (a level-headed look). */
  _lookAwayDirection(front) {
    const facing = new THREE.Vector3(-front.lookVector.x, 0, -front.lookVector.z);
    if (facing.lengthSq() < 1e-6) facing.set(0, 0, -1);
    facing.normalize();
    const left = new THREE.Vector3(-facing.z, 0, facing.x);
    const right = left.clone().negate();
    const eye = this._creatureEye();
    const reach = (dir) => {
      let d = 0;
      for (const step of [4, 8, 12, 16]) {
        if (!this._lineClear(eye, eye.clone().addScaledVector(dir, step))) break;
        d = step;
      }
      return d;
    };
    const l = reach(left);
    const r = reach(right);
    // turned well away: down the tunnel and a little back, so the spot it watches is out of its eyes
    const side = l >= r ? left : right;
    return side.addScaledVector(facing, -0.35).normalize();
  }

  /** Takes over the Creature for the run: placed at its level's CreatureSpawn, Dormant until that level activates. */
  _attach(levelId) {
    this.mover = new Mover(this.body, {
      computePath: (from, to) => {
        const nav = this._nav(this.creatureLevel);
        return nav ? nav.computePath(from, to) : null;
      },
      clear: (from, to) => this.env.monsterClear(from, to),
    }, () => this.now());
    this.ctx = this._newContext();
    const fallback = levelId && levelIndex(levelId) >= 1 ? levelId : LEVEL_ORDER[0];
    this.state = 'Dormant';
    this.current = STATES.Dormant;
    this.stateSince = this.now();
    this.lastReason = 'placed';
    this.awake = false;
    this.wakeAt = null;
    this.warp = null;
    this.action = null;
    this.body.setHidden(false);
    this._relocate(fallback, false);
    Dormant.enter(this.ctx);
  }

  // ------------------------------------------------------------------ run + levels

  /** The difficulty the next run starts on (the lobby's choice). */
  setDifficulty(name) {
    this.difficulty = name === 'Nightmare' ? 'Nightmare' : 'Standard';
  }

  /** Starts a run (BeginRun): the Creature is placed Dormant at `startLevel`'s spawn (the basement's by default). */
  beginRun(opts = {}) {
    this.running = true;
    this.difficulty = (opts.difficulty ?? this.difficulty) === 'Nightmare' ? 'Nightmare' : 'Standard';
    this.presence = presenceConfig(this.env.meta(), this.difficulty);
    this.director = new Director(this.presence.Director);
    this.director.reset(this.now());
    this.directAt = 0;
    this.approaches = 0;
    this.beats = 0;
    this.walks.clear();
    this.glowAt.clear();
    this.awareness.clear();
    this.pacing = new Pacing(this.difficulty, this.now(), this.presence.Chase.CapSeconds, this.presence.Chase.Breather);
    this.paused = false;
    this.stunUntil = 0;
    this.devHuntUntil = 0;
    this.catching = null;
    this.graceUntil.clear();
    this.pendingReach = null;
    this.scripted = null;
    this.accumulated = 0;
    this.lastCatchAt = -Infinity;
    this.lastDownAt = -Infinity;
    this.teleportReadyAt = Infinity;
    this.teleports = 0;
    this.lastTeleportTarget = null;
    this.startleUntil = -Infinity;
    this._attach(opts.level || null);
  }

  /** Ends the run (EndRun): the catch is called off, the Creature stops and is hidden. */
  endRun() {
    if (this.catching || this.jumpscare.isBusy()) this.jumpscare.abort('RunEnded');
    if (this.jumpscareView) this.jumpscareView.end();
    this.running = false;
    this.scripted = null;
    this.catching = null;
    this._forgetMind();
    this.warp = null;
    this.action = null;
    this.mover = null;
    this.ctx = null;
    this.creatureLevel = null;
    this.pacing = null;
    this.director = null;
    this.state = 'Dormant';
    this.current = STATES.Dormant;
    this.awake = false;
    this.wakeAt = null;
    this.paused = false;
    this.speedScale = 1;
    this.lastSeen.clear();
    this.body.setHidden(true);
    this.env.setNavLevel(null);
  }

  /** LevelDirector.LevelActivated: grace, relocate hidden to the level's spawn when elsewhere, wake after WakeDelay. */
  activateLevel(levelId) {
    if (!this.running) this.beginRun({ difficulty: this.difficulty, level: levelId });
    const p = this.pacing;
    const c = this.ctx;
    if (!p || !c || levelIndex(levelId) < 1) return;
    const t = this.now();
    p.noteAirlock(t);
    if (this.catching) this.jumpscare.abort('Level');
    this.stunUntil = 0;
    this.pendingReach = null;
    if (this.creatureLevel !== levelId) this._relocate(levelId, true);
    else this._forgetMind();
    this.awake = false;
    this.wakeAt = t + WAKE_DELAY;
    this.lastSeenAny = t;
    this.graceEndsAt = t + (CreatureConfig.FloorGrace[this.difficulty] ?? CreatureConfig.FloorGrace.Standard);
    this.teleportReadyAt = this.graceEndsAt + T.FirstAfterGrace;
    this.nextTeleportTry = 0;
    this.director.reset(t);
    this.directAt = 0;
    this.walks.clear();
    this.lastReason = `level ${levelId} activated`;
    if (!this.scripted) this._enterState('Dormant', t);
  }

  // ------------------------------------------------------------------ public API

  getState() {
    return this.state;
  }

  getTarget() {
    return this._publishedTarget();
  }

  /**
   * The player it is after, as the game is told (getTarget, the snapshot): its target, else, while it peeks at,
   * crosses before or follows someone (Peek, Glimpse, Shadow), that beat's player (the "Followed" hint, its look).
   */
  _publishedTarget() {
    const c = this.ctx;
    if (!c) return null;
    if (c.target) return c.target;
    return FOLLOWING_BEATS.has(this.state) && c.beatPlan ? c.beatPlan.target : null;
  }

  _applyStun(seconds, from) {
    const c = this.ctx;
    if (!c) return;
    const t = this.now();
    this.stunUntil = Math.max(this.stunUntil, t + Math.max(0, seconds));
    c.stunFrom = from.clone();
    this.feed.fire({ kind: 'Stun', seconds, from: from.clone() });
    this._setTarget(null);
    this.pendingReach = null;
    this.lookAway = null;
    if (this.action === 'LookAway' || this.action === 'ReachIn') this._setAction(null);
    this.env.play(STUN_PRESET, { position: this._creatureEye() });
    if (this.state === 'Stunned') Stunned.retreat(c);
    else this._enterState('Stunned', t);
  }

  /** Blinded for `seconds`, stumbling back away from `from`. A catch in progress is called off; not while held / asleep. */
  stun(seconds, from) {
    if (!(this.running && this.ctx) || this.scripted || !this.awake || this.body.hidden) return;
    if (!isFiniteNumber(seconds) || !isFiniteVector(from)) return;
    if (this.catching) {
      this.jumpscare.abort('Stunned');
      if (this.catching) this._settleCatch('Aborted');
    }
    this._cancelWarp();
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
    if (this.body.hidden) this._hide();
    const t = this.now();
    let wanted = nextState && MonsterStates.includes(nextState) && nextState !== 'Scripted' ? nextState : 'Patrol';
    if (wanted === 'VentChase') wanted = 'InvestigateNoise';
    if (wanted === 'Search' || wanted === 'HidingResponse' || wanted === 'Teleport') wanted = 'Patrol';
    this.awake = wanted !== 'Dormant';
    this.wakeAt = null;
    const here = this.body.getPosition();
    if (wanted === 'WallChase') {
      const victim = this._nearestPlayerTo(here, (pl) => !this._inVent(pl));
      if (victim) this._chase(victim, t);
      else wanted = 'Patrol';
    } else if (wanted === 'InvestigateNoise') {
      const near = this._nearestPlayerTo(here, null);
      const position = near ? this._rootOf(near) : null;
      c.investigation = { position: this._floorPointNear(position || here), rank: EXACT_RANK, at: t };
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
        if (!live() || !['Biped', 'Hunched', 'Quadruped'].includes(poseMode)) return;
        this.body.setPose(poseMode);
      },
      setHidden: (hidden) => {
        if (!live()) return;
        this._cancelWarp();
        this.body.setHidden(hidden === true);
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
      playAction: (name, startAt, rate) => (this.view ? this.view.playAction(name, startAt, rate) : false),
      stopAction: (name) => {
        if (this.view) this.view.stopAction(name);
      },
    };
    return handle;
  }

  /**
   * Exclusive control for a cutscene: null while another token holds it, during a catch, or without a run; the same
   * token gets its handle back. A warp in progress is called off (the script places the Creature itself).
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
    this.pendingReach = null;
    this.lookAway = null;
    this._cancelWarp();
    this._setAction(null);
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

  /** Level tuning: every state's pace times `scale` (0.5..2, never past SpeedCap); a pace already set follows at once. */
  setSpeedScale(scale) {
    const value = isFiniteNumber(scale) ? clamp(scale, MIN_SPEED_SCALE, MAX_SPEED_SCALE) : 1;
    const previous = this.speedScale;
    if (Math.abs(value - previous) < 1e-6) return;
    this.speedScale = value;
    const m = this.mover;
    if (m && this.scripted === null && this.catching === null && this.state !== 'Scripted') {
      const pace = Math.min(CreatureConfig.SpeedCap, (this.body.walkSpeed * value) / previous);
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

  /** Pauses (true) or resumes the brain; a paused Creature stands where it is. */
  setPaused(value) {
    this.paused = !!value;
    if (value && this.mover) this.mover.stop();
  }

  /**
   * The Creature's public state: the old attributes (MonsterState, PoseMode, Hidden, ...) plus the view contract's
   * fields (viewState: state, speed, poseMode, action, actionStartedAt, fade).
   */
  snapshot() {
    const c = this.ctx;
    return {
      running: this.running,
      state: this.state,
      stateSince: this.stateSince,
      reason: this.lastReason,
      pose: this.body.pose,
      inVent: false,
      segment: null,
      hidden: this.body.hidden,
      levelId: this.creatureLevel,
      targetingPlayer: this._publishedTarget() === PLAYER,
      targetUserId: this._publishedTarget() ? this._publishedTarget().userId : null,
      awake: this.awake,
      catching: this.catching !== null,
      warping: this.warp ? this.warp.phase : null,
      teleports: this.teleports,
      approaches: this.approaches,
      beats: this.beats,
      director: this.director ? this.director.snapshot(this.now()) : null,
      pacing: this.pacing ? this.pacing.snapshot() : null,
      position: this.body.getPosition(),
      eye: this._creatureEye(),
      ...this.viewState(),
    };
  }

  // ------------------------------------------------------------------ dev commands (ai, hunt, ignoreme)

  _bringNear() {
    const c = this.ctx;
    const root = this.env.playerRoot();
    const eye = this._playerEye(PLAYER);
    const levelId = this.env.playerLevel();
    if (!c || !root || !eye || !levelId) return 'you need a character on a school level';
    if (levelIndex(levelId) < 1) return 'the Creature only hunts the school levels';
    if (this.creatureLevel !== levelId) {
      const info = this._levelInfo(levelId);
      this.creatureLevel = levelId;
      c.level = info;
      c.graph = this._graph(levelId);
      this.env.setNavLevel(levelId);
      this._forgetMind();
    }
    const info = c.level;
    if (!info) return `no layout for ${levelId}`;
    this._cancelWarp();
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
    if (this.warp && this.warp.kind === 'Reveal') {
      this._cancelWarp();
      this.body.setHidden(false);
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
    if (Brain.BEATS.has(wanted)) {
      if (this.state !== 'Patrol') this._enterState('Patrol', t);
      const walk = this.ctx.walkTo(PLAYER);
      const B = this.presence.Beats;
      const only = { ...B, Weights: Object.fromEntries(Object.keys(B.Weights).map((k) => [k, k === wanted ? 1 : 0])) };
      const chosen = this._planBeat(PLAYER, walk, only);
      if (!chosen) return `no place for a ${wanted} near you right now`;
      this.devHuntUntil = t + DEV_FORCE_SECONDS;
      c.beatPlan = chosen;
      c.beatReached = false;
      this.lastReason = `ai ${wanted}`;
      this._enterState(wanted, t);
      return `Creature: ${wanted}`;
    }
    if (wanted === 'Teleport') {
      if (this.state !== 'Patrol') this._enterState('Patrol', t);
      const plan = this._planTeleport();
      if (!plan) return 'no teleport spot near you right now';
      c.teleportPlan = plan;
      this.lastReason = 'ai Teleport';
      this._enterState('Teleport', t);
      return `Creature teleporting ${plan.side.toLowerCase()} you (${plan.walk.toFixed(0)} studs of walking)`;
    }
    if (!root) return 'you need a character';
    this.devHuntUntil = t + DEV_FORCE_SECONDS;
    this.lastReason = `ai ${wanted}`;
    if (wanted === 'InvestigateNoise') {
      c.investigation = { position: this._floorPointNear(root), rank: EXACT_RANK, at: t };
      this._enterState('InvestigateNoise', t);
    } else if (wanted === 'Search') {
      c.searchFrom = this._floorPointNear(root);
      this._enterState('Search', t);
    } else if (wanted === 'WallChase') {
      if (this._inVent(PLAYER)) return 'you are in a vent: it cannot follow you there';
      this._chase(PLAYER, t);
      this._enterState('WallChase', t);
    } else if (wanted === 'HidingResponse') {
      const spot = this._hideSpotOf(PLAYER);
      const front = spot ? this._hideSpotFront(spot) : null;
      if (!front) return 'you are not in a hiding spot';
      this.hideWatch = { player: PLAYER, spot, front, since: t };
      this._transition({ state: 'HidingResponse', reason: 'ai HidingResponse', reposition: false, giveUp: false }, t);
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
      const reply = this._force('WallChase');
      this.devHuntUntil = Math.max(this.devHuntUntil, this.now() + DEV_HUNT_SECONDS);
      return reply;
    }
    if (head === 'ignoreme') {
      this.ignored = !this.ignored;
      if (this.ignored && this.ctx.target === PLAYER) {
        this._setTarget(null);
        this.ctx.memory = null;
      }
      return this.ignored ? 'the Creature ignores you' : 'the Creature notices you again';
    }
    if (head !== 'ai') return 'usage: ai [state|pause|resume|tp] | hunt | ignoreme';
    const arg = words[1];
    if (!arg) {
      const s = this.pacing ? this.pacing.snapshot() : null;
      const t = this.now();
      return `${this.state} for ${(t - this.stateSince).toFixed(1)}s (${this.lastReason}) | target ${this.ctx.target ? 'you' : 'none'}` +
        ` | pose ${this._poseMode()}${this.body.hidden ? ', hidden' : ''}` +
        `${this.warp ? `, warp ${this.warp.kind}/${this.warp.phase}` : ''} | ${this.creatureLevel}` +
        ` | next teleport in ${Math.max(0, this.teleportReadyAt - t).toFixed(0)}s` +
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
 * @property {(poseMode: 'Biped'|'Hunched'|'Quadruped') => void} setPose
 * @property {(hidden: boolean) => void} setHidden
 * @property {(position: {x: number, y: number, z: number}) => void} face
 * @property {(nextState?: string) => void} release
 * @property {(target: any) => boolean} setTarget turns the held Creature's stare on the player (null clears)
 * @property {(name: string, startAt?: number, rate?: number) => boolean} playAction a one-shot animation layer (NeckSnap,
 *   Lunge, LockerRip, DoorSmash, Vanish, Reveal) or a held one (Stare, ReachIn), at `rate` (1 by default)
 * @property {(name: string) => void} stopAction ends that layer at once
 */

/** A CFrame from a CFrame, a THREE.Matrix4 or 12 Roblox components. */
export function toCFrame(value) {
  if (value instanceof CFrame) return value;
  if (value && value.isMatrix4) return CFrame.fromMatrix4(value);
  if (Array.isArray(value) && value.length >= 12) return CFrame.fromComponents(value);
  if (value && value.x !== undefined && value.y !== undefined && value.z !== undefined) return CFrame.at(value);
  return null;
}
