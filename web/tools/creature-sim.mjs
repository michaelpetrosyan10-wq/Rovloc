// Headless test of the Creature ("the Tall Man", Tunnels §2) on the real world data, on a fake clock.
//
//   node tools/creature-sim.mjs [--build <dir>] [--soak <seconds>] [--json <file>]
//
// The engine pieces that hold no GPU or DOM state are the real ones (World with its BVHs and probes, Entities with
// their colliders and attributes, the NoiseBus); the loop, the player, audio, input and UI are stand-ins with the
// engine's surface, driven tick by tick (30 Hz, the brain at 10 Hz, the rig animated every tick). Every tick of every
// scenario is watched: the speed (never faster than a sprinter, 19, outside Scripted), no NaN in the body or the
// view contract, no catch through a wall, and every teleport's materialisation (out of every player's view, never
// within 12 studs, after its 1.6 s warning).
//
// Scenarios:
//   patrol        Level 1 wakes; the Creature stalks its patrol loops at the Stalk pace.
//   basement      Level 0 is hunted now: it wakes and stalks its patrol loops (the tunnel planner's PatrolWaypoints;
//                 a floor without any gets loops derived from its rooms).
//   investigate   a FloorDebris noise in another room: it goes there (InvestigateNoise) and searches.
//   catch         a lit player in sight down a corridor: WallChase, a Hallway catch that downs; a second executes.
//   lose hidden   seen, then hidden (no spot): the chase ends in a Search, no catch.
//   LOS rule      seen, then gone round a corner: the chase searches ChaseLost seconds after the last sight.
//   22 s rule     a player kept in sight, out of reach: the chase gives up at MaxChase and fades away (also on
//                 Nightmare, never past a sprinter's pace).
//   vents         a crawler scurrying in a duct is never followed in: it never enters the ducts, nobody is caught.
//   stare         a held stare (7 deg, 1 s, within 18 studs in the dark) from behind starts a chase; a glance does not.
//   teleport      nobody seen for 25 s: grace + 45 s before the first; every one warned 1.6 s ahead, out of view,
//                 never within 12 studs, 12-24 studs of walking from the target; the target looking back gets the
//                 reveal; none while the game blocks them or within 25 s of a catch.
//   hiding        it sees a player climb into a locker: it stands facing it; the grunt then the LookAway; slipping
//                 out during a LookAway and breaking the line escapes; stepping out under its nose is a catch; the
//                 ReachIn at 30 s; a teammate's pull-out is no catch (co-op unit test, a remote handle).
//   fake-outs     the seeded fake-out spots: about 1 in 12, at most one per floor per player (hidespots.js); the
//                 stay limit: the warning at 35 s, shoved out at 45 s (held while a breath check runs).
//   soak          every level, a wandering, noisy player for --soak seconds each: never stuck past the stuck
//                 window, no state held past its bound, no NaN, nothing throws.
//   determinism   the patrol twice gives the same path.
//   pool          Level 4 fairness: the grace; a freestyle swimmer outswims it; every lunge telegraphed; the retreat
//                 after a grab; it never climbs out (in and out of the water only by fading, out of sight).
// Exit code 1 on any failure.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';
import { decodeWorld } from '../src/engine/data.js';
import { Entities } from '../src/engine/entities.js';
import { createSharedUniforms } from '../src/engine/materials.js';
import { NoiseBus } from '../src/engine/noise.js';
import { World } from '../src/engine/world.js';
import { createCreature, PLAYER } from '../src/creature/index.js';
import { CreatureConfig, ROOT_HEIGHT } from '../src/creature/config.js';
import { FloorNav } from '../src/creature/nav.js';
import { fakeoutSpots, FakeoutBudget, StayClock } from '../src/game/mechanics/hidespots.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
};
const buildDir = path.resolve(opt('--build', path.join(here, '..', 'build')));
const SOAK = Number(opt('--soak', '240'));
const jsonOut = opt('--json', null);

const PLAYER_ROOT = 3; // R15 root centre above the floor (HipHeight 2 + half the root)
const TICK = 1 / 30;
const STUCK_WINDOW = 2 * CreatureConfig.Repath.StuckSeconds + 0.2; // stall, fresh route, stall, then reposition
const SPRINT = 19;
const T = CreatureConfig.Teleport;
const H = CreatureConfig.Hiding;
// the longest each state may run before the soak calls it stuck (Patrol and the levels' holds are open-ended)
const STATE_BOUND = { InvestigateNoise: 70, Search: 40, HidingResponse: 45, Teleport: 40, WallChase: 30, Stunned: 15 };

// ---------------------------------------------------------------------------------------------------------------
// The engine stand-in
// ---------------------------------------------------------------------------------------------------------------

console.log(`[sim] decoding ${buildDir}`);
const meta = JSON.parse(fs.readFileSync(path.join(buildDir, 'world.json'), 'utf8'));
const binBuf = fs.readFileSync(path.join(buildDir, 'world.bin'));
const decoded = decodeWorld(meta, binBuf.buffer.slice(binBuf.byteOffset, binBuf.byteOffset + binBuf.byteLength));

class SimLoop {
  /** @param {number|null} fps a render loop at this rate interleaved with the 30 Hz ticks (null: one frame per tick) */
  constructor(fps = null) {
    this.time = 0;
    this.alpha = 0;
    this.tickDt = TICK;
    this.ticks = [];
    this.frames = [];
    this.fps = fps;
    this.frameAt = 0;
  }

  onTick(fn) {
    this.ticks.push(fn);
    return () => this.ticks.splice(this.ticks.indexOf(fn), 1);
  }

  onFrame(fn) {
    this.frames.push(fn);
    return () => this.frames.splice(this.frames.indexOf(fn), 1);
  }

  /** One fixed tick; with a render rate, the frames that fall before it run first (alpha between the ticks). */
  step() {
    const next = this.time + TICK;
    if (this.fps) {
      while (this.frameAt < next - 1e-9) {
        this.alpha = Math.max(0, (this.frameAt - this.time) / TICK);
        for (const f of this.frames.slice()) f(1 / this.fps, this.alpha);
        this.frameAt += 1 / this.fps;
      }
    }
    this.time = next;
    for (const f of this.ticks.slice()) f(TICK);
    if (!this.fps) for (const f of this.frames.slice()) f(TICK, 1);
  }
}

class SimPlayer {
  constructor() {
    this.body = { position: new THREE.Vector3(0, -1000, 0) };
    this.moveState = 'Standing';
    this.mode = 'OnFoot';
    this.lifeState = 'Alive';
    this.locks = new Map();
    this.yaw = 0;
    this.pitch = 0;
    this.flashlight = { on: true, setEmfSource: (fn) => { this.emf = fn; } };
    this.panic = { floors: new Map(), setFloor: (t, v) => { if (v == null) this.panic.floors.delete(t); else this.panic.floors.set(t, v); }, setCreatureSource: (fn) => { this.sense = fn; } };
    this.cameraOverrides = new Map();
  }

  lock(reason) {
    this.locks.set(reason, true);
  }

  unlock(reason) {
    this.locks.delete(reason);
  }

  teleport(m) {
    this.body.position.setFromMatrixPosition(m);
    const d = new THREE.Vector3(-m.elements[8], 0, -m.elements[10]);
    if (d.lengthSq() > 1e-6) this.yaw = Math.atan2(-d.x, -d.z);
  }

  eye(out = new THREE.Vector3()) {
    const h = CreatureConfig && { VentCrawling: -0.6, DownedCrawling: -0.8, Hiding: 1.3, Crouching: 0 }[this.moveState];
    return out.copy(this.body.position).add(new THREE.Vector3(0, h ?? 1.5, 0));
  }

  look() {
    const cp = Math.cos(this.pitch);
    return { yaw: this.yaw, pitch: this.pitch, direction: new THREE.Vector3(-Math.sin(this.yaw) * cp, Math.sin(this.pitch), -Math.cos(this.yaw) * cp) };
  }

  setLook(yaw, pitch) {
    this.yaw = yaw;
    this.pitch = pitch;
  }

  /** Turns the view to look straight at `point` from the eye. */
  lookAt(point) {
    const eye = this.eye();
    const d = point.clone().sub(eye);
    this.yaw = Math.atan2(-d.x, -d.z);
    this.pitch = Math.atan2(d.y, Math.hypot(d.x, d.z));
  }

  setLifeState(state) {
    this.lifeState = state;
    this.moveState = state === 'Downed' ? 'DownedCrawling' : this.moveState;
  }

  setCameraOverride(token, fn) {
    if (fn) this.cameraOverrides.set(token, fn);
    else this.cameraOverrides.delete(token);
  }

  surfaceAt() {
    return 'Concrete';
  }

  /** Stands the player on the floor at `floorPoint`. */
  place(floorPoint, mode = 'OnFoot') {
    this.mode = mode;
    if (mode === 'Vent') {
      this.body.position.copy(floorPoint);
      this.moveState = 'VentCrawling';
    } else {
      this.body.position.set(floorPoint.x, floorPoint.y + PLAYER_ROOT, floorPoint.z);
      if (this.moveState === 'VentCrawling') this.moveState = 'Standing';
    }
  }
}

