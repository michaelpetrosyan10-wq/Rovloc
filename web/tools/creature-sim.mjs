// Headless test of the Creature (W3) on the real world data, on a fake clock.
//
//   node tools/creature-sim.mjs [--build <dir>] [--soak <seconds>] [--json <file>]
//
// The engine pieces that hold no GPU or DOM state are the real ones (W2's World with its BVHs and probes, Entities
// with their colliders and attributes, the NoiseBus); the loop, the player, audio, input and UI are stand-ins with the
// engine's surface, driven tick by tick (30 Hz, the brain at 10 Hz, the rig animated every tick). Scenarios:
//   1. patrol       Level 1 wakes; the Creature walks its patrol loops (waypoints reached, distance covered).
//   2. investigate  a FloorDebris noise in another room: it goes there (InvestigateNoise) and searches.
//   3. catch        a stationary, lit player in sight down a corridor: WallChase, then a Hallway catch whose
//                   outcome downs the player (first catch); a second catch executes.
//   4. lose hidden  the player is seen, then hides: the chase runs out (memory, then a search), no catch.
//   5. vent chase   a crawler gives itself away (VentScurry in a duct): it goes in through a grate (kicking it) and
//                   catches them in the duct (Vent).
//   6. soak         patrols every level 1..5 for --soak seconds each: it never stays stuck past the stuck window
//                   (a stall, a fresh route, a second stall, then the unseen reposition) and nothing throws.
//   7. determinism  scenario 1 twice gives the same path.
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
import { nearest, path as ventPath } from '../src/creature/ventgraph.js';

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

// ---------------------------------------------------------------------------------------------------------------
// The engine stand-in
// ---------------------------------------------------------------------------------------------------------------

console.log(`[sim] decoding ${buildDir}`);
const meta = JSON.parse(fs.readFileSync(path.join(buildDir, 'world.json'), 'utf8'));
const binBuf = fs.readFileSync(path.join(buildDir, 'world.bin'));
const decoded = decodeWorld(meta, binBuf.buffer.slice(binBuf.byteOffset, binBuf.byteOffset + binBuf.byteLength));

class SimLoop {
  constructor() {
    this.time = 0;
    this.alpha = 0;
    this.tickDt = TICK;
    this.ticks = [];
    this.frames = [];
  }

  onTick(fn) {
    this.ticks.push(fn);
    return () => this.ticks.splice(this.ticks.indexOf(fn), 1);
  }

  onFrame(fn) {
    this.frames.push(fn);
    return () => this.frames.splice(this.frames.indexOf(fn), 1);
  }

  step() {
    this.time += TICK;
    for (const f of this.ticks.slice()) f(TICK);
    for (const f of this.frames.slice()) f(TICK, 1);
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
    const h = this.moveState === 'VentCrawling' ? -0.6 : this.moveState === 'DownedCrawling' ? -0.8 : 1.5;
    return out.copy(this.body.position).add(new THREE.Vector3(0, h, 0));
  }

  look() {
    const cp = Math.cos(this.pitch);
    return { yaw: this.yaw, pitch: this.pitch, direction: new THREE.Vector3(-Math.sin(this.yaw) * cp, Math.sin(this.pitch), -Math.cos(this.yaw) * cp) };
  }

