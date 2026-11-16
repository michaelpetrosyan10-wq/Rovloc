// The Creature's presence report (docs/MONSTER.md 20): how often a player meets the Tall Man on a real floor, measured
// with scripted players on the real world data and the real brain, on a fake clock (sim-engine.mjs).
//
//   node tools/presence-sim.mjs [--build <dir>] [--seeds 12] [--seed-base 1029] [--minutes 8] [--floors L0,L1,L2]
//                               [--difficulties Standard,Nightmare] [--players 1,2] [--bots objective,careful]
//                               [--report] [--json <file>]
// (the seeds: --seed-base, then every 977th; a new base measures on seeds no number was tuned on)
//
// Every floor starts as the game starts it: the level activates, the Creature is held at its start (the spawn rule:
// a PatrolWaypoint or CreatureSpawn 70..140 studs walked from the entry, picked by the seed) for the floor's grace,
// released early by a loud noise of a player or a player within 30, then hunts. The scripted players:
//   objective  walks the floor's objective targets in a seeded order (the fuses, the keys, the stations, the exits; the
//              Auditorium's batteries and its far side), sprinting whenever it has stamina, torch always on, working
//              each target for its hold (ObjectiveWork once a second, the station's ObjectiveClunk); it never hides:
//              chased, it runs (a point 30..60 off, far from the Creature and round a corner from it where there is
//              one, whose way does not run back toward it over its first 25 studs; a new one every 3 s), and seeing
//              it within 45 it turns away for a moment before it goes on; hearing it within 25 it looks that way.
//   careful    the same targets at a walk with the torch on and a look back every few seconds; it crouches with the
//              torch off when it hears the Creature near, hides (the nearest spot that does not lead toward it, whose
//              way keeps clear of it, out of its sight; with none, it runs, upright, to break the line first) when a
//              teleport is warned near it, a chase starts on it or it sees the Creature close (shown on the way to
//              the spot, another spot or away; only heard close with no spot to reach, unseen, it keeps still in the
//              dark), slips out of a watched spot during a LookAway, and waits hidden until it has walked off. A spot
//              refuses it as the game does (mechanics/lockers.js canHide: the Creature chases it with a clear line from
//              its eye to the bot's within its full sight range): it runs on to break the line, then hides.
//   Both bots notice a teleport's warning aimed at them or close by (the torch, the hiss and the lights): as the
//   Creature forms there they look at the warned spot for a moment, still going their way.
// Each player's noises are the game's own (the NoiseBus locomotion sampler at 10 Hz; a co-op teammate's reach the
// brain as a remote page's). A catch downs them (no execution: the floor's lives are counted as downs); the first
// down on a floor gets up where it fell 7 s later, a later one respawns at the entry (the Creature moved off and the
// respawn grace, as life.js does).
//
// Per run (a floor, a seed, a difficulty, 1 or 2 players, a bot) it measures, from the players' side:
//   sighting     the Creature shown (fade >= 0.5) inside a player's view (SightHalfAngle of their look, the screen's
//                half-width at FOV 70) within SightRange studs with a clear line to its head or chest;
//   walked       the walking distance from its feet to the nearest player's (its nav), once a second: the share of
//                time within 45 / 90 / 140, and within 20 with no chase and no presence beat running;
//   pass-by      it comes within 30 studs walked with no chase starting before it is 40 away again;
//   chases       every chase and how it ended: lost sight (Search), gave up at the cap, caught, the player hid (one taken
//                up again out of its search or hiding watch within 20 s of its end is the same chase);
//   presence     a sighting, a pass-by or a chase: the first one's time and the gaps between them;
//   downs        catches of the run's players.
// A teleport test then puts a player on its way through the floor and asks for a teleport on them (the director's
// approach teleports, which form facing away with no stare, are not it): a straight-line
// sprinter (on the warning it sprints on along its way, then walks) and a hider (it breaks the line and hides within
// 8 s): does the teleport's encounter (its stalk, the chase and the search that follow it, until it patrols again,
// within 30 s of the warning) catch them?
// The targets (TARGETS below) are asserted unless --report; exit code 1 on a failed target.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';
import { NoiseBus } from '../src/engine/noise.js';
import { CFrame } from '../src/creature/cframe.js';
import { createCreature, PLAYER } from '../src/creature/index.js';
import { CreatureConfig, ROOT_HEIGHT } from '../src/creature/config.js';
import { FloorNav } from '../src/creature/nav.js';
import { fullRange } from '../src/creature/perception.js';
import { seededRandom } from '../src/creature/util.js';
import { SpawnTuning } from '../src/game/objectives/config.js';
import { hurried } from '../src/game/mechanics/hidespots.js';
import { PLAYER_ROOT, TICK, loadWorld, makeEngine } from './sim-engine.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};
const buildDir = path.resolve(opt('--build', path.join(here, '..', 'build')));
const SEEDS = Number(opt('--seeds', '12'));
const MINUTES = Number(opt('--minutes', '8'));
const FLOOR_KEYS = opt('--floors', 'L0,L1,L2').split(',');
const DIFFICULTIES = opt('--difficulties', 'Standard,Nightmare').split(',');
const PLAYER_COUNTS = opt('--players', '1,2').split(',').map(Number);
const REPORT_ONLY = argv.includes('--report');
// the objective bot's downs (the measure of "not too hard") are asserted on this many seeds: on 12 a floor's mean moves
// by about 0.25 between seed sets (one catch reshuffles the rest of the floor), on 36 by about 0.15
const DOWNS_SEEDS = Math.max(SEEDS, Number(opt('--downs-seeds', '36')));
const jsonOut = opt('--json', null);

const FLOORS = { L0: 'Level0_Basement', L1: 'Level1_Hallways', L2: 'Level2_Auditorium' };
const BOTS = opt('--bots', 'objective,careful').split(',');
const SEED_BASE = Number(opt('--seed-base', '1029'));

// the player
const WALK = 11;
const SPRINT = 19;
const CROUCH = 5.5;
const STAMINA_DRAIN = 7;
const STAMINA_REGEN = 14;
const STAMINA_REGEN_DELAY = 1.2;
const STAMINA_RECOVERED = 25; // spent: no sprint until the meter is back over this
const GET_UP = 7; // LivesConfig.Standard GetUpDelay 3 + GetUpHold 4
const RESPAWN_BLACKOUT = 4;
const RESPAWN = { walked: 70, clear: 45, teleportDelay: 45, grace: 10 };
const WORK_HOLD = 2;
const STATION_HOLD = 3;
const ARRIVE = 1.5;
// what counts as seeing it: the screen's half-width at FOV 70 (16:9), within SightRange, a clear line
const SIGHT_HALF_ANGLE = 50;
const SIGHT_RANGE = 80;
const SIGHTING_GAP = 3; // unseen this long: the next sighting is a new one
const PASS_NEAR = 30;
const PASS_CLEAR = 40;
const SAMPLE_EVERY = 1;
const CHASE_CHAIN = 20;
const BEATS = new Set(['Peek', 'Glimpse', 'Shadow', 'PassBy']);
// the careful player
const HEAR_NEAR = 30; // it hears the Creature this close (straight): crouch, torch off
const HIDE_NEAR = 25; // this close and coming: hide
const SEE_HIDE = 45; // seen this close: break the line and hide
const WARN_NEAR = 40; // a teleport warned this close to it: hide
const WARN_REACT = 1.8; // it turns to a warned spot this long after the cue began (the hiss has risen: it forms)...
const WARN_LOOK = 1.5; // ...and looks there this long at most
const HIDE_REACH = 45; // the hiding spots it runs for: within this walked...
const HIDE_PASS = 12; // ...whose way keeps this far off the danger
const HIDDEN_MIN = 8;
const HIDDEN_MAX = 40; // out before the 45 s shove
const HIDDEN_CLEAR = 45; // the Creature walked this far off: out again
const STILL_MAX = 15; // no spot within reach: still in the dark this long at most
const LOOK_BACK_EVERY = 7;
const LOOK_BACK_SECONDS = 0.8;
// the objective player when chased, or when it sees the Creature this close
const FLEE_SECONDS = 6;
const FLEE_REPLAN = 3;
const CAREFUL_FLEE = 4; // the careful player's run from a danger it finds no hiding spot clear of
const FLEE_TRIES = 30; // flee points whose ways are asked, best first
const FLEE_LEG = 25; // the stretch of a flee route that must not run back toward the Creature...
const FLEE_SLACK = 2; // ...by more than this
const FLEE_CORNER = 25; // a flee point out of the Creature's sight scores this much more
const AVOID_NEAR = 45;
const HEAR_LOOK = 25;
const HEAR_LOOK_EVERY = 4;
// the teleport test
const TRIAL_HIDE_WITHIN = 8;
const TRIAL_WATCH = 30;

