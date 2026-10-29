// VentChase (States/VentChase.luau): a crawler gave itself away (seen climbing into a duct, heard scurrying or kicking
// in one, spotted through a grate), and the Creature goes in after them.
//
//   Choose    the way in: every grate of the level that is not Locked, costed as the time to walk to its mouth
//             (straight-line estimate x WalkDetour) plus the crawl along the ducts to the target. Open (or kicked)
//             grates win; a Closed one is kicked in only when no open grate leads there. No way in ends the chase.
//   Approach  it rushes to the grate's room side at WallChase speed, kicks it in if it must, and squeezes through into
//             the spider crawl (anchored root on the centreline, PoseMode Quadruped). A grate it cannot reach on foot
//             is set aside and another is chosen.
//   Hunt      A* along the VentGraph to the target's rail point at VentChase speed, re-routed every ChaseInterval as
//             they move; anyone in the ducts within VentCatchDistance is caught (Vent).
//   Exit      when the target leaves the ducts it comes out after them: through the grate they used if open, else the
//             open grate nearest to where they went. Once out, the chase is done.

import { CreatureConfig } from '../config.js';
import { railRoute, KICK_RECOVER } from '../locomotion.js';
import { horizontalDistance } from '../util.js';

export const Name = 'VentChase';
export const KickSeconds = KICK_RECOVER + 0.3;
const WALK_DETOUR = 1.3;
const UNREACHABLE_SECONDS = 20;
const REROUTE_MOVE = 1.5;

const runs = new WeakMap();

function isOpen(state) {
  return state === 'Open' || state === 'Kicked';
}

/**
 * The way into the ducts: [grateId, kick] or [null, false].
 * @param {Array<{grateId: string, state: string, walk: number, crawl: number}>} options
 */
export function chooseEntry(options, walkSpeed, crawlSpeed) {
  const time = (o, kick) => {
    if (o.walk === Infinity || o.crawl === Infinity) return Infinity;
    return o.walk / Math.max(walkSpeed, 1e-3) + o.crawl / Math.max(crawlSpeed, 1e-3) + (kick ? KickSeconds : 0);
  };
  let bestOpen = null;
  let bestOpenTime = Infinity;
  let bestKick = null;
  let bestKickTime = Infinity;
  for (const o of options) {
    if (o.state === 'Locked') continue;
    const open = isOpen(o.state);
    const cost = time(o, !open);
    if (cost === Infinity) continue;
    if (open) {
      if (cost < bestOpenTime || (cost === bestOpenTime && bestOpen !== null && o.grateId < bestOpen)) {
        bestOpen = o.grateId;
        bestOpenTime = cost;
      }
    } else if (cost < bestKickTime || (cost === bestKickTime && bestKick !== null && o.grateId < bestKick)) {
      bestKick = o.grateId;
      bestKickTime = cost;
    }
  }
  if (bestOpen) return [bestOpen, false];
  if (bestKick) return [bestKick, true];
  return [null, false];
}

/** The duct distance from a grate's mouth to the rail point `target` (Infinity when no duct leads there). */
export function crawlDistance(graph, grate, target) {
  const node = graph.nodes[grate.nodeId];
  if (!node) return Infinity;
  const start = { a: grate.nodeId, b: null, t: 0, position: node.position.clone(), distance: 0 };
  const [, cost] = railRoute(graph, start, target);
  if (cost === Infinity) return Infinity;
  return cost + grate.mouth.distanceTo(node.position);
}

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { phase: 'Choose', grateId: null, unreachable: {}, routedAt: -Infinity, routedTo: null };
    runs.set(ctx, run);
  }
  return run;
}

function setCrawling(ctx) {
  ctx.mover.setSpeed(ctx.speedOf(Name));
  ctx.mover.setRepathInterval(CreatureConfig.Repath.ChaseInterval);
}

function setRunning(ctx) {
  const speed = ctx.speedOf('WallChase');
  ctx.mover.setSpeed(speed);
  ctx.body.setWalkSpeed(speed);
  ctx.mover.setRepathInterval(CreatureConfig.Repath.ChaseInterval);
}

