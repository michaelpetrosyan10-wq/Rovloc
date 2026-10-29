// CreatureView (Controllers/Characters/CreatureController.luau): draws and animates the Creature.
//
//   * Rig: W1's skinned creature (3 chunks, one bone per vertex) through the engine's creature model (env:
//     createCreatureModel): every frame the ProceduralAnimator's bone frames drive its 31 bones (bone world matrix =
//     root world x the bone's rig-space frame). Lit by the level's probe irradiance at its chest plus the flashlight
//     (the world material's dynamic lights).
//   * Inputs: the profile state from MonsterState + PoseMode + InVent (Creature.resolveState), the hunch from PoseMode
//     Hunched, the root's velocity (measured from its motion), grounded, the game clock (actions line up with the
//     brain's schedule) and the look: the player's eyes (the camera) while it targets them, measured from its eye
//     point; with no target the head scans by itself.
//   * LOD (ProceduralAnimator: DefaultNear 60, DefaultFar 180): within Near of the camera, or while it hunts the
//     player and is in view, the rig steps every frame; in view up to Far, every third frame; otherwise it is frozen.
//   * Actions: playAction(name, startAt) layers a one-shot (NeckSnap, Lunge, LockerRip, DoorSmash, Vanish, Reveal).
//   * Hidden: the whole rig is hidden; its loops are silenced.
//   * Pupils: the pinprick Neon pupils are faint in the light and brighten (and grow slightly) in a duct or in
//     darkness (the summed falloff of the lit fixtures at its eyes); a small additive halo carries their glow on
//     tiers without bloom.
//   * Audio: while in a duct, looped VentScrape + VentBreathing follow the root, louder with speed; footsteps at the
//     feet from the animator's plants (heavy and slow on two legs; claws skittering in ducts); an occasional
//     CreatureGrowl at the head while it chases, on fixed time slots.

import * as THREE from 'three';
import { Animator, yawOf } from './animator.js';
import { CFrame } from './cframe.js';
import { CreatureConfig } from './config.js';
import * as Creature from './profile.js';
import { buildJointMap } from './rig.js';
import { clamp01, damp, dampNumber, lerp, seededRandom, smoothstep, yawPitchFromVector } from './util.js';

const CREATURE_SEED = 8517;
const TELEPORT_DISTANCE = 12;
const VELOCITY_DAMP = 12;
const EXTRAS_HZ = 10;
const DARK_EXPOSURE = 0.12;
const LIT_EXPOSURE = 0.9;
const LIGHT_REACH = 70;
const PUPIL_FAINT = 0.72;
const PUPIL_BRIGHT = 0;
const PUPIL_GROW = 1.35;
const PUPIL_SPEED = 3;
const PUPIL_EPSILON = 0.004;
const LOOP_FADE = 0.6;
const LOOP_VOLUME_FADE = 0.25;
const SCRAPE_QUIET = 0.3;
const BREATH_QUIET = 0.65;
const GROWL_SLOT = 4.5;
const GROWL_CHANCE = 0.65;
const HEAVY_SPEED = 0.72;
const HEAVY_SPRINT_SPEED = 0.66;
const HEAVY_VOLUME = 1.5;
const SKITTER_SPEED = 1.45;
const SKITTER_VOLUME = 0.6;
const DUPLICATE_WINDOW = 0.05;
const ANIM_NEAR = 60;
const ANIM_FAR = 180;
const REDUCED_EVERY = 3;
const NEON_STRENGTH = 2.4;
const HALO_SIZE = 0.22;
const HALO_OPACITY = 0.85;
const SKIN_ROUGHNESS = 0.35;
const SKIN_REFLECTANCE = 0.16;
const QUADRUPED_STATES = new Set(['VentCrawl', 'VentRetreat']);
const CHASE_STATES = new Set(['WallChase', 'VentChase']);
const PUPIL_COLOR = new THREE.Color(1, 0.9569, 0.8392);

/** The root's velocity from its displacement over the step; teleports read as still. */
export function estimateVelocity(displacement, dt) {
  if (displacement.length() > TELEPORT_DISTANCE || dt <= 0) return new THREE.Vector3();
  return displacement.clone().divideScalar(dt);
}

