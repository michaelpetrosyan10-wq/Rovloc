// Patrol (States/Patrol.luau): the Creature walks its level's patrol loops at Patrol speed.
//
//   * It joins a loop at the waypoint nearest it, walks it in order (the last waypoint leads back to the first) for
//     one lap, then picks the next loop.
//   * At a corner (the route turns by CornerDegrees or more) it stops: first it looks into the room's far corner, then
//     along the way it is about to go, a beat each.
//   * Choosing the next loop: the rooms it heard noises in lately pull it: with the pacing's sweep chance (BuildUp
//     0.6, Peak 0.45, Relax never) it takes the loop through the most and loudest of them; in Relax it takes the loop
//     farthest from the latest one instead; otherwise one of the three loops nearest it.
//   * Withdrawing: entered with ctx.reposition (after a catch, a stun, a chase that ran too long) it first walks, at
//     InvestigateNoise speed, to a waypoint out of every player's sight 35..140 studs from them, then patrols.
// Inside a duct the first walk crawls out through the best open grate (Locomotion plans the way out).

import * as THREE from 'three';
import { CreatureConfig } from '../config.js';
import { clamp, flat } from '../util.js';

export const Name = 'Patrol';
export const CornerDegrees = 50;
const LOOK_SECONDS = { min: 0.6, max: 1.1 };
export const HeardTtl = 60; // the noises heard in the last minute pull the next loop (was 90 s)
const ARRIVE = 2;
const MAX_FAILURES = 3;
const WITHDRAW_MIN = 35;
const WITHDRAW_MAX = 140;
export const SweepChance = Object.freeze({ BuildUp: 0.75, Peak: 0.6, Relax: 0 }); // harder Standard: was 0.6 / 0.45

/** @type {WeakMap<object, any>} */
const runs = new WeakMap();

/** The waypoint after `index` (0-based; the last leads back to the first). */
export function nextIndex(loop, index) {
  const count = loop.waypoints.length;
  if (count === 0) return 0;
  return (index + 1) % count;
}

/** The waypoint of `loop` nearest `position`. */
export function nearestIndex(loop, position) {
  let best = 0;
  let bestDistance = Infinity;
  loop.waypoints.forEach((w, i) => {
    const d = w.position.distanceTo(position);
    if (d < bestDistance) {
      best = i;
      bestDistance = d;
    }
  });
  return best;
}

/** Degrees the route turns at `here` (0 = straight on). */
export function turnDegrees(previous, here, next) {
  const incoming = flat(here.clone().sub(previous));
  const outgoing = flat(next.clone().sub(here));
  if (incoming.length() < 1e-4 || outgoing.length() < 1e-4) return 0;
  return (Math.acos(clamp(incoming.normalize().dot(outgoing.normalize()), -1, 1)) * 180) / Math.PI;
}

/** Where to look at a corner: into the farthest corner of the room not behind it, then the way on. */
export function cornerLooks(room, here, incoming, outgoing) {
  const looks = [];
  const forward = flat(incoming);
  if (room) {
    let best = null;
    let bestDistance = -1;
    for (const corner of [
      new THREE.Vector3(room.minX, here.y, room.minZ),
      new THREE.Vector3(room.minX, here.y, room.maxZ),
      new THREE.Vector3(room.maxX, here.y, room.minZ),
      new THREE.Vector3(room.maxX, here.y, room.maxZ),
    ]) {
      const offset = flat(corner.clone().sub(here));
      const len = offset.length();
      if (len < 1e-3) continue;
      if (forward.length() > 1e-3 && offset.clone().normalize().dot(forward.clone().normalize()) < -0.2) continue;
      if (len > bestDistance) {
        best = offset.clone().normalize();
        bestDistance = len;
      }
    }
    if (best) looks.push(best);
  }
  const onward = flat(outgoing);
  if (onward.length() > 1e-3) looks.push(onward.normalize());
  return looks;
}

/** How strongly the noises heard lately pull toward `loop`. */
export function heardPull(loop, heardZones, now) {
  let pull = 0;
  for (const [zoneId, heard] of Object.entries(heardZones)) {
    const age = now - heard.at;
    if (loop.zones.has(zoneId) && age >= 0 && age < HeardTtl) pull += heard.rank * (1 - age / HeardTtl);
  }
  return pull;
}

function distanceTo(loop, position) {
  let best = Infinity;
  for (const w of loop.waypoints) best = Math.min(best, w.position.distanceTo(position));
  return best;
}

/**
 * The next loop to walk (null when the level has none).
 * @param {import('../brain.js').Loop[]} loops
 * @param {THREE.Vector3} from
 * @param {{current: string|null, heardZones: Record<string, any>, now: number, sweepChance: number, avoid: boolean,
 *   roll: () => number}} options
 */