// The targets (docs/MONSTER.md 20), per difficulty and player count. Floors: the Basement and the Hallways (the
// Auditorium is reported, not asserted: an interim floor). Standard solo is the brief's ("not too hard": a careless
// player is caught 0.3..0.8 times a floor and spends both its get-up and its respawn on at most one floor in five);
// the others restate only what cannot apply as it is, each for the reason given:
//   Standard pair  chases 2..7: two quarries (1..3.5 a player, inside solo's 2..5); each careless player no more than
//                  alone (0.8 a floor, 2 or more downs on at most one floor in five) and still caught (0.15 or more:
//                  measured, the two share its chases); the careful player's floors with a down under 35 %: a floor
//                  counts a down of either of two (about twice a solo floor's exposure).
//   Nightmare      the presence targets are Standard's (Nightmare adds danger, not frequency), within 20 under 6 %
//                  and chases 2..8 [pair 2..9]: a faster Creature with keener senses closes in and starts more
//                  chases, and a chased player may hide only once out of its sight (docs/MONSTER.md 8), so a chase
//                  lasts until the line is broken; the objective player's downs 0.7..5 [pair 0.5..4]
//                  each: its chase runs at the cap (18.5), only just slower than a sprint (19), and lasts 45 s, and the
//                  floor's lives are one get-up,
//                  so a player who never hides is meant to lose a Nightmare floor; fairness there is the careful
//                  player's (a down on fewer than 40 % of floors) and the hider's (never caught).
const TARGETS = {
  'Standard/1': { first: 75, gapMedian: 75, gapMax: 150, within90: 0.5, near20: 0.05, chases: [2, 5], objectiveDowns: [0.3, 0.8],
    twoDowns: 0.2, carefulDownFloors: 0.25 },
  'Standard/2': { first: 75, gapMedian: 75, gapMax: 150, within90: 0.5, near20: 0.05, chases: [2, 7], objectiveDowns: [0.15, 0.8],
    twoDowns: 0.2, carefulDownFloors: 0.35 },
  'Nightmare/1': { first: 75, gapMedian: 75, gapMax: 150, within90: 0.5, near20: 0.06, chases: [2, 8], objectiveDowns: [0.7, 5],
    carefulDownFloors: 0.4 },
  'Nightmare/2': { first: 75, gapMedian: 75, gapMax: 150, within90: 0.5, near20: 0.06, chases: [2, 9], objectiveDowns: [0.5, 4],
    carefulDownFloors: 0.4 },
};
const ASSERTED_FLOORS = new Set(['Level0_Basement', 'Level1_Hallways']);

const { meta, decoded } = loadWorld(buildDir);

// ---------------------------------------------------------------------------------------------------------------
// The floor: entries, targets, the Creature's start
// ---------------------------------------------------------------------------------------------------------------

const playerNavs = new Map();
/** The players' nav: every door open (they open doors), the Creature's agent (no crawlways). */
const playerNav = (level) => {
  if (!playerNavs.has(level)) playerNavs.set(level, new FloorNav(level, meta, () => true));
  return playerNavs.get(level);
};
const anchorPoint = (a) => new THREE.Vector3(a.cframe[0], a.cframe[1], a.cframe[2]);
const anchorsOf = (level, kind) => meta.anchors.filter((a) => a.level === level && a.kind === kind)
  .sort((a, b) => (a.id < b.id ? -1 : 1));

/** A floor point on the nav for `p` (its room's floor). */
function floorPoint(nav, p) {
  const room = nav.roomAt(p) || nav.nearestRoom(p);
  return room ? new THREE.Vector3(p.x, room.floorY, p.z) : p.clone();
}

