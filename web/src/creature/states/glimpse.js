// Glimpse (docs/MONSTER.md 16.2): it walks unseen to a point on the left of a crossing ahead of the player, crosses it
// left to right at GlimpsePace into cover on the right and is gone (Patrol). The approach is limited to
// ApproachSeconds.

import * as Beat from './beat.js';

export const Name = 'Glimpse';
const runs = new WeakMap();

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = Beat.begin(runs, ctx, 'Approach');
  if (!run.plan) {
    ctx.stateDone = true;
    return;
  }
  Beat.pace(ctx, ctx.presence.Director.HintPace);
  ctx.mover.goTo(run.plan.from, { arrive: 1.5 });
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runs.get(ctx);
  if (!run || Beat.lost(ctx, run)) {
    ctx.stateDone = true;
    return;
  }
  const leg = Beat.leg(ctx);
  if (run.phase === 'Approach') {
    if (leg === 'moving' && ctx.now() < run.until) return;
    if (leg !== 'arrived') {
      ctx.stateDone = true;
      return;
    }
    run.phase = 'Cross';
    Beat.pace(ctx, ctx.presence.Beats.GlimpsePace);
    ctx.mover.goTo(run.plan.via, { arrive: 2 });
    return;
  }
  if (run.phase === 'Cross') {
    if (leg === 'moving') return;
    run.phase = 'Away';
    ctx.mover.goTo(run.plan.to, { arrive: 1.5 });
    return;
  }
  if (leg === 'moving') return;
  ctx.stateDone = true;
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  Beat.finish(runs, ctx);
}
