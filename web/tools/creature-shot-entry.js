// The game module of the Creature screenshot build (tools/creature-shot.mjs links it through build.mjs --entry): the
// real engine and the real Creature (createCreature: brain, rig, lighting), held by a Scripted handle and posed by
// hand in the best lit stretch of corridor on Levels 1 to 3, the player's camera a few studs away with the torch on.
//
//   window.__shot.stage(name) -> {frames}   sets up one view; the runner then steps `frames` frames and captures
//   window.__shot.place                      where the Creature and the camera stand
//
// Stages: idle, walk, hunched, crawl, necksnap, lunge, doorsmash, vanish, stunned, chase.

import * as THREE from 'three';
import { createCreature, PLAYER } from '../src/creature/index.js';
import { CFrame } from '../src/creature/cframe.js';
import { ROOT_HEIGHT } from '../src/creature/config.js';

const LEVELS = ['Level1_Hallways', 'Level2_ScienceHall', 'Level3_Gymnasium'];
const TOKEN = 'creature-shot';
const CAMERA_DISTANCE = 13;
const PLAYER_ROOT = 3; // the player's root above the floor
const FPS = 30;

/** The brightest probe point along a corridor's centreline with room for the camera behind it. */
function litSpot(engine) {
  const meta = engine.world.meta;
  const colour = new THREE.Color();
  let best = null;
  for (const room of meta.rooms) {
    if (!LEVELS.includes(room.level) || room.kind !== 'Corridor') continue;
    const r = room.rect;
    const alongX = r.w >= r.d;
    const length = alongX ? r.w : r.d;
    if (length < 2 * CAMERA_DISTANCE + 8) continue;
    for (let u = CAMERA_DISTANCE + 4; u <= length - 6; u += 4) {
      const at = alongX
        ? new THREE.Vector3(r.x + u, room.floorY, r.z + r.d / 2)
        : new THREE.Vector3(r.x + r.w / 2, room.floorY, r.z + u);
      const back = alongX ? new THREE.Vector3(-1, 0, 0) : new THREE.Vector3(0, 0, -1);
      const camera = at.clone().addScaledVector(back, CAMERA_DISTANCE);
      const chest = at.clone().add(new THREE.Vector3(0, 6, 0));
      const eye = camera.clone().add(new THREE.Vector3(0, PLAYER_ROOT + 1.6, 0));
      if (!engine.world.lineClear(eye, chest)) continue;
      engine.world.probeAt(chest, colour);
      const lum = 0.2126 * colour.r + 0.7152 * colour.g + 0.0722 * colour.b;
      if (!best || lum > best.lum) best = { level: room.level, room: room.id, floorY: room.floorY, at, camera, lum };
    }
  }
  return best;
}

/** @param {any} engine the W2 Engine */
export async function start(engine) {
  const creature = createCreature(engine);
  engine.creature = creature;
  const spot = litSpot(engine);
  if (!spot) throw new Error('no lit corridor found');
  const player = engine.player;
  player.setLifeState('Alive');
  player.setMetersActive(false);
  engine.setCurrentLevel(spot.level);
  creature.beginRun({ difficulty: 'Standard' });
  creature.activateLevel(spot.level);
  engine.ui.setVisible(false, 0);

  const eyeTarget = spot.at.clone().add(new THREE.Vector3(0, 6.5, 0));
  const placeCamera = (distance = CAMERA_DISTANCE) => {
    const dir = spot.at.clone().sub(spot.camera).setY(0).normalize();
    const root = spot.at.clone().addScaledVector(dir, -distance).add(new THREE.Vector3(0, PLAYER_ROOT, 0));
    const look = eyeTarget.clone().sub(root.clone().add(new THREE.Vector3(0, 1.6, 0)));
    const yaw = Math.atan2(-look.x, -look.z);
    player.teleport({ position: { x: root.x, y: root.y, z: root.z }, yaw });
    player.setLook(yaw, Math.atan2(look.y, Math.hypot(look.x, look.z)));
    player.flashlight.setOn(true);
  };
  const handle = () => creature.acquireScripted(TOKEN);
  /** Root CFrame `offset` studs beyond the spot (away from the camera), facing the camera. */
  const rootAt = (offset = 0) => {
    const away = spot.at.clone().sub(spot.camera).setY(0).normalize();
    const p = spot.at.clone().addScaledVector(away, offset).add(new THREE.Vector3(0, ROOT_HEIGHT, 0));
    return CFrame.lookAt(p, new THREE.Vector3(spot.camera.x, p.y, spot.camera.z));
  };
  const reset = (pose = 'Biped', offset = 0) => {
    creature.stopAction();
    const h = handle();
    h.setHidden(false);
    h.setPose(pose);
    h.teleport(rootAt(offset));
    h.setTarget(PLAYER);
    return h;
  };

  const stages = {
    idle: () => {
      reset('Biped');
      return { frames: 2 * FPS };
    },
    walk: () => {
      const h = reset('Biped', 9);
      h.moveTo(spot.at.clone().add(new THREE.Vector3(0, ROOT_HEIGHT, 0)), 7);
      return { frames: Math.round(1.1 * FPS) };
    },
    hunched: () => {
      reset('Hunched');
      return { frames: 2 * FPS };
    },
    crawl: () => {
      const h = reset('Quadruped', 8);
      h.moveTo(spot.at.clone().add(new THREE.Vector3(0, ROOT_HEIGHT, 0)), 8);
      return { frames: Math.round(1.2 * FPS) };
    },
    necksnap: () => {
      reset('Biped');
      creature.playAction('NeckSnap');
      return { frames: Math.round(0.55 * FPS) };
    },
    lunge: () => {
      reset('Biped', 3);
      creature.playAction('Lunge');
      return { frames: Math.round(0.4 * FPS) };
    },
    doorsmash: () => {
      reset('Biped');
      creature.playAction('DoorSmash');
      return { frames: Math.round(0.35 * FPS) };
    },
    vanish: () => {
      reset('Biped');
      creature.playAction('Vanish');
      return { frames: Math.round(0.25 * FPS) };
    },
    stunned: () => {
      const h = reset('Biped');
      h.release('Stunned');
      return { frames: Math.round(0.8 * FPS) };
    },
    chase: () => {
      const h = reset('Biped', 14);
      h.release('WallChase');
      return { frames: Math.round(0.6 * FPS) };
    },
  };

  window.__shot = {
    place: { level: spot.level, room: spot.room, at: spot.at.toArray(), camera: spot.camera.toArray(), probe: spot.lum },
    stages: Object.keys(stages),
    stage(name) {
      const run = stages[name];
      if (!run) throw new Error(`unknown stage ${name}`);
      placeCamera();
      // settle the camera, film and probes before the pose
      for (let i = 0; i < 3; i++) engine.loop.stepManual(1 / FPS);
      return run();
    },
    snapshot: () => {
      const s = creature.snapshot();
      return { state: s.state, pose: s.pose, hidden: s.hidden, position: s.position.toArray(), catching: !!s.catching };
    },
  };
}