function makeEngine(fps = null) {
  const shared = createSharedUniforms((decoded.meta.flickerGroups || []).length);
  const quality = { budget: { normalMaps: false, anisotropy: 1, flashlightShadow: false }, changed: { connect() {} } };
  const world = new World(decoded, {}, { shared, quality });
  const engine = { world, shared, loop: new SimLoop(fps), currentLevel: null };
  engine.entities = new Entities(engine);
  engine.noise = new NoiseBus({ loop: engine.loop, world });
  engine.player = new SimPlayer();
  const played = [];
  engine.audio = {
    played,
    play(name, opts = {}) {
      played.push({ name, at: engine.loop.time, position: opts.position ? opts.position.clone() : null });
      return { playing: true, stop() { this.playing = false; }, setVolume() {} };
    },
  };
  engine.lighting = { addLight: () => ({ set() {}, remove() {} }) };
  engine.input = { stack: [], pushContext(token, ctx) { this.stack.push([token, ctx]); }, popContext(token) { this.stack = this.stack.filter((e) => e[0] !== token); } };
  engine.ui = { hudTarget: 1, setVisible(v) { this.hudTarget = v ? 1 : 0; }, root: null };
  engine.settings = { get: () => 1 };
  const camera = new THREE.PerspectiveCamera(70, 16 / 9, 0.1, 1000);
  engine.renderer = { camera };
  engine.loop.onFrame(() => {
    engine.player.eye(camera.position);
    camera.lookAt(camera.position.clone().add(engine.player.look().direction));
    camera.updateMatrixWorld();
  });
  return engine;
}

// ---------------------------------------------------------------------------------------------------------------
// Helpers and the per-tick watch
// ---------------------------------------------------------------------------------------------------------------

const results = [];
let failed = false;
function report(ok, name, detail = '') {
  results.push({ ok, name, detail });
  if (!ok) failed = true;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  ${detail}` : ''}`);
}

// every session's watch, gathered for the global fairness checks at the end
const fairness = { maxSpeed: { v: 0, state: null, level: null }, nan: 0, wallCatches: [], catches: 0, materialised: [], badMaterial: [] };
const navs = new Map();
const navOf = (level) => {
  if (!navs.has(level)) navs.set(level, new FloorNav(level, meta, () => true));
  return navs.get(level);
};

/** A run of the Creature on a fresh engine. */
function session(opts = {}) {
  const engine = makeEngine(opts.fps || null);
  const creature = createCreature(engine);
  const s = {
    engine,
    creature,
    player: engine.player,
    events: { caught: [], finished: [], states: [], warnings: [], revealed: [], stared: [], gaveUp: [], grunts: [] },
    stuck: { anchor: null, since: 0, max: 0, maxAt: null },
    path: [],
    prev: null,
    prevAt: 0,
    prevPlacements: 0,
    warpPhase: null,
    stateAt: 0,
    longest: {},
    hideSpot: null,
    blocked: false,
    remotes: [],
  };
  const svc = creature.service;
  creature.bindGame({ hideSpotOf: () => s.hideSpot, teleportBlocked: () => s.blocked });
  if (opts.roster) svc.setRoster(() => s.remotes);
  creature.stateChanged.connect((next, prev) => {
    const t = engine.loop.time;
    s.events.states.push({ at: t, next, prev });
    s.longest[prev] = Math.max(s.longest[prev] || 0, t - s.stateAt);
    s.stateAt = t;
  });
  creature.caught.connect((victim, kind) => {
    s.events.caught.push({ at: engine.loop.time, kind, victim });
    fairness.catches += 1;
    const root = victim === PLAYER ? engine.player.body.position : victim.root();
    const here = svc.body.getPosition();
    if (root && !engine.world.lineClear(new THREE.Vector3(here.x, here.y + 1, here.z), new THREE.Vector3(root.x, root.y + 0.5, root.z))) {
      fairness.wallCatches.push({ at: engine.loop.time, kind, level: svc.creatureLevel });
    }
  });
  creature.jumpscareFinished.connect((_p, kind, outcome) => s.events.finished.push({ at: engine.loop.time, kind, outcome }));
  svc.teleportWarning.connect((spot, target, seconds) => s.events.warnings.push({ at: engine.loop.time, spot: spot.clone(), target, seconds,
    plan: svc.warp && svc.warp.plan ? { walk: svc.warp.plan.walk, side: svc.warp.plan.side } : null }));
  svc.revealed.connect((target, kind) => s.events.revealed.push({ at: engine.loop.time, target, kind }));
  svc.stared.connect((player) => s.events.stared.push({ at: engine.loop.time, player }));
  svc.gaveUp.connect((player, position) => s.events.gaveUp.push({ at: engine.loop.time, player, position }));
  svc.grunted.connect(() => s.events.grunts.push({ at: engine.loop.time }));
  return s;
}

/** Players in play for the view checks: [{eye, look}] (the local player and the remote handles). */
function viewers(s) {
  const out = [];
  if (s.player.lifeState === 'Alive' || s.player.lifeState === 'Downed') out.push({ eye: s.player.eye(), look: s.player.look().direction, root: s.player.body.position.clone() });
  for (const r of s.remotes) {
    const root = r.root();
    if (root) out.push({ eye: root.clone().add(new THREE.Vector3(0, 1.5, 0)), look: r.look(), root });
  }
  return out;
}

/** Whether a viewer sees the Creature's root at `p` (the same rule as the design: an 80 deg cone and a clear line). */
function inViewOf(s, v, p) {
  const metrics = s.creature.service.metrics;
  for (const lift of [metrics.eyeHeights.Biped, 0]) {
    const q = new THREE.Vector3(p.x, p.y + lift, p.z);
    const d = q.clone().sub(v.eye);
    if (d.length() <= 8) return true;
    const angle = (Math.acos(Math.max(-1, Math.min(1, d.clone().normalize().dot(v.look.clone().normalize())))) * 180) / Math.PI;
    if (angle <= T.ViewHalfAngle && s.engine.world.lineClear(v.eye, q)) return true;
  }
  return false;
}

function watch(s) {
  const svc = s.creature.service;
  const t = s.engine.loop.time;
  const pos = svc.body.getPosition();
  if (s.prev && svc.body.placements === s.prevPlacements && svc.state !== 'Scripted' && !svc.catching && t > s.prevAt) {
    const v = Math.hypot(pos.x - s.prev.x, pos.z - s.prev.z) / (t - s.prevAt);
    if (v > fairness.maxSpeed.v) {
      fairness.maxSpeed = { v, state: svc.state, level: svc.creatureLevel, difficulty: svc.difficulty, medium: svc.mover.getMedium(),
        legs: svc.mover.legs.map((l) => l.kind).join('+'), warp: svc.warp ? `${svc.warp.kind}:${svc.warp.phase}` : null,
        hidden: svc.body.hidden, at: +t.toFixed(2) };
    }
  }
  s.prev = pos.clone();
  s.prevAt = t;
  s.prevPlacements = svc.body.placements;
  const vs = svc.viewState();
  if (![pos.x, pos.y, pos.z, vs.fade, vs.speed, vs.actionStartedAt].every(Number.isFinite)) fairness.nan += 1;
  const phase = svc.warp ? `${svc.warp.kind}:${svc.warp.phase}` : null;
  if (phase !== s.warpPhase) {
    if (phase === 'Teleport:FadeIn') {
      const vws = viewers(s);
      const seen = vws.some((v) => inViewOf(s, v, pos));
      const nearest = Math.min(...vws.map((v) => v.root.distanceTo(pos)));
      const warning = s.events.warnings[s.events.warnings.length - 1];
      const lead = warning ? t - warning.at : null;
      const m = { at: t, level: svc.creatureLevel, seen, nearest: +nearest.toFixed(1), lead: lead !== null ? +lead.toFixed(2) : null,
        walk: warning && warning.plan ? +warning.plan.walk.toFixed(1) : null, side: warning && warning.plan ? warning.plan.side : null };
      fairness.materialised.push(m);
      if (seen || nearest < T.MinStraight - 0.05 || lead === null || lead < T.WarningSeconds - 0.05 ||
        (m.walk !== null && (m.walk < T.MinWalk - 0.05 || m.walk > T.MaxWalk + 0.05))) fairness.badMaterial.push(m);
    }
    s.warpPhase = phase;
  }
}

/** Advances `seconds` (stopping early when `until()` holds); watches every tick. Returns seconds taken (-1: never). */
function advance(s, seconds, until) {
  const ticks = Math.round(seconds / TICK);
  for (let i = 0; i < ticks; i++) {
    s.engine.loop.step();
    trackStuck(s);
    watch(s);
    if (until && until()) return (i + 1) * TICK;
  }
  return until ? -1 : seconds;
}