function options(ctx, run, target) {
  const graph = ctx.graph;
  const out = [];
  if (!graph) return out;
  const position = ctx.body.getPosition();
  const now = ctx.now();
  for (const id of graph.grateIds) {
    const grate = graph.grates[id];
    const failedAt = run.unreachable[id];
    let walk = Infinity;
    if (failedAt === undefined || now - failedAt >= UNREACHABLE_SECONDS) {
      const stand = ctx.standPoint(grate).position;
      walk = horizontalDistance(position, stand) * WALK_DETOUR + Math.abs(position.y - stand.y) * 2;
    }
    out.push({ grateId: id, state: ctx.grateState(id), walk, crawl: crawlDistance(graph, grate, target) });
  }
  return out;
}

function choose(ctx, run, target) {
  const graph = ctx.graph;
  const rail = ctx.railPointOf(target);
  if (!graph || !rail) {
    ctx.ventBlocked = true;
    ctx.stateDone = true;
    return;
  }
  const [grateId, kick] = chooseEntry(options(ctx, run, rail), ctx.speedOf('WallChase'), ctx.speedOf(Name));
  const grate = grateId ? graph.grates[grateId] : null;
  if (!grateId || !grate) {
    ctx.ventBlocked = true;
    ctx.stateDone = true;
    return;
  }
  run.grateId = grateId;
  run.phase = 'Approach';
  setRunning(ctx);
  ctx.mover.enterVent(grate, kick);
}

function exitAfter(ctx, run, target) {
  const graph = ctx.graph;
  const used = ctx.exitGrateOf(target);
  let grate = null;
  if (graph && used) {
    const candidate = graph.grates[used];
    if (candidate && isOpen(ctx.grateState(used))) grate = candidate;
  }
  run.phase = 'Exit';
  if (!ctx.mover.exitVent(grate, ctx.rootOf(target))) ctx.stateDone = true;
}

function hunt(ctx, run, target) {
  for (const player of ctx.ventOccupants()) {
    const kind = ctx.catchKind(player);
    if (kind === 'Vent' && ctx.tryCatch(player, kind)) return;
  }
  const rail = ctx.railPointOf(target);
  if (!rail) return;
  const now = ctx.now();
  const moved = run.routedTo === null || run.routedTo.distanceTo(rail.position) >= REROUTE_MOVE;
  if (ctx.mover.busy()) return;
  if (moved || now - run.routedAt >= CreatureConfig.Repath.ChaseInterval || ctx.mover.getStatus() !== 'Moving') {
    if (ctx.mover.railTo(rail)) {
      run.routedAt = now;
      run.routedTo = rail.position.clone();
    }
  }
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = runOf(ctx);
  run.grateId = null;
  run.routedAt = -Infinity;
  run.routedTo = null;
  ctx.ventBlocked = false;
  ctx.body.face(null);
  if (ctx.mover.getMedium() === 'Vent') {
    run.phase = 'Hunt';
    setCrawling(ctx);
  } else {
    run.phase = 'Choose';
    setRunning(ctx);
  }
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runOf(ctx);
  const mover = ctx.mover;
  const target = ctx.target;
  const inside = mover.getMedium() === 'Vent';
  if (!target || !ctx.inVent(target)) {
    if (run.phase === 'Exit') {
      if (!inside && !mover.busy()) ctx.stateDone = true;
      return;
    }
    if (inside && target) exitAfter(ctx, run, target);
    else if (inside) {
      run.phase = 'Exit';
      if (!mover.exitVent(null, null)) ctx.stateDone = true;
    } else if (!mover.busy()) ctx.stateDone = true;
    return;
  }
  if (run.phase === 'Choose') {
    if (inside) {
      run.phase = 'Hunt';
      setCrawling(ctx);
    } else choose(ctx, run, target);
    return;
  }
  if (run.phase === 'Approach') {
    const status = mover.getStatus();
    const grateId = run.grateId;
    if (inside && !mover.busy()) {
      run.phase = 'Hunt';
      setCrawling(ctx);
      return;
    }
    if ((status === 'Failed' || status === 'Stuck') && !inside) {
      if (grateId) run.unreachable[grateId] = ctx.now();
      run.phase = 'Choose';
      return;
    }
    if (grateId && !inside && ctx.grateState(grateId) === 'Locked') run.phase = 'Choose';
    return;
  }
  if (run.phase === 'Hunt') {
    if (!inside) {
      run.phase = 'Choose';
      return;
    }
    hunt(ctx, run, target);
  }
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  const run = runOf(ctx);
  run.phase = 'Choose';
  run.grateId = null;
  ctx.body.face(null);
}