/** Summed light at `point`: each lit source adds brightness * (1 - d / range)^2 inside its range. */
export function exposure(point, samples) {
  let total = 0;
  for (const s of samples) {
    if (s.brightness > 0 && s.range > 0) {
      const d = s.position.distanceTo(point);
      if (d < s.range) {
        const f = 1 - d / s.range;
        total += s.brightness * f * f;
      }
    }
  }
  return total;
}

/** How brightly the pupils glow (0 faint .. 1 bright): fully in a duct or in the dark. */
export function pupilGlow(inVent, exposureValue) {
  if (inVent) return 1;
  return 1 - smoothstep(DARK_EXPOSURE, LIT_EXPOSURE, exposureValue);
}

/** Pupil [transparency, size factor] for a glow. */
export function pupilLook(glow) {
  const g = clamp01(glow);
  return [lerp(PUPIL_FAINT, PUPIL_BRIGHT, g), lerp(1, PUPIL_GROW, g)];
}

/** Duct loop volumes [scrape, breathing] for the Creature's speed. */
export function ventVolumes(speed) {
  const pace = clamp01(speed / CreatureConfig.Speeds.VentChase);
  return [lerp(SCRAPE_QUIET, 1, pace), lerp(BREATH_QUIET, 1, pace)];
}

/** The time a growl plays in growl slot `slot` (null: a quiet slot). */
export function growlAt(slot, seed) {
  const roll = seededRandom(seed, `Growl:${slot}`);
  if (roll.nextNumber() >= GROWL_CHANCE) return null;
  return (slot + roll.nextNumber(0.05, 0.85)) * GROWL_SLOT;
}

/** Footstep playback [speed, volume] for an animator plant. */
export function footstepVoice(state, sprint, volume) {
  if (QUADRUPED_STATES.has(state)) return [SKITTER_SPEED, volume * SKITTER_VOLUME];
  return [sprint ? HEAVY_SPRINT_SPEED : HEAVY_SPEED, volume * HEAVY_VOLUME];
}

function haloTexture() {
  const size = 32;
  const data = new Uint8Array(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const dx = (x + 0.5) / size - 0.5;
      const dy = (y + 0.5) / size - 0.5;
      const r = Math.sqrt(dx * dx + dy * dy) * 2;
      const a = Math.max(0, 1 - r) ** 2.2;
      const i = (y * size + x) * 4;
      data[i] = 255;
      data[i + 1] = 255;
      data[i + 2] = 255;
      data[i + 3] = Math.round(a * 255);
    }
  }
  const tex = new THREE.DataTexture(data, size, size, THREE.RGBAFormat);
  tex.needsUpdate = true;
  return tex;
}

export class CreatureView {
  /**
   * @param {import('./env.js').CreatureEnv} env
   * @param {import('./service.js').MonsterAI} service
   */
  constructor(env, service) {
    this.env = env;
    this.service = service;
    const meta = env.meta();
    this.map = buildJointMap(meta.creature);
    this.animator = new Animator(this.map, Creature.Profile, { seed: CREATURE_SEED });
    this.animator.setGroundProbe((origin, direction) => env.monsterFloorProbe(origin, direction));
    this.animator.footstep.connect((event) => this._onFootstep(event));
    this.bones = meta.creature.bones.map((b) => b.name);
    this.model = env.createCreatureModel();
    env.addToScene(this.model.object);
    this._tuneMaterials();
    this.pupils = this._findPupils(meta.creature);
    this.halos = this._buildHalos();
    this.prevRoot = service.body.getCFrame();
    this.currRoot = service.body.getCFrame();
    this.placements = service.body.placements;
    this.root = this.currRoot;
    this.lastPosition = null;
    this.velocity = new THREE.Vector3();
    this.speed = 0;
    this.glow = 0;
    this.extrasClock = 0;
    this.lodFrame = 0;
    this.pendingDt = 0;
    this.scrape = null;
    this.breathing = null;
    this.growlSlot = Math.floor(env.renderTime() / GROWL_SLOT);
    this.growlPlan = -1;
    this.growlAtTime = null;
    this.hidden = null;
    this.lights = [];
    this.lightsLevel = null;
    this.stepped = false;
    this._writeBones(this.root);
    this._applyHidden(true);
  }

