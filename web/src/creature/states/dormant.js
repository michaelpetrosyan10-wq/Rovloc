// Dormant (States/Dormant.luau): the Creature waits, still, where it was placed: at its level's CreatureSpawn before
// the player reaches that level, after an airlock relocation (hidden until nobody can see it appear), or held by a
// dev command. Its root is anchored (the Level 4 spawn is under water); nothing is hunted. The service wakes it
// (Patrol) a short delay after its level activates; a cutscene that acquired it first takes it from there instead.

export const Name = 'Dormant';

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  ctx.setTarget(null);
  ctx.mover.stop();
  ctx.mover.setSpeed(0);
  ctx.body.setWalkSpeed(0);
  ctx.body.face(null);
  const medium = ctx.mover.getMedium();
  if (medium !== 'Vent') {
    ctx.body.setAnchored(true);
    ctx.body.setPose(medium === 'Water' ? 'Swim' : 'Biped');
  }
}

export function update() {}

export function exit() {}
