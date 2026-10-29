// AquaticStalk (States/AquaticStalk.luau): the pool level (Level 4). Someone is swimming, so the Creature slips under
// the murky surface (a kinematic glide, PoseMode Swim, SwimDepth down) and stalks: toward the swimmer while it can see
// them (underwater players are only seen by a swimming Creature), else toward the latest splash it heard, else where
// it last sensed them.
//
// The grab belongs to the pool system (W4) through the pool grabber hook. Once a swimmer's splashing has crossed the
// grab threshold (the splash meter, remembered for a while), the Creature closes in fast (AquaticLunge speed) from
// below and, within GrabReach, calls the hook; a grab that starts holds it there until the pool system lets go.
// Without a hook registered it circles under them and never grabs.

import * as THREE from 'three';
import { CreatureConfig, difficultySpec } from '../config.js';
import { SWIM_DEPTH } from '../water.js';

export const Name = 'AquaticStalk';
export const LungeRange = 12;
export const GrabReach = 4.5;
const LUNGE_DEPTH = 1.2;
const UNDER = 2;
const CIRCLE_RADIUS = 6;
const CIRCLE_SPEED = 0.6;

const runs = new WeakMap();

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { holding: false, circle: 0 };
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
  const here = ctx.body.getPosition();
  const grabber = ctx.poolGrabber();
  const lunging = target !== null && swimmerRoot !== null &&
    shouldLunge(swimmerRoot.distanceTo(here), ctx.grabArmed(target), grabber !== null);
  if (lunging && target && swimmerRoot && grabber) {
    if (swimmerRoot.distanceTo(here) <= GrabReach && mover.getMedium() === 'Water') {
      let started = false;
      try {
        started = grabber(target) === true;
      } catch (err) {
        console.warn('[creature] pool grabber failed', err);
      }
      if (started) {
        run.holding = true;
        mover.stop();
        ctx.setGrabbed(target);
        return;
      }
    }
    mover.setSpeed(speedFor(ctx, true));
    mover.goTo(swimmerRoot.clone().sub(new THREE.Vector3(0, UNDER, 0)), { arrive: 1, depth: LUNGE_DEPTH });
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
  runOf(ctx).holding = false;
}
