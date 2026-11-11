// Stunned: blinded by a chemical cloud (stun, GameConfig.StunSeconds). The Creature claws at its face and stumbles back
// away from the cloud at Stunned speed: a short stagger straight back (veering off a wall behind it, flailing in place
// when boxed in). No catches, no noises heard, nobody targeted. When the stun ends the brain sends it off to withdraw
// (Patrol, out of sight). The view contract's poseMode reads 'Stunned' throughout (the stun flail).

export const Name = 'Stunned';
const FLAIL_SECONDS = 0.5;

/** Starts (or restarts, for a second cloud) the stumbling retreat. @param {import('../service.js').Context} ctx */
export function retreat(ctx) {
  const position = ctx.body.getPosition();
  const from = ctx.stunFrom || position.clone().add(ctx.body.getCFrame().lookVector);
  ctx.mover.setSpeed(ctx.speedOf(Name));
  ctx.body.setWalkSpeed(ctx.speedOf(Name));
  ctx.mover.retreat(from);
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  ctx.setTarget(null);
  ctx.mover.stop();
  retreat(ctx);
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const mover = ctx.mover;
  if (mover.busy() || mover.getStatus() === 'Moving') return;
  mover.hold(FLAIL_SECONDS, null);
}

export function exit() {}
