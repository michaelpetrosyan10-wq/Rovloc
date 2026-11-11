// CreatureView (Controllers/Characters/CreatureController.luau): draws and animates the Creature, the Tall Man.
//
//   * Rig: W1's skinned creature (the shadow body, the porcelain mask, the Neon pinpricks: one chunk per material,
//     one bone per vertex) through the engine's creature model (env: createCreatureModel): every frame the
//     ProceduralAnimator's bone frames drive its bones (bone world matrix = root world x the bone's rig-space frame).
//     Lit by the level's probe irradiance at its chest plus the torch and the point lights (the world material's
//     lighting, which look.js extends with the shadow body, the painted mask and the dissolve).
//   * The contract (R <-> A). Every frame readContract(snapshot) gives {state, speed, poseMode, action,
//     actionStartedAt, fade}: the service publishes them in snapshot() (A's behaviour); whatever it leaves out is
//     derived from today's state (the profile state from MonsterState + PoseMode, the measured speed, no contract
//     action, fade 0 while hidden). `state` and `poseMode` pick the profile state and the hunch; `speed` drives the
//     smoke; `action` (Stare, ReachIn, LookAway, FadeOut, FadeIn, Jumpscare) plays from `actionStartedAt` and a held one
//     (Stare, LookAway, ReachIn) is released when the action clears or changes; `fade` (1 whole .. 0 gone) drives the
//     dissolve. Optional `actionTarget` (a world point) aims ReachIn / Jumpscare; else the player's eye while it
//     targets them.
//   * The look target: the player's eye (the camera) while it targets them, measured from its eye point; with no
//     target the head scans by itself.
//   * LOD (ProceduralAnimator: DefaultNear 60, DefaultFar 180): within Near of the camera, or while it hunts the
//     player and is in view, the rig steps every frame; in view up to Far, every third frame; otherwise it is frozen.
//   * Actions: playAction(name, startAt) layers a one-shot (NeckSnap, Lunge, LockerRip, DoorSmash, Vanish, Reveal and
//     the contract's). Vanish dissolves it into static over its glitch; Reveal forms it out of static.
//   * Hidden / gone: fade 0 hides the whole rig; its loops are silenced.
//   * Smoke: wisps trail from the rig's smoke anchors (denser with speed) and the shroud hangs off its body from the
//     shoulders down; FadeOut / FadeIn throw a burst.
//   * The mask in the jumpscare (mask.js maskFx, from the Lunge's start): the cracks race, the slit tears into the
//     maw, strands stretch across it, the right pupil dilates, the room's light falls away; porcelain shards break off
//     as it tears (shards.js). Outside it, the hinge parting tears the slit a little (the stun's flail, the rip).
//   * Pinpricks: the painted pupils glow only within Look.glowFar of the camera, brighter in the dark (the additive
//     halos are off on every tier: no cute glowing dots).
//   * Audio: while in a duct (legacy), looped VentScrape + VentBreathing; footsteps at the feet from the animator's
//     plants (heavy and slow: low-pitched and loud); an occasional CreatureGrowl at the head while it chases, on fixed
//     time slots; CreatureVanish as it dissolves.

import * as THREE from 'three';
import { Animator, yawOf } from './animator.js';
import { CFrame } from './cframe.js';
import { CreatureConfig } from './config.js';
import { Look, applyCreatureLook } from './look.js';
import { maskFx } from './mask.js';
import * as Creature from './profile.js';
import { buildJointMap } from './rig.js';
import { Shards } from './shards.js';
import { Smoke } from './smoke.js';
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
const LOOP_FADE = 0.6;
const LOOP_VOLUME_FADE = 0.25;
const SCRAPE_QUIET = 0.3;
const BREATH_QUIET = 0.65;
const GROWL_SLOT = 4.5;
const GROWL_CHANCE = 0.65;
const HEAVY_SPEED = 0.52;
const HEAVY_SPRINT_SPEED = 0.6;
const HEAVY_VOLUME = 1.9;
const SKITTER_SPEED = 1.45;
const SKITTER_VOLUME = 0.6;
const DUPLICATE_WINDOW = 0.05;
const ANIM_NEAR = 60;
const ANIM_FAR = 180;
const REDUCED_EVERY = 3;
const HALO_SIZE = 0.16;
const HALO_OPACITY = 0.5;
const BURST_PUFFS = 34;
const QUADRUPED_STATES = new Set(['VentCrawl', 'VentRetreat']);
const CHASE_STATES = new Set(['WallChase', 'VentChase', 'Chase']);
const NO_FX = Object.freeze({ race: 0, tear: 0, strands: 0, dilate: 0, focus: 0, shatter: false });
const HINGE_TEAR = [0.044, 0.105]; // radians: the hinge parting this far tears the slit open (outside the jumpscare)
const HINGE_TEAR_MAX = 0.6;
const PUPIL_COLOR = new THREE.Color(...Look.pupilColor);
/** The contract's actions the view plays (anything else is ignored). */
export const ContractActions = Object.freeze(['Stare', 'ReachIn', 'LookAway', 'FadeOut', 'FadeIn', 'Jumpscare']);

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

