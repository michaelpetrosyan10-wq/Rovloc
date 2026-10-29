// Scripted (States/Scripted.luau): a cutscene holds the Creature (acquireScripted). The brain is paused: no senses,
// no decisions, no catches; the scripted handle moves, teleports, poses, hides and turns it until release(nextState).

export const Name = 'Scripted';

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  ctx.setTarget(null);
  ctx.mover.stop();
  ctx.mover.setSpeed(ctx.speedOf(Name));
  ctx.body.setWalkSpeed(ctx.speedOf(Name));
}

export function update() {}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  ctx.body.face(null);
}
