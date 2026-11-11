// The game module of the Creature screenshot build (tools/creature-shot.mjs links it through build.mjs --entry): the
// real engine and the real Creature (createCreature: brain, rig, lighting, look, smoke, jumpscare view), held by a
// Scripted handle and posed by hand in a lit stretch of corridor on Level 1 or 2, the player's camera a few studs
// away with the torch on. The R <-> A contract fields (action, actionStartedAt, fade, poseMode, speed) are fed into the
// service's snapshot by a wrapper here, the way the behaviour publishes them.
//
//   window.__shot.stage(name) -> {frames}   sets up one view; the runner then steps `frames` frames and captures
//   window.__shot.place                      where the Creature and the camera stand
//
// Stages:
//   idle, walk, hunched, crawl, necksnap, lunge, doorsmash, vanish, chase, stunned  (the originals)
//   far          standing at the end of a lit corridor, 26 studs off, in the torch
//   low          hunched (PoseMode Hunched) in the lowest corridor there is, walking at the camera
//   chase2       mid-chase: loping at the camera
//   mask         a close-up of the mask
//   maw          the mask at the jumpscare's distance, held torn open (a debug view: no shake or glitch)
//   stare, lookaway, reachin   the held contract actions
//   jumpscare1..5              moments of a Hallway catch: the snap-in with the tilt, the maw tearing (shards), the
//                              dilated pupil in the violent shake, the red flash, the static tear
//   reveal                     the reveal scare, a third of the way in
//   fadeout1..3, fadein1..3    the dissolve both ways

import * as THREE from 'three';
import { createCreature, PLAYER } from '../src/creature/index.js';
import { CFrame } from '../src/creature/cframe.js';
import { ROOT_HEIGHT } from '../src/creature/config.js';
import { spacing } from '../src/creature/jumpscare.js';

const LEVELS = ['Level1_Hallways', 'Level2_Auditorium'];
const TOKEN = 'creature-shot';
const PLAYER_ROOT = 3; // the player's root above the floor
const FPS = 30;

/** The brightest probe point along a corridor's centreline with `back` studs of clear corridor behind it for the camera. */
function litSpot(engine, back, pick = 'bright') {
  const meta = engine.world.meta;
  const colour = new THREE.Color();
  let best = null;
  for (const room of meta.rooms) {
    if (!LEVELS.includes(room.level) || room.kind !== 'Corridor') continue;
    const r = room.rect;
    const alongX = r.w >= r.d;
    const length = alongX ? r.w : r.d;
    if (length < back + 14) continue;
    for (let u = back + 4; u <= length - 6; u += 4) {
      const at = alongX
        ? new THREE.Vector3(r.x + u, room.floorY, r.z + r.d / 2)
        : new THREE.Vector3(r.x + r.w / 2, room.floorY, r.z + u);
      const dir = alongX ? new THREE.Vector3(-1, 0, 0) : new THREE.Vector3(0, 0, -1);
      const camera = at.clone().addScaledVector(dir, back);
      const chest = at.clone().add(new THREE.Vector3(0, 7, 0));
      const eye = camera.clone().add(new THREE.Vector3(0, PLAYER_ROOT + 1.6, 0));
      if (!engine.world.lineClear(eye, chest)) continue;
      engine.world.probeAt(chest, colour);
      const lum = 0.2126 * colour.r + 0.7152 * colour.g + 0.0722 * colour.b;
      const score = pick === 'dim' ? -Math.abs(lum - 0.05) : lum;
      if (!best || score > best.score) best = { level: room.level, room: room.id, floorY: room.floorY, at, camera, lum, score, back };
    }
  }
  return best;
}