function trackStuck(s) {
  const svc = s.creature.service;
  const m = svc.mover;
  const t = s.engine.loop.time;
  const pos = svc.body.getPosition();
  if (s.path.length === 0 || s.path[s.path.length - 1].distanceTo(pos) > 0.5) s.path.push(pos.clone());
  const trying = !!m && m.getStatus() === 'Moving' && !m.busy() && !svc.catching && !svc.warp && svc.state !== 'Dormant' &&
    svc.state !== 'Scripted' && svc.awake;
  const st = s.stuck;
  if (!trying || !st.anchor || pos.distanceTo(st.anchor) >= 1.2) {
    st.anchor = pos.clone();
    st.since = t;
    return;
  }
  const window = t - st.since;
  if (window > st.max) {
    st.max = window;
    st.maxAt = { t, state: svc.state, position: pos.clone(), level: svc.creatureLevel };
  }
}

const waypointsOf = (levelId) => meta.anchors.filter((a) => a.kind === 'PatrolWaypoint' && a.level === levelId)
  .map((a) => ({ id: a.id, room: a.room, position: new THREE.Vector3(a.cframe[0], a.cframe[1], a.cframe[2]) }));

function hideFar(s, levelId) {
  // the player tucked away (Hiding: never seen) at the standing spot farthest from the Creature
  const svc = s.creature.service;
  const here = svc.body.getPosition();
  const info = svc._levelInfo(levelId);
  const wps = info.waypoints.map((w) => w.position).sort((a, b) => b.distanceTo(here) - a.distanceTo(here));
  s.player.place(wps[0]);
  s.player.moveState = 'Hiding';
  return wps[0];
}

/**
 * Waits (up to `seconds`) until the patrolling Creature walks toward a goal `min`..`max` studs ahead with a clear
 * sight line, then stands the lit player there. Returns the distance, or -1.
 */
function ambush(s, min, max, seconds) {
  const svc = s.creature.service;
  let distance = -1;
  advance(s, seconds, () => {
    const goal = svc.mover && svc.mover.goal();
    if (svc.state !== 'Patrol' || !goal || svc.mover.busy() || svc.warp) return false;
    const eye = svc._creatureEye();
    const playerEye = goal.clone().add(new THREE.Vector3(0, PLAYER_ROOT + 1.5, 0));
    const d = eye.distanceTo(playerEye);
    const toward = playerEye.clone().sub(eye).normalize();
    if (d < min || d > max || toward.dot(svc.body.getCFrame().lookVector) < 0.8 || !s.engine.world.lineClear(eye, playerEye)) return false;
    s.player.moveState = 'Standing';
    s.player.flashlight.on = true;
    s.player.place(goal);
    s.player.lookAt(eye.clone().add(new THREE.Vector3(30, 0, 0)));
    distance = d;
    return true;
  });
  return distance;
}

/** Puts the Creature at `point` (floor) facing `toward` through the public scripted handle, then releases it. */
function stage(s, point, toward, release = 'Patrol') {
  const h = s.creature.acquireScripted('sim');
  if (!h) throw new Error('could not acquire the Creature');
  const at = point.clone().add(new THREE.Vector3(0, ROOT_HEIGHT, 0));
  const m = new THREE.Matrix4().lookAt(at, new THREE.Vector3(toward.x, at.y, toward.z), new THREE.Vector3(0, 1, 0)).setPosition(at);
  h.teleport(m);
  h.setHidden(false);
  h.release(release);
}

/** A fresh run on `level`, awake and past its airlock grace, the player tucked away. */
function awakeOn(level, difficulty = 'Standard', opts = {}) {
  const s = session(opts);
  s.creature.beginRun({ difficulty });
  s.creature.activateLevel(level);
  hideFar(s, level);
  advance(s, 14);
  return s;
}

/** Free floor points of a level (the nav lattice), [{position, room}]. */
const samplesOf = (level) => navOf(level).samplePoints(4);

/** A floor point `min..max` studs from `from` with (or without) a clear line from `eye`, nearest `near` first. */
function pointFrom(s, level, from, eye, min, max, clear, near = from, accept = null) {
  const pts = samplesOf(level).map((p) => p.position)
    .filter((p) => Math.abs(p.y - from.y) < 4 && p.distanceTo(from) >= min && p.distanceTo(from) <= max && (!accept || accept(p)))
    .sort((a, b) => a.distanceTo(near) - b.distanceTo(near));
  for (const p of pts) {
    const e = p.clone().add(new THREE.Vector3(0, PLAYER_ROOT + 1.5, 0));
    if (s.engine.world.lineClear(eye, e) === clear) return p;
  }
  return null;
}

// ---------------------------------------------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------------------------------------------

const LEVEL = 'Level1_Hallways';
const summary = {};

function scenarioPatrol(level = LEVEL) {
  const s = session();
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(level);
  hideFar(s, level);
  advance(s, 4.6);
  const awake = s.creature.getState();
  const start = s.creature.service.body.getPosition();
  const reached = new Set();
  const wps = s.creature.service._levelInfo(level).waypoints;
  let travelled = 0;
  let last = start.clone();
  const ticks = Math.round(60 / TICK);
  for (let i = 0; i < ticks; i++) {
    s.engine.loop.step();
    trackStuck(s);
    watch(s);
    const p = s.creature.service.body.getPosition();
    travelled += Math.hypot(p.x - last.x, p.z - last.z);
    last = p;
    for (const w of wps) if (Math.hypot(w.position.x - p.x, w.position.z - p.z) <= 2.6) reached.add(w.id);
  }
  return { s, awake, reached: reached.size, travelled, state: s.creature.getState(), end: s.creature.service.body.getPosition(), pathLength: s.path.length };
}

// 1. patrol (the Stalk)
const p1 = scenarioPatrol();
summary.patrol = { awake: p1.awake, reached: p1.reached, travelled: +p1.travelled.toFixed(1), state: p1.state, maxStuck: +p1.s.stuck.max.toFixed(2) };
report(p1.awake === 'Patrol', 'patrol: wakes into Patrol WakeDelay after the level activates', `state ${p1.awake}`);
report(p1.reached >= 5 && p1.travelled >= 200 && p1.travelled <= 60 * CreatureConfig.Speeds.Patrol + 5, 'patrol: stalks its loops at the Stalk pace (7 studs/s)',
  `${p1.reached} waypoints reached, ${p1.travelled.toFixed(0)} studs in 60 s`);

// 2. the basement is hunted
{
  const b = scenarioPatrol('Level0_Basement');
  const info = b.s.creature.service._levelInfo('Level0_Basement');
  summary.basement = { awake: b.awake, reached: b.reached, travelled: +b.travelled.toFixed(1), loops: info.loops.length, derived: info.derived };
  report(b.awake === 'Patrol' && info.loops.length > 0 && b.reached >= 4 && b.travelled >= 150,
    'basement: Level 0 wakes and stalks its patrol loops', JSON.stringify(summary.basement));
}

// 3. investigate a noise (the airlock grace is long over)
{
  const s = p1.s;
  const svc = s.creature.service;
  const here = svc.body.getPosition();
  const room = svc.ctx.level ? Object.values(svc.ctx.level.rooms).find((r) => here.x >= r.minX && here.x <= r.maxX && here.z >= r.minZ && here.z <= r.maxZ) : null;
  const target = waypointsOf(LEVEL)
    .filter((w) => (!room || w.room !== room.id) && w.position.distanceTo(here) > 30 && w.position.distanceTo(here) < 70)
    .sort((a, b) => a.position.distanceTo(here) - b.position.distanceTo(here))[0];
  s.engine.noise.emit(target.position.clone().add(new THREE.Vector3(0, 1, 0)), 'FloorDebris', { level: LEVEL });
  const heardIn = advance(s, 1, () => svc.state === 'InvestigateNoise');
  let closest = Infinity;
  const arrived = advance(s, 25, () => {
    closest = Math.min(closest, Math.hypot(svc.body.getPosition().x - target.position.x, svc.body.getPosition().z - target.position.z));
    return closest <= 4;
  });
  const searched = advance(s, 40, () => svc.state === 'Patrol');
  summary.investigate = { heardIn, arrived, closest: +closest.toFixed(2), backToPatrolAfter: searched, noiseRoom: target.room };
  report(heardIn >= 0, 'investigate: a FloorDebris noise starts InvestigateNoise', `after ${heardIn.toFixed(2)} s`);
  report(arrived >= 0, 'investigate: it reaches the noise', `${arrived.toFixed(1)} s, closest ${closest.toFixed(1)} studs (room ${target.room})`);
  report(searched >= 0 && searched <= CreatureConfig.Investigate.MaxSeconds + 4, 'investigate: searches there 6..10 s, then stalks on',
    `after ${searched.toFixed(1)} s`);
}