  _tuneMaterials() {
    for (const mesh of this.model.object.children) {
      const u = mesh.material && mesh.material.uniforms;
      if (!u) continue;
      const chunkMaterial = String((mesh.material.userData && mesh.material.userData.key) || '').split('|')[0];
      if (u.uEmissive && u.uEmissive.value > 0) {
        this.pupilMesh = mesh;
        continue;
      }
      if (chunkMaterial !== 'Fabric' && u.uRoughness && u.uReflectance) {
        u.uRoughness.value = SKIN_ROUGHNESS;
        u.uReflectance.value = SKIN_REFLECTANCE;
      }
    }
  }

  _findPupils(creature) {
    const out = [];
    const head = creature.bones.find((b) => b.name === 'Head');
    for (const p of creature.parts || []) {
      if (p.name === 'LeftPupil' || p.name === 'RightPupil') out.push({ name: p.name, model: new THREE.Vector3(p.cf[0], p.cf[1], p.cf[2]) });
    }
    this.headIndex = this.bones.indexOf('Head');
    this.headRestInverse = head ? CFrame.fromComponents(head.rest).inverse() : new CFrame();
    // pupil vertices of the Neon chunk (model space at rest), grouped by the nearer pupil, for the glow growth
    const mesh = this.pupilMesh;
    if (mesh && out.length > 0) {
      const pos = mesh.geometry.getAttribute('position');
      this.pupilRest = Float32Array.from(pos.array);
      this.pupilOwner = new Uint8Array(pos.count);
      for (let v = 0; v < pos.count; v++) {
        const x = pos.array[v * 3];
        const y = pos.array[v * 3 + 1];
        const z = pos.array[v * 3 + 2];
        let best = 0;
        let bestD = Infinity;
        out.forEach((p, i) => {
          const d = (p.model.x - x) ** 2 + (p.model.y - y) ** 2 + (p.model.z - z) ** 2;
          if (d < bestD) {
            bestD = d;
            best = i;
          }
        });
        this.pupilOwner[v] = best;
      }
    }
    return out;
  }

  _buildHalos() {
    const tex = haloTexture();
    const out = [];
    for (let i = 0; i < this.pupils.length; i++) {
      const mat = new THREE.SpriteMaterial({
        map: tex, color: PUPIL_COLOR, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, opacity: 0,
      });
      const sprite = new THREE.Sprite(mat);
      sprite.scale.setScalar(HALO_SIZE);
      sprite.renderOrder = 12;
      this.env.addToScene(sprite);
      out.push(sprite);
    }
    return out;
  }

  // ------------------------------------------------------------------ ticks

  /** Before the service's tick: remember where the root was (render interpolation). */
  beforeTick() {
    this.prevRoot = this.service.body.getCFrame();
    this.placementsBefore = this.service.body.placements;
  }

  /** After the service's tick. */
  afterTick() {
    this.currRoot = this.service.body.getCFrame();
    if (this.service.body.placements !== this.placementsBefore) this.prevRoot = this.currRoot; // teleport: no blend
  }

  /** The face frame (FaceFrontAttachment) in world space under the latest pose. */
  faceWorld() {
    const head = this.animator.getPartFrame('Head');
    const m = Creature.measure(this.map);
    if (!head) return null;
    return this.root.mul(head).mul(m.faceInHead);
  }

  /** Plays action `name` from `startAt` (default now); the same action at the same moment plays once. */
  playAction(name, startAt) {
    if (!Creature.isAction(name)) return false;
    const at = Number.isFinite(startAt) ? startAt : this.service.now();
    const running = Creature.actionStart(this.map, name);
    if (running !== null && Math.abs(running - at) <= DUPLICATE_WINDOW) return true;
    return Creature.playAction(this.map, name, at);
  }

  stopAction(name) {
    Creature.stopAction(this.map, name ?? null);
  }

  // ------------------------------------------------------------------ frame

