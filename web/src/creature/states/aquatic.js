// AquaticStalk (States/AquaticStalk.luau): the pool level (Level 4). Someone is swimming, so the Creature slips under
// the murky surface (a kinematic glide, PoseMode Swim, SwimDepth down) and stalks: toward the swimmer while it can see
// them (underwater players are only seen by a swimming Creature), else toward the latest splash it heard, else where
// it last sensed them. It stalks at the AquaticStalk pace (6.5): a freestyle swimmer (9) outswims it, one treading
// water (4) does not.
//
// The grab belongs to the pool system (W4) through the pool grabber hook. Once a swimmer's splashing has crossed the
// grab threshold (the splash meter, remembered for a while) and they are within LungeRange, the Creature TELEGRAPHS:
// it holds still for Water.TelegraphSeconds while the lunge origin gives it away (ctx.telegraph: rising bubbles, a
// ripple ring on the surface and a low growl there), so the swimmer can climb out or swim off. Only then does it close
// in fast (AquaticLunge) from below, for at most Water.LungeWindow, and within GrabReach call the hook; a grab that
// starts holds it there until the pool system lets go. A lunge that misses (the swimmer out of reach or out of the
// water) waits Water.LungeCooldown before the next telegraph. Without a hook registered it circles under them and
// never grabs. While the service has it retreating after a grab (ctx.poolRetreat), it swims to the far end of the
// water and never lunges.

import * as THREE from 'three';
import { CreatureConfig, difficultySpec } from '../config.js';
import { SWIM_DEPTH } from '../water.js';

export const Name = 'AquaticStalk';
export const LungeRange = CreatureConfig.Water.LungeRange;
export const GrabReach = 4.5;
export const TelegraphSeconds = CreatureConfig.Water.TelegraphSeconds;
const LUNGE_WINDOW = CreatureConfig.Water.LungeWindow;
const LUNGE_COOLDOWN = CreatureConfig.Water.LungeCooldown;
const LUNGE_DEPTH = 1.2;
const UNDER = 2;
const CIRCLE_RADIUS = 6;
const CIRCLE_SPEED = 0.6;

const runs = new WeakMap();

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { holding: false, circle: 0, telegraphUntil: null, lungeUntil: null, nextTelegraphAt: 0 };
    runs.set(ctx, run);
  }
  return run;
}

/** Whether the Creature lunges at a swimmer `distance` away. */
export function shouldLunge(distance, armed, grabber) {
  return armed && grabber && distance <= LungeRange;
}

function inSight(ctx, player) {
  return ctx.sightings.some((s) => s.player === player);
}

function speedFor(ctx, lunging) {
  if (!lunging) return ctx.speedOf(Name);
  return CreatureConfig.Speeds.AquaticLunge * difficultySpec(ctx.difficulty).creatureSpeedMultiplier;
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = runOf(ctx);
  run.holding = false;
  run.telegraphUntil = null;
  run.lungeUntil = null;
  run.circle = ctx.random.nextNumber(0, Math.PI * 2);
  ctx.mover.setSpeed(ctx.speedOf(Name));
  ctx.body.setWalkSpeed(ctx.speedOf(Name));
  ctx.mover.setRepathInterval(CreatureConfig.Repath.ChaseInterval);
  ctx.body.face(null);
}