// 4. chase and catch a stationary visible player; a second catch executes
{
  const s = awakeOn(LEVEL);
  const distance = ambush(s, 20, 60, 120);
  if (distance < 0) report(false, 'catch: the patrol route offers a sight line for the test');
  else {
    const chased = advance(s, 1.5, () => s.creature.getState() === 'WallChase');
    const caughtIn = advance(s, 15, () => s.events.caught.length > 0);
    const finishedIn = advance(s, 4, () => s.events.finished.length > 0);
    const first = s.events.finished[0];
    report(chased >= 0, 'catch: a lit player in sight starts WallChase', `after ${chased.toFixed(2)} s, ${distance.toFixed(0)} studs ahead`);
    report(caughtIn >= 0 && s.events.caught[0].kind === 'Hallway', 'catch: it runs them down and catches (Hallway)', caughtIn >= 0 ? `after ${caughtIn.toFixed(2)} s` : 'no catch');
    report(!!first && first.outcome === 'Downed' && s.player.lifeState === 'Downed', 'catch: the first catch downs the player',
      first ? `${first.outcome} ${finishedIn.toFixed(2)} s after the catch, life ${s.player.lifeState}` : 'not finished');
    const jumpscareSeen = s.engine.audio.played.some((p) => p.name === 'JumpscareSting') && s.engine.audio.played.some((p) => p.name === 'Screech');
    report(jumpscareSeen, 'catch: screech and sting play');
    const second = advance(s, 150, () => s.events.finished.length > 1);
    const last = s.events.finished[1];
    report(second >= 0 && !!last && last.outcome === 'Executed' && s.player.lifeState === 'Dead', 'catch: a catch of a downed player executes',
      last ? `${last.outcome} after ${second.toFixed(1)} s more` : `no second catch (state ${s.creature.getState()}, life ${s.player.lifeState})`);
    summary.catch = { distance, chased, caughtIn, first: first && first.outcome, second: last && last.outcome, secondAfter: second };
  }
}

// 5. loses a hidden player (no spot: it never saw them get in anywhere)
{
  const s = awakeOn(LEVEL);
  const distance = ambush(s, 35, 70, 180);
  const chased = advance(s, 1.5, () => s.creature.getState() === 'WallChase');
  advance(s, 0.4);
  s.player.moveState = 'Hiding';
  const gaveUp = advance(s, 40, () => s.creature.getState() !== 'WallChase');
  const after = s.creature.getState();
  advance(s, 30);
  report(distance > 0 && chased >= 0 && gaveUp >= 0 && after === 'Search' && s.events.caught.length === 0,
    'lose hidden: the chase ends in a Search and nobody is caught',
    `seen ${distance.toFixed(0)} studs ahead, chase ended ${gaveUp.toFixed(1)} s after hiding -> ${after}, catches ${s.events.caught.length}`);
  summary.loseHidden = { distance, chased, gaveUp, after, catches: s.events.caught.length };
}

// 6. the LOS rule: gone round a corner, the chase searches ChaseLost seconds after the last sight
{
  const s = awakeOn(LEVEL);
  const svc = s.creature.service;
  const distance = ambush(s, 30, 60, 180);
  const chased = advance(s, 1.5, () => svc.state === 'WallChase');
  advance(s, 0.3);
  // out of its sight, far off, torch off, standing still in the dark
  const eye = svc._creatureEye();
  const away = pointFrom(s, LEVEL, svc.body.getPosition().clone().setY(svc.body.getPosition().y - ROOT_HEIGHT), eye, 45, 90, false);
  s.player.flashlight.on = false;
  s.player.place(away);
  const goneAt = s.engine.loop.time;
  const ended = advance(s, 12, () => svc.state !== 'WallChase');
  const endedAs = svc.state;
  const lost = svc.chaseSeenAt;
  const after = s.engine.loop.time - Math.max(lost, goneAt - TICK * 4);
  report(distance > 0 && chased >= 0 && ended >= 0 && endedAs === 'Search' && after <= CreatureConfig.Search.MaxSeconds &&
    ended <= difficultyLost('Standard') + 0.5 && s.events.caught.length === 0,
    `LOS rule: line of sight lost, the chase searches the last seen point within ${difficultyLost('Standard')} s`,
    `ended ${ended.toFixed(1)} s after the player vanished -> ${endedAs}`);
  summary.losRule = { distance, ended, endedAs };
}

function difficultyLost(d) {
  return d === 'Nightmare' ? 5 : 4;
}

// 7. the 22 s rule (and Nightmare's 28 s, never past a sprinter)
for (const difficulty of ['Standard', 'Nightmare']) {
  const s = awakeOn(LEVEL, difficulty);
  const svc = s.creature.service;
  const distance = ambush(s, 25, 45, 180);
  // the game refuses every catch: it runs them down and stands over them, in plain sight, until it has to give up
  s.creature.setCatchHooks({ canCatch: () => false });
  const chased = advance(s, 1.5, () => svc.state === 'WallChase');
  const startedAt = svc.chaseStarted;
  const ended = advance(s, 40, () => svc.state !== 'WallChase');
  s.creature.setCatchHooks(null);
  const length = s.engine.loop.time - (startedAt ?? 0);
  const limit = difficulty === 'Nightmare' ? 28 : 22;
  const warp = svc.warp ? svc.warp.kind : null;
  report(distance > 0 && chased >= 0 && ended >= 0 && Math.abs(length - limit) <= 0.35 && warp === 'GiveUp' && s.events.gaveUp.length === 1 &&
    s.events.caught.length === 0, `22 s rule (${difficulty}): a chase still in sight gives up at ${limit} s and fades away`,
  `chase ${length.toFixed(1)} s -> ${svc.state} (${warp || 'no'} warp), gaveUp ${s.events.gaveUp.length}, catches ${s.events.caught.length}`);
  advance(s, 4);
  const back = !svc.warp && !svc.body.hidden;
  const far = back ? s.player.body.position.distanceTo(svc.body.getPosition()) : 0;
  report(back && far >= CreatureConfig.GiveUp.MinDistance - 1, `22 s rule (${difficulty}): it comes back out of sight, far away`, `${far.toFixed(0)} studs off`);
  summary[`giveUp${difficulty}`] = { length: +length.toFixed(2), far: +far.toFixed(1) };
}

// 8. vents: a crawler is never followed into the ducts
{
  const s = awakeOn(LEVEL);
  const svc = s.creature.service;
  const graph = svc._graph(LEVEL);
  const grate = graph.grates[graph.grateIds[0]];
  const node = graph.nodes[grate.nodeId];
  s.player.moveState = 'VentScurrying';
  s.player.place(node.position.clone(), 'Vent');
  const stand = svc._grateStandPoint(grate);
  stage(s, stand.position.clone().add(stand.lookVector.clone().multiplyScalar(4)), stand.position);
  let entered = false;
  let states = new Set();
  advance(s, 25, () => {
    if (Math.round(s.engine.loop.time * 30) % 9 === 0) s.engine.noise.emit(node.position.clone(), 'VentScurry', { source: 'player', level: LEVEL, ventNodeId: node.id, medium: 'Vent' });
    if (svc.mover.getMedium() !== 'Floor' && svc.mover.getMedium() !== 'Water') entered = true;
    states.add(svc.state);
    return false;
  });
  states = [...states];
  report(!entered && !states.includes('VentChase') && s.events.caught.length === 0,
    'vents: a scurrying crawler is never followed into the ducts (no VentChase, no catch)', `states ${states.join(', ')}`);
}

// 9. the stare: a held look at its head starts a chase, a glance does not
{
  const s = awakeOn(LEVEL);
  const svc = s.creature.service;
  s.player.flashlight.on = false;
  s.player.moveState = 'Standing';
  /** Puts the player `d` studs behind the walking Creature (out of its cone), looking at its head when `look`. */
  const behind = (d, look) => {
    const here = svc.body.getPosition();
    const back = svc.body.getCFrame().lookVector.clone().setY(0).normalize().negate();
    const feet = here.clone().setY(here.y - ROOT_HEIGHT).addScaledVector(back, d);
    s.player.place(feet);
    const head = svc._creatureEye();
    if (look) s.player.lookAt(head);
    else s.player.lookAt(head.clone().add(new THREE.Vector3(0, 0, 0)).addScaledVector(back, -1).add(new THREE.Vector3(10, -6, 10)));
    return s.engine.world.lineClear(s.player.eye(), head);
  };
  // find a moment it walks a straight stretch with room behind it
  let ok = false;
  advance(s, 60, () => {
    if (svc.state !== 'Patrol' || svc.warp) return false;
    ok = behind(14, false);
    return ok;
  });
  // a glance (0.6 s), away, a glance: no chase
  let glanceChase = false;
  for (const look of [true, false, true, false]) {
    advance(s, 0.6, () => {
      behind(14, look);
      if (svc.state === 'WallChase') glanceChase = true;
      return false;
    });
  }
  const before = s.events.stared.length;
  let held = 0;
  const started = advance(s, 3, () => {
    behind(14, true);
    held += TICK;
    return svc.state === 'WallChase';
  });
  const fromStare = s.events.stared.length > before && s.events.stared[s.events.stared.length - 1].player === PLAYER;
  report(ok && !glanceChase && started >= 0 && fromStare && held >= CreatureConfig.Stare.Seconds - 0.05 && held <= CreatureConfig.Stare.Seconds + 0.3,
    'stare: a 1 s stare at its head (dark, 14 studs, from behind) starts a chase; glances do not',
    `setup ${ok}, glance chase ${glanceChase}, chase after ${held.toFixed(2)} s of staring (stared ${fromStare})`);
  summary.stare = { held: +held.toFixed(2), glanceChase };
}