/** @param {any} engine the W2 Engine */
export async function start(engine) {
  const creature = createCreature(engine);
  engine.creature = creature;
  const spots = {
    near: litSpot(engine, 13),
    far: litSpot(engine, 24),
  };
  if (!spots.near) throw new Error('no lit corridor found');
  if (!spots.far) spots.far = spots.near;
  let spot = spots.near;
  const player = engine.player;
  player.setLifeState('Alive');
  player.setMetersActive(false);
  engine.setCurrentLevel(spot.level);
  creature.beginRun({ difficulty: 'Standard' });
  creature.activateLevel(spot.level);
  engine.ui.setVisible(false, 0);
  const hush = document.createElement('style');
  hush.textContent = '.rv-lock{display:none!important}'; // the pointer-lock hint
  document.head.appendChild(hush);

  // the contract fields, published into the service's snapshot the way the behaviour does it
  const contract = { action: null, actionStartedAt: null, fade: undefined, poseMode: undefined, speed: undefined };
  const service = creature.service;
  const baseSnapshot = service.snapshot.bind(service);
  service.snapshot = () => {
    const s = baseSnapshot();
    if (contract.action) {
      s.action = contract.action;
      s.actionStartedAt = contract.actionStartedAt;
    }
    if (contract.fade !== undefined) s.fade = contract.fade;
    if (contract.poseMode) s.poseMode = contract.poseMode;
    return s;
  };
  const setContract = (patch) => Object.assign(contract, { action: null, actionStartedAt: null, fade: undefined, poseMode: undefined }, patch);

  const useSpot = (name) => {
    const next = spots[name] || spots.near;
    if (next.level !== spot.level) {
      engine.setCurrentLevel(next.level);
      creature.activateLevel(next.level);
    }
    spot = next;
  };
  const eyeTarget = () => spot.at.clone().add(new THREE.Vector3(0, 6.5, 0));
  const placeCamera = (distance = spot.back, lookAt = null) => {
    const dir = spot.at.clone().sub(spot.camera).setY(0).normalize();
    const root = spot.at.clone().addScaledVector(dir, -distance).add(new THREE.Vector3(0, PLAYER_ROOT, 0));
    const look = (lookAt || eyeTarget()).clone().sub(root.clone().add(new THREE.Vector3(0, 1.6, 0)));
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
  const now = () => service.now();
  const jumpscare = () => service.jumpscareView;
  const reset = (pose = 'Biped', offset = 0) => {
    creature.stopAction();
    if (creature.view) creature.view.fxOverride = null;
    if (jumpscare()) jumpscare().end();
    player.setCameraOverride(TOKEN, null);
    setContract({});
    const h = handle();
    h.setHidden(false);
    h.teleport(rootAt(offset)); // a teleport onto a floor stands a Quadruped back up, so the pose comes after it
    h.setPose(pose);
    h.setTarget(PLAYER);
    return h;
  };
  const settle = () => {
    for (let i = 0; i < 20; i++) engine.loop.stepManual(1 / FPS);
  };
  /** A catch staged by hand: the Creature at the Hallway spacing (jumpscare.js spacing), its Lunge and the session. */
  const catchAt = (kind = 'Hallway') => {
    reset('Biped', 0);
    placeCamera(spacing(kind).distance, spot.at.clone().add(new THREE.Vector3(0, 7.5, 0)));
    settle();
    const t = now();
    creature.playAction('Lunge', t);
    jumpscare().start({ kind, startAt: t, endsAt: t + 0.45 + 1.4, face: creature.view.faceWorld().position });
  };
  const fadeAt = (action) => {
    reset('Biped', 2);
    settle();
    setContract({ action, actionStartedAt: now() });
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
      // the duct crawl's posture (Quadruped is the vent pose: walking a floor stands it back up, so it holds still)
      reset('Quadruped', -3);
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
    chase: () => {
      const h = reset('Biped', 14);
      h.release('Patrol');
      creature.devCommand('hunt'); // the run has only begun: pacing would not let it hunt yet
      return { frames: Math.round(0.6 * FPS) };
    },
    stunned: () => {
      const h = reset('Biped');
      h.release('Stunned');
      return { frames: Math.round(0.8 * FPS) };
    },
    far: () => {
      useSpot('far');
      placeCamera();
      reset('Biped');
      return { frames: 2 * FPS };
    },
    low: () => {
      placeCamera(10, spot.at.clone().add(new THREE.Vector3(0, 5.5, 0)));
      const h = reset('Hunched', 5);
      setContract({ poseMode: 'Hunched' });
      h.moveTo(spot.at.clone().add(new THREE.Vector3(0, ROOT_HEIGHT, 0)), 5);
      return { frames: Math.round(1.1 * FPS) };
    },
    chase2: () => {
      const h = reset('Biped', 16);
      h.moveTo(spot.at.clone().add(new THREE.Vector3(0, ROOT_HEIGHT, 0)), 16.5);
      return { frames: Math.round(0.75 * FPS) };
    },
    mask: () => {
      reset('Biped');
      settle();
      const face = creature.view.faceWorld();
      const eye = face.position.clone().addScaledVector(face.lookVector, 2.6).add(new THREE.Vector3(0.35, -0.2, 0));
      player.setCameraOverride(TOKEN, () => ({ position: eye, lookAt: creature.view.faceWorld().position, fov: 50 }), { blendIn: 0 });
      return { frames: Math.round(0.4 * FPS) };
    },
    maw: () => {
      // the mask held at the jumpscare's height (tools only: a fixed moment of the tear, no shake or glitch)
      reset('Biped');
      settle();
      creature.view.fxOverride = { race: 1, tear: 1, strands: 0.45, dilate: 1, focus: 1 };
      const face = creature.view.faceWorld();
      const eye = face.position.clone().addScaledVector(face.lookVector, 1.35).add(new THREE.Vector3(0.12, 0.05, 0));
      player.setCameraOverride(TOKEN, () => ({ position: eye, lookAt: creature.view.faceWorld().position, fov: 55 }), { blendIn: 0 });
      return { frames: Math.round(0.3 * FPS) };
    },
    stare: () => {
      reset('Biped', 2);
      settle();
      setContract({ action: 'Stare', actionStartedAt: now() });
      return { frames: Math.round(1.6 * FPS) };
    },
    lookaway: () => {
      reset('Biped', 2);
      settle();
      setContract({ action: 'LookAway', actionStartedAt: now() });
      return { frames: Math.round(1.2 * FPS) };
    },
    reachin: () => {
      // from inside a hiding spot: the player crouched low, 3.4 studs off, looking up at it as the hand comes in
      reset('Biped', 0);
      placeCamera(3.4, spot.at.clone().add(new THREE.Vector3(0, 8.5, 0)));
      const eye = player.eye().clone().add(new THREE.Vector3(0, -0.9, 0));
      player.setCameraOverride(TOKEN, () => ({ position: eye, lookAt: creature.view.faceWorld().position.clone().add(new THREE.Vector3(0, -1.6, 0)), fov: 70 }), { blendIn: 0 });
      settle();
      setContract({ action: 'ReachIn', actionStartedAt: now() });
      return { frames: Math.round(1.8 * FPS) };
    },
    jumpscare1: () => {
      catchAt();
      return { frames: 4 };
    },
    jumpscare2: () => {
      catchAt();
      return { frames: 17 };
    },
    jumpscare3: () => {
      catchAt();
      return { frames: 29 };
    },
    jumpscare4: () => {
      catchAt();
      return { frames: 34 };
    },
    jumpscare5: () => {
      catchAt();
      return { frames: 41 };
    },
    reveal: () => {
      reset('Biped', 30);
      handle().setHidden(true);
      settle();
      jumpscare().reveal('Teleport', { side: 1 });
      return { frames: 9 };
    },
    fadeout1: () => {
      fadeAt('FadeOut');
      return { frames: 5 };
    },
    fadeout2: () => {
      fadeAt('FadeOut');
      return { frames: 10 };
    },
    fadeout3: () => {
      fadeAt('FadeOut');
      return { frames: 15 };
    },
    fadein1: () => {
      fadeAt('FadeIn');
      return { frames: 6 };
    },
    fadein2: () => {
      fadeAt('FadeIn');
      return { frames: 13 };
    },
    fadein3: () => {
      fadeAt('FadeIn');
      return { frames: 20 };
    },
  };

  window.__shot = {
    get place() {
      return { level: spot.level, room: spot.room, at: spot.at.toArray(), camera: spot.camera.toArray(), probe: spot.lum };
    },
    stages: Object.keys(stages),
    stage(name) {
      const run = stages[name];
      if (!run) throw new Error(`unknown stage ${name}`);
      if (name !== 'far') useSpot('near');
      placeCamera();
      // settle the camera, film and probes before the pose
      for (let i = 0; i < 3; i++) engine.loop.stepManual(1 / FPS);
      return run();
    },
    /** Times the rig per frame on `tier` over `frames` rendered frames, the Creature stalking at the camera. */
    perf(tier, frames) {
      engine.quality.setTier(tier);
      useSpot('near');
      placeCamera();
      const h = reset('Biped', 12);
      h.moveTo(spot.at.clone().add(new THREE.Vector3(0, ROOT_HEIGHT, 0)), 7);
      const view = creature.view;
      const frame = view.frame.bind(view);
      const js = service.jumpscareView;
      const step = js.step.bind(js);
      let spent = 0;
      view.frame = (dt, alpha) => {
        const t = performance.now();
        frame(dt, alpha);
        spent += performance.now() - t;
      };
      js.step = () => {
        const t = performance.now();
        step();
        spent += performance.now() - t;
      };
      // where the time goes: the animator, the bone upload, the smoke, the 10 Hz extras
      const parts = {};
      const unwrap = [];
      const time = (owner, name, label) => {
        const fn = owner[name];
        owner[name] = function wrapped(...args) {
          const t = performance.now();
          const out = fn.apply(this, args);
          parts[label] = (parts[label] || 0) + performance.now() - t;
          return out;
        };
        unwrap.push(() => {
          owner[name] = fn;
        });
      };
      time(view.animator, 'step', 'animator');
      time(view, '_writeBones', 'bones');
      time(view, '_feed', 'feed');
      time(view.smoke, 'step', 'smoke');
      time(view, '_emitSmoke', 'emit');
      time(view, '_updatePupils', 'pupils');
      if (js._phantom) js._phantom(); // the reveal's phantom is built once, before the measurement
      const samples = [];
      const totals = [];
      for (let i = 0; i < 20; i++) engine.loop.stepManual(1 / FPS);
      for (const k of Object.keys(parts)) parts[k] = 0;
      let calls = 0;
      for (let i = 0; i < frames; i++) {
        spent = 0;
        const t = performance.now();
        engine.loop.stepManual(1 / FPS);
        totals.push(performance.now() - t);
        samples.push(spent);
        calls = engine.renderer.stats.calls;
      }
      view.frame = frame;
      js.step = step;
      for (const u of unwrap) u();
      for (const k of Object.keys(parts)) parts[k] = Math.round((parts[k] / frames) * 1000) / 1000;
      const sorted = samples.slice().sort((a, b) => a - b);
      const mean = samples.reduce((a, b) => a + b, 0) / samples.length;
      return {
        rig: mean,
        median: sorted[Math.floor(sorted.length / 2)],
        p95: sorted[Math.floor(sorted.length * 0.95)],
        frame: totals.reduce((a, b) => a + b, 0) / totals.length,
        calls,
        parts,
      };
    },
    snapshot: () => {
      const s = creature.snapshot();
      return { state: s.state, pose: s.pose, hidden: s.hidden, position: s.position.toArray(), catching: !!s.catching, fade: creature.view.fade, contract: creature.view.contract, now: service.now() };
    },
  };
}
