// The game module of the people screenshot build (tools/people-shot.mjs links it through game-build.mjs --entry): the
// whole game as the site runs it, plus a lab on window.__people that stands bodies of the avatar renderer
// (src/game/coop/avatars.js) wherever the runner asks, so a teammate, a cast member or a whole line-up can be looked at
// in the real engine's light (the Back Lot's day, a torch in the Basement).
//
//   __people.stand(list)   replaces the lab's bodies: each {look: 'slot:<n>' | 'cast:<Actor>', x, y, z (feet), yaw
//                          (radians), clip?, moveState?, flags?, pitch?, walk? [vx, vz] (studs / s)}
//   __people.clear()       removes them
// The bodies are posed every frame (a walking one moves on the tick, so its gait comes from the speed it really has).

import * as THREE from 'three';
import { AvatarBody, createBodyBatch, lookOfCostume, lookOfSlot, PARTS } from '../src/game/coop/avatars.js';
import { start as startGame } from '../src/game/start.js';

const ROOT_TO_FEET = 3;

export async function start(engine) {
  const game = await startGame(engine);
  const env = game.env;
  const lab = { batch: null, capacity: 0, bodies: [] };

  const lookOf = (name) => {
    const [kind, id] = String(name).split(':');
    if (kind === 'cast') {
      const actor = (game.world.meta.castConfig || { Actors: {} }).Actors[id];
      if (!actor) throw new Error(`people-shot: no cast member ${id}`);
      return lookOfCostume(actor);
    }
    return lookOfSlot(Number(id) || 0);
  };

  const clear = () => {
    for (const b of lab.bodies) b.body.dispose();
    lab.bodies.length = 0;
    if (lab.batch) lab.batch.table.flush();
  };

  const stand = (list) => {
    clear();
    if (!lab.batch || lab.capacity < list.length) {
      lab.capacity = Math.max(8, list.length);
      lab.batch = createBodyBatch(env, lab.capacity);
    }
    list.forEach((spec, i) => {
      const body = new AvatarBody(env, lab.batch, i * PARTS, lookOf(spec.look), `Lab:${spec.look}`);
      lab.bodies.push({ body, spec: { ...spec }, t: 0 });
    });
  };

  env.onTick((dt) => {
    for (const b of lab.bodies) {
      b.t += dt;
      if (b.spec.walk) {
        b.spec.x += b.spec.walk[0] * dt;
        b.spec.z += b.spec.walk[1] * dt;
      }
    }
  });
  env.onFrame((dt) => {
    if (!lab.bodies.length) return;
    for (const b of lab.bodies) {
      const s = b.spec;
      b.body.draw(dt, { x: s.x, y: s.y + ROOT_TO_FEET, z: s.z, yaw: s.yaw || 0, pitch: s.pitch || 0, clip: s.clip,
        clipTime: b.t, moveState: s.moveState || 'Standing', life: s.life || 'Alive', flags: s.flags || 0, held: s.held });
    }
    lab.batch.table.flush();
  });

  window.__people = { THREE, stand, clear, lab };
  return game;
}