  /**
   * Per render frame. @param {number} dt @param {number} alpha share of the next tick (0..1)
   */
  frame(dt, alpha) {
    const service = this.service;
    const snap = service.snapshot();
    const shown = snap.running && !snap.hidden;
    this._applyHidden(!shown);
    if (!snap.running) {
      this._stopLoops(LOOP_FADE);
      return;
    }
    this.root = this.prevRoot.lerp(this.currRoot, clamp01(alpha));
    const camera = this.env.cameraPosition();
    const distance = camera ? camera.distanceTo(this.root.position) : 0;
    const now = this.env.renderTime();
    // growl slots and the 10 Hz extras run whether or not the rig steps
    this._updateGrowl(snap, now);
    this.extrasClock += dt;
    if (this.extrasClock >= 1 / EXTRAS_HZ) {
      const step = this.extrasClock;
      this.extrasClock = 0;
      this._updateLoops(snap);
      if (distance <= ANIM_FAR) this._updatePupils(snap, step);
    }
    if (!shown) return;
    // LOD: animation only when near, or in view within Far (every frame while it hunts the player in view)
    const visible = this.env.inView(this.root.position, 6);
    let tier = 'Frozen';
    if (distance <= ANIM_NEAR) tier = 'Full';
    else if (visible && distance <= ANIM_FAR) tier = snap.targetingPlayer ? 'Full' : 'Reduced';
    this.pendingDt = Math.min(this.pendingDt + dt, 0.1);
    this.lodFrame++;
    if (tier === 'Frozen') {
      this.pendingDt = 0;
      if (!this.stepped) this._writeBones(this.root);
      return;
    }
    if (tier === 'Reduced' && this.lodFrame % REDUCED_EVERY !== 0) return;
    const stepDt = this.pendingDt;
    this.pendingDt = 0;
    this._feed(snap, stepDt, now, camera);
    this.animator.step(stepDt, this.root);
    this.stepped = true;
    this._writeBones(this.root);
  }

  _feed(snap, dt, now, camera) {
    const map = this.map;
    const state = Creature.resolveState(snap.state, snap.pose, snap.inVent);
    const hunch = Creature.hunchFor(snap.pose);
    const position = this.root.position;
    const last = this.lastPosition;
    this.lastPosition = position.clone();
    const displacement = last ? position.clone().sub(last) : new THREE.Vector3();
    const raw = estimateVelocity(displacement, dt);
    this.velocity.lerp(raw, damp(VELOCITY_DAMP, dt));
    this.speed = Math.hypot(this.velocity.x, this.velocity.z);
    const grounded = QUADRUPED_STATES.has(state) || state === 'Swim' ? true : this.service.body.anchored || this.service.body.grounded;
    let yaw = null;
    let pitch = null;
    if (snap.targetingPlayer && camera) {
      const eye = new THREE.Vector3(position.x, position.y + (CreatureConfig.EyeHeightAboveRoot[snap.pose] ?? 3.1), position.z);
      const delta = camera.clone().sub(eye);
      if (delta.length() > 1e-3) ({ yaw, pitch } = yawPitchFromVector(delta));
    }
    Creature.setFocus(map, yaw !== null);
    Creature.setHunch(map, hunch);
    this.animator.setInputs({
      moveState: state,
      velocity: this.velocity,
      grounded,
      lookYaw: yaw ?? yawOf(this.root),
      lookPitch: pitch ?? 0,
      time: now,
    });
  }

  _writeBones(root) {
    const frames = this.animator.frames;
    for (let i = 0; i < this.bones.length; i++) {
      const frame = frames[this.bones[i]];
      if (!frame) continue;
      this.model.setBoneWorld(i, root.mul(frame).toMatrix4(_m));
    }
    const chest = frames.UpperTorso ? root.mul(frames.UpperTorso).position : root.position;
    this.model.setLight(this.env.probeAt(chest, _c));
    // pupil halos ride the head
    const head = frames.Head;
    if (head && this.halos.length > 0) {
      const headWorld = root.mul(head).mul(this.headRestInverse);
      this.pupils.forEach((p, i) => headWorld.pointToWorld(p.model, this.halos[i].position));
    }
    this.model.flush();
  }

  _applyHidden(hidden) {
    if (this.hidden === hidden) return;
    this.hidden = hidden;
    this.model.setVisible(!hidden);
    this.model.object.visible = !hidden;
    for (const h of this.halos) h.visible = !hidden;
    if (hidden) this._stopLoops(0.1);
    this.model.flush();
  }

  // ------------------------------------------------------------------ pupils

