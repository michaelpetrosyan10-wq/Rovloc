// WallChase (States/WallChase.luau): the Creature has seen someone and runs them down on two legs at WallChase
// speed x the difficulty's multiplier, re-routing every Repath.ChaseInterval (and walking straight at them when the
// way is clear and close).
//
//   * Goal: the target while in sight; once not, the last place it saw or heard them (memory, MemorySeconds long).
//     Reaching that spot with nobody in sight ends the chase (the brain searches the area).
//   * Catches: anyone in sight within CatchDistance (same floor, clear line, the brain's catch rules) is caught as a
//     Hallway jumpscare; the target first.
//   * An unreachable target (no route) is retried a moment later while still in sight; an unreachable memory ends it.

import { CreatureConfig } from '../config.js';
import { horizontalDistance } from '../util.js';

export const Name = 'WallChase';
const RETRY_SECONDS = 1;
const MEMORY_REACHED = 4;

const runs = new WeakMap();

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { retryAt: 0 };
    runs.set(ctx, run);
  }
  return run;
}

/** The players in sight, the target first (the order catches are tried in). */
export function catchOrder(sightings, target) {
  const order = [];
  if (target && sightings.includes(target)) order.push(target);
  for (const p of sightings) if (p !== target) order.push(p);
  return order;
}

function inSight(ctx, player) {
  return ctx.sightings.some((s) => s.player === player);
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  runOf(ctx).retryAt = 0;
  const speed = ctx.speedOf(Name);
  ctx.mover.setSpeed(speed);
  ctx.body.setWalkSpeed(speed);
  ctx.mover.setRepathInterval(CreatureConfig.Repath.ChaseInterval);
  ctx.body.setPose('Biped');
  ctx.body.face(null);
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runOf(ctx);
  const seen = ctx.sightings.map((s) => s.player);
  for (const player of catchOrder(seen, ctx.target)) {
    const kind = ctx.catchKind(player);
    if (kind && ctx.tryCatch(player, kind)) return;
  }
  const target = ctx.target;
  const memory = ctx.memory;
  const visible = target !== null && inSight(ctx, target);
  let goal = null;
  if (visible && target) goal = ctx.rootOf(target);
  else if (memory) goal = memory.position;
  if (!goal) {
    ctx.stateDone = true;
    return;
  }
  const mover = ctx.mover;
  const status = mover.getStatus();
  const now = ctx.now();
  if (status === 'Failed' || status === 'Stuck') {
    if (!visible) {
      ctx.stateDone = true;
      return;
    }
    if (now < run.retryAt) return;
  }
  if (!visible && status !== 'Moving' && horizontalDistance(ctx.body.getPosition(), goal) <= MEMORY_REACHED) {
    ctx.stateDone = true;
    return;
  }
  if (mover.busy()) return;
  run.retryAt = now + RETRY_SECONDS;
  mover.goTo(goal, { arrive: visible ? 1 : 2 });
}

export function exit() {}