/** The pinpricks' reach: full within Look.glowNear of the camera, gone past Look.glowFar. */
export function glowReach(distance) {
  return 1 - smoothstep(Look.glowNear, Look.glowFar, distance);
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

/** Footstep playback [speed, volume] for an animator plant: heavy and slow on two legs. */
export function footstepVoice(state, sprint, volume) {
  if (QUADRUPED_STATES.has(state)) return [SKITTER_SPEED, volume * SKITTER_VOLUME];
  return [sprint ? HEAVY_SPRINT_SPEED : HEAVY_SPEED, volume * HEAVY_VOLUME];
}

/**
 * The fade a contract action implies at `now` (FadeOut 1 -> 0 over Look.fadeOutSeconds, FadeIn 0 -> 1 over
 * Look.fadeInSeconds), or null for any other action.
 */
export function actionFade(action, startedAt, now) {
  if (!Number.isFinite(startedAt)) return null;
  const t = now - startedAt;
  if (action === 'FadeOut') return 1 - smoothstep(0, Look.fadeOutSeconds, t);
  if (action === 'FadeIn') return smoothstep(0, Look.fadeInSeconds, t);
  return null;
}

/**
 * The ONE function the view reads the Creature's per-frame state through (the R <-> A contract):
 * {state, speed, poseMode, action, actionStartedAt, fade}. The service's snapshot publishes these fields; any it
 * leaves out comes from today's snapshot: state = MonsterState, poseMode = the body's PoseMode (pose), speed = the
 * measured ground speed, action = null, fade = 0 while hidden (else 1, or what a playing FadeOut / FadeIn implies).
 * @param {any} snap the service's snapshot()
 * @param {{speed?: number, now?: number}} [derived] what the view measured
 */
export function readContract(snap, derived = {}) {
  const now = Number.isFinite(derived.now) ? derived.now : 0;
  const action = typeof snap.action === 'string' && ContractActions.includes(snap.action) ? snap.action : null;
  const actionStartedAt = action && Number.isFinite(snap.actionStartedAt) ? snap.actionStartedAt : null;
  let fade;
  if (Number.isFinite(snap.fade)) fade = clamp01(snap.fade);
  else {
    const implied = action ? actionFade(action, actionStartedAt ?? now, now) : null;
    fade = implied !== null ? implied : snap.hidden ? 0 : 1;
  }
  return {
    state: typeof snap.state === 'string' ? snap.state : 'Dormant',
    speed: Number.isFinite(snap.speed) ? snap.speed : derived.speed ?? 0,
    poseMode: typeof snap.poseMode === 'string' ? snap.poseMode : snap.pose || 'Biped',
    action,
    actionStartedAt,
    fade,
  };
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
    this.meta = meta;
    this.map = buildJointMap(meta.creature);
    this.animator = new Animator(this.map, Creature.Profile, { seed: CREATURE_SEED });
    this.animator.setGroundProbe((origin, direction) => env.monsterFloorProbe(origin, direction));
    this.animator.footstep.connect((event) => this._onFootstep(event));
    this.bones = meta.creature.bones.map((b) => b.name);
    if (typeof service.body.useRigMetrics === 'function') service.body.useRigMetrics(meta.creature);
    this.model = env.createCreatureModel();
    env.addToScene(this.model.object);
    this.look = applyCreatureLook(this.model, meta, this._budget());
    this.smoke = new Smoke(env.engine && env.engine.shared, CREATURE_SEED);
    env.addToScene(this.smoke.mesh);
    this.shards = new Shards(env.engine && env.engine.shared, 32);
    env.addToScene(this.shards.mesh);
    this.shattered = null;
    this.fx = NO_FX;
    /** Tools only: a fixed {race, tear, strands, dilate, focus} on the mask instead of the Lunge's. */
    this.fxOverride = null;
    this.jawRestInverse = this._jawRest(meta.creature);
    this.anchors = this._findAnchors(meta.creature);
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
    this.reach = 0;
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
    /** the contract action playing (and when it started) */
    this.contractAction = null;
    this.contractStart = null;
    this.contract = null;
    this.fade = 1;
    this.vanishing = null;
    this._writeBones(this.root);
    this._applyHidden(true);
  }

  _budget() {
    const q = this.env.engine && this.env.engine.quality;
    return q && q.budget ? q.budget : null;
  }

  _findAnchors(creature) {
    const out = [];
    for (const a of creature.attachments || []) {
      if (!/^Smoke/.test(a.name)) continue;
      const part = a.parent;
      if (!this.map.rest[part]) continue;
      const weight = a.attributes && Number.isFinite(a.attributes.SmokeWeight) ? a.attributes.SmokeWeight : 1;
      const shroud = !!(a.attributes && a.attributes.SmokeShroud);
      out.push({ name: a.name, part, local: CFrame.fromComponents(a.cframe).position, weight, shroud, position: new THREE.Vector3() });
    }
    return out;
  }

  _findPupils(creature) {
    const out = [];
    const head = creature.bones.find((b) => b.name === 'Head');
    for (const p of creature.parts || []) {
      if (p.name === 'LeftPupil' || p.name === 'RightPupil') out.push({ name: p.name, model: new THREE.Vector3(p.cf[0], p.cf[1], p.cf[2]) });
    }
    this.headIndex = this.bones.indexOf('Head');
    this.headRestInverse = head ? CFrame.fromComponents(head.rest).inverse() : new CFrame();
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
    const ok = Creature.playAction(this.map, name, at);
    if (ok) this._onActionStarted(name, at);
    return ok;
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
    const now = this.env.renderTime();
    const contract = readContract(snap, { speed: this.speed, now: service.now ? service.now() : now });
    this.contract = contract;
    this._syncContractAction(contract);
    const fade = this._visualFade(contract, snap, now);
    this.fade = fade;
    const shown = snap.running && fade > 0.002;
    this._applyHidden(!shown);
    this.look.setBudget(this._budget());
    if (!snap.running) {
      this._stopLoops(LOOP_FADE);
      this.smoke.clear();
      return;
    }
    this.root = this.prevRoot.lerp(this.currRoot, clamp01(alpha));
    const camera = this.env.cameraPosition();
    const distance = camera ? camera.distanceTo(this.root.position) : 0;
    // growl slots and the 10 Hz extras run whether or not the rig steps
    this._updateGrowl(snap, now);
    this.extrasClock += dt;
    if (this.extrasClock >= 1 / EXTRAS_HZ) {
      const step = this.extrasClock;
      this.extrasClock = 0;
      this._updateLoops(snap);
      if (distance <= ANIM_FAR) this._updatePupils(snap, step, distance);
      this.smoke.setTier(this.look.tierName);
    }
    this.fx = this._maskFx(now);
    this.look.set({ fade, time: now, pupil: this.glow * this.reach, fx: this.fx });
    this.smoke.step(Math.min(dt, 0.1));
    this.shards.step(Math.min(dt, 0.1));
    if (!shown) return;
    // LOD: animation only when near, or in view within Far (every frame while it hunts the player in view)
    const visible = this.env.inView(this.root.position, 7);
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
    this._feed(snap, contract, stepDt, now, camera);
    this.animator.step(stepDt, this.root);
    this.stepped = true;
    this._writeBones(this.root);
    if (visible || distance < 30) this._emitSmoke(stepDt, contract, fade);
  }

  /** The rest relation of the Jaw to the Head (its hinge's zero), inverted. */
  _jawRest(creature) {
    const head = creature.bones.find((b) => b.name === 'Head');
    const jaw = creature.bones.find((b) => b.name === 'Jaw');
    if (!head || !jaw) return null;
    return CFrame.fromComponents(head.rest).inverse().mul(CFrame.fromComponents(jaw.rest)).inverse();
  }

  /** How far the hinge stands open now (radians). */
  _jawAngle() {
    const head = this.animator.getPartFrame('Head');
    const jaw = this.animator.getPartFrame('Jaw');
    if (!head || !jaw || !this.jawRestInverse) return 0;
    return this.jawRestInverse.mul(head.inverse().mul(jaw)).toAxisAngle()[1] || 0;
  }

  /**
   * The mask's jumpscare (mask.js maskFx) through the Lunge: the race, the tear, the strands, the dilation, and the
   * shards thrown once as it tears; outside it, the hinge parting tears the slit a little (the stun's flail, the rip).
   */
  _maskFx(now) {
    if (this.fxOverride) return this.fxOverride; // tools: hold a moment of the jumpscare on the mask
    const lungeAt = Creature.actionStart(this.map, 'Lunge');
    if (lungeAt !== null && now >= lungeAt) {
      const fx = maskFx(now - lungeAt, Creature.ActionDurations.Lunge);
      if (fx.shatter && this.shattered !== lungeAt && now - lungeAt < 0.9) {
        this.shattered = lungeAt;
        this._shatter();
      }
      return fx;
    }
    if (!this.stepped) return NO_FX;
    const tear = HINGE_TEAR_MAX * smoothstep(HINGE_TEAR[0], HINGE_TEAR[1], this._jawAngle());
    return tear > 0 ? { race: 0, tear, strands: tear * 0.5, dilate: 0, focus: 0, shatter: false } : NO_FX;
  }

  /** Porcelain breaks off round the maw as it tears, thrown toward whoever it faces. */
  _shatter() {
    const face = this.faceWorld();
    if (!face) return;
    const count = this.look.tier.shards || 0;
    if (count <= 0) return;
    const points = [];
    for (const [x, y] of [[-0.06, -0.3], [0.08, -0.28], [0.02, -0.22], [-0.04, -0.42], [0.06, -0.48], [0.1, -0.36], [-0.1, -0.36]]) {
      points.push(face.pointToWorld(new THREE.Vector3(x, y, -0.02)));
    }
    const out = face.lookVector;
    this.shards.burst(points, out, face.rightVector, face.upVector, count);
  }

  /** Starts / releases the contract's action when it changes. */
  _syncContractAction(contract) {
    const name = contract.action;
    const start = contract.actionStartedAt;
    if (name === this.contractAction && (start === this.contractStart || start === null)) return;
    const now = this.service.now ? this.service.now() : this.env.renderTime();
    if (this.contractAction && Creature.isHeld(this.contractAction)) Creature.releaseAction(this.map, this.contractAction, now);
    this.contractAction = name;
    this.contractStart = start;
    // the catch's Lunge is already playing from the handler's schedule (startAt = now + OneShotLead): keep its timing
    if (name === 'Jumpscare' && Creature.actionStart(this.map, 'Lunge') !== null) return;
    if (name) this.playAction(name === 'Jumpscare' ? 'Lunge' : name, start ?? now);
  }

  /** The dissolve's fade: the contract's, with the legacy Vanish / Reveal glitches dissolving too. */
  _visualFade(contract, snap, now) {
    let fade = contract.fade;
    if (Number.isFinite(snap.fade)) return fade;
    const vanish = Creature.actionStart(this.map, 'Vanish');
    if (vanish !== null && now >= vanish) fade = Math.min(fade, 1 - smoothstep(0.04, Creature.ActionDurations.Vanish, now - vanish));
    const reveal = Creature.actionStart(this.map, 'Reveal');
    if (reveal !== null && now >= reveal && !snap.hidden) fade = Math.min(fade, smoothstep(0, 0.22, now - reveal));
    return fade;
  }

  _onActionStarted(name, at) {
    if (name === 'FadeOut' || name === 'FadeIn' || name === 'Vanish') {
      const late = this.env.renderTime() - at;
      if (late > 0.5) return;
      this._burst(name === 'FadeIn' ? 0.7 : 1);
      if (name === 'FadeOut' && !this.hidden) {
        const head = this.animator.getPartFrame('Head');
        const position = head ? this.root.mul(head).position : this.root.position;
        this.env.play('CreatureVanish', { position });
      }
    }
  }

  _burst(scale) {
    // from where the body is now (a FadeIn follows a teleport): the bones and the anchors on the latest root
    const root = this.currRoot;
    const points = [];
    const frames = this.animator.frames;
    for (const name of this.bones) {
      const f = frames[name];
      if (f && name !== this.map.rootName) points.push(root.mul(f).position);
    }
    for (const a of this.anchors) {
      const f = frames[a.part];
      if (f) points.push(root.mul(f).pointToWorld(a.local));
    }
    const centre = root.position.clone().add(new THREE.Vector3(0, 2, 0));
    this.smoke.burst(points, centre, BURST_PUFFS * scale);
  }

  _emitSmoke(dt, contract, fade) {
    const frames = this.animator.frames;
    for (const a of this.anchors) {
      const f = frames[a.part];
      if (f) this.root.mul(f).pointToWorld(a.local, a.position);
    }
    const speed = Number.isFinite(contract.speed) ? Math.max(contract.speed, this.speed) : this.speed;
    _vel.copy(this.velocity).setLength(speed > 1e-3 ? speed : 0);
    this.smoke.emit(this.anchors, _vel, dt, fade);
  }

  _feed(snap, contract, dt, now, camera) {
    const map = this.map;
    const state = Creature.resolveState(contract.state, contract.poseMode, snap.inVent);
    const hunch = Creature.hunchFor(contract.poseMode);
    const position = this.root.position;
    const last = this.lastPosition;
    this.lastPosition = position.clone();
    const displacement = last ? position.clone().sub(last) : new THREE.Vector3();
    const raw = estimateVelocity(displacement, dt);
    this.velocity.lerp(raw, damp(VELOCITY_DAMP, dt));
    this.speed = Math.hypot(this.velocity.x, this.velocity.z);
    const grounded = QUADRUPED_STATES.has(state) ? true : this.service.body.anchored || this.service.body.grounded;
    let yaw = null;
    let pitch = null;
    const eyeHeight = this._eyeHeight(contract.poseMode);
    if (snap.targetingPlayer && camera) {
      const eye = new THREE.Vector3(position.x, position.y + eyeHeight, position.z);
      const delta = camera.clone().sub(eye);
      if (delta.length() > 1e-3) ({ yaw, pitch } = yawPitchFromVector(delta));
    }
    // the look target (rig space) for the jumpscare and the reach: the contract's point, else the player's eye
    const target = snap.actionTarget && Number.isFinite(snap.actionTarget.x) ? snap.actionTarget : this.env.playerEye ? this.env.playerEye() : camera;
    Creature.setLookTarget(map, target ? this.root.pointToObject(target, _target) : null);
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

  /** The eye's height over the root for a PoseMode (the rig's metrics, else CreatureConfig). */
  _eyeHeight(poseMode) {
    const c = this.meta.creature;
    const fromRig = c && c.eyeHeightAboveRoot && c.eyeHeightAboveRoot[poseMode];
    if (Number.isFinite(fromRig)) return fromRig;
    return CreatureConfig.EyeHeightAboveRoot[poseMode] ?? CreatureConfig.EyeHeightAboveRoot.Biped;
  }

  _writeBones(root) {
    const frames = this.animator.frames;
    for (let i = 0; i < this.bones.length; i++) {
      const frame = frames[this.bones[i]];
      if (!frame) continue;
      this.model.setBoneWorld(i, root.mul(frame).toMatrix4(_m));
    }
    const chest = frames.UpperTorso ? root.mul(frames.UpperTorso).position : root.position;
    const probe = this.env.probeAt(chest, _c);
    this.model.setLight(probe);
    this.smoke.setProbe(probe);
    this.shards.setProbe(probe);
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

  _updatePupils(snap, dt, distance) {
    let ex = 0;
    if (!snap.inVent) ex = exposure(snap.eye, this._lightSamples(snap.levelId, snap.eye));
    const target = 0.45 + 0.55 * pupilGlow(snap.inVent, ex);
    this.glow = dampNumber(this.glow, target, PUPIL_SPEED, dt);
    this.reach = glowReach(distance);
    const [, scale] = pupilLook(this.glow);
    const strength = this.glow * this.reach * this.fade;
    for (const h of this.halos) {
      h.material.opacity = HALO_OPACITY * strength;
      h.visible = !this.hidden && strength > 0.01 && this.look.tier.halos;
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
    if (this.hidden || this.fade < 0.5) return;
    const surface = this.env.surfaceAt(event.position);
    const [speed, volume] = footstepVoice(event.state, event.sprint, event.volume);
    this.env.play(`Footstep${event.sprint ? 'Sprint' : ''}${surface}`, { position: event.position, volume, speed });
  }

  dispose() {
    this._stopLoops(0);
    this.env.removeFromScene(this.model.object);
    this.env.removeFromScene(this.smoke.mesh);
    this.smoke.dispose();
    this.env.removeFromScene(this.shards.mesh);
    this.shards.dispose();
    for (const h of this.halos) this.env.removeFromScene(h);
  }
}

const _m = new THREE.Matrix4();
const _c = new THREE.Color();
const _vel = new THREE.Vector3();
const _target = new THREE.Vector3();
