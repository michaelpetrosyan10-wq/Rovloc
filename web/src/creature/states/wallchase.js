// WallChase (the Chase, Tunnels §2.3): the Creature saw someone (or was stared at) and runs them down at 16.5 studs/s
// (x the difficulty, never past SpeedCap: a sprinting player, 19, gains on it; a walking one loses ground), re-routing
// every Repath.ChaseInterval (and walking straight at them when the way is clear and close).
//
//   * Goal: the target while in sight; once not, the last place it saw or heard them, and then, when it saw them
//     running, on along the way they ran (the pursuit, docs/MONSTER.md 18: ctx.pursuitPoint, Presence.Chase.Pursuit
//     studs on from the last seen point along their travel, on its floor) before it gives the search a try.
//   * The wind-up (docs/MONSTER.md 18.1): entered from anything but a watched hiding spot, it holds Chase.Windup
//     seconds facing them (the screech) before it runs, Chase.SurpriseWindup when they stand within
//     Chase.SurpriseRange (met round a corner). It screeches, it does not reach: no catch until the wind-up is over
//     (a player who bolts past it then is still in its path, a few steps ahead), then one is tried every tick.
//   * Catches: anyone in sight within the catch reach (4 studs, the same floor, a clear line eye to eye and chest to
//     chest: never through a wall; the brain's catch rules) is caught as a Hallway jumpscare; the target first.
//   * Ends (the brain): after ChaseLost seconds without a sight of its quarry (the clock waits while it runs to the
//     last place it saw them and on along their way: running()), or on reaching the end of its pursuit with nobody in
//     sight, it searches there (Search); MaxChase seconds in, it gives up and fades out (Patrol).
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
    run = { retryAt: 0, toMemory: false, windupUntil: 0 };
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

/**
 * Whether it is running to the last place it saw or heard its quarry, or on along their way (the pursuit): the chase's
 * loss clock waits meanwhile.
 */
export function running(ctx) {
  const run = runs.get(ctx);
  return !!run && run.toMemory;
}

function inSight(ctx, player) {
  return ctx.sightings.some((s) => s.player === player);
}

/** @param {import('../service.js').Context} ctx @param {string} previous */
export function enter(ctx, previous) {
  const run = runOf(ctx);
  run.retryAt = 0;
  run.toMemory = false;
  run.windupUntil = 0;
  const speed = ctx.speedOf(Name);
  ctx.mover.setSpeed(speed);
  ctx.body.setWalkSpeed(speed);
  ctx.mover.setRepathInterval(CreatureConfig.Repath.ChaseInterval);
  ctx.body.setPose('Biped');
  ctx.body.face(null);
  // the wind-up: out of anything but a watched hiding spot it screeches facing them a beat before it runs
  if (previous !== 'HidingResponse') {
    const root = ctx.target ? ctx.rootOf(ctx.target) : null;
    const face = root ? root.clone().sub(ctx.body.getPosition()).setY(0) : null;
    const C = ctx.presence.Chase;
    const close = !!face && face.length() <= C.SurpriseRange;
    const windup = close ? C.SurpriseWindup : C.Windup;
    run.windupUntil = ctx.now() + windup;
    ctx.mover.hold(windup, face && face.lengthSq() > 1e-6 ? face.normalize() : null);
  }
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runOf(ctx);
  const seen = ctx.sightings.map((s) => s.player);
  if (ctx.now() >= run.windupUntil) {
    for (const player of catchOrder(seen, ctx.target)) {
      const kind = ctx.catchKind(player);
      if (kind && ctx.tryCatch(player, kind)) return;
    }
  }
  const target = ctx.target;
  const memory = ctx.memory;
  const visible = target !== null && inSight(ctx, target);
  let goal = null;
  if (visible && target) goal = ctx.rootOf(target);
  else if (memory) goal = memory.position;
  run.toMemory = !visible && !!memory && horizontalDistance(ctx.body.getPosition(), memory.position) > MEMORY_REACHED;
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
    // the last place it saw them: on the way they were running, once
    const on = memory && memory.travel && !memory.pursued ? ctx.pursuitPoint(memory) : null;
    if (!on) {
      ctx.stateDone = true;
      return;
    }
    ctx.memory = { ...memory, position: on, pursued: true };
    run.retryAt = now + RETRY_SECONDS;
    mover.goTo(on, { arrive: 2 });
    return;
  }
  if (mover.busy()) return;
  run.retryAt = now + RETRY_SECONDS;
  mover.goTo(goal, { arrive: visible ? 1 : 2 });
}

export function exit() {}