function shuffle(list, random) {
  const out = list.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(random.nextNumber() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

/** The entry (a route's spawn slots, by seed) and the objective targets of a floor. */
function floorPlan(level, seed) {
  const nav = playerNav(level);
  const random = seededRandom(seed, `Presence|${level}`);
  const spawns = anchorsOf(level, 'PlayerSpawn');
  const byRoom = new Map();
  for (const a of spawns) {
    if (!byRoom.has(a.room)) byRoom.set(a.room, []);
    byRoom.get(a.room).push(a);
  }
  const routes = [...byRoom.keys()].sort();
  const entryRoom = routes[Math.floor(random.nextNumber() * routes.length)];
  const entries = byRoom.get(entryRoom).map((a) => floorPoint(nav, anchorPoint(a)));
  const lv = meta.objectives.levels[level];
  const points = [];
  for (const c of lv && Array.isArray(lv.candidates) ? lv.candidates : []) {
    if (c.eligible === false) continue;
    const p = c.stand && c.stand.pos ? new THREE.Vector3(c.stand.pos[0], 0, c.stand.pos[2]) : new THREE.Vector3(c.pos[0], 0, c.pos[2]);
    points.push({ at: floorPoint(nav, new THREE.Vector3(p.x, c.pos[1], p.z)), station: false });
  }
  for (const kind of ['BreakerPanel', 'ExitLock']) {
    for (const a of anchorsOf(level, kind)) points.push({ at: floorPoint(nav, anchorPoint(a)), station: true });
  }
  if (points.length < 4) {
    for (const a of anchorsOf(level, 'BatteryCandidate')) points.push({ at: floorPoint(nav, anchorPoint(a)), station: false });
    // the far side: the walkable point farthest from the entry
    let far = null;
    let farWalk = -1;
    for (const s of nav.samplePoints(5)) {
      const w = nav.pathLength(entries[0], s.position);
      if (Number.isFinite(w) && w > farWalk) {
        far = s.position;
        farWalk = w;
      }
    }
    if (far) points.push({ at: far.clone(), station: true });
  }
  const reachable = points.filter((p) => Number.isFinite(nav.pathLength(entries[0], p.at)));
  return { level, entries, entryRoom, targets: reachable, random };
}

/**
 * The Creature's start (objectives/spawns.js; the Hallways' classroom scare stands in as the same hold): a
 * PatrolWaypoint or CreatureSpawn SpawnTuning.MinDistance..MaxDistance studs walked from the entry, out of sight of
 * the entry room (its centre and inset corners at EntryEyeHeight, to the anchor at AnchorHeights), picked by the seed.
 */
function spawnPoint(world, level, entry, entryRoom, seed) {
  const nav = playerNav(level);
  const room = meta.rooms.find((r) => r.id === entryRoom);
  const eyes = [];
  if (room) {
    const { x, z, w, d } = room.rect;
    const i = SpawnTuning.EntryInset;
    const y = room.floorY + SpawnTuning.EntryEyeHeight;
    for (const [px, pz] of [[x + w / 2, z + d / 2], [x + i, z + i], [x + w - i, z + i], [x + i, z + d - i], [x + w - i, z + d - i]]) {
      eyes.push(new THREE.Vector3(px, y, pz));
    }
  }
  const seen = (p) => SpawnTuning.AnchorHeights.some((h) => eyes.some((e) =>
    world.lineClear(e, new THREE.Vector3(p.x, p.y + h, p.z), { ignoreEntities: true })));
  const pool = [...anchorsOf(level, 'PatrolWaypoint'), ...anchorsOf(level, 'CreatureSpawn')].map((a) => {
    const p = floorPoint(nav, anchorPoint(a));
    return { p, walk: nav.pathLength(entry, p) };
  }).filter((c) => c.walk >= SpawnTuning.MinDistance && c.walk <= SpawnTuning.MaxDistance && !seen(c.p));
  if (!pool.length) return null;
  return pool[Math.floor(seededRandom(seed, `CreatureSpawn|${level}`).nextNumber() * pool.length)].p;
}

// ---------------------------------------------------------------------------------------------------------------
// A session: the engine, the Creature, the players
// ---------------------------------------------------------------------------------------------------------------

function session(level, difficulty) {
  const engine = makeEngine(decoded);
  const creature = createCreature(engine, { render: false });
  const svc = creature.service;
  const s = { engine, creature, svc, level, difficulty, bots: [], events: [] };
  svc.env.setCatchHooks({ outcome: () => 'Down', apply: () => onCaught(s, s.bots[0]) });
  creature.bindGame({
    hideSpotOf: () => s.bots[0] && s.bots[0].locker,
    hideSpotOccupied: (id) => !!s.bots[0] && s.bots[0].locker === id,
    lifeState: () => (s.bots[0] ? s.bots[0].life : 'Lobby'),
    downedCount: () => 0,
  });
  svc.setRoster(() => s.bots.slice(1).map((b) => b.handle));
  const t = () => engine.loop.time;
  svc.stateChanged.connect((next, prev) => {
    const target = svc.getTarget();
    const bot = s.bots.find((b) => b.handle === target);
    const start = next === 'WallChase' && bot ? { stamina: Math.round(bot.stamina),
      distance: Math.round(bot.root.distanceTo(svc.body.getPosition())) } : null;
    s.events.push({ kind: 'state', at: t(), next, prev, target, start });
  });
  svc.caught.connect((victim, kind) => {
    const bot = s.bots.find((b) => b.handle === victim);
    s.events.push({ kind: 'caught', at: t(), victim, how: kind, state: svc.state, mode: bot ? bot.mode : null,
      stamina: bot ? Math.round(bot.stamina) : null });
  });
  svc.gaveUp.connect(() => s.events.push({ kind: 'gaveUp', at: t() }));
  svc.teleportWarning.connect((spot, target) => {
    // the director's approach (it forms facing away, no stare) or a teleport (the stare and the stalk)
    const approach = !!svc.warp && !!svc.warp.plan && svc.warp.plan.side === 'Approach';
    s.events.push({ kind: 'warning', at: t(), spot: spot.clone(), target, approach });
    for (const b of s.bots) {
      const mine = target === b.handle;
      b.warnings.push({ at: t(), spot: spot.clone(), mine, approach });
      // a warning it notices (its torch stutters, or the hiss and the stuttering lights close by): it looks there
      if (b.kind !== 'trial' && (mine || spot.distanceTo(feet(b.root)) < WARN_NEAR)) {
        b.glance = { spot: spot.clone(), from: t() + WARN_REACT, until: t() + WARN_REACT + WARN_LOOK, back: null };
      }
    }
  });
  s.hideSpots = svc.env.hideSpots(level);
  return s;
}

/** A player: the local SimPlayer (index 0) or a co-op teammate's handle (the brain's RemotePlayer). */
function addBot(s, kind, entry, targets) {
  const index = s.bots.length;
  const bot = {
    index, kind, root: entry.clone().setY(entry.y + PLAYER_ROOT), look: new THREE.Vector3(0, 0, -1), moveState: 'Standing',
    torch: true, life: 'Alive', locker: null, caught: false, stamina: 100, spent: false, drainedAt: -Infinity,
    sprintedAt: -Infinity, entry: entry.clone(), targets, ti: 0, route: null, ri: 0, goal: null, holdUntil: 0, workAt: 0,
    mode: 'travel', downAt: 0, floorDowns: 0, downs: 0, hiddenAt: 0, warnings: [], lookBackAt: LOOK_BACK_EVERY, speed: 0,
    heardLookUntil: 0, glance: null,
    bus: null, lastSeenAt: -Infinity,
  };
  if (index === 0) {
    bot.handle = PLAYER;
    bot.bus = s.engine.noise;
  } else {
    const bus = new NoiseBus({ loop: s.engine.loop, world: s.engine.world });
    bus.on((e) => s.svc.hearRemote({ position: e.position.clone(), kind: e.kind, radius: e.radius, priority: e.priority,
      medium: e.medium, levelId: e.level, ventNodeId: null, serverTime: e.time, sourceUserId: bot.handle.userId }));
    bot.bus = bus;
    bot.handle = {
      userId: 1 + index, name: `Mate${index}`,
      root: () => (bot.life === 'Dead' ? null : bot.root.clone()),
      // facing their look, as a co-op page builds a teammate's (game/coop/creature.js): the catch needs it
      rootCFrame: () => (bot.life === 'Dead' ? null
        : CFrame.lookAt(bot.root.clone(), bot.root.clone().add(new THREE.Vector3(bot.look.x, 0, bot.look.z)))),
      look: () => bot.look.clone(),
      lifeState: () => bot.life,
      downedCount: () => 0,
      moveState: () => bot.moveState,
      mode: () => 'OnFoot',
      inVent: () => false,
      flashlightOn: () => bot.torch,
      lockerId: () => bot.locker,
      hasLock: () => false,
      controlLock: () => 'None',
      canCatch: () => true,
      setCaught: (on) => {
        bot.caught = on;
      },
      turn: () => {},
      catchCue: () => {},
      catchAbort: () => {
        bot.caught = false;
      },
      catchOutcome: () => onCaught(s, bot),
    };
  }
  s.bots.push(bot);
  return bot;
}

function onCaught(s, bot) {
  if (!bot) return;
  bot.life = 'Downed';
  bot.moveState = 'DownedCrawling';
  bot.downs += 1;
  bot.floorDowns += 1;
  bot.downAt = s.engine.loop.time;
  bot.mode = 'downed';
  bot.route = null;
  bot.caught = false;
}

/** Mirrors the local bot onto the SimPlayer the Creature's env reads. */
function syncLocal(s) {
  const b = s.bots[0];
  const p = s.engine.player;
  p.body.position.copy(b.root);
  p.moveState = b.moveState;
  p.lifeState = b.life;
  p.flashlight.on = b.torch;
  p.setLook(Math.atan2(-b.look.x, -b.look.z), Math.asin(Math.max(-1, Math.min(1, b.look.y))));
}

// ---------------------------------------------------------------------------------------------------------------
// The players' minds
// ---------------------------------------------------------------------------------------------------------------

const feet = (root) => new THREE.Vector3(root.x, root.y - PLAYER_ROOT, root.z);
const creatureFeet = (svc) => {
  const p = svc.body.getPosition();
  return new THREE.Vector3(p.x, p.y - ROOT_HEIGHT, p.z);
};

function routeTo(s, bot, goal) {
  const path = playerNav(s.level).computePath(feet(bot.root), goal);
  bot.goal = goal.clone();
  bot.route = path ? path.waypoints : [goal.clone()];
  bot.ri = 0;
}

function nextTarget(s, bot) {
  const list = bot.targets;
  if (!list.length) return null;
  if (bot.ti >= list.length) {
    bot.targets = shuffle(list, s.plan.random);
    bot.ti = 0;
  }
  return bot.targets[bot.ti++];
}

/** The Creature is chasing this bot. */
function chasedBy(s, bot) {
  return s.svc.state === 'WallChase' && s.svc.getTarget() === bot.handle;
}

/** Whether the bot sees the Creature now (the report's sighting rule). */
function sees(s, bot) {
  const svc = s.svc;
  if (bot.life !== 'Alive' || bot.locker || svc.body.hidden || svc.viewState().fade < 0.5) return false;
  const eye = bot.root.clone().add(new THREE.Vector3(0, 1.5, 0));
  const look = bot.look;
  for (const q of [svc._creatureEye(), svc.body.getPosition()]) {
    const d = q.clone().sub(eye);
    const length = d.length();
    if (length > SIGHT_RANGE) continue;
    const flatLook = Math.hypot(look.x, look.z) || 1;
    const flatD = Math.hypot(d.x, d.z) || 1;
    const angle = (Math.acos(Math.max(-1, Math.min(1, (look.x * d.x + look.z * d.z) / (flatLook * flatD)))) * 180) / Math.PI;
    if (angle <= SIGHT_HALF_ANGLE && s.engine.world.lineClear(eye, q)) return true;
  }
  return false;
}

/**
 * The hiding spot to run for: within HIDE_REACH walked, not leading toward `danger` (the spot, and the way to it
 * keeps HIDE_PASS off it), its door out of the Creature's sight, nearest first.
 */
function hideSpotFor(s, bot, danger) {
  const nav = playerNav(s.level);
  const from = feet(bot.root);
  const toDanger = danger ? Math.hypot(danger.x - from.x, danger.z - from.z) : Infinity;
  // its eye while it is shown (else where a warning says it will form): a spot it would see them get into is no
  // hiding spot
  const watcher = !s.svc.body.hidden ? s.svc._creatureEye() :
    danger ? new THREE.Vector3(danger.x, danger.y + ROOT_HEIGHT + s.svc.metrics.eyeHeights.Biped, danger.z) : null;
  const ranked = [];
  for (const spot of s.hideSpots) {
    const at = spot.front.position;
    if (Math.abs(at.y - from.y) > 6 || at.distanceTo(from) > HIDE_REACH) continue;
    if ([...s.bots].some((o) => o !== bot && o.locker === spot.id)) continue;
    if (danger && Math.hypot(danger.x - at.x, danger.z - at.z) < Math.min(toDanger, 18)) continue;
    if (watcher && watcher.distanceTo(at) < SEE_HIDE &&
      s.engine.world.lineClear(watcher, new THREE.Vector3(at.x, at.y + PLAYER_ROOT, at.z))) continue;
    const walk = nav.pathLength(from, at);
    if (!Number.isFinite(walk) || walk > HIDE_REACH) continue;
    ranked.push({ spot, walk });
  }
  ranked.sort((a, b) => a.walk - b.walk);
  // never a way that runs past the danger: over its first FLEE_LEG studs it keeps HIDE_PASS off it (or no nearer
  // than the bot stands now)
  const start = danger ? Math.hypot(from.x - danger.x, from.z - danger.z) : Infinity;
  for (const r of ranked) {
    if (!danger) return r.spot;
    const path = nav.computePath(from, r.spot.front.position);
    if (path && start + closing(path.waypoints, from, danger) >= Math.min(start - FLEE_SLACK, HIDE_PASS)) return r.spot;
  }
  return null;
}

function goHide(s, bot, danger) {
  const spot = hideSpotFor(s, bot, danger);
  if (!spot) return false;
  bot.mode = 'toHide';
  bot.hideTarget = spot;
  routeTo(s, bot, spot.front.position);
  return true;
}

/**
 * The game's refusal at a hiding spot (mechanics/lockers.js canHide, "It's watching you. Lose it first."): the
 * Creature chases the bot and has a clear line from its eye to theirs within its full sight range.
 */
function watched(s, bot) {
  if (!chasedBy(s, bot)) return false;
  const from = s.svc._creatureEye();
  const to = s.svc._playerEye(bot.handle);
  return !!to && from.distanceTo(to) <= fullRange(s.difficulty) && s.engine.world.lineClear(from, to);
}

/** Gets into the spot it ran for; false when the spot refuses it (watched). */
function enterHide(s, bot) {
  if (watched(s, bot)) return false;
  const spot = bot.hideTarget;
  const t = s.engine.loop.time;
  bot.bus.emit(spot.front.position, hurried(bot.sprintedAt, t) ? 'HideEnterHurried' : 'HideEnter',
    { source: 'player', level: s.level });
  bot.locker = spot.id;
  bot.moveState = 'Hiding';
  const inside = spot.front.position.clone().addScaledVector(spot.front.lookVector, -1.2);
  bot.root.set(inside.x, inside.y + PLAYER_ROOT, inside.z);
  bot.mode = 'hidden';
  bot.hiddenAt = t;
  bot.route = null;
  return true;
}

function leaveHide(s, bot) {
  const spot = bot.hideTarget;
  bot.locker = null;
  bot.moveState = 'Standing';
  if (spot) bot.root.set(spot.front.position.x, spot.front.position.y + PLAYER_ROOT, spot.front.position.z);
  bot.mode = 'travel';
  bot.route = null;
}

/** The careful bot's reading of the danger: what it hears, sees and is warned of (10 Hz). */
function carefulThink(s, bot, t) {
  const svc = s.svc;
  const shown = !svc.body.hidden;
  const here = svc.body.getPosition();
  const straight = shown ? here.distanceTo(bot.root) : Infinity;
  if (bot.mode === 'hidden') {
    const watched = svc.state === 'HidingResponse' && svc.getTarget() === bot.handle;
    if (watched) {
      // out during a LookAway, then away from it
      if (svc.action === 'LookAway') {
        leaveHide(s, bot);
        runFrom(s, bot, t, here, FLEE_SECONDS);
      }
      return;
    }
    const walked = playerNav(s.level).pathLength(feet(bot.root), creatureFeet(svc));
    const away = !shown || walked > HIDDEN_CLEAR;
    if ((t - bot.hiddenAt >= HIDDEN_MIN && away && svc.state !== 'WallChase') || t - bot.hiddenAt >= HIDDEN_MAX) leaveHide(s, bot);
    return;
  }
  if (bot.mode === 'toHide') {
    // creeping to a spot: a dash once it chases them
    if (bot.creep && chasedBy(s, bot)) bot.creep = false;
    // the Creature shown on the way there (it formed on it, it came round): another spot, else away from it
    if (shown && straight < SEE_HIDE && bot.route) {
      const from = feet(bot.root);
      const start = Math.hypot(from.x - here.x, from.z - here.z);
      if (start + closing(bot.route.slice(bot.ri), from, here) < Math.min(start - FLEE_SLACK, HIDE_PASS) &&
        !goHide(s, bot, here)) runFrom(s, bot, t, here, CAREFUL_FLEE);
    }
    return;
  }
  const warned = bot.warnings.find((w) => t - w.at < 2 && (w.mine || w.spot.distanceTo(feet(bot.root)) < WARN_NEAR));
  bot.warnings = bot.warnings.filter((w) => t - w.at < 2);
  const chased = chasedBy(s, bot);
  const seen = bot.lastSeenAt >= t - 0.15 && straight < SEE_HIDE;
  const closingIn = shown && straight < HIDE_NEAR;
  const spotted = svc.ctx.sightings.some((x) => x.player === bot.handle);
  if (bot.mode === 'still') {
    // keeping still in the dark until it has gone (or it finds them)
    if (!warned && !chased && !seen && !spotted) {
      if (!shown || straight > HIDDEN_CLEAR || t >= bot.stillUntil) bot.mode = 'travel';
      return;
    }
  }
  if (warned || chased || seen || closingIn) {
    const danger = warned ? warned.spot : here;
    if (goHide(s, bot, danger)) {
      // a crouched creep when it only hears it coming; a dash when warned, chased or in its sight
      bot.creep = closingIn && !warned && !chased && !seen;
      return;
    }
    // no spot to reach clear of it, only heard close and unseen: still, crouched, the torch off (it sees half as far)
    if (!warned && !chased && !seen && !spotted) {
      bot.mode = 'still';
      bot.route = null;
      bot.moveState = 'Crouching';
      bot.torch = false;
      bot.stillUntil = t + STILL_MAX;
      return;
    }
    if (bot.mode !== 'flee') {
      runFrom(s, bot, t, danger, CAREFUL_FLEE);
      return;
    }
  }
  // running for it: on its feet (a sprint), not creeping
  if (bot.mode === 'flee') return;
  const near = shown && straight < HEAR_NEAR;
  bot.moveState = near ? 'Crouching' : 'Standing';
  bot.torch = !near;
}

/**
 * How close a route comes to `danger` over its first FLEE_LEG studs, against where it starts: the least of (distance
 * to `danger` at a point of the way) - (distance at its start). Under 0: the way runs back toward it.
 */
function closing(route, from, danger) {
  const start = Math.hypot(from.x - danger.x, from.z - danger.z);
  let worst = Infinity;
  let walked = 0;
  let prev = from;
  for (const w of route) {
    const step = Math.hypot(w.x - prev.x, w.z - prev.z);
    // the leg's nearest point to the danger
    const t = step > 1e-6 ? Math.max(0, Math.min(1, ((danger.x - prev.x) * (w.x - prev.x) + (danger.z - prev.z) * (w.z - prev.z)) / (step * step))) : 0;
    const near = Math.hypot(prev.x + (w.x - prev.x) * t - danger.x, prev.z + (w.z - prev.z) * t - danger.z);
    worst = Math.min(worst, near - start);
    walked += step;
    prev = w;
    if (walked >= FLEE_LEG) break;
  }
  return worst;
}

/**
 * Runs for a walkable point 30..60 studs away, far from `danger` and round a corner from it where there is one, whose
 * way does not run back toward it (over its first FLEE_LEG studs it never comes nearer than where the bot stands;
 * failing that, the way that comes least near, unless the flee way it is already on comes less near: a fresh pick
 * never turns it round into the Creature's arms).
 */
function fleeFrom(s, bot, danger) {
  const nav = playerNav(s.level);
  const from = feet(bot.root);
  const current = bot.route && bot.route === bot.fleeRoute && bot.ri < bot.route.length ?
    closing(bot.route.slice(bot.ri), from, danger) : -Infinity;
  // round a corner first: a point out of its sight (from its eye, else from the danger's head height) scores more
  const eye = !s.svc.body.hidden ? s.svc._creatureEye() : new THREE.Vector3(danger.x, danger.y + ROOT_HEIGHT, danger.z);
  const ranked = [];
  for (const p of nav.samplePoints(5)) {
    const at = p.position;
    const d = at.distanceTo(from);
    if (d < 30 || d > 60 || Math.abs(at.y - from.y) > 6) continue;
    const out = !s.engine.world.lineClear(eye, new THREE.Vector3(at.x, at.y + PLAYER_ROOT, at.z), { ignoreEntities: true });
    ranked.push({ at, score: at.distanceTo(danger) - d * 0.3 + (out ? FLEE_CORNER : 0) });
  }
  ranked.sort((a, b) => b.score - a.score);
  let best = null;
  for (const c of ranked.slice(0, FLEE_TRIES)) {
    const path = nav.computePath(from, c.at);
    if (!path) continue;
    const worst = closing(path.waypoints, from, danger);
    if (!best || worst > best.worst) best = { at: c.at, path, worst };
    if (worst >= -FLEE_SLACK) break;
  }
  if (!best || (best.worst < -FLEE_SLACK && best.worst <= current)) return;
  bot.goal = best.at.clone();
  bot.route = best.path.waypoints;
  bot.fleeRoute = bot.route;
  bot.ri = 0;
}

/** Runs from `danger` for `seconds`, on its feet, by a new way every FLEE_REPLAN seconds while it is told to. */
function runFrom(s, bot, t, danger, seconds) {
  if (bot.mode === 'flee' && t < bot.replanAt) return;
  bot.mode = 'flee';
  bot.moveState = 'Standing';
  bot.fleeUntil = t + seconds;
  bot.replanAt = t + FLEE_REPLAN;
  fleeFrom(s, bot, danger);
}

/**
 * The objective bot: chased, it runs (never hides), a new way every few seconds; seeing the Creature close ahead, it
 * turns away from it for a moment, then goes on; hearing it right by (its footfalls and rattle within HEAR_LOOK), it
 * looks that way.
 */
function objectiveThink(s, bot, t) {
  const chased = chasedBy(s, bot);
  const here = s.svc.body.getPosition();
  const near = s.svc.body.hidden ? Infinity : here.distanceTo(bot.root);
  if (!chased && near < HEAR_LOOK && bot.lastSeenAt < t - 1 && t >= bot.heardLookUntil) {
    bot.look.set(here.x - bot.root.x, 0, here.z - bot.root.z).normalize();
    bot.lookingBack = true;
    bot.lookBackAt = t + LOOK_BACK_SECONDS;
    bot.heardLookUntil = t + HEAR_LOOK_EVERY;
  }
  const ahead = !chased && bot.lastSeenAt >= t - 0.15 && near < AVOID_NEAR;
  if (chased || ahead) runFrom(s, bot, t, here, FLEE_SECONDS);
}

/**
 * A teleport's warning the bot noticed (bot.glance): WARN_REACT after the cue began it looks at the warned spot, still
 * going its way, until it has seen the Creature there (endGlance) or WARN_LOOK is up; then its look is its own again.
 */
function lookAtWarning(bot, t) {
  const g = bot.glance;
  if (!g || t < g.from) return;
  if (t >= g.until || bot.locker) {
    endGlance(bot);
    return;
  }
  const dx = g.spot.x - bot.root.x;
  const dz = g.spot.z - bot.root.z;
  const d = Math.hypot(dx, dz);
  if (d < 1e-3) return;
  if (!g.back) g.back = bot.look.clone();
  bot.look.set(dx / d, 0, dz / d);
}

function endGlance(bot) {
  if (!bot.glance) return;
  if (bot.glance.back) bot.look.copy(bot.glance.back);
  bot.glance = null;
}

/** One 30 Hz step of a bot: its mind (at 10 Hz), its legs, its noises. */
function stepBot(s, bot, dt, think) {
  const t = s.engine.loop.time;
  if (bot.mode === 'downed') {
    if (t - bot.downAt < GET_UP) return;
    if (bot.floorDowns >= 2) {
      if (t - bot.downAt < GET_UP + RESPAWN_BLACKOUT) {
        bot.life = 'Dead';
        return;
      }
      bot.root = bot.entry.clone().setY(bot.entry.y + PLAYER_ROOT);
      s.svc.relocateFrom(bot.entry, { walked: RESPAWN.walked, clear: RESPAWN.clear, teleportDelay: RESPAWN.teleportDelay });
      s.svc.ignore(bot.handle, RESPAWN.grace);
    }
    bot.life = 'Alive';
    bot.moveState = 'Standing';
    bot.mode = 'travel';
    bot.route = null;
    return;
  }
  if (bot.caught || (bot.index === 0 && s.engine.player.locks.has('Jumpscare'))) return;
  if (think) {
    lookAtWarning(bot, t);
    if (sees(s, bot)) {
      if (t - bot.lastSeenAt > SIGHTING_GAP) s.events.push({ kind: 'sighting', at: t, bot: bot.index });
      bot.lastSeenAt = t;
      endGlance(bot);
    }
    if (bot.kind === 'careful') carefulThink(s, bot, t);
    else if (bot.kind === 'objective') objectiveThink(s, bot, t);
  }
  if (bot.mode === 'hidden' || bot.mode === 'still') return;
  if (bot.mode === 'work') {
    if (t >= bot.workAt) {
      bot.workAt = t + 1;
      bot.bus.emit(feet(bot.root), 'ObjectiveWork', { source: 'player', level: s.level });
    }
    if (t >= bot.holdUntil) {
      if (bot.station) bot.bus.emit(feet(bot.root), 'ObjectiveClunk', { source: 'player', level: s.level });
      bot.mode = 'travel';
      bot.route = null;
    }
    return;
  }
  if (bot.mode === 'flee' && t >= bot.fleeUntil) {
    bot.mode = 'travel';
    bot.route = null;
  }
  if (!bot.route) {
    if (bot.mode === 'travel') {
      const target = nextTarget(s, bot);
      if (!target) return;
      bot.current = target;
      routeTo(s, bot, target.at);
    } else if (bot.mode === 'flee') {
      fleeFrom(s, bot, s.svc.body.getPosition());
      if (!bot.route) bot.mode = 'travel';
      return;
    }
  }
  // legs
  const wantSprint = bot.kind === 'objective' || bot.mode === 'flee' || (bot.mode === 'toHide' && !bot.creep) || bot.sprintAlways;
  if (bot.mode === 'toHide') bot.moveState = bot.creep ? 'Crouching' : 'Standing';
  if (bot.spent && bot.stamina >= STAMINA_RECOVERED) bot.spent = false;
  const sprinting = wantSprint && !bot.spent && bot.moveState !== 'Crouching';
  const pace = sprinting ? SPRINT : bot.moveState === 'Crouching' ? CROUCH : WALK;
  let left = pace * dt;
  let moved = 0;
  while (left > 1e-6 && bot.route && bot.ri < bot.route.length) {
    const wp = bot.route[bot.ri];
    const f = feet(bot.root);
    const dx = wp.x - f.x;
    const dz = wp.z - f.z;
    const d = Math.hypot(dx, dz);
    if (d < 1e-3) {
      bot.ri += 1;
      continue;
    }
    const step = Math.min(d, left);
    bot.root.x += (dx / d) * step;
    bot.root.z += (dz / d) * step;
    bot.root.y = wp.y + PLAYER_ROOT;
    left -= step;
    moved += step;
    if (!bot.lookingBack && !(bot.glance && bot.glance.back)) bot.look.set(dx / d, 0, dz / d);
    if (step >= d - 1e-6) bot.ri += 1;
  }
  bot.speed = moved / dt;
  if (sprinting && moved > 0) {
    bot.stamina = Math.max(0, bot.stamina - STAMINA_DRAIN * dt);
    bot.drainedAt = t;
    bot.sprintedAt = t;
    if (bot.stamina <= 0) bot.spent = true;
  } else if (t - bot.drainedAt >= STAMINA_REGEN_DELAY) bot.stamina = Math.min(100, bot.stamina + STAMINA_REGEN * dt);
  if (bot.moveState !== 'Crouching' && bot.moveState !== 'Hiding') bot.moveState = sprinting && moved > 0 ? 'Sprinting' : 'Standing';
  // a look back now and then (the careful one); a heard look ends
  if (bot.kind !== 'careful' && bot.lookingBack && t >= bot.lookBackAt) bot.lookingBack = false;
  if (bot.kind === 'careful' && bot.mode === 'travel' && !(bot.glance && bot.glance.back)) {
    if (!bot.lookingBack && t >= bot.lookBackAt) {
      bot.lookingBack = true;
      bot.look.multiplyScalar(-1);
      bot.lookBackAt = t + LOOK_BACK_SECONDS;
    } else if (bot.lookingBack && t >= bot.lookBackAt) {
      bot.lookingBack = false;
      bot.look.multiplyScalar(-1);
      bot.lookBackAt = t + LOOK_BACK_EVERY;
    }
  }
  if (think) bot.bus.sampleLocomotion(feet(bot.root), bot.moveState, bot.speed, { level: s.level });
  if (bot.route && bot.ri >= bot.route.length) {
    bot.route = null;
    if (bot.mode === 'toHide') {
      // refused at the door (it is watching): away from it, to lose it first
      if (!enterHide(s, bot)) runFrom(s, bot, t, s.svc.body.getPosition(), CAREFUL_FLEE);
    } else if (bot.mode === 'travel' && bot.current) {
      bot.mode = 'work';
      bot.station = bot.current.station;
      bot.holdUntil = t + (bot.station ? STATION_HOLD : WORK_HOLD);
      bot.workAt = t;
      bot.moveState = 'Standing';
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------
// One measured floor
// ---------------------------------------------------------------------------------------------------------------

/** The game's floor start: activation, the spawn hold for the grace (released early), then the hunt. */
function startFloor(s, seed) {
  const svc = s.svc;
  s.creature.beginRun({ difficulty: s.difficulty });
  s.creature.activateLevel(s.level);
  const at = spawnPoint(s.engine.world, s.level, s.plan.entries[0], s.plan.entryRoom, seed);
  const grace = SpawnTuning.Grace[s.difficulty];
  if (!at) return;
  const h = s.creature.acquireScripted('CreatureSpawn');
  const root = at.clone().setY(at.y + ROOT_HEIGHT);
  const entry = s.plan.entries[0];
  h.teleport(new THREE.Matrix4().lookAt(root, new THREE.Vector3(entry.x, root.y, entry.z), new THREE.Vector3(0, 1, 0)).setPosition(root));
  h.setHidden(false);
  s.hold = { handle: h, until: s.engine.loop.time + grace, loud: false };
  const listen = (e) => {
    if (!s.hold || e.level !== s.level || (e.priority !== 'High' && e.priority !== 'Critical')) return;
    s.hold.loud = true;
    if (e.position.distanceTo(svc.body.getPosition()) <= e.radius) s.hold.alert = { position: e.position.clone(), priority: e.priority };
  };
  s.engine.noise.on(listen);
  for (const b of s.bots.slice(1)) b.bus.on(listen);
}

function stepHold(s) {
  const hold = s.hold;
  if (!hold) return;
  const here = s.svc.body.getPosition();
  const near = s.bots.some((b) => b.life === 'Alive' && b.root.distanceTo(here) <= SpawnTuning.ReleaseNear);
  if (s.engine.loop.time < hold.until && !hold.loud && !near) return;
  hold.handle.release('Patrol');
  if (hold.alert) s.svc.alert(hold.alert.position, hold.alert.priority);
  s.hold = null;
}

function median(list) {
  if (!list.length) return null;
  const sorted = list.slice().sort((a, b) => a - b);
  const m = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[m] : (sorted[m - 1] + sorted[m]) / 2;
}

function runFloor(level, seed, difficulty, players, kind) {
  const s = session(level, difficulty);
  s.plan = floorPlan(level, seed);
  for (let i = 0; i < players; i++) {
    const targets = shuffle(s.plan.targets, seededRandom(seed, `PresenceTargets|${level}|${i}`));
    const bot = addBot(s, kind, s.plan.entries[Math.min(i, s.plan.entries.length - 1)], targets);
    bot.lookBackAt = LOOK_BACK_EVERY + i * 2;
  }
  syncLocal(s);
  startFloor(s, seed);
  const svc = s.svc;
  const nav = svc._nav(level);
  const total = MINUTES * 60;
  const ticks = Math.round(total / TICK);
  const start = s.engine.loop.time;
  const samples = { n: 0, w45: 0, w90: 0, w140: 0, near20: 0, walks: [] };
  let passing = null;
  const passBys = [];
  let tick = 0;
  let maxSpeed = 0;
  let fastest = null;
  const stateTime = {};
  const phaseTime = {};
  let heardTicks = 0;
  let brainTicks = 0;
  let prev = svc.body.getPosition().clone();
  let prevPlacements = svc.body.placements;
  let wasCatching = false;
  for (; tick < ticks; tick++) {
    const think = tick % 3 === 0;
    for (const b of s.bots) stepBot(s, b, TICK, think);
    syncLocal(s);
    stepHold(s);
    s.engine.loop.step();
    const t = s.engine.loop.time - start;
    const pos = svc.body.getPosition();
    // its own walk only: a catch's staging (and its last tick) moves the body itself
    const catching = !!svc.catching || svc.jumpscare.isBusy();
    if (svc.body.placements === prevPlacements && svc.state !== 'Scripted' && !catching && !wasCatching) {
      const v = Math.hypot(pos.x - prev.x, pos.z - prev.z) / TICK;
      if (v > maxSpeed) {
        maxSpeed = v;
        fastest = { at: +t.toFixed(2), state: svc.state, warp: svc.warp ? svc.warp.phase : null };
      }
    }
    if (tick % 3 === 0 && !s.hold) {
      brainTicks += 1;
      stateTime[svc.state] = (stateTime[svc.state] || 0) + 1;
      const phase = svc.pacing ? svc.pacing.phase : 'none';
      phaseTime[phase] = (phaseTime[phase] || 0) + 1;
      if (svc.ctx && svc.ctx.heard) heardTicks += 1;
    }
    prev = pos.clone();
    prevPlacements = svc.body.placements;
    wasCatching = catching;
    if (tick % Math.round(SAMPLE_EVERY / TICK) !== 0 || s.hold) continue;
    // the walked distance to the nearest player
    const from = creatureFeet(svc);
    let walked = Infinity;
    for (const b of s.bots) {
      if (b.life === 'Dead') continue;
      walked = Math.min(walked, nav.pathLength(from, feet(b.root)));
    }
    samples.n += 1;
    if (walked <= 45) samples.w45 += 1;
    if (walked <= 90) samples.w90 += 1;
    if (walked <= 140) samples.w140 += 1;
    const chasing = svc.state === 'WallChase' || svc.state === 'HidingResponse';
    if (walked <= 20 && !chasing && !BEATS.has(svc.state) && !svc.body.hidden) samples.near20 += 1;
    if (Number.isFinite(walked)) samples.walks.push(walked);
    if (!passing && walked <= PASS_NEAR && !chasing && !svc.body.hidden) passing = { at: t, chased: false };
    if (passing) {
      if (svc.state === 'WallChase') passing.chased = true;
      if (walked > PASS_CLEAR) {
        if (!passing.chased) {
          passBys.push(passing.at);
          s.events.push({ kind: 'passBy', at: passing.at + start });
        }
        passing = null;
      }
    }
  }
  // chases and how they ended
  const chases = [];
  let open = null;
  for (const e of s.events) {
    if (e.kind === 'state' && e.next === 'WallChase') open = { at: e.at, end: null, how: null, caught: false, from: e.prev, start: e.start };
    else if (open && e.kind === 'caught') open.caught = true;
    else if (open && e.kind === 'state' && e.prev === 'WallChase') {
      open.end = e.at;
      open.how = open.caught ? 'caught' : e.next === 'HidingResponse' ? 'hid' : e.next === 'Search' ? 'lost' :
        s.events.some((g) => g.kind === 'gaveUp' && Math.abs(g.at - e.at) < 0.2) ? 'cap' : `to ${e.next}`;
      chases.push(open);
      open = null;
    }
  }
  if (open) chases.push({ ...open, how: 'running' });
  // chase episodes: a chase taken up again out of the search or the hiding watch that followed the last one, within
  // CHASE_CHAIN seconds of its end, is the same chase
  const episodes = [];
  for (const c of chases) {
    const last = episodes[episodes.length - 1];
    const chained = last && last.end !== null && (c.from === 'Search' || c.from === 'HidingResponse') &&
      c.at - last.end <= CHASE_CHAIN;
    if (chained) {
      last.end = c.end;
      last.how = c.how;
    } else episodes.push({ ...c });
  }
  const presence = [...s.events.filter((e) => e.kind === 'sighting' || e.kind === 'passBy').map((e) => e.at - start),
    ...episodes.map((c) => c.at - start)].sort((a, b) => a - b);
  const gaps = [];
  let last = 0;
  for (const at of presence) {
    gaps.push(at - last);
    last = at;
  }
  gaps.push(total - last);
  const sightings = s.events.filter((e) => e.kind === 'sighting').map((e) => e.at - start);
  const firstPresence = presence.length ? presence[0] : null;
  const ends = {};
  for (const c of episodes) ends[c.how] = (ends[c.how] || 0) + 1;
  const downs = s.bots.reduce((n, b) => n + b.downs, 0);
  // each player's longest stretch without seeing it (the start and the floor's end bound it)
  const sightGapMax = Math.max(...s.bots.map((b) => {
    let longest = 0;
    let from = 0;
    for (const at of [...s.events.filter((e) => e.kind === 'sighting' && e.bot === b.index).map((e) => e.at - start), total]) {
      longest = Math.max(longest, at - from);
      from = at;
    }
    return longest;
  }));
  return {
    level, seed, difficulty, players, bot: kind,
    firstSighting: sightings.length ? +sightings[0].toFixed(1) : null,
    firstPresence: firstPresence !== null ? +firstPresence.toFixed(1) : null,
    sightingsPerMinute: +(sightings.length / MINUTES).toFixed(2),
    share45: +(samples.w45 / samples.n).toFixed(3),
    share90: +(samples.w90 / samples.n).toFixed(3),
    share140: +(samples.w140 / samples.n).toFixed(3),
    near20: +(samples.near20 / samples.n).toFixed(3),
    medianWalk: Math.round(median(samples.walks) ?? -1),
    passBys: passBys.length,
    chases: episodes.length,
    chaseStartsRaw: chases.length,
    chaseEnds: ends,
    chaseFrom: chases.map((c) => c.from),
    chaseStarts: chases.map((c) => ({ from: c.from, how: c.how, ...(c.start || {}), seconds: c.end !== null ? +(c.end - c.at).toFixed(1) : null })),
    chaseSeconds: +median(chases.filter((c) => c.end !== null).map((c) => c.end - c.at)) || 0,
    gapMedian: +median(gaps).toFixed(1),
    gapMax: +Math.max(...gaps).toFixed(1),
    downs,
    downsEach: s.bots.map((b) => b.downs),
    downFloor: downs > 0,
    sightGapMax: +sightGapMax.toFixed(1),
    teleports: svc.teleports,
    maxSpeed: +maxSpeed.toFixed(2),
    fastest,
    stateShare: Object.fromEntries(Object.entries(stateTime).map(([k, v]) => [k, +(v / brainTicks).toFixed(3)])),
    phaseShare: Object.fromEntries(Object.entries(phaseTime).map(([k, v]) => [k, +(v / brainTicks).toFixed(3)])),
    heardPerMinute: +((heardTicks / brainTicks) * 600).toFixed(1),
    states: [...new Set(s.events.filter((e) => e.kind === 'state').map((e) => e.next))].sort(),
    catches: s.events.filter((e) => e.kind === 'caught').map((e) => `${Math.round(e.at - start)}s ${e.how}/${e.state}/${e.mode}/${e.stamina}`),
    longestGapAt: (() => {
      let at = 0;
      let best = -1;
      let last = 0;
      for (const p of [...presence, total]) {
        if (p - last > best) {
          best = p - last;
          at = last;
        }
        last = p;
      }
      return Math.round(at);
    })(),
  };
}

// ---------------------------------------------------------------------------------------------------------------
// The teleport test: a straight-line sprinter, a hider
// ---------------------------------------------------------------------------------------------------------------

function teleportTrial(level, seed, difficulty, response) {
  const s = session(level, difficulty);
  s.plan = floorPlan(level, seed);
  const random = seededRandom(seed, `TeleportTrial|${level}`);
  const nav = playerNav(level);
  // a long way through the floor from a seeded point
  const samples = nav.samplePoints(5);
  const from = samples[Math.floor(random.nextNumber() * samples.length)].position;
  let goal = null;
  for (let i = 0; i < 40 && !goal; i++) {
    const p = samples[Math.floor(random.nextNumber() * samples.length)].position;
    const w = nav.pathLength(from, p);
    if (Number.isFinite(w) && w > 160) goal = p;
  }
  const bot = addBot(s, 'objective', from, goal ? [{ at: goal, station: false }] : s.plan.targets);
  bot.kind = 'trial';
  syncLocal(s);
  s.creature.beginRun({ difficulty });
  s.creature.activateLevel(level);
  const svc = s.svc;
  // the Creature far off, then a teleport asked for as soon as the rules let it
  const ticks = Math.round(120 / TICK);
  let warned = null;
  let caught = null;
  let chased = false;
  let hidAt = null;
  let over = false; // the teleport's encounter is over once it patrols again after its warp
  for (let i = 0; i < ticks; i++) {
    const t = s.engine.loop.time;
    if (!warned && t > 20 && svc.state === 'Patrol' && svc.awake) {
      svc.teleportReadyAt = Math.min(svc.teleportReadyAt, t);
      svc.lastSeenAny = Math.min(svc.lastSeenAny, t - CreatureConfig.Teleport.UnseenSeconds - 1);
      svc.nextTeleportTry = 0;
    }
    // the teleport asked for (a director's approach on the way is not it)
    const w = bot.warnings.find((x) => x.mine && !x.approach);
    if (w && !warned) {
      warned = { at: w.at, spot: w.spot.clone(), downs: bot.downs };
      if (response === 'hide') {
        if (!goHide(s, bot, w.spot)) bot.mode = 'travel';
      } else bot.sprintAlways = true;
    }
    bot.warnings = [];
    stepBot(s, bot, TICK, i % 3 === 0);
    if (response === 'hide' && bot.mode === 'hidden' && hidAt === null) hidAt = t;
    if (bot.mode === 'hidden' && t - bot.hiddenAt > 20 && playerNav(level).pathLength(feet(bot.root), creatureFeet(svc)) > 45) leaveHide(s, bot);
    syncLocal(s);
    s.engine.loop.step();
    if (warned) {
      if (!over && chasedBy(s, bot)) chased = true;
      if (!over && bot.downs > warned.downs && caught === null) caught = s.engine.loop.time - warned.at;
      if (!svc.warp && svc.state === 'Patrol') over = true;
      if (over || s.engine.loop.time - warned.at > TRIAL_WATCH) break;
    }
  }
  return {
    level, seed, difficulty, response, warned: !!warned, chased, caught: caught !== null, caughtAfter: caught,
    hidWithin: hidAt !== null && warned ? +(hidAt - warned.at).toFixed(1) : null,
  };
}

// ---------------------------------------------------------------------------------------------------------------
// The report
// ---------------------------------------------------------------------------------------------------------------

const results = [];
let failed = false;
function check(ok, name, detail = '') {
  results.push({ ok, name, detail });
  if (!ok && !REPORT_ONLY) failed = true;
  console.log(`${REPORT_ONLY ? (ok ? 'meets' : 'misses') : ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  ${detail}` : ''}`);
}

const rows = [];
const seeds = Array.from({ length: SEEDS }, (_, i) => SEED_BASE + i * 977);
const t0 = Date.now();
for (const key of FLOOR_KEYS) {
  const level = FLOORS[key];
  for (const difficulty of DIFFICULTIES) {
    for (const players of PLAYER_COUNTS) {
      for (const bot of BOTS) {
        for (const seed of seeds) rows.push(runFloor(level, seed, difficulty, players, bot));
      }
    }
  }
}
// more seeds for the objective bot's downs where a target asserts them (the group's key -> its extra rows)
const downsRows = new Map();
for (const key of FLOOR_KEYS) {
  const level = FLOORS[key];
  if (!ASSERTED_FLOORS.has(level) || !BOTS.includes('objective')) continue;
  for (const difficulty of DIFFICULTIES) {
    for (const players of PLAYER_COUNTS) {
      const extra = [];
      for (let i = SEEDS; i < DOWNS_SEEDS; i++) extra.push(runFloor(level, SEED_BASE + i * 977, difficulty, players, 'objective'));
      downsRows.set(`${level}|${difficulty}|${players}`, extra);
    }
  }
}
console.log(`[presence] ${rows.length} floors of ${MINUTES} min (and ${[...downsRows.values()].flat().length} more for the ` +
  `objective bot's downs) in ${((Date.now() - t0) / 1000).toFixed(0)} s`);

const groups = new Map();
for (const r of rows) {
  const k = `${r.level}|${r.difficulty}|${r.players}`;
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(r);
}
const fmt = (v) => (v === null || v === undefined ? '-' : typeof v === 'number' ? (Number.isInteger(v) ? String(v) : v.toFixed(2)) : String(v));
const mean = (list) => (list.length ? list.reduce((a, b) => a + b, 0) / list.length : 0);
console.log('\nfloor              diff       p bot        first  sight/m  <=45  <=90 <=140  <20  walk  pass chases gapMed gapMax unseen downs  chase ends');
// (unseen: a player's longest stretch without seeing it, the floor's worst; reported, not a target: the careful bot's
// own play (crouched, torch off, hidden when warned or chased) is what keeps it from seeing it)
for (const [k, list] of groups) {
  for (const bot of BOTS) {
    const g = list.filter((r) => r.bot === bot);
    if (!g.length) continue;
    const ends = {};
    for (const r of g) for (const [h, n] of Object.entries(r.chaseEnds)) ends[h] = (ends[h] || 0) + n;
    const [level, difficulty, players] = k.split('|');
    const firsts = g.map((r) => (r.firstPresence === null ? MINUTES * 60 : r.firstPresence));
    console.log(`${level.padEnd(18)} ${difficulty.padEnd(10)} ${players} ${bot.padEnd(10)} ${fmt(median(firsts)).padStart(6)} ` +
      `${fmt(mean(g.map((r) => r.sightingsPerMinute))).padStart(7)} ${fmt(mean(g.map((r) => r.share45))).padStart(5)} ` +
      `${fmt(mean(g.map((r) => r.share90))).padStart(5)} ${fmt(mean(g.map((r) => r.share140))).padStart(5)} ` +
      `${fmt(mean(g.map((r) => r.near20))).padStart(5)} ${fmt(median(g.map((r) => r.medianWalk))).padStart(5)} ` +
      `${fmt(mean(g.map((r) => r.passBys))).padStart(5)} ${fmt(mean(g.map((r) => r.chases))).padStart(6)} ` +
      `${fmt(median(g.map((r) => r.gapMedian))).padStart(6)} ${fmt(Math.max(...g.map((r) => r.gapMax))).padStart(6)} ` +
      `${fmt(Math.max(...g.map((r) => r.sightGapMax))).padStart(6)} ` +
      `${fmt(mean(g.map((r) => r.downs))).padStart(5)}  ${JSON.stringify(ends)}`);
  }
}

console.log('\nwhere its time goes (share of the floor after the start hold)');
for (const [k, list] of groups) {
  const states = {};
  const phases = {};
  for (const r of list) {
    for (const [n, v] of Object.entries(r.stateShare)) states[n] = (states[n] || 0) + v / list.length;
    for (const [n, v] of Object.entries(r.phaseShare)) phases[n] = (phases[n] || 0) + v / list.length;
  }
  const show = (o) => Object.entries(o).sort((a, b) => b[1] - a[1]).map(([n, v]) => `${n} ${(v * 100).toFixed(0)}%`).join(', ');
  console.log(`${k.padEnd(30)} ${show(states)} | ${show(phases)} | heard ${mean(list.map((r) => r.heardPerMinute)).toFixed(1)} ticks/min, ` +
    `teleports ${mean(list.map((r) => r.teleports)).toFixed(1)}`);
}
const fastest = rows.reduce((a, r) => (r.maxSpeed > a.maxSpeed ? r : a), rows[0]);
console.log(`fastest: ${fastest.maxSpeed} ${JSON.stringify(fastest.fastest)} (${fastest.level} ${fastest.difficulty} seed ${fastest.seed} ${fastest.bot} ${fastest.players})`);

// the teleport test
const trials = [];
for (const key of FLOOR_KEYS) {
  for (const difficulty of DIFFICULTIES) {
    for (const response of ['sprint', 'hide']) {
      for (const seed of seeds) trials.push(teleportTrial(FLOORS[key], seed, difficulty, response));
    }
  }
}
console.log('\nteleport test       diff       response  warned chased caught  hid<=8s');
for (const key of FLOOR_KEYS) {
  for (const difficulty of DIFFICULTIES) {
    for (const response of ['sprint', 'hide']) {
      const g = trials.filter((x) => x.level === FLOORS[key] && x.difficulty === difficulty && x.response === response);
      const warned = g.filter((x) => x.warned);
      console.log(`${FLOORS[key].padEnd(19)} ${difficulty.padEnd(10)} ${response.padEnd(9)} ${String(warned.length).padStart(6)} ` +
        `${String(warned.filter((x) => x.chased).length).padStart(6)} ${String(warned.filter((x) => x.caught).length).padStart(6)} ` +
        `${String(warned.filter((x) => x.hidWithin !== null && x.hidWithin <= TRIAL_HIDE_WITHIN).length).padStart(8)}`);
    }
  }
}
console.log('');

// the targets
for (const [k, list] of groups) {
  const [level, difficulty, players] = k.split('|');
  const target = TARGETS[`${difficulty}/${players}`];
  if (!target || !ASSERTED_FLOORS.has(level)) continue;
  const tag = `${level} ${difficulty} ${players === '1' ? 'solo' : `${players} players`}`;
  const firsts = list.map((r) => (r.firstPresence === null ? Infinity : r.firstPresence));
  check(firsts.every((f) => f <= target.first), `${tag}: a sighting, a pass-by or a chase within ${target.first} s of the start`,
    `latest ${fmt(Math.max(...firsts))} s`);
  check(median(list.map((r) => r.gapMedian)) <= target.gapMedian && list.every((r) => r.gapMax <= target.gapMax),
    `${tag}: a presence event every ${target.gapMedian} s on median, never a gap over ${target.gapMax} s`,
    `median ${fmt(median(list.map((r) => r.gapMedian)))} s, longest ${fmt(Math.max(...list.map((r) => r.gapMax)))} s`);
  check(mean(list.map((r) => r.share90)) >= target.within90, `${tag}: within 90 studs walked of the nearest player at least ${Math.round(target.within90 * 100)} % of the time`,
    `${(mean(list.map((r) => r.share90)) * 100).toFixed(0)} %`);
  check(mean(list.map((r) => r.near20)) <= target.near20, `${tag}: within 20 studs walked with no chase or beat under ${target.near20 * 100} % of the time`,
    `${(mean(list.map((r) => r.near20)) * 100).toFixed(1)} %`);
  const chases = mean(list.map((r) => r.chases));
  check(chases >= target.chases[0] && chases <= target.chases[1], `${tag}: ${target.chases[0]} to ${target.chases[1]} chases per ${MINUTES}-minute floor`,
    `${chases.toFixed(1)}`);
  const careful = list.filter((r) => r.bot === 'careful');
  // the objective bot's downs: on DOWNS_SEEDS seeds (the floor's own SEEDS and more), each player of a floor counted
  const objective = [...list, ...(downsRows.get(k) || [])].filter((r) => r.bot === 'objective');
  const each = objective.flatMap((r) => r.downsEach);
  const od = mean(each);
  check(od >= target.objectiveDowns[0] && od <= target.objectiveDowns[1],
    `${tag}: the objective bot's downs a floor (${target.objectiveDowns[0]}..${target.objectiveDowns[1]} per player, ${objective.length} seeds)`,
    `${od.toFixed(2)}`);
  if (target.twoDowns !== undefined) {
    const two = each.filter((d) => d >= 2).length / Math.max(1, each.length);
    check(two <= target.twoDowns, `${tag}: the objective bot spends its get-up and its respawn (2 or more downs) on at most ` +
      `${target.twoDowns * 100} % of floors (per player, ${objective.length} seeds)`, `${(two * 100).toFixed(0)} %`);
  }
  const cd = careful.filter((r) => r.downFloor).length / Math.max(1, careful.length);
  check(cd < target.carefulDownFloors, `${tag}: the careful bot goes down on fewer than ${target.carefulDownFloors * 100} % of floors`,
    `${(cd * 100).toFixed(0)} %`);
}
for (const difficulty of DIFFICULTIES) {
  const g = trials.filter((x) => x.difficulty === difficulty && x.warned && ASSERTED_FLOORS.has(x.level));
  const sprint = g.filter((x) => x.response === 'sprint');
  const hide = g.filter((x) => x.response === 'hide');
  check(sprint.length > 0 && sprint.some((x) => x.caught), `${difficulty}: a straight-line sprinter no longer always escapes a teleport`,
    `${sprint.filter((x) => x.caught).length} of ${sprint.length} caught`);
  const hidden = hide.filter((x) => x.hidWithin !== null && x.hidWithin <= TRIAL_HIDE_WITHIN);
  check(hidden.length > 0 && hidden.every((x) => !x.caught), `${difficulty}: breaking the line and hiding within ${TRIAL_HIDE_WITHIN} s always escapes`,
    `${hidden.filter((x) => x.caught).length} of ${hidden.length} caught`);
}
check(rows.every((r) => r.maxSpeed < SPRINT), 'never faster than a sprinting player (19) outside Scripted',
  `max ${Math.max(...rows.map((r) => r.maxSpeed)).toFixed(2)}`);

if (jsonOut) fs.writeFileSync(jsonOut, JSON.stringify({ rows, trials, results }, null, 2));
console.log(failed ? '[presence] FAILED' : REPORT_ONLY ? '[presence] report done' : '[presence] all targets met');
process.exit(failed ? 1 : 0);