// 10. teleports
{
  const s = session();
  const svc = s.creature.service;
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(LEVEL);
  const activatedAt = s.engine.loop.time;
  // the player: silent, torch off, strolling a dark stretch far from where it starts (a trail behind them)
  const start = hideFar(s, LEVEL);
  s.player.moveState = 'Standing';
  s.player.flashlight.on = false;
  const strollPts = samplesOf(LEVEL).map((p) => p.position).filter((p) => p.distanceTo(start) < 40 && Math.abs(p.y - start.y) < 3);
  let k = 0;
  const stroll = () => {
    if (Math.round(s.engine.loop.time * 30) % 60 === 0 && strollPts.length) {
      const p = strollPts[(k++ * 7) % strollPts.length];
      s.player.place(p);
      s.player.lookAt(p.clone().add(new THREE.Vector3(Math.sin(k) * 10, PLAYER_ROOT + 1.5, Math.cos(k) * 10)));
    }
  };
  // the target looks back at it when it forms: the reveal (the first teleport only)
  const firstAt = advance(s, 240, () => {
    stroll();
    const w = svc.warp;
    if (w && w.kind === 'Teleport' && w.phase === 'FadeIn') {
      // the target turns round where they can see it (round the corner if it formed out of their line)
      const head = svc._creatureEye();
      const feet = svc.body.getPosition().clone().setY(svc.body.getPosition().y - ROOT_HEIGHT);
      if (!s.engine.world.lineClear(s.player.eye(), head)) {
        const p = pointFrom(s, LEVEL, feet, head, 12, 22, true, s.player.body.position.clone().setY(feet.y));
        if (p) s.player.place(p);
      }
      s.player.lookAt(head);
      return true;
    }
    return false;
  });
  const warning = s.events.warnings[0];
  advance(s, 2);
  const first = warning ? warning.at - activatedAt : null;
  report(warning !== undefined && first >= CreatureConfig.FloorGrace.Standard + T.FirstAfterGrace - 0.05,
    `teleport: the first comes no sooner than the floor's grace + ${T.FirstAfterGrace} s`,
    warning ? `first warning ${first.toFixed(1)} s after the level activated` : `no teleport in 240 s (state ${svc.state})`);
  report(s.events.revealed.length === 1 && s.events.revealed[0].target === PLAYER, 'teleport: the target looking back as it forms gets the reveal scare (once)',
    `${s.events.revealed.length} reveals`);
  // more of them: never while the game blocks them; and they keep coming (the game refuses catches here, so a stalk
  // that finds the strolling player does not end the run)
  s.creature.setCatchHooks({ canCatch: () => false });
  s.blocked = true;
  const blockedFrom = s.engine.loop.time;
  const warningsBefore = s.events.warnings.length;
  advance(s, 150, () => {
    stroll();
    return false;
  });
  const duringBlock = s.events.warnings.length - warningsBefore;
  s.blocked = false;
  advance(s, 300, () => {
    stroll();
    return false;
  });
  const total = s.events.warnings.length;
  report(duringBlock === 0, 'teleport: none while the game blocks them (survive countdown, finale)', `${duringBlock} during ${(s.engine.loop.time - blockedFrom).toFixed(0)} s blocked`);
  const gaps = s.events.warnings.slice(1).map((w, i) => w.at - s.events.warnings[i].at);
  report(total >= 2 && gaps.every((g) => g >= 25), 'teleport: they keep coming, a cooldown (and 25 s unseen) between them',
    `${total} teleports, gaps ${gaps.map((g) => g.toFixed(0)).join(', ')} s`);
  summary.teleport = { first, total, gaps, reveals: s.events.revealed.length, sides: s.events.warnings.map((w) => w.plan && w.plan.side) };
}

// 10b. no teleport within AfterCatch of a catch
{
  const s = awakeOn(LEVEL);
  const svc = s.creature.service;
  advance(s, 70);
  const distance = ambush(s, 15, 40, 120);
  const caught = advance(s, 20, () => s.events.caught.length > 0);
  advance(s, 4);
  const catchAt = s.events.caught.length ? s.events.caught[0].at : null;
  s.player.setLifeState('Alive');
  s.player.moveState = 'Standing';
  s.player.flashlight.on = false;
  const before = s.events.warnings.length;
  advance(s, T.AfterCatch);
  const within = s.events.warnings.filter((w) => catchAt !== null && w.at - catchAt < T.AfterCatch).length;
  report(distance > 0 && caught >= 0 && within === 0, `teleport: none within ${T.AfterCatch} s of a catch`,
    `catch ${caught >= 0 ? 'yes' : 'no'}, ${within} too soon (${s.events.warnings.length - before} after it)`);
}

// 11. hiding: the saw-you-hide rule
const HIDE_LEVEL = LEVEL;
const lockersOf = (level) => meta.entities.filter((e) => e.type === 'Locker' && e.level === level).map((e) => {
  const ex = e.attachments.ExitAnchor;
  const hide = e.attachments.HideAnchor;
  const front = new THREE.Vector3(ex[0], ex[1], ex[2]);
  // CFrame components [x, y, z, R00..R22]: the LookVector (out of the spot) is -(R02, R12, R22)
  const out = new THREE.Vector3(-ex[5], 0, -ex[11]).normalize();
  return { id: e.id, room: e.attributes.ZoneId, front, out, hide: new THREE.Vector3(hide[0], hide[1], hide[2]) };
});
/**
 * The Creature 22 studs out from a corridor locker, facing it, the player at its door in plain sight, then climbing in.
 * Returns the locker, or null.
 */
function seenHiding(s, who = PLAYER) {
  const svc = s.creature.service;
  const locker = lockersOf(HIDE_LEVEL).find((l) => l.room === 'L1_NorthHall_West' && l.id === 'L1_Locker_03') || lockersOf(HIDE_LEVEL)[0];
  // along the corridor, in front of the locker
  const along = new THREE.Vector3(-locker.out.z, 0, locker.out.x);
  let from = null;
  for (const sign of [1, -1]) {
    const p = locker.front.clone().addScaledVector(locker.out, 3).addScaledVector(along, sign * 20);
    if (navOf(HIDE_LEVEL).roomAt(p) && s.engine.world.lineClear(p.clone().setY(p.y + 7), locker.front.clone().setY(locker.front.y + 4.5))) {
      from = p;
      break;
    }
  }
  if (!from) return null;
  if (who === PLAYER) {
    s.player.moveState = 'Standing';
    s.player.flashlight.on = true;
    s.player.place(locker.front);
  } else {
    who.state.root = locker.front.clone().setY(locker.front.y + PLAYER_ROOT);
    who.state.moveState = 'Standing';
    who.state.torch = true;
    s.player.moveState = 'Hiding';
  }
  // on its way to them (it sees them at the door), then in they go
  stage(s, from, locker.front, 'WallChase');
  // seen at the door...
  const seen = advance(s, 2, () => svc.lastSeen.has(who));
  if (process.env.SIM_DEBUG) console.log('[debug] seenHiding', { from: from.toArray(), seen, state: svc.state, scripted: !!svc.scripted, awake: svc.awake });
  // ...and in it goes
  if (who === PLAYER) {
    s.player.place(locker.hide.clone().setY(locker.front.y));
    s.player.moveState = 'Hiding';
    s.hideSpot = locker.id;
  } else {
    who.state.root = locker.hide.clone().setY(locker.front.y + PLAYER_ROOT);
    who.state.moveState = 'Hiding';
    who.state.locker = locker.id;
  }
  const responding = advance(s, 1, () => svc.state === 'HidingResponse');
  if (process.env.SIM_DEBUG) console.log('[debug] responding', { responding, state: svc.state, watch: !!svc.hideWatch, lastSeen: svc.lastSeen.get(who), t: s.engine.loop.time, spot: svc._hideSpotOf(who) });
  return seen >= 0 && responding >= 0 ? { locker, enteredAt: s.engine.loop.time - responding } : null;
}

/** Out of the spot and away out of its sight (a run round the corner). */
function slipAway(s, locker) {
  const svc = s.creature.service;
  s.hideSpot = null;
  s.player.moveState = 'Standing';
  s.player.flashlight.on = false;
  s.player.place(locker.front);
  advance(s, 0.4);
  const eye = svc._creatureEye();
  const p = pointFrom(s, HIDE_LEVEL, locker.front, eye, 14, 30, false);
  if (p) s.player.place(p);
  return !!p;
}