  _lightSamples(levelId, point) {
    if (this.lightsLevel !== levelId) {
      this.lightsLevel = levelId;
      this.lights = this.env.fixtureLights(levelId);
    }
    const out = [];
    for (const l of this.lights) {
      if (l.position.distanceTo(point) > LIGHT_REACH) continue;
      const brightness = l.brightness * this.env.lightFactor(l);
      if (brightness > 0) out.push({ position: l.position, brightness, range: l.range });
    }
    return out;
  }

  _updatePupils(snap, dt) {
    let ex = 0;
    if (!snap.inVent) ex = exposure(snap.eye, this._lightSamples(snap.levelId, snap.eye));
    const target = pupilGlow(snap.inVent, ex);
    this.glow = dampNumber(this.glow, target, PUPIL_SPEED, dt);
    const [transparency, scale] = pupilLook(this.glow);
    if (this.lastPupil !== undefined && Math.abs(this.lastPupil - transparency) <= PUPIL_EPSILON) return;
    this.lastPupil = transparency;
    const mesh = this.pupilMesh;
    if (mesh) {
      mesh.material.uniforms.uEmissive.value = NEON_STRENGTH * (1 - transparency);
      if (this.pupilRest) {
        const pos = mesh.geometry.getAttribute('position');
        for (let v = 0; v < pos.count; v++) {
          const c = this.pupils[this.pupilOwner[v]].model;
          pos.array[v * 3] = c.x + (this.pupilRest[v * 3] - c.x) * scale;
          pos.array[v * 3 + 1] = c.y + (this.pupilRest[v * 3 + 1] - c.y) * scale;
          pos.array[v * 3 + 2] = c.z + (this.pupilRest[v * 3 + 2] - c.z) * scale;
        }
        pos.needsUpdate = true;
      }
    }
    for (const h of this.halos) {
      h.material.opacity = HALO_OPACITY * (1 - transparency);
      h.scale.setScalar(HALO_SIZE * scale);
    }
  }

  // ------------------------------------------------------------------ audio

  _stopLoops(fade) {
    const { scrape, breathing } = this;
    this.scrape = null;
    this.breathing = null;
    if (scrape) scrape.stop(fade);
    if (breathing) breathing.stop(fade);
  }

  _updateLoops(snap) {
    if (!snap.inVent || snap.hidden) {
      this._stopLoops(LOOP_FADE);
      return;
    }
    const [scrapeVolume, breathVolume] = ventVolumes(this.speed);
    const follow = () => this.root.position;
    if (this.scrape && this.scrape.playing !== false) this.scrape.setVolume(scrapeVolume, LOOP_VOLUME_FADE);
    else this.scrape = this.env.play('VentScrape', { follow, volume: scrapeVolume, fadeIn: LOOP_FADE, loop: true });
    if (this.breathing && this.breathing.playing !== false) this.breathing.setVolume(breathVolume, LOOP_VOLUME_FADE);
    else this.breathing = this.env.play('VentBreathing', { follow, volume: breathVolume, fadeIn: LOOP_FADE, loop: true });
  }

  _updateGrowl(snap, now) {
    if (snap.hidden || !CHASE_STATES.has(snap.state)) return;
    const slot = Math.floor(now / GROWL_SLOT);
    if (slot === this.growlSlot) return;
    if (this.growlPlan !== slot) {
      this.growlPlan = slot;
      this.growlAtTime = growlAt(slot, CREATURE_SEED);
    }
    const at = this.growlAtTime;
    if (at === null) {
      this.growlSlot = slot;
      return;
    }
    if (now < at) return;
    this.growlSlot = slot;
    if (now - at > 0.5) return;
    const head = this.animator.getPartFrame('Head');
    const position = head ? this.root.mul(head).position : this.root.position;
    this.env.play('CreatureGrowl', { position, seed: (slot % 2147483646) + 1 });
  }

  _onFootstep(event) {
    if (this.hidden) return;
    const surface = this.env.surfaceAt(event.position);
    const [speed, volume] = footstepVoice(event.state, event.sprint, event.volume);
    this.env.play(`Footstep${event.sprint ? 'Sprint' : ''}${surface}`, { position: event.position, volume, speed });
  }

  dispose() {
    this._stopLoops(0);
    this.env.removeFromScene(this.model.object);
    for (const h of this.halos) this.env.removeFromScene(h);
  }
}

const _m = new THREE.Matrix4();
const _c = new THREE.Color();
