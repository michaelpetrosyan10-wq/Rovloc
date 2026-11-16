// Pass-by (docs/MONSTER.md 16.4): its walk goes straight through the player's corridor: on to a point PassNear..PassFar
// from them, then on PassOn..PassOnMax beyond, at the Stalk's pace, and it patrols on from there. Its senses are its
// own throughout: hiding (or keeping out of its cone in the dark) and watching it go past is the answer. The approach
// is limited to ApproachSeconds.

import * as Beat from './beat.js';

export const Name = 'PassBy';
const runs = new WeakMap();

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = Beat.begin(runs, ctx, 'Approach');
  if (!run.plan) {
    ctx.stateDone = true;
    return;
  }
  Beat.pace(ctx, ctx.presence.Director.PatrolPace);
  ctx.mover.goTo(run.plan.via, { arrive: 2 });
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runs.get(ctx);
  if (!run || !run.plan) {
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
    run.phase = 'On';
    ctx.mover.goTo(run.plan.to, { arrive: 2 });
    return;
  }
  if (leg === 'moving') return;
  ctx.stateDone = true;
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  Beat.finish(runs, ctx);
}