/** @param {import('../service.js').Context} ctx @param {number} dt */
export function update(ctx, dt) {
  const run = runOf(ctx);
  if (run.holding) return;
  const mover = ctx.mover;
  if (mover.busy()) return;
  const now = ctx.now();
  const here = ctx.body.getPosition();
  // after a grab: off to the far end of the water, no lunges
  const retreat = ctx.poolRetreat ? ctx.poolRetreat() : null;
  if (retreat) {
    run.telegraphUntil = null;
    run.lungeUntil = null;
    mover.setSpeed(speedFor(ctx, false));
    mover.goTo(retreat, { arrive: 2, depth: SWIM_DEPTH });
    return;
  }
  const target = ctx.target;
  const heard = ctx.heard;
  let goal = null;
  const swimmerRoot = target ? ctx.rootOf(target) : null;
  if (target && swimmerRoot && inSight(ctx, target)) goal = swimmerRoot;
  else if (heard && heard.medium === 'Water') goal = heard.position;
  else {
    const memory = ctx.memory;
    goal = memory ? memory.position : swimmerRoot;
  }
  if (!goal) return;
  const grabber = ctx.poolGrabber();
  const swimming = target !== null && swimmerRoot !== null && ctx.swimming(target);
  const distance = swimmerRoot ? swimmerRoot.distanceTo(here) : Infinity;
  const wants = swimming && shouldLunge(distance, ctx.grabArmed(target), grabber !== null);
  // the telegraph: held still at the lunge origin, the cues playing there
  if (run.telegraphUntil !== null) {
    if (!swimming || distance > LungeRange * 1.5 || mover.getMedium() !== 'Water') {
      run.telegraphUntil = null;
      run.nextTelegraphAt = now + LUNGE_COOLDOWN;
    } else if (now < run.telegraphUntil) {
      mover.stop();
      return;
    } else {
      run.telegraphUntil = null;
      run.lungeUntil = now + LUNGE_WINDOW;
    }
  }
  if (run.lungeUntil !== null && (now > run.lungeUntil || !swimming || mover.getMedium() !== 'Water')) {
    run.lungeUntil = null;
    run.nextTelegraphAt = now + LUNGE_COOLDOWN;
  }
  if (run.lungeUntil === null && wants && now >= run.nextTelegraphAt && mover.getMedium() === 'Water') {
    run.telegraphUntil = now + TelegraphSeconds;
    mover.stop();
    if (ctx.telegraph) ctx.telegraph(here.clone(), TelegraphSeconds);
    return;
  }
  if (run.lungeUntil !== null && target && swimmerRoot && grabber) {
    if (distance <= GrabReach && mover.getMedium() === 'Water') {
      let started = false;
      try {
        started = grabber(target) === true;
      } catch (err) {
        console.warn('[creature] pool grabber failed', err);
      }
      if (started) {
        run.holding = true;
        run.lungeUntil = null;
        mover.stop();
        ctx.setGrabbed(target);
        return;
      }
    }
    mover.setSpeed(speedFor(ctx, true));
    mover.goTo(swimmerRoot.clone().sub(new THREE.Vector3(0, UNDER, 0)), { arrive: 1, depth: LUNGE_DEPTH, lunge: true });
    return;
  }
  mover.setSpeed(speedFor(ctx, false));
  let aim = goal.clone().sub(new THREE.Vector3(0, UNDER, 0));
  const basin = mover.basinAt(aim) || mover.basinAt(goal);
  if (basin && aim.distanceTo(here) <= CIRCLE_RADIUS * 1.5) {
    // close under a swimmer it may not take: circle beneath them
    run.circle += CIRCLE_SPEED * dt;
    aim = goal.clone().add(new THREE.Vector3(Math.cos(run.circle) * CIRCLE_RADIUS, -UNDER, Math.sin(run.circle) * CIRCLE_RADIUS));
  }
  mover.goTo(aim, { arrive: 1.5, depth: SWIM_DEPTH });
}

/** Whether a lunge is being telegraphed now (the dev read and the tests). @param {any} ctx */
export function telegraphing(ctx) {
  const run = runs.get(ctx);
  return !!run && run.telegraphUntil !== null;
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  const run = runOf(ctx);
  if (run.holding) {
    run.holding = false;
    ctx.setGrabbed(null);
  }
}

/** The pool system let go: the Creature may move again. @param {import('../service.js').Context} ctx */
export function released(ctx) {
  const run = runOf(ctx);
  run.holding = false;
  run.telegraphUntil = null;
  run.lungeUntil = null;
  run.nextTelegraphAt = ctx.now() + LUNGE_COOLDOWN;
}