{
  // a. the grunt, the LookAway, slipping out unseen
  const s = awakeOn(HIDE_LEVEL);
  const svc = s.creature.service;
  const hid = seenHiding(s);
  let lookAt = -1;
  if (hid) lookAt = advance(s, 20, () => svc.action === 'LookAway');
  const grunt = s.events.grunts.length ? s.events.grunts[s.events.grunts.length - 1].at : null;
  const lead = grunt !== null && lookAt >= 0 ? svc.actionAt - grunt : null;
  const sinceIn = hid && lookAt >= 0 ? svc.actionAt - hid.enteredAt : null;
  let escaped = false;
  if (lookAt >= 0) {
    escaped = slipAway(s, hid.locker);
    advance(s, 10);
  }
  report(!!hid && lookAt >= 0 && lead !== null && lead >= H.GruntLead - 0.15 && sinceIn >= H.LookAwayMin - 0.2 && sinceIn <= H.LookAwayMax + 8,
    'hiding: it sees them climb in, stands facing the spot, grunts, then looks away', hid ? `LookAway ${sinceIn !== null ? sinceIn.toFixed(1) : '-'} s in, grunt ${lead !== null ? lead.toFixed(2) : '-'} s ahead` : 'no setup');
  report(escaped && s.events.caught.length === 0 && svc.state !== 'HidingResponse', 'hiding: slipping out during a LookAway and breaking the line escapes',
    `catches ${s.events.caught.length}, now ${svc.state}`);
  summary.hidingEscape = { lookAway: sinceIn, gruntLead: lead, state: svc.state };
}
{
  // b. stepping out under its nose
  const s = awakeOn(HIDE_LEVEL);
  const svc = s.creature.service;
  const hid = seenHiding(s);
  let arrived = -1;
  if (hid) arrived = advance(s, 10, () => svc.mover.getStatus() !== 'Moving' && Math.hypot(svc.body.getPosition().x - hid.locker.front.x, svc.body.getPosition().z - hid.locker.front.z) < 4);
  advance(s, 0.5);
  const looking = svc.action === 'LookAway';
  s.hideSpot = null;
  s.player.moveState = 'Standing';
  s.player.place(hid ? hid.locker.front : new THREE.Vector3());
  const caught = advance(s, 1.5, () => s.events.caught.length > 0);
  report(!!hid && arrived >= 0 && !looking && caught >= 0 && s.events.caught[0].kind === 'Hallway',
    `hiding: stepping out within ${H.CatchRange} studs while it is not looking away is a catch`, caught >= 0 ? `caught after ${caught.toFixed(2)} s` : 'no catch');
}
{
  // c. the ReachIn at 30 s
  const s = awakeOn(HIDE_LEVEL);
  const svc = s.creature.service;
  const hid = seenHiding(s);
  let reachAt = -1;
  if (hid) advance(s, 40, () => {
    if (svc.action === 'ReachIn' && reachAt < 0) reachAt = s.engine.loop.time;
    return s.events.caught.length > 0;
  });
  const catchAt = s.events.caught.length ? s.events.caught[0].at : null;
  const after = hid && catchAt !== null ? catchAt - hid.enteredAt : null;
  report(!!hid && after !== null && s.events.caught[0].kind === 'Locker' && Math.abs(after - (H.ReachInSeconds + H.ReachInLead)) <= 0.7 && reachAt > 0,
    `hiding: it reaches in after ${H.ReachInSeconds} s (ReachIn, a Locker catch)`, after !== null ? `caught ${after.toFixed(2)} s after they got in` : 'no catch');
}
{
  // d. a teammate pulls them out (co-op unit test: a remote hider)
  const s = awakeOn(HIDE_LEVEL, 'Standard', { roster: true });
  const svc = s.creature.service;
  const state = { root: null, moveState: 'Standing', torch: true, locker: null, life: 'Alive', look: new THREE.Vector3(0, 0, -1) };
  const remote = {
    userId: 2, name: 'Mate', state,
    root: () => (state.root ? state.root.clone() : null),
    rootCFrame: () => null,
    look: () => state.look.clone(),
    lifeState: () => state.life,
    downedCount: () => 0,
    moveState: () => state.moveState,
    mode: () => 'OnFoot',
    inVent: () => false,
    flashlightOn: () => state.torch,
    lockerId: () => state.locker,
    hasLock: () => false,
    controlLock: () => 'None',
    canCatch: () => true,
    setCaught: () => {},
    turn: () => {},
    catchCue: () => {},
    catchAbort: () => {},
    catchOutcome: (o) => {
      state.life = o === 'Down' ? 'Downed' : 'Dead';
    },
  };
  s.remotes.push(remote);
  const hid = seenHiding(s, remote);
  let arrived = -1;
  if (hid) arrived = advance(s, 10, () => svc.mover.getStatus() !== 'Moving' && Math.hypot(svc.body.getPosition().x - hid.locker.front.x, svc.body.getPosition().z - hid.locker.front.z) < 4);
  advance(s, 1);
  // pulled out by a teammate: out at the door, then off out of its sight
  svc.notePulled(remote);
  state.locker = null;
  state.moveState = 'Standing';
  state.root = hid ? hid.locker.front.clone().setY(hid.locker.front.y + PLAYER_ROOT) : null;
  const noCatch = advance(s, 1, () => s.events.caught.length > 0) < 0;
  const ended = svc.state !== 'HidingResponse';
  const p = hid ? pointFrom(s, HIDE_LEVEL, hid.locker.front, svc._creatureEye(), 14, 30, false) : null;
  if (p) state.root = p.clone().setY(p.y + PLAYER_ROOT);
  state.torch = false;
  advance(s, 6);
  report(!!hid && arrived >= 0 && noCatch && ended && s.events.caught.length === 0,
    'hiding: a teammate pulling them out is no catch (co-op unit test)', `ended ${ended}, catches ${s.events.caught.length}, now ${svc.state}`);
}

// 12. fake-outs (hidespots.js): seeded, about 1 in 12, at most one per floor per player
{
  const ids = meta.entities.filter((e) => e.type === 'Locker').map((e) => e.id);
  let total = 0;
  const seeds = 200;
  for (let seed = 1; seed <= seeds; seed++) total += fakeoutSpots(seed, ids).size;
  const share = total / (seeds * ids.length);
  const again = [...fakeoutSpots(4242, ids)].join() === [...fakeoutSpots(4242, ids)].join();
  const budget = new FakeoutBudget();
  const first = budget.take('Level3_Gymnasium');
  const second = budget.take('Level3_Gymnasium');
  const other = budget.take('Level2_ScienceHall');
  report(Math.abs(share - 1 / CreatureConfig.FakeoutOneIn) < 0.02 && again && first && !second && other,
    'fake-outs: about 1 in 12 hiding spots (seeded per run), at most one per floor per player',
    `share ${(share * 100).toFixed(1)} %, deterministic ${again}, budget ${first}/${second}/${other}`);
}

// 12b. the stay limit (hidespots.js): the warning at 35 s, the shove at 45 s, held while a breath check runs
{
  const clock = new StayClock(100);
  const events = [];
  for (let t = 100; t <= 160; t += 0.1) {
    const checking = t >= 144 && t < 147;
    const e = clock.step(t, checking);
    if (e) events.push({ e, at: +(t - 100).toFixed(1) });
  }
  const warn = events.find((x) => x.e === 'Warn');
  const out = events.find((x) => x.e === 'KickOut');
  report(events.length === 2 && warn && Math.abs(warn.at - H.KickOutWarning) < 0.11 && out && Math.abs(out.at - 47) < 0.11,
    `hide spots: the warning at ${H.KickOutWarning} s, out at ${H.KickOutSeconds} s (held while a breath check runs)`, JSON.stringify(events));
}

// 13. soak: every level, a wandering and sometimes noisy player
{
  let worst = 0;
  let worstAt = null;
  const levels = ['Level0_Basement', 'Level1_Hallways', 'Level2_ScienceHall', 'Level3_Gymnasium', 'Level4_FloodedPool', 'Level5_Roof'];
  const per = {};
  const over = [];
  for (const level of levels) {
    const s = session();
    const svc = s.creature.service;
    s.creature.beginRun({ difficulty: level === 'Level3_Gymnasium' ? 'Nightmare' : 'Standard' });
    s.creature.activateLevel(level);
    hideFar(s, level);
    s.player.moveState = 'Standing';
    s.player.flashlight.on = level !== 'Level0_Basement';
    const pts = samplesOf(level).map((p) => p.position);
    const t0 = Date.now();
    let k = 0;
    let downs = 0;
    advance(s, SOAK, () => {
      const t = s.engine.loop.time;
      if (s.player.lifeState === 'Downed' || s.player.lifeState === 'Dead') {
        // back on their feet a while later (a revive), somewhere else
        if (Math.round(t * 30) % 300 === 0) {
          downs += 1;
          s.player.setLifeState('Alive');
          s.player.moveState = 'Standing';
          s.player.place(pts[(k++ * 13) % pts.length]);
        }
        return false;
      }
      if (Math.round(t * 30) % 90 === 0 && pts.length) {
        const p = pts[(k++ * 7) % pts.length];
        s.player.place(p);
        s.player.lookAt(p.clone().add(new THREE.Vector3(Math.sin(k) * 10, PLAYER_ROOT + 1.5, Math.cos(k) * 10)));
        if (k % 4 === 0) s.engine.noise.sampleLocomotion(p.clone(), 'Sprinting', 19, { level });
        if (k % 9 === 0) s.engine.noise.emit(p.clone().add(new THREE.Vector3(0, 1, 0)), 'ObjectiveClunk', { source: 'player', level });
      }
      // the state bounds
      const held = t - s.stateAt;
      const bound = STATE_BOUND[svc.state];
      if (bound && held > bound && !svc.catching) over.push({ level, state: svc.state, held: +held.toFixed(1) });
      if (svc.warp && t - svc.warp.startedAt > 30) over.push({ level, warp: svc.warp.kind, phase: svc.warp.phase });
      return false;
    });
    const wall = (Date.now() - t0) / 1000;
    const visited = [...new Set(s.events.states.map((e) => e.next))];
    per[level] = { maxStuck: +s.stuck.max.toFixed(2), unsticks: svc.unsticks || 0, state: svc.state, medium: svc.mover.getMedium(),
      teleports: svc.teleports, catches: s.events.caught.length, downs, visited: visited.join('/'), cpuSeconds: +wall.toFixed(1) };
    if (s.stuck.max > worst) {
      worst = s.stuck.max;
      worstAt = { level, ...s.stuck.maxAt };
    }
  }
  summary.soak = { seconds: SOAK, per, worst: +worst.toFixed(2), worstAt, over: over.slice(0, 5) };
  for (const [level, r] of Object.entries(per)) {
    console.log(`      ${level}: longest no-progress ${r.maxStuck} s, repositions ${r.unsticks}, teleports ${r.teleports}, catches ${r.catches}, states ${r.visited}, ${r.cpuSeconds} s CPU`);
  }
  report(worst <= STUCK_WINDOW, `soak: never stuck past the stuck window (${STUCK_WINDOW.toFixed(1)} s) over ${SOAK} s on each of 6 levels`,
    `worst ${worst.toFixed(2)} s${worstAt ? ` (${worstAt.level}, ${worstAt.state})` : ''}`);
  report(over.length === 0, 'soak: no state or warp held past its bound', over.length ? JSON.stringify(over.slice(0, 3)) : 'none');
}

