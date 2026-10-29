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


const LEVEL = process.argv[2] || 'Level2_ScienceHall';
const s = session();
s.creature.beginRun({ difficulty: 'Standard' });
s.creature.activateLevel(LEVEL);
hideFar(s, LEVEL);
const svc = s.creature.service;
const until = Number(process.argv[3] || 240);
const log = [];
let lastState = '';
for (let t = 0; t < until; t += 0.25) {
  advance(s, 0.25);
  const m = svc.mover;
  const leg = m.legs[0];
  const p = svc.body.getPosition();
  log.push(`${s.engine.loop.time.toFixed(2)} ${svc.state} ${m.getStatus()} ${m.getMedium()} pos ${p.x.toFixed(1)} ${p.y.toFixed(2)} ${p.z.toFixed(1)} leg ${leg && leg.kind} goal ${leg && leg.goal ? leg.goal.toArray().map(v=>v.toFixed(1)).join(',') : ''} wps ${m.walk ? m.walk.waypoints.map(w=>w.x.toFixed(0)+'/'+w.y.toFixed(0)+'/'+w.z.toFixed(0)).join(' ') : ''} idx ${m.walk && m.walk.index} unsticks ${svc.unsticks||0}`);
}
const at = s.stuck.maxAt;
console.log('max', s.stuck.max.toFixed(2), at && at.t.toFixed(2), at && at.state, at && at.position.toArray().map(v=>v.toFixed(1)).join(','));
const k = log.findIndex((l) => Number(l.split(' ')[0]) >= at.t);
for (const l of log.slice(Math.max(0, k - 28), k + 6)) console.log(l);