  setLook(yaw, pitch) {
    this.yaw = yaw;
    this.pitch = pitch;
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

function makeEngine() {
  const shared = createSharedUniforms();
  const quality = { budget: { normalMaps: false, anisotropy: 1, flashlightShadow: false }, changed: { connect() {} } };
  const world = new World(decoded, {}, { shared, quality });
  const engine = { world, shared, loop: new SimLoop(), currentLevel: null };
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
// Helpers
// ---------------------------------------------------------------------------------------------------------------

const results = [];
let failed = false;
function report(ok, name, detail = '') {
  results.push({ ok, name, detail });
  if (!ok) failed = true;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  ${detail}` : ''}`);
}

/** A run of the Creature on a fresh engine. */
function session() {
  const engine = makeEngine();
  const creature = createCreature(engine);
  const s = {
    engine,
    creature,
    player: engine.player,
    events: { caught: [], finished: [], states: [] },
    stuck: { anchor: null, since: 0, max: 0, maxAt: null },
    path: [],
  };
  creature.stateChanged.connect((next, prev) => s.events.states.push({ at: engine.loop.time, next, prev }));
  creature.caught.connect((_p, kind) => s.events.caught.push({ at: engine.loop.time, kind }));
  creature.jumpscareFinished.connect((_p, kind, outcome) => s.events.finished.push({ at: engine.loop.time, kind, outcome }));
  return s;
}

/** Advances `seconds` (stopping early when `until()` holds); tracks the stuck windows. Returns seconds taken. */
function advance(s, seconds, until) {
  const ticks = Math.round(seconds / TICK);
  for (let i = 0; i < ticks; i++) {
    s.engine.loop.step();
    trackStuck(s);
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
  const trying = !!m && m.getStatus() === 'Moving' && !m.busy() && !svc.catching && svc.state !== 'Dormant' && svc.state !== 'Scripted' && svc.awake;
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
  // the player tucked away (Hiding: never seen) at the waypoint farthest from the Creature
  const svc = s.creature.service;
  const here = svc.body.getPosition();
  const wps = waypointsOf(levelId).sort((a, b) => b.position.distanceTo(here) - a.position.distanceTo(here));
  s.player.place(wps[0].position);
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
    if (svc.state !== 'Patrol' || !goal || svc.mover.busy()) return false;
    const eye = svc._creatureEye();
    const playerEye = goal.clone().add(new THREE.Vector3(0, PLAYER_ROOT + 1.5, 0));
    const d = eye.distanceTo(playerEye);
    const toward = playerEye.clone().sub(eye).normalize();
    if (d < min || d > max || toward.dot(svc.body.getCFrame().lookVector) < 0.8 || !s.engine.world.lineClear(eye, playerEye)) return false;
    s.player.moveState = 'Standing';
    s.player.flashlight.on = true;
    s.player.place(goal);
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
  h.release(release);
}

// ---------------------------------------------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------------------------------------------

const LEVEL = 'Level1_Hallways';
const summary = {};

function scenarioPatrol(seed) {
  const s = session();
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(LEVEL);
  hideFar(s, LEVEL);
  advance(s, 4.6);
  const awake = s.creature.getState();
  const start = s.creature.service.body.getPosition();
  const reached = new Set();
  const wps = waypointsOf(LEVEL);
  let travelled = 0;
  let last = start.clone();
  const ticks = Math.round(60 / TICK);
  for (let i = 0; i < ticks; i++) {
    s.engine.loop.step();
    trackStuck(s);
    const p = s.creature.service.body.getPosition();
    travelled += Math.hypot(p.x - last.x, p.z - last.z);
    last = p;
    for (const w of wps) if (Math.hypot(w.position.x - p.x, w.position.z - p.z) <= 2.6) reached.add(w.id);
  }
  return { s, awake, reached: reached.size, travelled, state: s.creature.getState(), end: s.creature.service.body.getPosition(), pathLength: s.path.length };
}

const p1 = scenarioPatrol(1);
summary.patrol = { awake: p1.awake, reached: p1.reached, travelled: +p1.travelled.toFixed(1), state: p1.state, maxStuck: +p1.s.stuck.max.toFixed(2) };
report(p1.awake === 'Patrol', 'patrol: wakes into Patrol WakeDelay after the level activates', `state ${p1.awake}`);
report(p1.reached >= 5 && p1.travelled >= 250, 'patrol: walks its loops', `${p1.reached} waypoints reached, ${p1.travelled.toFixed(0)} studs in 60 s`);

// 2. investigate a noise (the airlock grace is long over)
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
  report(searched >= 0, 'investigate: searches, then patrols again', `after ${searched.toFixed(1)} s`);
}

// 3. chase and catch a stationary visible player; a second catch executes
{
  const s = session();
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(LEVEL);
  hideFar(s, LEVEL);
  advance(s, 14);
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
    // the catch cooldown and the breather pass; the downed player is caught again: executed
    const second = advance(s, 150, () => s.events.finished.length > 1);
    const last = s.events.finished[1];
    report(second >= 0 && !!last && last.outcome === 'Executed' && s.player.lifeState === 'Dead', 'catch: a catch of a downed player executes',
      last ? `${last.outcome} after ${second.toFixed(1)} s more` : `no second catch (state ${s.creature.getState()}, life ${s.player.lifeState})`);
    summary.catch = { distance, chased, caughtIn, first: first && first.outcome, second: last && last.outcome, secondAfter: second };
  }
}

// 4. loses a hidden player
{
  const s = session();
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(LEVEL);
  hideFar(s, LEVEL);
  advance(s, 14);
  const distance = ambush(s, 35, 70, 180);
  const chased = advance(s, 1.5, () => s.creature.getState() === 'WallChase');
  advance(s, 0.4);
  s.player.moveState = 'Hiding';
  const gaveUp = advance(s, 40, () => s.creature.getState() !== 'WallChase');
  const after = s.creature.getState();
  advance(s, 30);
  report(distance > 0 && chased >= 0 && gaveUp >= 0 && s.events.caught.length === 0, 'lose hidden: the chase runs out and nobody is caught',
    `seen ${distance.toFixed(0)} studs ahead, chase ended ${gaveUp.toFixed(1)} s after hiding -> ${after}, catches ${s.events.caught.length}`);
  summary.loseHidden = { distance, chased, gaveUp, after, catches: s.events.caught.length, maxStuck: +s.stuck.max.toFixed(2) };
}

// 5. vent chase
{
  const s = session();
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(LEVEL);
  hideFar(s, LEVEL);
  advance(s, 14);
  const svc = s.creature.service;
  const graph = svc.ctx.graph;
  let chosen = null;
  for (const gid of graph.grateIds) {
    const grate = graph.grates[gid];
    const state = s.creature.env.grateState(gid);
    if (state === 'Locked') continue;
    // a node two ducts in from the grate's node
    for (const id of graph.ids) {
      const [route] = ventPath(graph, grate.nodeId, id);
      if (route && route.length === 3) {
        chosen = { grate, node: id };
        break;
      }
    }
    if (chosen) break;
  }
  const stand = svc._grateStandPoint(chosen.grate);
  const crawlAt = graph.nodes[chosen.node].position.clone();
  s.player.place(crawlAt, 'Vent');
  const into = stand.position.clone().add(stand.lookVector.clone().multiplyScalar(-3));
  stage(s, stand.position.clone().add(stand.lookVector.clone().multiplyScalar(4)), into);
  advance(s, 0.3);
  s.engine.noise.emit(crawlAt, 'VentScurry', { source: 'player', level: LEVEL, ventNodeId: chosen.node, medium: 'Vent' });
  const ventChase = advance(s, 1, () => svc.state === 'VentChase');
  const inside = advance(s, 20, () => svc.mover.getMedium() === 'Vent');
  const caughtIn = advance(s, 20, () => s.events.caught.length > 0);
  const kicked = s.creature.env.grateState(chosen.grate.id);
  report(ventChase >= 0, 'vent chase: a scurrying crawler starts VentChase', `grate ${chosen.grate.id} (${kicked}), crawler at ${chosen.node}`);
  report(inside >= 0, 'vent chase: it goes in through the grate', inside >= 0 ? `inside after ${inside.toFixed(1)} s` : `state ${svc.state} medium ${svc.mover.getMedium()}`);
  report(caughtIn >= 0 && s.events.caught[0].kind === 'Vent', 'vent chase: it catches the crawler in the duct (Vent)', caughtIn >= 0 ? `after ${caughtIn.toFixed(1)} s` : 'no catch');
  summary.ventChase = { grate: chosen.grate.id, grateState: kicked, ventChase, inside, caughtIn };
}

// 6. soak: patrol every level; never stuck past the window
{
  let worst = 0;
  let worstAt = null;
  const levels = ['Level1_Hallways', 'Level2_ScienceHall', 'Level3_Gymnasium', 'Level4_FloodedPool', 'Level5_Roof'];
  const per = {};
  for (const level of levels) {
    const s = session();
    s.creature.beginRun({ difficulty: 'Standard' });
    s.creature.activateLevel(level);
    hideFar(s, level);
    const t0 = Date.now();
    advance(s, SOAK);
    const wall = (Date.now() - t0) / 1000;
    const svc = s.creature.service;
    per[level] = { maxStuck: +s.stuck.max.toFixed(2), unsticks: svc.unsticks || 0, state: svc.state, medium: svc.mover.getMedium(), cpuSeconds: +wall.toFixed(1) };
    if (s.stuck.max > worst) {
      worst = s.stuck.max;
      worstAt = { level, ...s.stuck.maxAt };
    }
  }
  summary.soak = { seconds: SOAK, per, worst: +worst.toFixed(2), worstAt };
  for (const [level, r] of Object.entries(per)) console.log(`      ${level}: longest no-progress ${r.maxStuck} s, unseen repositions ${r.unsticks}, ends ${r.state}/${r.medium}, ${r.cpuSeconds} s CPU`);
  report(worst <= STUCK_WINDOW, `soak: never stuck past the stuck window (${STUCK_WINDOW.toFixed(1)} s) over ${SOAK} s on each of 5 levels`,
    `worst ${worst.toFixed(2)} s${worstAt ? ` (${worstAt.level}, ${worstAt.state})` : ''}`);
}

// 7. determinism
{
  const again = scenarioPatrol(2);
  const same = again.pathLength === p1.pathLength && again.end.distanceTo(p1.end) < 1e-9;
  report(same, 'determinism: the same run gives the same path', `${again.pathLength} / ${p1.pathLength} samples`);
}

if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify({ results, summary }, null, 2));
console.log(failed ? '[sim] FAILED' : '[sim] all passed');
process.exit(failed ? 1 : 0);
