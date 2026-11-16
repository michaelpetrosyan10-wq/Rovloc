// What the presence beats share (docs/MONSTER.md 16): the plan the director handed over (ctx.beatPlan), the paces, the
// approach's time limit and the face toward the player it plays to. The sight rule while a beat plays (only a player
// within Beats.Near, or a stare, starts a chase) is the service's summary.

/** The run of a beat state on `ctx`: {plan, phase, until, ...} kept in `runs`. */
export function begin(runs, ctx, phase) {
  const run = { plan: ctx.beatPlan, phase, until: ctx.now() + ctx.presence.Beats.ApproachSeconds, nextAt: 0 };
  runs.set(ctx, run);
  ctx.body.setPose('Biped');
  ctx.body.face(null);
  return run;
}

/** Walks at `base` studs/s (the difficulty's multiplier and the level's scale, never past SpeedCap). */
export function pace(ctx, base) {
  const speed = ctx.paceOf(base);
  ctx.mover.setSpeed(speed);
  ctx.body.setWalkSpeed(speed);
}

/** Whether the beat cannot go on: no plan, its player out of play, hiding or in a duct. */
export function lost(ctx, run) {
  const target = run && run.plan ? run.plan.target : null;
  return !target || !ctx.playing(target) || ctx.isHiding(target) || ctx.inVent(target);
}

/** The mover's verdict on a leg: 'moving', 'arrived' or 'failed'. */
export function leg(ctx) {
  if (ctx.mover.busy()) return 'moving';
  const status = ctx.mover.getStatus();
  if (status === 'Moving') return 'moving';
  return status === 'Failed' || status === 'Stuck' ? 'failed' : 'arrived';
}

/** The flat way from its root to the player's (null when they stand on it). */
export function toward(ctx, player) {
  const root = ctx.rootOf(player);
  if (!root) return null;
  const dir = root.clone().sub(ctx.body.getPosition());
  dir.y = 0;
  return dir.lengthSq() > 1e-6 ? dir.normalize() : null;
}

/** Ends a beat (the service tells the director of the encounter as the state is left). */
export function finish(runs, ctx) {
  const run = runs.get(ctx);
  if (run) run.plan = null;
  ctx.beatPlan = null;
  ctx.body.face(null);
}
