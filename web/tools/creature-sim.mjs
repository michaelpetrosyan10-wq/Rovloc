// Headless test of the Creature ("the Tall Man", Tunnels §2) on the real world data, on a fake clock.
//
//   node tools/creature-sim.mjs [--build <dir>] [--soak <seconds>] [--json <file>]
//
// The engine pieces that hold no GPU or DOM state are the real ones (sim-engine.mjs: World with its BVHs and probes,
// Entities with their colliders and attributes, the NoiseBus); the loop, the player, audio, input and UI are stand-ins
// with the engine's surface, driven tick by tick (30 Hz, the brain at 10 Hz, the rig animated every tick). Every tick of every
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
//   LOS rule      seen, then gone round a corner: the chase searches the presence layer's LostSeconds (4 [6]) after
//                 the last sight.
//   the cap       a player kept in sight, out of reach: the chase gives up at its cap (12 [45] s) and fades away
//                 (also on Nightmare, never past a sprinter's pace).
//   vents         a crawler scurrying in a duct is never followed in: it never enters the ducts, nobody is caught.
//   stare         a held stare (7 deg, 1 s, within 18 studs in the dark) from behind starts a chase; a glance does not.
//   teleport      nobody seen for 25 s: grace + 45 s before the first; every one warned 1.6 s ahead, out of view,
//                 never within 12 studs, 12-24 studs of walking from the target; the target looking back gets the
//                 reveal; none while the game blocks them or within 25 s of a catch; a stalk whose mover sticks ends
//                 there (never its warp and warning replayed).
//   hiding        it sees a player climb into a locker: it stands facing it; the grunt then the LookAway; slipping
//                 out during a LookAway and breaking the line escapes; stepping out under its nose is a catch; the
//                 ReachIn at 30 s; after a long walk to the spot (Nightmare) still one LookAway before the reach; a
//                 teammate's pull-out is no catch (co-op unit test, a remote handle).
//   fake-outs     the seeded fake-out spots: about 1 in 12, at most one per floor per player (hidespots.js); the
//                 stay limit: the warning at 35 s, shoved out at 45 s (held while a breath check runs).
//   soak          every level, a wandering, noisy player for --soak seconds each: never stuck past the stuck
//                 window, no state held past its bound, no NaN, nothing throws.
//   determinism   the patrol twice gives the same path.
//   presence      (docs/MONSTER.md 15-18; the numbers asserted are the spec's, SPEC, and the config is held to them)
//                 the director's search hints (30..55 walked, never in view, 8 s apart) bring
//                 it into the leash; the approach teleport is warned, 45..80 walked, out of view, past the grace, 25 s
//                 apart; each beat (Peek, Glimpse, PassBy, Shadow) keeps 25 walked off its player, never chases on
//                 sight alone and ends (the Shadow freezes under a look); noticing (a glimpse far off starts no chase,
//                 staying in sight does); the chase's wind-up (longer for a target met within SurpriseRange; no
//                 catch during it) and
//                 pursuit; a beat that never reached its player is no encounter; a pass-by is never planned for a
//                 player on the run, a shadow never for a sprinter (and its player is the target it publishes); a
//                 runner is approached only ahead, past their lead; the torch's glow; standing still in the dark;
//                 co-op attention (a teammate left alone becomes the focus).
// Exit code 1 on any failure.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';
import { WorldConfig } from '../src/engine/config.js';
import { createCreature, PLAYER } from '../src/creature/index.js';
import { CreatureConfig, ROOT_HEIGHT, difficultySpec } from '../src/creature/config.js';
import { FloorNav } from '../src/creature/nav.js';
import { presenceConfig } from '../src/creature/presence.js';
import { fakeoutSpots, FakeoutBudget, StayClock } from '../src/game/mechanics/hidespots.js';
import { PLAYER_ROOT, TICK, loadWorld, makeEngine } from './sim-engine.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : fallback;
};
const buildDir = path.resolve(opt('--build', path.join(here, '..', 'build')));
const SOAK = Number(opt('--soak', '240'));
const jsonOut = opt('--json', null);

const STUCK_WINDOW = 2 * CreatureConfig.Repath.StuckSeconds + 0.2; // stall, fresh route, stall, then reposition
const SPRINT = 19;
const T = CreatureConfig.Teleport;
const H = CreatureConfig.Hiding;
// the longest each state may run before the soak calls it stuck (Patrol and the levels' holds are open-ended)
const STATE_BOUND = { InvestigateNoise: 70, Search: 40, HidingResponse: 45, Teleport: 40, WallChase: 50, Stunned: 15, Peek: 40,
  Glimpse: 40, Shadow: 50, PassBy: 60 };
// docs/MONSTER.md's numbers for the presence layer, written down here from the spec (never read from the code under
// test): the cases assert these, and one check holds CreatureConfig.Presence to them, so a drifted number fails loudly.
// [Standard, Nightmare] where the spec gives two.
const SPEC = {
  'Chase.CapSeconds': [12, 45], // 18.3
  'Chase.LostSeconds': [4, 6], // 18.3
  'Chase.Breather': [35, 15], // 18.3
  'Chase.Pursuit': [30, 40], // 18.2
  'Chase.Windup': [1.5, 0.7], // 18.1
  'Chase.SurpriseWindup': [2.8, 2], // 18.1
  'Chase.SurpriseRange': [20, 20], // 18.1
  'Director.HintMin': [30, 30], // 15.3
  'Director.HintMax': [55, 55],
  'Director.HintEvery': [8, 8],
  'Director.LeashWalk': [100, 100],
  'Director.ApproachMin': [45, 45], // 15.3
  'Director.ApproachMax': [80, 80],
  'Director.ApproachCooldown': [25, 25],
  'Director.AheadDot': [0.4, 0.4], // 15.3
  'Director.BeatEvery': [35, 25], // 15.3
  'Director.QuietSeconds': [40, 35], // 15.1
  'Director.QuietAfterCatch': [45, 40],
  'Director.StarveSeconds': [75, 75], // 15.2
  'Beats.SafeWalk': [25, 25], // 16
  'Beats.PassWalk': [20, 20], // 16.4
  'Detection.NoticeSeconds': [2, 1.8], // 17.3
  'Teleport.CutOffShare': [0.75, 1], // 7.2, 18.4
  'Teleport.CutOffMin': [24, 24], // 18.4
  'Teleport.CutOffMax': [70, 70],
  'Teleport.StalkSight': [40, 50], // 18.4
};
/** MONSTER.md's number `key` for `difficulty`. */
const spec = (key, difficulty = 'Standard') => SPEC[key][difficulty === 'Nightmare' ? 1 : 0];

// ---------------------------------------------------------------------------------------------------------------
// The engine stand-in
// ---------------------------------------------------------------------------------------------------------------