// 13b. graphics never change gameplay: the same run with the render loop at 20 and at 144 fps (and one frame per tick)
// makes the same decisions in the same places, tick for tick; the light it reads is the baked probe, never the flicker
{
  const trace = (fps) => {
    const s = session({ fps });
    const svc = s.creature.service;
    s.creature.beginRun({ difficulty: 'Standard' });
    s.creature.activateLevel(LEVEL);
    hideFar(s, LEVEL);
    s.player.moveState = 'Standing';
    s.player.flashlight.on = true;
    const pts = samplesOf(LEVEL).map((p) => p.position);
    const rows = [];
    let k = 0;
    for (let i = 0; i < Math.round(150 / TICK); i++) {
      if (s.player.lifeState !== 'Alive' && i % 300 === 0) {
        s.player.setLifeState('Alive');
        s.player.moveState = 'Standing';
      }
      if (i % 90 === 0 && pts.length) {
        const p = pts[(k++ * 11) % pts.length];
        s.player.place(p);
        s.player.lookAt(p.clone().add(new THREE.Vector3(Math.sin(k) * 10, PLAYER_ROOT + 1.5, Math.cos(k) * 10)));
        if (k % 3 === 0) s.engine.noise.sampleLocomotion(p.clone(), 'Sprinting', 19, { level: LEVEL });
      }
      s.engine.loop.step();
      const p = svc.body.getPosition();
      const v = svc.viewState();
      rows.push(`${v.state}|${p.x.toFixed(6)}|${p.y.toFixed(6)}|${p.z.toFixed(6)}|${v.action}|${v.fade.toFixed(5)}|${svc.body.hidden}|${s.events.caught.length}`);
    }
    return { rows, states: [...new Set(s.events.states.map((e) => e.next))], catches: s.events.caught.length, teleports: svc.teleports };
  };
  const slow = trace(20);
  const fast = trace(144);
  const tick = trace(null);
  let first = -1;
  for (let i = 0; i < slow.rows.length; i++) {
    if (slow.rows[i] !== fast.rows[i] || slow.rows[i] !== tick.rows[i]) {
      first = i;
      break;
    }
  }
  report(first < 0 && slow.rows.length === fast.rows.length, 'graphics never change gameplay: 20 fps and 144 fps render loops give the same decisions and positions, tick for tick',
    first < 0 ? `${slow.rows.length} ticks identical (states ${slow.states.join('/')}, ${slow.catches} catches, ${slow.teleports} teleports)`
      : `first difference at tick ${first}: 20 fps ${slow.rows[first]} / 144 fps ${fast.rows[first]} / per tick ${tick.rows[first]}`);
}

// 14. determinism
{
  const again = scenarioPatrol();
  const same = again.pathLength === p1.pathLength && again.end.distanceTo(p1.end) < 1e-9;
  report(same, 'determinism: the same run gives the same path', `${again.pathLength} / ${p1.pathLength} samples`);
}

