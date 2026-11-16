// Shadow (docs/MONSTER.md 16.3): it follows a moving player ShadowGap behind along the way they came (their trail), for
// ShadowMinSeconds..ShadowMaxSeconds, its footfalls heard. Closer than ShadowMin walked it stops; farther than
// ShadowMax it walks at ShadowFast to catch up, else at their pace (never under the Stalk's, never over ShadowFast).
// The player looking back at it (their view within FreezeAngle of its head, a clear line) freezes it where it stands;
// a long look is the stare that starts a chase (the service's stare rule). Then it withdraws (Patrol, withdrawing).

import * as Beat from './beat.js';

export const Name = 'Shadow';
const REGOAL = 0.5;
const runs = new WeakMap();

/** The trail point `gap` studs back along `trail` (oldest first) from its newest point, else the oldest. */
export function trailPoint(trail, gap) {
  if (!trail.length) return null;
  let left = gap;
  for (let i = trail.length - 1; i > 0; i--) {
    const a = trail[i];
    const b = trail[i - 1];
    const d = Math.hypot(a.x - b.x, a.z - b.z);
    if (d >= left) return a.clone().lerp(b, d > 1e-6 ? left / d : 0);
    left -= d;
  }
  return trail[0].clone();
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = Beat.begin(runs, ctx, 'Follow');
  if (!run.plan) {
    ctx.stateDone = true;
    return;
  }
  const B = ctx.presence.Beats;
  run.until = ctx.now() + ctx.random.nextNumber(B.ShadowMinSeconds, B.ShadowMaxSeconds);
  Beat.pace(ctx, ctx.presence.Director.PatrolPace);
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runs.get(ctx);
  if (!run || Beat.lost(ctx, run) || ctx.now() >= run.until) {
    ctx.stateDone = true;
    ctx.reposition = true;
    return;
  }
  const B = ctx.presence.Beats;
  const now = ctx.now();
  const target = run.plan.target;
  const face = () => Beat.toward(ctx, target) || ctx.body.getCFrame().lookVector.clone();
  if (ctx.lookedAt(target, B.FreezeAngle)) {
    // frozen under their look
    if (!ctx.mover.busy()) ctx.mover.hold(REGOAL, face());
    return;
  }
  if (now < run.nextAt) return;
  run.nextAt = now + REGOAL;
  const walk = ctx.walkTo(target);
  if (walk < B.ShadowMin) {
    ctx.mover.hold(REGOAL, face());
    return;
  }
  const goal = trailPoint(ctx.trailOf(target), B.ShadowGap);
  if (!goal) return;
  const keep = Math.min(B.ShadowFast, Math.max(ctx.presence.Director.PatrolPace, ctx.speedOfPlayer(target)));
  Beat.pace(ctx, walk > B.ShadowMax ? B.ShadowFast : keep);
  ctx.mover.goTo(ctx.floorPointNear(goal), { arrive: 2 });
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  Beat.finish(runs, ctx);
}