export function chooseLoop(loops, from, options) {
  const candidates = loops.filter((l) => l.waypoints.length > 0 && (l.id !== options.current || loops.length === 1));
  if (candidates.length === 0) return null;
  candidates.sort((a, b) => {
    const da = distanceTo(a, from);
    const db = distanceTo(b, from);
    if (da !== db) return da - db;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  let latest = null;
  for (const heard of Object.values(options.heardZones)) {
    const age = options.now - heard.at;
    if (age >= 0 && age < HeardTtl && (latest === null || heard.at > latest.at)) latest = heard;
  }
  if (options.avoid) {
    if (latest) {
      let best = candidates[0];
      let bestDistance = -1;
      for (const loop of candidates) {
        const d = loop.centre.distanceTo(latest.position);
        if (d > bestDistance) {
          best = loop;
          bestDistance = d;
        }
      }
      return best;
    }
    return candidates[0];
  }
  if (latest && options.roll() < options.sweepChance) {
    let best = null;
    let bestPull = 0;
    for (const loop of candidates) {
      const pull = heardPull(loop, options.heardZones, options.now);
      if (pull > bestPull) {
        best = loop;
        bestPull = pull;
      }
    }
    if (best) return best;
  }
  const pick = Math.min(candidates.length, 1 + Math.floor(options.roll() * Math.min(3, candidates.length)));
  return candidates[pick - 1];
}

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { loop: null, index: 0, walked: 0, looks: [], arrived: false, withdrawTo: null, failures: 0, lastLoop: null };
    runs.set(ctx, run);
  }
  return run;
}

function pickLoop(ctx, run) {
  const level = ctx.level;
  if (!level) {
    run.loop = null;
    return;
  }
  const position = ctx.body.getPosition();
  const loop = chooseLoop(level.loops, position, {
    current: run.lastLoop,
    heardZones: ctx.heardZones,
    now: ctx.now(),
    sweepChance: SweepChance[ctx.phase] || 0,
    avoid: ctx.phase === 'Relax',
    roll: () => ctx.random.nextNumber(),
  });
  run.loop = loop;
  run.walked = 0;
  run.failures = 0;
  run.looks = [];
  run.arrived = false;
  if (loop) {
    run.lastLoop = loop.id;
    run.index = nearestIndex(loop, position);
    ctx.mover.goTo(loop.waypoints[run.index].position, { arrive: ARRIVE });
  }
}

function setSpeed(ctx, state) {
  ctx.mover.setSpeed(ctx.speedOf(state));
  ctx.body.setWalkSpeed(ctx.speedOf(state));
}

function arrive(ctx, run, loop) {
  const count = loop.waypoints.length;
  const here = loop.waypoints[run.index];
  const previous = loop.waypoints[(run.index - 1 + count) % count];
  const following = loop.waypoints[nextIndex(loop, run.index)];
  run.arrived = true;
  run.walked += 1;
  if (count >= 3 && turnDegrees(previous.position, here.position, following.position) >= CornerDegrees) {
    const room = ctx.level ? ctx.level.rooms[here.zoneId] || null : null;
    run.looks = cornerLooks(room, here.position, here.position.clone().sub(previous.position),
      following.position.clone().sub(here.position));
  }
}

function walkOn(ctx, run, loop) {
  run.arrived = false;
  if (run.walked >= loop.waypoints.length) {
    pickLoop(ctx, run);
    return;
  }
  run.index = nextIndex(loop, run.index);
  ctx.mover.goTo(loop.waypoints[run.index].position, { arrive: ARRIVE });
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = runOf(ctx);
  run.loop = null;
  run.looks = [];
  run.withdrawTo = null;
  ctx.mover.setRepathInterval(CreatureConfig.Repath.PatrolInterval);
  ctx.body.setPose('Biped');
  if (ctx.reposition) {
    ctx.reposition = false;
    const point = ctx.repositionPoint(WITHDRAW_MIN, WITHDRAW_MAX);
    if (point) {
      run.withdrawTo = point;
      setSpeed(ctx, 'InvestigateNoise');
      ctx.mover.goTo(point, { arrive: ARRIVE });
      return;
    }
  }
  setSpeed(ctx, Name);
  pickLoop(ctx, run);
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runOf(ctx);
  const mover = ctx.mover;
  if (mover.busy()) return;
  const status = mover.getStatus();
  if (run.withdrawTo) {
    if (status === 'Moving') return;
    run.withdrawTo = null;
    setSpeed(ctx, Name);
    pickLoop(ctx, run);
    return;
  }
  const loop = run.loop;
  if (!loop) {
    pickLoop(ctx, run);
    return;
  }
  if (status === 'Moving') return;
  if (status === 'Failed' || status === 'Stuck') {
    run.failures += 1;
    if (run.failures >= MAX_FAILURES) pickLoop(ctx, run);
    else {
      run.walked += 1;
      walkOn(ctx, run, loop);
    }
    return;
  }
  if (!run.arrived) arrive(ctx, run, loop);
  const look = run.looks.shift();
  if (look) {
    mover.hold(ctx.random.nextNumber(LOOK_SECONDS.min, LOOK_SECONDS.max), look);
    return;
  }
  walkOn(ctx, run, loop);
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  const run = runOf(ctx);
  run.withdrawTo = null;
  run.looks = [];
  ctx.body.face(null);
}