const { meta, decoded } = loadWorld(buildDir);

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
  const engine = makeEngine(decoded, opts.fps || null);
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
    // a Locker catch is the ReachIn into the victim's own hiding spot (the game tears its door off): that spot's door
    // and shell are no wall, anything else between the chests is
    const spot = kind === 'Locker' ? (victim === PLAYER ? s.hideSpot : victim.lockerId && victim.lockerId()) : null;
    if (root && !engine.world.lineClear(new THREE.Vector3(here.x, here.y + 1, here.z), new THREE.Vector3(root.x, root.y + 0.5, root.z),
      spot ? { ignoreEntity: spot } : {})) {
      fairness.wallCatches.push({ at: engine.loop.time, kind, level: svc.creatureLevel });
    }
  });
  creature.jumpscareFinished.connect((_p, kind, outcome) => s.events.finished.push({ at: engine.loop.time, kind, outcome }));
  // (warp: the teleport it belongs to: a spot watched when its warning ends is re-picked and warned again, one teleport)
  svc.teleportWarning.connect((spot, target, seconds) => s.events.warnings.push({ at: engine.loop.time, spot: spot.clone(), target, seconds,
    warp: svc.warp ? svc.warp.startedAt : null,
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
      fairness.maxSpeed = { v, state: svc.state, level: svc.creatureLevel, difficulty: svc.difficulty,
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
        walk: warning && warning.plan ? +warning.plan.walk.toFixed(1) : null, side: warning && warning.plan ? warning.plan.side : null,
        lead: warning && warning.plan ? +(warning.plan.lead || 0).toFixed(1) : 0 };
      fairness.materialised.push(m);
      // the walk band of its kind: the director's approach, the cut-off ahead of a moving target, else 12..24 (a
      // moving target's bands lie past their lead: the way they cover before it may appear)
      const d = svc.difficulty;
      const band = m.side === 'Approach' ? [spec('Director.ApproachMin', d) + m.lead, spec('Director.ApproachMax', d) + m.lead]
        : m.side === 'Ahead' && m.lead > 0 ? [spec('Teleport.CutOffMin', d) + m.lead, spec('Teleport.CutOffMax', d) + m.lead]
          : [T.MinWalk, T.MaxWalk];
      if (seen || nearest < T.MinStraight - 0.05 || lead === null || lead < T.WarningSeconds - 0.05 ||
        (m.walk !== null && (m.walk < band[0] - 0.05 || m.walk > band[1] + 0.05))) fairness.badMaterial.push(m);
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
  // a waypoint in another room 30-70 studs off that it can hear (a tunnel floor's solid ground between two runs is a
  // wall or more: FloorDebris's 130 studs shrink to 28 behind three), the nearest first
  const band = waypointsOf(LEVEL)
    .filter((w) => (!room || w.room !== room.id) && w.position.distanceTo(here) > 30 && w.position.distanceTo(here) < 70)
    .sort((a, b) => a.position.distanceTo(here) - b.position.distanceTo(here));
  const audible = (w) => svc.env.countOccluders(w.position.clone().add(new THREE.Vector3(0, 1, 0)), here, 3) <= 1;
  const target = band.find(audible) || band[0];
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
    const chased = advance(s, 3, () => s.creature.getState() === 'WallChase');
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
  const chased = advance(s, 3, () => s.creature.getState() === 'WallChase');
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
  const chased = advance(s, 3, () => svc.state === 'WallChase');
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
  return spec('Chase.LostSeconds', d);
}

// 7. the chase's cap (12 s, Nightmare's 45 s, never past a sprinter)
for (const difficulty of ['Standard', 'Nightmare']) {
  const s = awakeOn(LEVEL, difficulty);
  const svc = s.creature.service;
  const distance = ambush(s, 25, 45, 180);
  // the game refuses every catch: it runs them down and stands over them, in plain sight, until it has to give up
  s.creature.setCatchHooks({ canCatch: () => false });
  const chased = advance(s, 3, () => svc.state === 'WallChase');
  const startedAt = svc.chaseStarted;
  const ended = advance(s, 60, () => svc.state !== 'WallChase');
  s.creature.setCatchHooks(null);
  const length = s.engine.loop.time - (startedAt ?? 0);
  const limit = spec('Chase.CapSeconds', difficulty);
  const warp = svc.warp ? svc.warp.kind : null;
  report(distance > 0 && chased >= 0 && ended >= 0 && Math.abs(length - limit) <= 0.35 && warp === 'GiveUp' && s.events.gaveUp.length === 1 &&
    s.events.caught.length === 0, `the cap (${difficulty}): a chase still in sight gives up at ${limit} s and fades away`,
  `chase ${length.toFixed(1)} s -> ${svc.state} (${warp || 'no'} warp), gaveUp ${s.events.gaveUp.length}, catches ${s.events.caught.length}`);
  advance(s, 4);
  const back = !svc.warp && !svc.body.hidden;
  const far = back ? s.player.body.position.distanceTo(svc.body.getPosition()) : 0;
  report(back && far >= CreatureConfig.GiveUp.MinDistance - 1, `the cap (${difficulty}): it comes back out of sight, far away`, `${far.toFixed(0)} studs off`);
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
  const floorY = svc.body.getPosition().y;
  advance(s, 25, () => {
    if (Math.round(s.engine.loop.time * 30) % 9 === 0) s.engine.noise.emit(node.position.clone(), 'VentScurry', { source: 'player', level: LEVEL, ventNodeId: node.id, medium: 'Vent' });
    // a duct runs at the ceiling: the body leaving its floor's height would be the Creature climbing in
    if (Math.abs(svc.body.getPosition().y - floorY) > 4) entered = true;
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
  // the stare held without a break: a tick whose line to the head is blocked (its walk turning a corner) starts it over,
  // as the Creature's own count does
  let held = 0;
  const started = advance(s, 3, () => {
    held = behind(14, true) ? held + TICK : 0;
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
    if (w && w.kind === 'Teleport' && w.stare && w.phase === 'FadeIn') {
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
  const jumpscares = () => s.events.warnings.filter((w) => !w.plan || w.plan.side !== 'Approach');
  const warning = jumpscares()[0];
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
  // (every teleport, the approach too, waits while the game blocks them)
  const duringBlock = s.events.warnings.length - warningsBefore;
  s.blocked = false;
  advance(s, 300, () => {
    stroll();
    return false;
  });
  report(duringBlock === 0, 'teleport: none while the game blocks them (survive countdown, finale)', `${duringBlock} during ${(s.engine.loop.time - blockedFrom).toFixed(0)} s blocked`);
  // one teleport per warp: its first warning, and how many times a watched spot made it warn again
  const teleports = [];
  for (const w of jumpscares()) {
    const last = teleports[teleports.length - 1];
    if (last && w.warp !== null && last.warp === w.warp) last.warnings += 1;
    else teleports.push({ at: w.at, warp: w.warp, warnings: 1 });
  }
  const total = teleports.length;
  const gaps = teleports.slice(1).map((w, i) => w.at - teleports[i].at);
  const rewarned = teleports.map((w) => w.warnings);
  report(total >= 2 && gaps.every((g) => g >= 25) && rewarned.every((n) => n <= T.Retries + 1),
    'teleport: they keep coming, a cooldown (and 25 s unseen) between them',
    `${total} teleports, gaps ${gaps.map((g) => g.toFixed(0)).join(', ')} s, warnings each ${rewarned.join(', ')} (at most ${T.Retries + 1})`);
  summary.teleport = { first, total, gaps, reveals: s.events.revealed.length, sides: s.events.warnings.map((w) => w.plan && w.plan.side) };
}

// 10c. a teleport's stalk whose mover sticks: moved unseen, the stalk is over (docs/MONSTER.md 10): never its warp
// and warning replayed at the same spot, never Teleport held past its bound
{
  const s = session();
  const svc = s.creature.service;
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(LEVEL);
  const start = hideFar(s, LEVEL);
  s.player.moveState = 'Standing';
  s.player.flashlight.on = false;
  s.player.place(start);
  s.creature.setCatchHooks({ canCatch: () => false });
  const stalking = advance(s, 300, () => svc.state === 'Teleport' && !svc.warp && !svc.body.hidden);
  const enteredAt = s.events.states.filter((e) => e.next === 'Teleport').map((e) => e.at).pop() ?? s.engine.loop.time;
  const warningsBefore = s.events.warnings.length;
  // the target off round a corner, out of its line (it is moved only while nobody could see it)
  const feet = svc.body.getPosition().clone().setY(svc.body.getPosition().y - ROOT_HEIGHT);
  const off = pointFrom(s, LEVEL, feet, svc._creatureEye(), 60, 150, false);
  if (off) s.player.place(off);
  // its mover reports Stuck once (a passable link the body cannot pass); the service moves it unseen
  const status = svc.mover.getStatus.bind(svc.mover);
  const relocate = svc._relocateUnseen.bind(svc);
  let moved = null;
  svc._relocateUnseen = () => {
    moved = relocate();
    return moved;
  };
  let stick = true;
  svc.mover.getStatus = () => {
    if (!stick) return status();
    stick = false;
    return 'Stuck';
  };
  const left = advance(s, 60, () => svc.state !== 'Teleport');
  const held = s.engine.loop.time - enteredAt;
  delete svc.mover.getStatus;
  delete svc._relocateUnseen;
  // a replay would warn again at once: none for this teleport in the seconds after
  advance(s, 5);
  const replayed = s.events.warnings.slice(warningsBefore).filter((w) => !w.plan || w.plan.side !== 'Approach').length;
  s.creature.setCatchHooks(null);
  report(stalking >= 0 && !stick && moved === true && left >= 0 && replayed === 0 && held <= STATE_BOUND.Teleport,
    'teleport: a stalk whose mover sticks ends there (moved unseen): no warp or warning replayed, Teleport within its bound',
    stalking < 0 ? 'no stalk' : `moved ${moved}, left Teleport ${left.toFixed(1)} s after the stick (${held.toFixed(1)} s in it), ${replayed} replayed warnings, now ${svc.state}`);
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
const lockersOf = (level) => meta.entities.filter((e) => e.type === 'Locker' && e.level === level).map((e) => {
  const ex = e.attachments.ExitAnchor;
  const hide = e.attachments.HideAnchor;
  const front = new THREE.Vector3(ex[0], ex[1], ex[2]);
  // CFrame components [x, y, z, R00..R22]: the LookVector (out of the spot) is -(R02, R12, R22)
  const out = new THREE.Vector3(-ex[5], 0, -ex[11]).normalize();
  return { id: e.id, room: e.attributes.ZoneId, front, out, hide: new THREE.Vector3(hide[0], hide[1], hide[2]) };
});
/** Where the Creature stands to watch `locker`: 20 studs along its wall, 3 out, on the floor, in plain sight; or null. */
function watchPoint(s, level, locker) {
  const along = new THREE.Vector3(-locker.out.z, 0, locker.out.x);
  for (const sign of [1, -1]) {
    const p = locker.front.clone().addScaledVector(locker.out, 3).addScaledVector(along, sign * 20);
    if (navOf(level).roomAt(p) && s.engine.world.lineClear(p.clone().setY(p.y + 7), locker.front.clone().setY(locker.front.y + 4.5))) {
      return p;
    }
  }
  return null;
}
// A locker along a wall with 20 studs of floor in front of it, Level 1's first, else another floor's (Level 1's tunnel
// lockers stand at the back of their niches, out of sight from along a run).
const HIDE = (() => {
  const probe = session();
  const order = WorldConfig.LevelOrder.slice(1).concat(WorldConfig.LevelOrder[0]);
  for (const level of [LEVEL, ...order.filter((l) => l !== LEVEL)]) {
    for (const locker of lockersOf(level)) if (watchPoint(probe, level, locker)) return { level, locker };
  }
  return { level: LEVEL, locker: lockersOf(LEVEL)[0] };
})();
const HIDE_LEVEL = HIDE.level;
console.log(`      hiding scenarios: ${HIDE.locker.id} (${HIDE.locker.room}, ${HIDE_LEVEL})`);
/**
 * The Creature 22 studs out from a corridor locker, facing it, the player at its door in plain sight, then climbing in.
 * Returns the locker, or null.
 */
function seenHiding(s, who = PLAYER) {
  const svc = s.creature.service;
  const locker = HIDE.locker;
  // along the corridor, in front of the locker
  const from = watchPoint(s, HIDE_LEVEL, locker);
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
  // a2. its way to the spot sticks (a passable link the body cannot pass): moved unseen, the watch is over (never a
  // walk back into the same stall, held for as long as the hider stays in)
  const s = awakeOn(HIDE_LEVEL);
  const svc = s.creature.service;
  const hid = seenHiding(s);
  const approaching = hid ? advance(s, 1, () => svc.state === 'HidingResponse' && svc.mover.busy()) : -1;
  const status = svc.mover.getStatus.bind(svc.mover);
  const relocate = svc._relocateUnseen.bind(svc);
  let moved = null;
  // the player in the spot sees nothing outside it: the service moves it unseen
  svc._relocateUnseen = () => {
    moved = relocate();
    return moved;
  };
  // Stuck until the service has acted on it (anything else reading the status meanwhile sees it too)
  svc.mover.getStatus = () => (moved === null ? 'Stuck' : status());
  const left = approaching >= 0 ? advance(s, 20, () => svc.state !== 'HidingResponse') : -1;
  delete svc.mover.getStatus;
  delete svc._relocateUnseen;
  report(!!hid && approaching >= 0 && moved === true && left >= 0 && left <= 1,
    'hiding: a watch whose way to the spot sticks is over once it is moved unseen (never a walk back into the stall)',
    !hid ? 'no setup' : `moved ${moved}, left HidingResponse ${left >= 0 ? `${left.toFixed(1)} s after the stick` : 'never'}, now ${svc.state}`);
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
  // c2. a long walk to the spot (Nightmare's sooner reach): the watch still has one LookAway, after its grunt, before
  // the reach, and slipping out then escapes (the walk held until the scheduled first LookAway could no longer fit)
  const s = awakeOn(HIDE_LEVEL, 'Nightmare');
  const svc = s.creature.service;
  const hid = seenHiding(s);
  const reach = difficultySpec('Nightmare').reachInSeconds;
  const holdUntil = hid ? hid.enteredAt + reach - H.ReachInLead - H.LookAwaySeconds - H.LookAwayMin + 0.5 : 0;
  const busy = svc.mover.busy.bind(svc.mover);
  svc.mover.busy = () => s.engine.loop.time < holdUntil || busy();
  let reachAt = -1;
  const lookAt = hid ? advance(s, reach + 6, () => {
    if (svc.action === 'ReachIn' && reachAt < 0) reachAt = s.engine.loop.time;
    return svc.action === 'LookAway' || s.events.caught.length > 0;
  }) : -1;
  delete svc.mover.busy;
  const looked = lookAt >= 0 && svc.action === 'LookAway';
  const grunt = s.events.grunts.length ? s.events.grunts[s.events.grunts.length - 1].at : null;
  const lead = looked && grunt !== null ? svc.actionAt - grunt : null;
  const sinceIn = looked ? svc.actionAt - hid.enteredAt : null;
  let escaped = false;
  if (looked) {
    escaped = slipAway(s, hid.locker);
    advance(s, 10);
  }
  report(!!hid && looked && reachAt < 0 && lead !== null && lead >= H.GruntLead - 0.15 && escaped && s.events.caught.length === 0,
    `hiding: after a long walk to the spot it still looks away once before the reach (${reach} s on Nightmare), and slipping out then escapes`,
    !hid ? 'no setup' : looked ? `LookAway ${sinceIn.toFixed(1)} s in, grunt ${lead !== null ? lead.toFixed(2) : '-'} s ahead, catches ${s.events.caught.length}` :
      `no LookAway (${s.events.caught.length ? `caught ${s.events.caught[0].kind}` : svc.state})`);
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
  const first = budget.take('Level1_Hallways');
  const second = budget.take('Level1_Hallways');
  const other = budget.take('Level0_Basement');
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
  const levels = WorldConfig.LevelOrder;
  const per = {};
  const over = [];
  for (const level of levels) {
    const s = session();
    const svc = s.creature.service;
    s.creature.beginRun({ difficulty: level === 'Level2_Auditorium' ? 'Nightmare' : 'Standard' });
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
    per[level] = { maxStuck: +s.stuck.max.toFixed(2), unsticks: svc.unsticks || 0, state: svc.state,
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

// 15. the presence layer (docs/MONSTER.md 15-18): the director's hint, its approach and caps, each beat, noticing, the
// wind-up and the pursuit, the torch's glow, standing still in the dark, co-op attention

// 15-. the config carries MONSTER.md's numbers (SPEC): the cases below assert the spec's numbers, so a drift fails here
{
  const off = [];
  for (const [key, want] of Object.entries(SPEC)) {
    const [table, name] = key.split('.');
    ['Standard', 'Nightmare'].forEach((d, i) => {
      const got = presenceConfig(meta, d)[table][name];
      if (got !== want[i]) off.push(`${key} ${d} ${got} (spec ${want[i]})`);
    });
  }
  report(off.length === 0, `presence: CreatureConfig.Presence carries docs/MONSTER.md's ${Object.keys(SPEC).length} numbers`, off.join(', ') || 'all match');
}

/** A fresh run on `level`, the player standing in plain view at `at` (torch on), facing `toward`. */
function standing(level, at, toward, difficulty = 'Standard', opts = {}) {
  const s = session(opts);
  s.creature.beginRun({ difficulty });
  s.creature.activateLevel(level);
  s.player.place(at);
  s.player.moveState = 'Standing';
  s.player.flashlight.on = true;
  if (toward) s.player.lookAt(toward.clone().setY(at.y + PLAYER_ROOT + 1.5));
  return s;
}

/** Floor points of `level` whose room has two ways out or more and a hiding spot within 25 walked (a beat's place). */
function beatPlaces(s, level) {
  const svc = s.creature.service;
  const nav = svc._nav(level);
  const spots = svc.env.hideSpots(level).map((x) => x.front.position);
  return samplesOf(level).map((p) => p.position).filter((p) => nav.waysOut(p) >= 2 &&
    spots.some((h) => h.distanceTo(p) < 20 && nav.pathLength(p, h) <= 25));
}

// 15a. the director: a player far off and out of its way gets a search hint (30..55 walked from them, never in view,
// never their own spot), the hints at least HintEvery apart; it comes into the leash
{
  const s = session();
  const svc = s.creature.service;
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(LEVEL);
  advance(s, 1);
  const nav = svc._nav(LEVEL);
  // the player 160+ walked from where it starts, standing still in the dark (it neither sees nor hears them)
  const from = svc._feet();
  const far = samplesOf(LEVEL).map((p) => p.position).find((p) => Math.abs(p.y - from.y) < 3 && nav.pathLength(from, p) > 160);
  s.player.place(far);
  s.player.flashlight.on = false;
  const hints = [];
  let closest = Infinity;
  advance(s, 120, () => {
    const h = svc.ctx.hint;
    if (h && (!hints.length || hints[hints.length - 1].at !== h.at)) {
      hints.push({ at: h.at, walk: nav.pathLength(far, h.point), seen: svc._inViewOfAnyone(h.point.clone().setY(h.point.y + ROOT_HEIGHT)) });
    }
    closest = Math.min(closest, svc.walks.get(PLAYER) ?? Infinity);
    return false;
  });
  const spaced = hints.slice(1).every((h, i) => h.at - hints[i].at >= spec('Director.HintEvery') - 0.05);
  report(hints.length > 0 && hints.every((h) => h.walk >= spec('Director.HintMin') - 0.5 && h.walk <= spec('Director.HintMax') + 0.5 && !h.seen) &&
    spaced && closest <= spec('Director.LeashWalk'),
  'director: a far player gets search hints 30..55 walked from them (never in view, at least 8 s apart) and it comes within the leash',
  `${hints.length} hints, walks ${hints.map((h) => h.walk.toFixed(0)).join('/')}, closest ${closest.toFixed(0)} walked`);
  summary.directorHint = { hints: hints.length, closest };
}

// 15b. the approach teleport: warned, 45..80 walked from its player, out of view, never within 12 of anyone, not in
// the floor's grace, at least ApproachCooldown apart
{
  const s = session();
  const svc = s.creature.service;
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(LEVEL);
  const activated = s.engine.loop.time;
  advance(s, 1);
  const nav = svc._nav(LEVEL);
  const from = svc._feet();
  const pts = samplesOf(LEVEL).map((p) => p.position).filter((p) => Math.abs(p.y - from.y) < 3 && nav.pathLength(from, p) > 220);
  let k = 0;
  s.player.flashlight.on = false;
  const approaches = [];
  advance(s, 240, () => {
    // the player keeps moving off (every 20 s a new far point), out of its reach on foot
    if (Math.round(s.engine.loop.time * 30) % 600 === 0 && pts.length) {
      const here = svc._feet();
      const p = pts.filter((x) => nav.pathLength(here, x) > 200)[(k++ * 7) % 5] || pts[0];
      s.player.place(p);
    }
    return false;
  });
  for (const w of s.events.warnings) if (w.plan && w.plan.side === 'Approach') approaches.push(w);
  const bad = fairness.materialised.filter((m) => m.side === 'Approach' && (m.seen || m.nearest < T.MinStraight - 0.05));
  const gaps = approaches.slice(1).map((w, i) => w.at - approaches[i].at);
  const past = (w) => w.plan.walk - (w.plan.lead || 0);
  report(approaches.length > 0 && approaches.every((w) => past(w) >= spec('Director.ApproachMin') - 0.5 && past(w) <= spec('Director.ApproachMax') + 0.5 &&
    w.at - activated >= CreatureConfig.FloorGrace.Standard) && gaps.every((g) => g >= spec('Director.ApproachCooldown') - 0.05) && bad.length === 0,
  'director: the approach teleport is warned, 45..80 walked from its player (past their lead), out of view, past the grace, 25 s apart',
  `${approaches.length} approaches, walks ${approaches.map((w) => past(w).toFixed(0)).join('/')}, gaps ${gaps.map((g) => g.toFixed(0)).join('/')}, ${bad.length} bad`);
}

// 15c. the beats: each one, played to a player standing in a safe place, keeps 25 walked off them (a pass-by 20 all along its walk), never chases on
// sight alone, is seen (Peek, Glimpse) and ends in Patrol; the Shadow follows, freezes under a look and a stare chases
{
  const probe = session();
  probe.creature.beginRun({ difficulty: 'Standard' });
  probe.creature.activateLevel(LEVEL);
  const places = beatPlaces(probe, LEVEL);
  // the Shadow's tries: a sprinter (faster than ShadowFast) is never shadowed; while it plays, the player it follows
  // is the one it publishes (getTarget, the snapshot), its own target untouched
  const shadow = { sprinterPlans: 0, planned: 0, published: 0, ticks: 0 };
  /** One try of `kind` from the `first`th place on: {ok, detail} (null: no place fits). */
  const tryBeat = (kind, first) => {
    let s = null;
    let plan = null;
    for (let i = first; i < places.length && !plan; i += 23) {
      const at = places[i];
      const ahead = places.find((p) => p.distanceTo(at) > 35 && p.distanceTo(at) < 55 && Math.abs(p.y - at.y) < 2) || null;
      s = standing(LEVEL, at, ahead);
      const svc = s.creature.service;
      // dark and still while it wakes (it is not to find them first), the torch on for the beat
      s.player.flashlight.on = false;
      advance(s, 25);
      // found them anyway while waking (a patrol past their place): not a safe place for a beat, the next one
      if (s.events.caught.length || s.events.states.some((e) => e.next === 'WallChase')) continue;
      s.player.flashlight.on = true;
      // the shadow needs a player on the move: a walk along the lattice away from it
      if (kind === 'Shadow') s.walkTo = places.filter((p) => p.distanceTo(at) > 60 && p.distanceTo(at) < 90 && Math.abs(p.y - at.y) < 2);
      const B = svc.presence.Beats;
      const only = { ...B, Weights: Object.fromEntries(Object.keys(B.Weights).map((k) => [k, k === kind ? 1 : 0])) };
      if (kind === 'Shadow') {
        // stage it 45 walked behind a walking player
        const nav = svc._nav(LEVEL);
        const route = s.walkTo.length ? nav.computePath(at, s.walkTo[0]) : null;
        if (!route) continue;
        s.route = route.waypoints;
        const behind = places.find((p) => Math.abs(p.y - at.y) < 2 && nav.pathLength(at, p) > 38 && nav.pathLength(at, p) < 50 &&
          new THREE.Vector3(p.x - at.x, 0, p.z - at.z).dot(new THREE.Vector3(route.waypoints[0].x - at.x, 0, route.waypoints[0].z - at.z)) < 0 &&
          !s.engine.world.lineClear(s.player.eye(), p.clone().setY(p.y + 9)));
        if (!behind) continue;
        stage(s, behind, at);
        // a few steps along the way so it knows they are moving
        for (let n = 0; n < 15; n++) {
          const f = s.player.body.position.clone().setY(at.y);
          const wp = s.route.find((w) => w.distanceTo(f) > 1) || s.route[s.route.length - 1];
          const d = wp.clone().sub(f).setY(0).normalize().multiplyScalar(11 * 0.1);
          s.player.place(f.add(d));
          s.player.lookAt(s.player.body.position.clone().add(d.clone().multiplyScalar(20)).setY(s.player.body.position.y + 1.5));
          advance(s, 0.1);
        }
      }
      plan = svc._planBeat(PLAYER, svc.ctx.walkTo(PLAYER), only);
      if (kind === 'Shadow' && plan) {
        const rec = svc._record(PLAYER);
        const speed = rec.speed;
        rec.speed = B.ShadowRunning + 5;
        if (svc._planBeat(PLAYER, svc.ctx.walkTo(PLAYER), only)) shadow.sprinterPlans += 1;
        rec.speed = speed;
        shadow.planned += 1;
      }
    }
    if (!plan || !s) return null;
    const svc = s.creature.service;
    const nav = svc._nav(LEVEL);
    const B = svc.presence.Beats;
    const reply = s.creature.devCommand(`ai ${kind}`);
    const began = svc.state === kind;
    let nearest = Infinity;
    let seenByPlayer = 0;
    let frozen = 0;
    let looks = 0;
    let chased = false;
    const end = advance(s, 60, () => {
      if (svc.state === 'WallChase') chased = true;
      if (kind === 'Shadow' && s.route) {
        // the player walks on; every 4 s they look back at it for 1 s (a glance: no stare)
        const t = s.engine.loop.time;
        const lookBack = Math.floor(t) % 4 === 0;
        const f = s.player.body.position.clone().setY(s.route[0].y);
        const wp = s.route.find((w) => w.distanceTo(f) > 1);
        if (wp && !lookBack) {
          const d = wp.clone().sub(f).setY(0).normalize().multiplyScalar(11 * TICK);
          s.player.place(f.add(d));
          s.player.lookAt(s.player.body.position.clone().add(d.clone().multiplyScalar(100)).setY(s.player.body.position.y + 1.5));
        } else if (lookBack) {
          const head = svc._creatureEye();
          const eye = s.player.eye();
          const side = new THREE.Vector3(head.z - eye.z, 0, eye.x - head.x).normalize();
          s.player.lookAt(head.clone().addScaledVector(side, Math.tan((12 * Math.PI) / 180) * head.distanceTo(eye)));
          looks += 1;
          if (svc.speedMeasured < 0.5) frozen += 1;
        }
      }
      const root = s.player.body.position.clone().setY(s.player.body.position.y - PLAYER_ROOT);
      if (svc.state === kind) nearest = Math.min(nearest, nav.pathLength(svc._feet(), root));
      if (kind === 'Shadow' && svc.state === 'Shadow') {
        shadow.ticks += 1;
        if (svc.getTarget() === PLAYER && svc.snapshot().targetingPlayer && svc.ctx.target === null) shadow.published += 1;
      }
      if (viewers(s).some((v) => inViewOf(s, v, svc.body.getPosition())) && !svc.body.hidden) seenByPlayer += 1;
      return svc.state !== kind;
    });
    const after = svc.state;
    // a beat's stand points keep SafeWalk off them; a pass-by's whole walk keeps PassWalk off them (16.4)
    const keepsOff = nearest >= (kind === 'PassBy' ? spec('Beats.PassWalk') - 2 : spec('Beats.SafeWalk') - 4);
    const seen = kind === 'PassBy' || kind === 'Shadow' || seenByPlayer > 0;
    let detail = `${reply}; ended ${end.toFixed(1)} s -> ${after}, nearest ${nearest.toFixed(0)} walked, seen ${seenByPlayer} ticks`;
    let ok = began && end >= 0 && keepsOff && seen;
    if (kind === 'PassBy') ok = ok && (after === 'Patrol' || after === 'WallChase');
    else ok = ok && !chased && after === 'Patrol';
    if (kind === 'Shadow') {
      ok = ok && frozen > 0;
      detail += `, frozen in ${frozen} of ${looks} look-back ticks`;
    }
    return { ok, detail, safe: keepsOff && (kind === 'PassBy' || !chased) };
  };
  for (const kind of ['Peek', 'Glimpse', 'PassBy', 'Shadow']) {
    // a few places: the first that plays through counts; every try must be safe (a stand point it cannot reach ends
    // the beat early, safely)
    const tries = [];
    for (let first = 0; first < 20 && !(tries.length && tries[tries.length - 1].ok); first += 5) {
      const r = tryBeat(kind, first);
      if (r) tries.push(r);
    }
    const last = tries[tries.length - 1];
    report(!!last && last.ok && tries.every((r) => r.safe),
      `beat ${kind}: plays safely (${kind === 'PassBy' ? `${spec('Beats.PassWalk')} walked off all along, its own senses` : `${spec('Beats.SafeWalk')} walked off, no chase on sight alone`}) and ends`,
      last ? `${tries.length} tries; ${last.detail}${tries.some((r) => !r.safe) ? ` (unsafe: ${tries.filter((r) => !r.safe).map((r) => r.detail).join(' | ')})` : ''}`
        : `no place on ${LEVEL} where it fits`);
  }
  report(shadow.planned > 0 && shadow.sprinterPlans === 0,
    'beat Shadow: never planned for a sprinter (over ShadowRunning: they would leave it behind unseen)',
    `${shadow.planned} plans for a walker; ${shadow.sprinterPlans} for the same player at a sprint`);
  report(shadow.ticks > 0 && shadow.published === shadow.ticks,
    'beat Shadow: the player it follows is the one it publishes (getTarget, the snapshot: the "Followed" hint), its own target untouched',
    `${shadow.published} of ${shadow.ticks} Shadow ticks`);
}

// 15d. noticing: a glimpse across its cone far off starts no chase; staying in its sight does
{
  const s = awakeOn(LEVEL);
  const svc = s.creature.service;
  const distance = ambush(s, 50, 66, 180);
  // half a second in sight, then out of its line
  advance(s, 0.5);
  const quick = svc.state;
  const eye = svc._creatureEye();
  const away = pointFrom(s, LEVEL, svc._feet(), eye, 45, 90, false);
  s.player.place(away);
  advance(s, 2);
  const glanced = svc.state !== 'WallChase';
  report(distance > 0 && quick !== 'WallChase' && glanced,
    'noticing: half a second in its sight far off starts no chase', `${distance.toFixed(0)} studs, state ${svc.state}`);
}
{
  const s = awakeOn(LEVEL);
  const svc = s.creature.service;
  const distance = ambush(s, 50, 66, 180);
  const chased = advance(s, 4, () => svc.state === 'WallChase');
  const want = spec('Detection.NoticeSeconds');
  report(distance > 0 && chased >= 0.5 && chased <= want + 0.5,
    `noticing: staying in its sight at ${Math.round(distance)} studs starts the chase within ${want} s`, `after ${chased.toFixed(2)} s`);
}

// 15e. the wind-up and the pursuit: a fresh chase holds a beat before it runs; losing them, it runs on along the way
// they fled past the last place it saw them. Staged in a long straight tunnel: it 30 behind the player, both facing
// along it; the player runs on 45 studs, then is gone (out of its line, still, torch off).
{
  const nav = navOf(LEVEL);
  const probe = awakeOn(LEVEL);
  const clear = (a, b) => probe.engine.world.lineClear(a.clone().setY(a.y + 2), b.clone().setY(b.y + 2));
  const runOf = (from, d, max) => {
    let n = 0;
    let p = from.clone();
    while (n < max) {
      const q = p.clone().addScaledVector(d, 2);
      if (!nav.roomAt(q) || !clear(p, q)) break;
      p = q;
      n += 2;
    }
    return n;
  };
  let lane = null;
  const pts = samplesOf(LEVEL).map((p) => p.position);
  for (let i = 0; i < pts.length && !lane; i += 11) {
    for (let a = 0; a < 4 && !lane; a++) {
      const d = new THREE.Vector3(Math.cos((a * Math.PI) / 2), 0, Math.sin((a * Math.PI) / 2));
      if (runOf(pts[i], d, 100) >= 100 && runOf(pts[i], d.clone().negate(), 34) >= 34) lane = { at: pts[i], dir: d };
    }
  }
  if (!lane) report(false, 'chase: a long straight tunnel for the wind-up and the pursuit', 'none');
  else {
    const s = awakeOn(LEVEL);
    const svc = s.creature.service;
    const { at, dir } = lane;
    s.player.place(at);
    s.player.moveState = 'Standing';
    s.player.flashlight.on = true;
    s.player.lookAt(at.clone().addScaledVector(dir, 20).setY(at.y + PLAYER_ROOT + 1.5));
    stage(s, at.clone().addScaledVector(dir, -30), at);
    const chased = advance(s, 4, () => svc.state === 'WallChase');
    const from = svc.body.getPosition().clone();
    let still = 0;
    advance(s, spec('Chase.Windup') - 0.1, () => {
      if (svc.body.getPosition().distanceTo(from) < 0.05) still += TICK;
      return false;
    });
    report(chased >= 0 && still >= spec('Chase.Windup') - 0.25,
      `chase: a fresh chase winds up ${spec('Chase.Windup')} s before it runs`, `still ${still.toFixed(2)} s`);
    let fled = at.clone();
    for (let n = 0; n < 24; n++) {
      fled = fled.clone().addScaledVector(dir, 19 * 0.1);
      s.player.place(fled);
      s.player.lookAt(fled.clone().addScaledVector(dir, 10).setY(fled.y + PLAYER_ROOT + 1.5));
      advance(s, 0.1);
    }
    const lastSeen = svc.ctx.memory ? svc.ctx.memory.position.clone() : null;
    const hide = pointFrom(s, LEVEL, fled, svc._creatureEye(), 30, 80, false, fled, (p) => dir.dot(p.clone().sub(fled).setY(0)) < 0);
    if (hide) {
      s.player.place(hide);
      s.player.flashlight.on = false;
    }
    let furthest = -Infinity;
    advance(s, 12, () => {
      if (lastSeen) furthest = Math.max(furthest, svc._feet().clone().sub(lastSeen).setY(0).dot(dir));
      return svc.state !== 'WallChase';
    });
    report(!!lastSeen && !!hide && furthest >= 10,
      'chase: losing them, it runs on past the last place it saw them along the way they fled (the pursuit)',
      `${furthest.toFixed(1)} studs on past the last sight, then ${svc.state}`);
    // met round a corner: a chase that starts with its target within SurpriseRange winds up SurpriseWindup
    const near = awakeOn(LEVEL);
    const nsvc = near.creature.service;
    const C = { SurpriseRange: spec('Chase.SurpriseRange'), SurpriseWindup: spec('Chase.SurpriseWindup') };
    near.player.place(at);
    near.player.moveState = 'Standing';
    near.player.flashlight.on = true;
    near.player.lookAt(at.clone().addScaledVector(dir, 20).setY(at.y + PLAYER_ROOT + 1.5));
    stage(near, at.clone().addScaledVector(dir, -(C.SurpriseRange - 6)), at);
    const close = advance(near, 4, () => nsvc.state === 'WallChase');
    const start = nsvc.body.getPosition().clone();
    let held = 0;
    advance(near, C.SurpriseWindup - 0.1, () => {
      if (nsvc.body.getPosition().distanceTo(start) < 0.05) held += TICK;
      return false;
    });
    report(close >= 0 && held >= C.SurpriseWindup - 0.25,
      `chase: a chase that starts within ${C.SurpriseRange} of its target winds up ${C.SurpriseWindup} s (met round a corner)`,
      `still ${held.toFixed(2)} s`);
    // within its reach as the chase starts: the wind-up is a screech, not a grab; it catches once it is over
    const grab = awakeOn(LEVEL);
    const gsvc = grab.creature.service;
    grab.player.place(at);
    grab.player.moveState = 'Standing';
    grab.player.flashlight.on = true;
    grab.player.lookAt(at.clone().addScaledVector(dir, 20).setY(at.y + PLAYER_ROOT + 1.5));
    stage(grab, at.clone().addScaledVector(dir, -3.5), at);
    const begun = advance(grab, 4, () => gsvc.state === 'WallChase');
    const caughtIn = begun >= 0 && grab.events.caught.length === 0 ?
      advance(grab, spec('Chase.SurpriseWindup') + 3, () => grab.events.caught.length > 0) : -1;
    report(begun >= 0 && caughtIn >= spec('Chase.SurpriseWindup') - 0.15,
      `chase: a target within reach as it starts is not caught during the ${spec('Chase.SurpriseWindup')} s wind-up (it screeches, it does not reach), then is`,
      begun < 0 ? 'no chase' : caughtIn < 0 ? `no catch after (caught ${grab.events.caught.length} at the start)` : `caught ${caughtIn.toFixed(2)} s after the chase began`);
  }
}

// 15i. a beat that never reached its player is no encounter (their menace stands, no quiet spell); a pass-by is only
// planned for a player who is not on the run
{
  const probe = session();
  probe.creature.beginRun({ difficulty: 'Standard' });
  probe.creature.activateLevel(LEVEL);
  const places = beatPlaces(probe, LEVEL);
  let passed = null;
  for (let i = 0; i < places.length && !passed; i += 17) {
    const at = places[i];
    const s = standing(LEVEL, at, null);
    const svc = s.creature.service;
    s.player.flashlight.on = false;
    advance(s, 25);
    const B = svc.presence.Beats;
    const only = { ...B, Weights: { PassBy: 1, Peek: 0, Glimpse: 0, Shadow: 0 } };
    const still = svc._planBeat(PLAYER, svc.ctx.walkTo(PLAYER), only);
    if (!still) continue;
    const rec = svc._record(PLAYER);
    const saved = { speed: rec.speed, travel: rec.travel };
    rec.speed = 11;
    rec.travel = new THREE.Vector3(1, 0, 0);
    const running = svc._planBeat(PLAYER, svc.ctx.walkTo(PLAYER), only);
    rec.speed = saved.speed;
    rec.travel = saved.travel;
    passed = { at, running };
  }
  report(!!passed && passed.running === null, 'beat PassBy: planned for a player standing, never for one on the run (they would run into it)',
    passed ? `standing: a plan; at a run: ${passed.running ? passed.running.kind : 'none'}` : `no place on ${LEVEL} where it fits`);
  // a Peek forced on a player who is at once far off and out of its sight: it never reaches them
  let unreached = null;
  for (let i = 0; i < places.length && !unreached; i += 19) {
    const at = places[i];
    const s = standing(LEVEL, at, places.find((p) => p.distanceTo(at) > 35 && p.distanceTo(at) < 55 && Math.abs(p.y - at.y) < 2) || null);
    const svc = s.creature.service;
    s.player.flashlight.on = false;
    advance(s, 25);
    if (!/Peek/.test(s.creature.devCommand('ai Peek'))) continue;
    const nav = svc._nav(LEVEL);
    // far off and out of its line (beyond the director's SeenRange straight too): they never see it
    const D = svc.presence.Director;
    const away = samplesOf(LEVEL).map((p) => p.position).find((p) => Math.abs(p.y - at.y) < 3 &&
      nav.pathLength(svc._feet(), p) > 200 && p.distanceTo(svc._feet()) > D.SeenRange + 10);
    if (!away) continue;
    s.player.place(away);
    s.player.flashlight.on = false;
    s.player.lookAt(away.clone().add(new THREE.Vector3(0, PLAYER_ROOT + 1.5, -10)));
    const from = s.engine.loop.time;
    const before = svc.director.snapshot(from).players.find((x) => x.userId === PLAYER.userId);
    let reached = false;
    advance(s, 30, () => {
      if (svc.ctx.beatReached) reached = true;
      return svc.state !== 'Peek';
    });
    const elapsed = s.engine.loop.time - from;
    const after = svc.director.snapshot(s.engine.loop.time).players.find((x) => x.userId === PLAYER.userId);
    unreached = { before, after, elapsed, reached, state: svc.state };
  }
  // no encounter: the quiet spell it had (if any) only ran down, the menace only rose
  report(!!unreached && !unreached.reached && unreached.after.quiet <= Math.max(0, unreached.before.quiet - unreached.elapsed) + 0.05 &&
    unreached.after.menace >= unreached.before.menace,
  'director: a beat that never reached its player (unseen, never within 30 walked) is no encounter: no quiet spell, the menace stands',
  unreached ? `menace ${unreached.before.menace} -> ${unreached.after.menace}, quiet ${unreached.before.quiet.toFixed(1)} -> ` +
    `${unreached.after.quiet.toFixed(1)} s over ${unreached.elapsed.toFixed(1)} s, then ${unreached.state}` : 'no Peek fitted');
}

/**
 * A face-off on `level`: the Creature's floor point and the player's, `min..max` apart with a clear line eye to eye
 * (and `accept` the player's point), or null.
 */
function faceOff(s, level, min, max, accept = null) {
  const pts = samplesOf(level).map((p) => p.position);
  const eyeOf = (p, h) => p.clone().setY(p.y + h);
  for (let i = 0; i < pts.length; i += 7) {
    const at = pts[i];
    if (accept && !accept(at)) continue;
    for (const m of pts) {
      const d = m.distanceTo(at);
      if (d < min || d > max || Math.abs(m.y - at.y) > 1) continue;
      if (s.engine.world.lineClear(eyeOf(m, ROOT_HEIGHT + 5.64), eyeOf(at, PLAYER_ROOT + 1.5))) return { monster: m, player: at };
    }
  }
  return null;
}

/** A run with the Creature staged at the face-off's point facing the player there, held facing them every tick. */
function staredDown(off, torch, moving, seconds, until) {
  const s = awakeOn(LEVEL);
  const svc = s.creature.service;
  s.player.place(off.player);
  s.player.moveState = 'Standing';
  s.player.flashlight.on = torch;
  stage(s, off.monster, off.player);
  return advance(s, seconds, () => {
    svc.mover.stop();
    svc.body.face(off.player.clone().sub(off.monster));
    if (moving) s.player.place(off.player.clone().add(new THREE.Vector3(Math.sin(s.engine.loop.time * 8) * 0.4, 0, 0)));
    return until(s, svc);
  });
}

// 15j. the director's approach on a runner: only ahead of their way (behind them they are gone before it has formed),
// 45..80 walked past their lead (the way they cover in the FadeOut and the Warning)
{
  const probe = session();
  probe.creature.beginRun({ difficulty: 'Standard' });
  probe.creature.activateLevel(LEVEL);
  const places = beatPlaces(probe, LEVEL);
  const ways = [new THREE.Vector3(1, 0, 0), new THREE.Vector3(0, 0, 1), new THREE.Vector3(-1, 0, 0), new THREE.Vector3(0, 0, -1)];
  const plans = [];
  for (let i = 0; i < places.length && plans.length < 8; i += 29) {
    const s = standing(LEVEL, places[i], null);
    const svc = s.creature.service;
    advance(s, 2);
    const rec = svc._record(PLAYER);
    const root = svc._rootOf(PLAYER);
    for (const way of ways) {
      rec.speed = SPRINT;
      rec.travel = way.clone();
      const plan = svc._planApproach(PLAYER);
      if (!plan) continue;
      const lead = SPRINT * (T.FadeOutSeconds + T.WarningSeconds);
      plans.push({ ahead: svc._ahead(way, root, plan.spot.position), lead: plan.lead, past: plan.walk - plan.lead, want: lead });
    }
  }
  const bad = plans.filter((p) => p.ahead < spec('Director.AheadDot') || Math.abs(p.lead - p.want) > 0.01 || p.past < spec('Director.ApproachMin') - 0.5 ||
    p.past > spec('Director.ApproachMax') + 0.5);
  report(plans.length > 0 && bad.length === 0,
    'director: a runner is approached only ahead of their way, 45..80 walked past their lead',
    `${plans.length} plans, ${bad.length} bad${bad.length ? ` ${JSON.stringify(bad.slice(0, 2))}` : ''}`);
}

// 15f. the torch's glow: a lit torch 75..85 off (beyond its 70), shone back toward it, lights a spot it sees: it goes to
// look; the same player with the torch off does not
{
  const probe = awakeOn(LEVEL);
  const off = faceOff(probe, LEVEL, 75, 85);
  const glow = (torch) => staredDown(off, torch, false, 3, (s) => {
    const eye = s.creature.service._creatureEye();
    s.player.lookAt(eye.clone().lerp(s.player.eye(), 0.55));
    return s.creature.service.state === 'InvestigateNoise' || s.creature.service.state === 'WallChase';
  });
  const lit = off ? glow(true) : null;
  const dark = off ? glow(false) : null;
  report(!!off && lit >= 0 && dark === -1, 'detection: a lit torch\'s glow seen from beyond its sight draws it to look; a dark one does not',
    off ? `torch on ${lit.toFixed(2)} s, torch off ${dark}` : 'no face-off on the floor');
}

// 15g. standing still in the dark: 12..15 studs in front of it, torch off, unlit, still: unseen; moving there: seen
{
  const probe = awakeOn(LEVEL);
  const env = probe.creature.service.env;
  const off = faceOff(probe, LEVEL, 12, 15, (p) => !env.litAt(p.clone().setY(p.y + PLAYER_ROOT + 1), CreatureConfig.Senses.LitIrradiance));
  const seen = (moving) => staredDown(off, false, moving, 1.5, (s, svc) => svc.ctx.sightings.length > 0) >= 0;
  const still = off ? seen(false) : null;
  const moving = off ? seen(true) : null;
  report(!!off && still === false && moving === true, 'detection: standing still in the dark 12..15 studs off it is unseen; moving there it is seen',
    `still ${still}, moving ${moving}`);
}

// 15h. co-op attention: the director does not tunnel one player; a teammate left alone for StarveSeconds becomes its
// focus (two players: the local one near it, a remote handle far off)
{
  const s = session({ roster: true });
  const svc = s.creature.service;
  s.creature.beginRun({ difficulty: 'Standard' });
  s.creature.activateLevel(LEVEL);
  advance(s, 1);
  const nav = svc._nav(LEVEL);
  const from = svc._feet();
  const pts = samplesOf(LEVEL).map((p) => p.position).filter((p) => Math.abs(p.y - from.y) < 3);
  const near = pts.find((p) => nav.pathLength(from, p) > 40 && nav.pathLength(from, p) < 60);
  const far = pts.find((p) => nav.pathLength(from, p) > 250);
  s.player.place(near);
  s.player.flashlight.on = false;
  const state = { root: far.clone().setY(far.y + PLAYER_ROOT), look: new THREE.Vector3(0, 0, -1), life: 'Alive', moveState: 'Standing', torch: false, locker: null };
  s.remotes.push({
    userId: 2, name: 'Mate',
    root: () => state.root.clone(), rootCFrame: () => null, look: () => state.look.clone(), lifeState: () => state.life,
    downedCount: () => 0, moveState: () => state.moveState, mode: () => 'OnFoot', inVent: () => false, flashlightOn: () => state.torch,
    lockerId: () => state.locker, hasLock: () => false, controlLock: () => 'None', canCatch: () => false, setCaught: () => {},
    turn: () => {}, catchCue: () => {}, catchAbort: () => {}, catchOutcome: () => {},
  });
  s.creature.setCatchHooks({ canCatch: () => false });
  const focus = [];
  advance(s, spec('Director.StarveSeconds') + 40, () => {
    const f = svc.director.focusPlayer;
    if (f && (!focus.length || focus[focus.length - 1].who !== f.userId)) focus.push({ who: f.userId, at: s.engine.loop.time });
    // the local player keeps close to it (pressured), out of its sight
    const here = svc._feet();
    if (Math.round(s.engine.loop.time * 30) % 150 === 0) {
      const p = pts.find((x) => nav.pathLength(here, x) > 40 && nav.pathLength(here, x) < 60 &&
        !s.engine.world.lineClear(svc._creatureEye(), x.clone().setY(x.y + PLAYER_ROOT + 1.5)));
      if (p) s.player.place(p);
    }
    return false;
  });
  const mate = focus.find((f) => f.who === 2);
  report(!!mate, `co-op: the director turns to a teammate left alone (within ${spec('Director.StarveSeconds')} s and a little more), never tunnels one player`,
    `focus ${focus.map((f) => `${f.who}@${f.at.toFixed(0)}`).join(', ')}`);
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

// the global fairness checks (every scenario's every tick)
report(fairness.maxSpeed.v <= SPRINT, `fairness: never faster than a sprinting player (${SPRINT}) outside Scripted`,
  `max ${fairness.maxSpeed.v.toFixed(2)} studs/s ${JSON.stringify({ ...fairness.maxSpeed, v: undefined })}`);
report(fairness.materialised.length > 0 && fairness.badMaterial.length === 0,
  'fairness: it never teleports into view nor within 12 studs (every one warned 1.6 s ahead; 12-24 studs of walking, 24-70 past their lead cutting off a moving target, 45-80 for an approach)',
  `${fairness.materialised.length} materialisations, ${fairness.badMaterial.length} bad${fairness.badMaterial.length ? ` ${JSON.stringify(fairness.badMaterial.slice(0, 2))}` : ''}`);
report(fairness.catches > 0 && fairness.wallCatches.length === 0, 'fairness: it never catches through a wall',
  `${fairness.catches} catches, ${fairness.wallCatches.length} through a wall`);
report(fairness.nan === 0, 'fairness: no NaN in the body or the view contract', `${fairness.nan} ticks`);
summary.fairness = { maxSpeed: fairness.maxSpeed, materialised: fairness.materialised.length, bad: fairness.badMaterial, wallCatches: fairness.wallCatches, nan: fairness.nan };

if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify({ results, summary }, null, 2));
console.log(failed ? '[sim] FAILED' : '[sim] all passed');
process.exit(failed ? 1 : 0);
