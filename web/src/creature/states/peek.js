// Peek (docs/MONSTER.md 16.1): it walks unseen to a corner near a junction or a corridor's end ahead of the player,
// steps out into their view PeekMin..PeekMax away (within 2, or as far as it got in 6 s), stands there
// PeekHoldMin..PeekHoldMax seconds facing them, then steps back round the corner and is gone (Patrol). The approach is
// limited to ApproachSeconds.

import * as Beat from './beat.js';

export const Name = 'Peek';
const STEP_ARRIVE = 2;
const STEP_SECONDS = 6; // the step out is a few strides: it holds where it got to after this
const runs = new WeakMap();

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = Beat.begin(runs, ctx, 'Approach');
  if (!run.plan) {
    ctx.stateDone = true;
    return;
  }
  Beat.pace(ctx, ctx.presence.Director.HintPace);
  ctx.mover.goTo(run.plan.corner, { arrive: 1.5 });
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runs.get(ctx);
  if (!run || Beat.lost(ctx, run)) {
    ctx.stateDone = true;
    return;
  }
  const B = ctx.presence.Beats;
  const leg = Beat.leg(ctx);
  if (run.phase === 'Approach') {
    if (leg === 'moving' && ctx.now() < run.until) return;
    if (leg !== 'arrived') {
      ctx.stateDone = true;
      return;
    }
    run.phase = 'Step';
    run.until = ctx.now() + STEP_SECONDS;
    Beat.pace(ctx, ctx.presence.Director.PatrolPace);
    ctx.mover.goTo(run.plan.stand, { arrive: STEP_ARRIVE });
    return;
  }
  if (run.phase === 'Step') {
    if (leg === 'moving' && ctx.now() < run.until) return;
    run.phase = 'Hold';
    const face = Beat.toward(ctx, run.plan.target) || ctx.body.getCFrame().lookVector.clone();
    ctx.mover.hold(ctx.random.nextNumber(B.PeekHoldMin, B.PeekHoldMax), face);
    return;
  }
  if (run.phase === 'Hold') {
    if (ctx.mover.busy()) return;
    run.phase = 'Withdraw';
    ctx.mover.goTo(run.plan.corner, { arrive: 1.5 });
    return;
  }
  if (leg === 'moving') return;
  ctx.stateDone = true;
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  Beat.finish(runs, ctx);
}
