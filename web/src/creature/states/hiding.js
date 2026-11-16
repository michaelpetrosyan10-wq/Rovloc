// HidingResponse (Tunnels §2.3: THRESHOLD's barrel rule with a fair outplay). The Creature saw someone climb into a
// hiding spot (a locker, a barrel, a cabinet): it comes and stands facing the spot, StandOff studs out from its front.
//
//   * Every LookAwayMin..LookAwayMax seconds it does a LookAway: a low grunt GruntLead seconds before (the tell), then
//     for LookAwaySeconds its head turns down the tunnel (the open side) and it neither sees toward the spot nor feels
//     anything close (the service's perception uses the look-away facing, no peripheral sense). Slipping out then and
//     breaking the line of sight escapes.
//   * ReachInSeconds after they got in it reaches in: the ReachIn action, then a Locker catch. Every watch has one
//     LookAway before it: after a long walk to the spot the first comes as late as still fits (or the reach waits).
//   * Stepping out while it is not looking away, within CatchRange, is a catch (Hallway).
//   * A teammate pulling them out (the THRESHOLD throw, hidespots.js) is no catch: the pull startles it for a moment
//     (the service) and the brain moves on (WallChase on whoever it sees, else Search).
//   * Done when the hider is out (or taken, or gone); the brain decides what follows.

import * as THREE from 'three';
import { CreatureConfig, difficultySpec } from '../config.js';
import { horizontalDistance } from '../util.js';

export const Name = 'HidingResponse';
const H = CreatureConfig.Hiding;
const ARRIVE = 1;
const APPROACH_SPEED = CreatureConfig.Speeds.InvestigateNoise;

const runs = new WeakMap();

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { watch: null, phase: 'Approach', stand: null, nextLookAt: Infinity, lookAwayUntil: null, gruntAt: Infinity,
      grunted: false, reachAt: Infinity, reached: false };
    runs.set(ctx, run);
  }
  return run;
}

/** Where it stands: StandOff out from the spot's front (its exit anchor, facing out of the spot). */
export function standPoint(front) {
  const out = new THREE.Vector3(front.lookVector.x, 0, front.lookVector.z);
  if (out.lengthSq() < 1e-6) out.set(0, 0, -1);
  out.normalize();
  return front.position.clone().addScaledVector(out, H.StandOff - 1);
}

function scheduleLook(ctx, run, now) {
  run.nextLookAt = now + ctx.random.nextNumber(H.LookAwayMin, H.LookAwayMax);
  run.gruntAt = run.nextLookAt - H.GruntLead;
  run.grunted = false;
}

/** The latest a LookAway may start: it ends ReachInLead before the reach. */
function latestLook(run) {
  return run.reachAt - H.ReachInLead - H.LookAwaySeconds;
}

/** Whether it is looking away right now. @param {any} ctx */
export function lookingAway(ctx) {
  const run = runs.get(ctx);
  return !!run && run.lookAwayUntil !== null;
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = runOf(ctx);
  const watch = ctx.hiding;
  run.watch = watch;
  run.phase = 'Approach';
  run.lookAwayUntil = null;
  run.nextLookAt = Infinity;
  run.gruntAt = Infinity;
  run.reached = false;
  ctx.setLookAway(null);
  if (!watch) {
    ctx.stateDone = true;
    return;
  }
  run.reachAt = watch.since + difficultySpec(ctx.difficulty).reachInSeconds;
  run.stand = standPoint(watch.front);
  const speed = Math.min(ctx.speedOf('WallChase'), APPROACH_SPEED);
  ctx.mover.setSpeed(speed);
  ctx.body.setWalkSpeed(speed);
  ctx.mover.setRepathInterval(CreatureConfig.Repath.ChaseInterval);
  ctx.body.setPose('Biped');
  ctx.body.face(null);
  ctx.mover.goTo(run.stand, { arrive: ARRIVE });
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runOf(ctx);
  const watch = run.watch;
  if (!watch) {
    ctx.stateDone = true;
    return;
  }
  const hider = watch.player;
  const now = ctx.now();
  if (!ctx.playing(hider)) {
    ctx.stateDone = true;
    return;
  }
  if (!ctx.isHiding(hider)) {
    // out of the spot: slipped out while it looked away (it notices nothing until the LookAway is over: whoever has
    // broken the line by then is gone), pulled by a teammate (no catch), or stepped out under its nose (a catch)
    if (run.lookAwayUntil !== null && now < run.lookAwayUntil) return;
    if (!ctx.pulledOut(hider) && run.lookAwayUntil === null) {
      const root = ctx.rootOf(hider);
      const here = ctx.body.getPosition();
      if (root && horizontalDistance(root, here) <= H.CatchRange && Math.abs(root.y - here.y) <= CreatureConfig.Senses.CatchVertical &&
        ctx.bodyClear(hider)) {
        ctx.tryCatch(hider, 'Hallway');
      }
    }
    ctx.setLookAway(null);
    ctx.stateDone = true;
    return;
  }
  if (ctx.hideSpotOf(hider) !== watch.spot) {
    ctx.stateDone = true;
    return;
  }
  const mover = ctx.mover;
  if (run.phase === 'Approach') {
    const status = mover.getStatus();
    if (status === 'Failed' || status === 'Stuck') {
      ctx.stateDone = true;
      return;
    }
    if (mover.busy() || status === 'Moving') return;
    run.phase = 'Watch';
    mover.stop();
    mover.face(watch.front.lookVector.clone().negate());
    scheduleLook(ctx, run, now);
    // the fair outplay: one LookAway (after its grunt) before the reach, however late it arrived (a long walk to the
    // spot): the first comes as late as still fits, and the reach waits for it when even that is past
    if (run.nextLookAt > latestLook(run)) {
      run.nextLookAt = Math.max(latestLook(run), now + H.GruntLead);
      run.gruntAt = run.nextLookAt - H.GruntLead;
      run.reachAt = Math.max(run.reachAt, run.nextLookAt + H.LookAwaySeconds + H.ReachInLead);
    }
    return;
  }
  // the reach: ReachInSeconds after they got in
  if (now >= run.reachAt) {
    if (!run.reached) {
      run.reached = true;
      run.lookAwayUntil = null;
      ctx.setLookAway(null);
      mover.face(watch.front.lookVector.clone().negate());
      ctx.reachIn(hider, watch.spot);
    }
    return;
  }
  if (run.lookAwayUntil !== null) {
    if (now < run.lookAwayUntil) return;
    run.lookAwayUntil = null;
    ctx.setLookAway(null);
    mover.face(watch.front.lookVector.clone().negate());
    scheduleLook(ctx, run, now);
    return;
  }
  // a LookAway that would still run when it reaches in is skipped
  if (run.nextLookAt > latestLook(run)) {
    run.nextLookAt = Infinity;
    run.gruntAt = Infinity;
  }
  if (!run.grunted && now >= run.gruntAt) {
    run.grunted = true;
    ctx.grunt();
  }
  if (now >= run.nextLookAt) {
    run.lookAwayUntil = now + H.LookAwaySeconds;
    ctx.setLookAway(ctx.lookAwayDirection(watch.front));
  }
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  const run = runOf(ctx);
  run.watch = null;
  run.lookAwayUntil = null;
  ctx.setLookAway(null);
  ctx.body.face(null);
  ctx.hiding = null;
}