// 15. the pool (Level 4 fairness)
{
  const POOL = 'Level4_FloodedPool';
  const W = CreatureConfig.Water;
  const basin = meta.basins.find((b) => b.level === POOL);
  const o = basin.origin;
  const box = { minX: o[0] + basin.rect.x, maxX: o[0] + basin.rect.x + basin.rect.w, minZ: o[2] + basin.rect.z, maxZ: o[2] + basin.rect.z + basin.rect.d };
  const surface = o[1] + basin.waterLevel;
  const cx = (box.minX + box.maxX) / 2;
  const swimAt = (x, z) => new THREE.Vector3(x, surface - 1, z);
  /** A session on Level 4: the player on the natatorium deck (the grace starts), awake and past the grace. */
  const poolSession = (skipGrace = true) => {
    const s = session();
    s.creature.beginRun({ difficulty: 'Standard' });
    s.creature.activateLevel(POOL);
    s.grabs = [];
    s.telegraphs = [];
    s.grabResult = false;
    s.creature.registerPoolGrabber(() => {
      s.grabs.push(s.engine.loop.time);
      return s.grabResult;
    });
    s.creature.service.lungeTelegraph.connect((origin, seconds) => s.telegraphs.push({ at: s.engine.loop.time, origin: origin.clone(), seconds }));
    hideFar(s, POOL);
    s.player.moveState = 'Standing';
    s.player.place(new THREE.Vector3(box.minX - 4, o[1], (box.minZ + box.maxZ) / 2));
    if (skipGrace) advance(s, W.PoolGraceSeconds + 1);
    return s;
  };
  /** The swimmer at `p` in `state`, its locomotion heard at 10 Hz. */
  const swim = (s, p, state, speed) => {
    s.player.mode = 'Swim';
    s.player.moveState = state;
    s.player.body.position.copy(p);
    if (Math.round(s.engine.loop.time * 30) % 3 === 0) {
      s.engine.noise.sampleLocomotion(p.clone().add(new THREE.Vector3(0, -2, 0)), state, speed, { level: POOL });
    }
  };
  const putInWater = (s, p, toward, release = 'AquaticStalk') => {
    const svc = s.creature.service;
    svc.swimmerAt = s.engine.loop.time;
    svc.swimmerPlayer = PLAYER;
    const h = s.creature.acquireScripted('sim');
    const at = new THREE.Vector3(p.x, surface - 2.5, p.z);
    h.teleport(new THREE.Matrix4().lookAt(at, new THREE.Vector3(toward.x, at.y, toward.z), new THREE.Vector3(0, 1, 0)).setPosition(at));
    h.setHidden(false);
    h.release(release);
  };
  const lungeLeg = (svc) => !!(svc.mover.legs[0] && svc.mover.legs[0].kind === 'Swim' && svc.mover.legs[0].lunge);
  const pool = {};

  // the grace: a loud swimmer right over it in the first seconds after entering the natatorium is left alone
  {
    const s = poolSession(false);
    advance(s, 5);
    const svc = s.creature.service;
    putInWater(s, new THREE.Vector3(cx, 0, box.minZ + 20), new THREE.Vector3(cx, 0, box.minZ + 30), 'Patrol');
    svc.swimmerAt = -Infinity;
    const enteredAt = svc.poolEnteredAt;
    const until = enteredAt + W.PoolGraceSeconds - 0.5;
    let stalked = false;
    while (s.engine.loop.time < until) {
      swim(s, swimAt(cx, box.minZ + 26), 'Freestyle', 9);
      s.engine.loop.step();
      watch(s);
      if (svc.state === 'AquaticStalk' || svc.state === 'WallChase') stalked = true;
    }
    pool.grace = { enteredAt, telegraphs: s.telegraphs.length, grabs: s.grabs.length, stalked };
    report(enteredAt !== null && s.telegraphs.length === 0 && s.grabs.length === 0 && !stalked,
      `pool: the ${W.PoolGraceSeconds} s grace after entering the natatorium (a loud swimmer 6 studs off is left alone)`,
      JSON.stringify(pool.grace));
  }

  // outswimming it: a freestyle swimmer heading away from a stalker 8 studs off
  {
    const s = poolSession();
    const svc = s.creature.service;
    putInWater(s, new THREE.Vector3(cx, 0, box.minZ + 12), new THREE.Vector3(cx, 0, box.maxZ));
    let z = box.minZ + 20;
    for (let i = 0; i < 3; i++) {
      swim(s, swimAt(cx, z), 'Treading', 0);
      s.engine.loop.step();
    }
    const start = svc.body.getPosition().distanceTo(swimAt(cx, z));
    let maxSwim = 0;
    let prev = svc.body.getPosition().clone();
    let placements = svc.body.placements;
    let minGap = Infinity;
    for (let i = 0; i < 8 * 30 && z < box.maxZ - 4; i++) {
      z += 9 * TICK;
      swim(s, swimAt(cx, z), 'Freestyle', 9);
      s.engine.loop.step();
      watch(s);
      const here = svc.body.getPosition();
      if (svc.mover.getMedium() === 'Water' && !lungeLeg(svc) && placements === svc.body.placements) maxSwim = Math.max(maxSwim, here.distanceTo(prev) / TICK);
      prev = here.clone();
      placements = svc.body.placements;
      minGap = Math.min(minGap, here.distanceTo(swimAt(cx, z)));
    }
    const end = svc.body.getPosition().distanceTo(swimAt(cx, z));
    pool.outswim = { start: +start.toFixed(1), end: +end.toFixed(1), minGap: +minGap.toFixed(1), grabs: s.grabs.length,
      telegraphs: s.telegraphs.length, maxSwim: +maxSwim.toFixed(2), state: svc.state };
    report(s.grabs.length === 0 && end > start + 5 && minGap > 4.5, 'pool: a freestyle swimmer outswims it (no grab, the gap grows)', JSON.stringify(pool.outswim));
    report(maxSwim <= CreatureConfig.Speeds.AquaticStalk + 0.05, `pool: it never swims faster than AquaticStalk (${CreatureConfig.Speeds.AquaticStalk}) outside a lunge`, `max ${maxSwim.toFixed(2)} studs/s`);
  }

  // every lunge is telegraphed; a grab sends it to the far end for GrabRetreatSeconds
  {
    const s = poolSession();
    const svc = s.creature.service;
    putInWater(s, new THREE.Vector3(cx, 0, box.minZ + 30), new THREE.Vector3(cx, 0, box.minZ + 40));
    const spot = swimAt(cx, box.minZ + 36);
    const lunges = [];
    let was = false;
    let grabsSeen = 0;
    const stepTracked = (state, speed) => {
      swim(s, spot, state, speed);
      const before = svc.body.getPosition().clone();
      s.engine.loop.step();
      watch(s);
      const now = lungeLeg(svc);
      if ((now && !was) || (s.grabs.length > grabsSeen && !was)) lunges.push({ at: s.engine.loop.time, position: before });
      grabsSeen = s.grabs.length;
      was = now;
    };
    for (let i = 0; i < 8 * 30; i++) stepTracked('Freestyle', 9);
    for (let i = 0; i < 12 * 30 && lunges.length < 3; i++) stepTracked('Treading', 1);
    const growls = s.engine.audio.played.filter((p) => p.name === 'CreatureGrowl');
    const firstOf = new Set();
    const told = lunges.map((l) => {
      const t = s.telegraphs.filter((x) => x.at <= l.at).pop();
      const growl = growls.filter((g) => g.at <= l.at).pop();
      const first = !!t && !firstOf.has(t);
      if (t) firstOf.add(t);
      return { lead: t ? +(l.at - t.at).toFixed(2) : null, first, fromOrigin: t ? +t.origin.distanceTo(l.position).toFixed(2) : null,
        growlAtOrigin: !!growl && !!t && growl.position && growl.position.distanceTo(t.origin) < 0.01 };
    });
    const allTold = lunges.length > 0 && told.every((x) => x.lead !== null && x.lead >= W.TelegraphSeconds - 0.05 &&
      x.lead <= W.TelegraphSeconds + W.LungeWindow + 0.1 && x.growlAtOrigin && (!x.first || x.fromOrigin < 1));
    const grabAfter = s.grabs.length > 0 && s.telegraphs.length > 0 && s.grabs[0] - s.telegraphs[0].at >= W.TelegraphSeconds - 0.05;
    pool.telegraph = { lunges: lunges.length, telegraphs: s.telegraphs.length, told, grabs: s.grabs.length };
    report(allTold, `pool: every lunge is telegraphed ${W.TelegraphSeconds} s ahead (held still, the growl at its origin)`,
      `${lunges.length} strikes after ${s.telegraphs.length} telegraphs: ${JSON.stringify(told.filter((x) => x.first))}`);
    report(grabAfter, 'pool: the grab comes only after the telegraph', s.grabs.length ? `grab ${(s.grabs[0] - s.telegraphs[0].at).toFixed(2)} s after it` : 'no grab');
    s.grabResult = true;
    for (let i = 0; i < 12 * 30 && !svc.grabbed; i++) {
      swim(s, spot, 'Treading', 1);
      s.engine.loop.step();
    }
    const grabbed = !!svc.grabbed;
    s.player.moveState = 'Grabbed';
    advance(s, 2);
    s.player.moveState = 'Treading';
    advance(s, 1.5);
    const releasedAt = s.engine.loop.time;
    const t0 = s.telegraphs.length;
    const g0 = s.grabs.length;
    let near = Infinity;
    let far = 0;
    while (s.engine.loop.time < releasedAt + W.GrabRetreatSeconds - 2) {
      swim(s, spot, 'Freestyle', 9);
      s.engine.loop.step();
      watch(s);
      const d = svc.body.getPosition().distanceTo(spot);
      if (s.engine.loop.time > releasedAt + 6) near = Math.min(near, d);
      far = Math.max(far, d);
    }
    pool.retreat = { grabbed, telegraphs: s.telegraphs.length - t0, grabs: s.grabs.length - g0, nearestAfter6s: +near.toFixed(1), farthest: +far.toFixed(1), state: svc.state };
    report(grabbed && s.telegraphs.length === t0 && s.grabs.length === g0 && near > 25,
      `pool: after a grab it retreats to the far end and leaves the swimmer alone for ${W.GrabRetreatSeconds} s`, JSON.stringify(pool.retreat));
  }

  // it never climbs out onto the deck: in and out of the water only by fading, out of sight, well away from them
  {
    const s = poolSession();
    const svc = s.creature.service;
    putInWater(s, new THREE.Vector3(box.minX + 6, 0, box.minZ + 50), new THREE.Vector3(box.minX - 10, 0, box.minZ + 50), 'Patrol');
    svc.swimmerAt = -Infinity;
    s.player.mode = 'OnFoot';
    s.player.moveState = 'Standing';
    s.player.flashlight.on = true;
    s.player.place(new THREE.Vector3(box.minX - 6, o[1], box.minZ + 50));
    let medium = svc.mover.getMedium();
    const changes = [];
    for (let i = 0; i < 40 * 30; i++) {
      const placements = svc.body.placements;
      s.engine.loop.step();
      watch(s);
      const m = svc.mover.getMedium();
      if (m !== medium) {
        const p = svc.body.getPosition();
        changes.push({ from: medium, to: m, warped: svc.body.placements !== placements || !!svc.warp || svc.body.hidden,
          fromPlayer: +p.distanceTo(s.player.body.position).toFixed(1), seen: svc._visible(p) });
        medium = m;
      }
    }
    const out = changes.find((c) => c.from === 'Water' && c.to === 'Floor');
    pool.sealed = { changes, state: svc.state, catches: s.events.caught.length };
    report(!!out && changes.every((c) => c.warped) && out.fromPlayer >= W.ExitMin - 0.5 && !out.seen,
      `pool: it never climbs out (it fades out under the water and in on land out of sight, ${W.ExitMin}+ studs away)`, JSON.stringify(pool.sealed));
  }
  summary.pool = pool;
}

// the global fairness checks (every scenario's every tick)
report(fairness.maxSpeed.v <= SPRINT, `fairness: never faster than a sprinting player (${SPRINT}) outside Scripted`,
  `max ${fairness.maxSpeed.v.toFixed(2)} studs/s ${JSON.stringify({ ...fairness.maxSpeed, v: undefined })}`);
report(fairness.materialised.length > 0 && fairness.badMaterial.length === 0,
  'fairness: it never teleports into view nor within 12 studs (every one warned 1.6 s ahead, 12-24 studs of walking)',
  `${fairness.materialised.length} materialisations, ${fairness.badMaterial.length} bad${fairness.badMaterial.length ? ` ${JSON.stringify(fairness.badMaterial.slice(0, 2))}` : ''}`);
report(fairness.catches > 0 && fairness.wallCatches.length === 0, 'fairness: it never catches through a wall',
  `${fairness.catches} catches, ${fairness.wallCatches.length} through a wall`);
report(fairness.nan === 0, 'fairness: no NaN in the body or the view contract', `${fairness.nan} ticks`);
summary.fairness = { maxSpeed: fairness.maxSpeed, materialised: fairness.materialised.length, bad: fairness.badMaterial, wallCatches: fairness.wallCatches, nan: fairness.nan };

if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify({ results, summary }, null, 2));
console.log(failed ? '[sim] FAILED' : '[sim] all passed');
process.exit(failed ? 1 : 0);
