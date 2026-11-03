// Dormant: the Creature waits, still, where it was placed: at its level's CreatureSpawn before the players reach that
// level, after an airlock relocation (hidden until nobody can see it fade in), or held by a dev command. Its root is
// anchored (the Level 4 spawn is under water); nothing is hunted. The service wakes it (Patrol) a short delay after
// its level activates; a level controller that acquired it first (the spawn hold, a scene) takes it from there.

export const Name = 'Dormant';

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  ctx.setTarget(null);
  ctx.mover.stop();
  ctx.mover.setSpeed(0);
  ctx.body.setWalkSpeed(0);
  ctx.body.face(null);
  ctx.body.setAnchored(true);
  ctx.body.setPose(ctx.mover.getMedium() === 'Water' ? 'Swim' : 'Biped');
}

export function update() {}

export function exit() {}
