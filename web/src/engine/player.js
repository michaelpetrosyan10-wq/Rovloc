// Player: the local player's body, MoveState machine, meters and first-person camera — PlayerStateService (the
// authority) and FirstPersonController (MovementController, CameraRig, CameraStates, ViewBob, CameraStack, Flashlight,
// HandRig, PanicVFX) in one, since single-player needs no prediction or reconciliation.
//
// MoveState (deriveState). A held override wins, highest first: Scripted > Trapped > Hiding > Parachuting >
// DownedCrawling (pushOverride / popOverride by token). Then a leap under way is Leaping and a slide Sliding (parkour.js:
// the slide, the leap, hard landings and the look-back). Otherwise the mode decides (setMode: OnFoot / Vent), with
// canSprint = sprint held && stamina > 0 && not exhausted:
//   OnFoot  Crouching if crouch; Sprinting if canSprint && moving (>= 4 studs/s or move input > 0.1); else Standing
//   Vent    VentScurrying if canSprint, else VentCrawling
// Exhaustion latch: set when stamina hits 0 with sprint held, cleared by releasing sprint or a full meter.
// WalkSpeed per state (GameConfig). Sprinting out of a crouch stands up. Changing mode clears the crouch.
//
// The body moves on the fixed 30 Hz tick, never per rendered frame (tick): crouch toggles and the jump press are
// latched by the input handlers and consumed at the next tick (a press shorter than a frame or a tick is never lost;
// one still pending when its action stops being live, as when the pause menu opens, is dropped; a held jump also
// jumps again on landing, like a Humanoid), MoveState is derived, then the body advances in SUBSTEPS
// substeps of 1/60 s (the walking physics, or the strongest motion override: vent rail, parachute), the wish direction read from the yaw and the move input at the tick. Everything gameplay reads (the root,
// speed, moving, grounded, footstep noise, landings, stamina) is that tick state. The frame draws the root
// interpolated between the last two tick states by loop.alpha (drawnRoot); a teleport or any move made outside a
// tick snaps the drawn root to it.
//
// Meters (active only while `metersActive`: a run is live and the player Alive / Downed; otherwise held full):
//   stamina  drains per state (Sprinting, VentScurrying: StaminaDrain); StaminaRegenDelay after draining stops (or a
//            spend) it regenerates at StaminaRegen.
//   battery  drains while the torch is lit (FlashlightService); pickups add (addBattery); max can be raised (perk).
//
// Camera (per frame; the view's yaw is the look's turned by the look-back, a hard landing dips the eye):
// look input -> pitch range of the camera state -> eye = spring-smoothed root height + the
// neck-pivot eye + the state offset (spring) -> panic + bob + shake -> FOV (base + sprint + panic + heartbeat warp)
// -> camera overrides (setCameraOverride, priority-blended) -> the camera. A ray from the root pulls the eye in front
// of walls. ControlLocks (lock(reason)) anchor the body and ignore movement input; "Jumpscare" / "Cutscene" locks
// also freeze the look.

import * as THREE from 'three';
import { CameraStack, CameraStates, CameraRig, LookInput, ViewBob, applyPitch, eyeOffset, settlePitch } from './camera.js';
import { CameraConfig, GameConfig, MaterialSurface, OverridePriority, StaminaDrain, WalkSpeeds, PhysicsConfig } from './config.js';
import { Flashlight } from './flashlight.js';
import { clamp01, dampNumber, NumberSpring, VectorSpring, toMatrix, wrapAngle, yawPitchFromVector } from './math.js';
import { PanicFx } from './panic.js';
import { Parkour } from './parkour.js';
import { CharacterBody, CrouchHeight, ROOT_ABOVE_FEET } from './physics.js';
import { Signal } from './signal.js';
import { Viewmodel } from './viewmodel.js';

const OVERRIDE_RANK = Object.fromEntries(OverridePriority.map((s, i) => [s, OverridePriority.length - i]));
const MODE_OF = { VentCrawling: 'Vent', VentScurrying: 'Vent' };
const NO_JUMP = new Set(['VentCrawling', 'VentScurrying', 'DownedCrawling', 'Hiding', 'Trapped', 'Sliding', 'Leaping']);
/** The MoveStates with the crouched body (3.7 tall: crawlways, slide bars). */
const LOW_BODY = new Set(['Crouching', 'Sliding']);
const FOOTSTEPS = { Standing: 1, Sprinting: 1, Crouching: 0.45, Scripted: 0.8 };
const SELF_FOOTSTEP_VOLUME = 0.55;
const SELF_MOVE_VOLUME = 0.9;
const MOVING_SPEED = 4;
const MOVE_DIRECTION_MIN = 0.1;
const HEIGHT_SPEED = 26;
const HEIGHT_SPEED_AIR = 60;
const MAX_HEIGHT_LAG = 0.9;
const OFFSET_SPEED = 11;
const SNAP_DISTANCE = 8;
const MIN_EYE_ABOVE_FLOOR = 0.6;
const CAMERA_SKIN = 0.25;
const COLLISION_RELEASE = 6;
const EXERTION_BELOW = 0.45;
const NOISE_HZ = 10;
/** Physics substeps per 30 Hz tick: the body steps at 1/60 s. */
export const SUBSTEPS = 2;

/** A meter: value in [0, max] and its listeners. */
export class Meter {
  constructor(max) {
    this.max = max;
    this.value = max;
    /** @type {Signal<[number, number]>} (value, max) after a discrete change */
    this.changed = new Signal();
  }

  get fraction() {
    return this.max > 0 ? clamp01(this.value / this.max) : 0;
  }

  set(value) {
    this.value = Math.min(this.max, Math.max(0, value));
    this.changed.fire(this.value, this.max);
  }

  add(delta) {
    if (!Number.isFinite(delta) || delta === 0) return;
    this.set(this.value + delta);
  }

  setMax(max, keepFraction = false) {
    const f = this.fraction;
    this.max = Math.max(0, max);
    this.value = keepFraction ? f * this.max : Math.min(this.value, this.max);
    this.changed.fire(this.value, this.max);
  }
}

export class Player {
  /** @param {import('./index.js').Engine} engine */
  constructor(engine) {
    this.engine = engine;
    const { world, input, audio, settings, quality, renderer, shared } = engine;
    this.world = world;
    this.input = input;
    this.audio = audio;
    this.settings = settings;
    this.body = new CharacterBody(world);
    this.meters = {
      stamina: new Meter(GameConfig.StaminaMax),
      battery: new Meter(GameConfig.BatteryMax),
    };
    this.metersActive = false;
    /** @type {Signal<[string, string]>} (new, old) */
    this.moveStateChanged = new Signal();
    /** @type {Signal<[THREE.Vector3, string, boolean]>} (position, surface, sprint) */
    this.footstep = new Signal();
    /** @type {Signal<[]>} */
    this.landed = new Signal();
    /** @type {Signal<[]>} a slide started (parkour.js) */
    this.slid = new Signal();
    /** @type {Signal<[import('./parkour.js').Strip, number]>} a leap started (the strip, the take-off before its lip) */
    this.leapt = new Signal();
    /** @type {Signal<[number]>} a hard landing (the fall in studs) */
    this.hardLanded = new Signal();

    this.mode = 'OnFoot';
    /** @type {Map<string, string>} */
    this.overrides = new Map();
    this.intent = { crouch: false, sprint: false };
    this.exhausted = false;
    this.moveState = 'Standing';
    this.moving = false;
    this.speed = 0;
    this.drainEndedAt = null;
    /** @type {Map<string, true>} ControlLock reasons */
    this.locks = new Map();
    /** 'Lobby' | 'Alive' | 'Downed' | 'Dead' | 'Spectating' (LifeStateService's attribute; W4 writes it) */
    this.lifeState = 'Lobby';
    this.inLobby = false;

    // look and camera
    this.yaw = 0;
    this.pitch = 0;
    /** the view's yaw this frame: the look turned by the look-back */
    this.viewYaw = 0;
    this.lookInput = new LookInput();
    this.bob = new ViewBob();
    this.stack = new CameraStack();
    this.forcedStates = new Map();
    this.forceOrder = 0;
    this.pitchMin = null;
    this.pitchMax = null;
    this.cameraState = 'Standing';
    this.heightSpring = new NumberSpring(0, HEIGHT_SPEED, 1);
    this.offsetSpring = new VectorSpring(new THREE.Vector3(), OFFSET_SPEED, 1);
    this.eyePosition = new THREE.Vector3();
    this.eyeQuat = new THREE.Quaternion();
    this.lastRoot = null;
    this.snapNext = true;
    this.collisionDistance = Infinity;
    this.fov = CameraConfig.FieldOfView.Base;
    this.cameraEnabled = true;
    /** @type {Map<string, {fn: Function, priority: number}>} */
    this.motionOverrides = new Map();
    this.noiseClock = 0;
    this.wasGrounded = true;
    this.jumpHeld = false;
    /** A Jump press since the last tick (consumed by the tick, so a press shorter than a tick still jumps). */
    this.jumpLatched = false;
    /** Crouch toggle presses since the last tick (an odd count toggles the crouch at the tick). */
    this.crouchPresses = 0;
    /** The root at the start and at the end of the last tick (the tick states the frame draws between). */
    this.tickPrevious = new THREE.Vector3();
    this.tickCurrent = new THREE.Vector3();
    /** The drawn root this frame: the tick states interpolated by loop.alpha. */
    this.drawnRoot = new THREE.Vector3();

    this.panic = new PanicFx({ world, audio });
    this.flashlight = new Flashlight({ shared, audio, scene: world.scene, meters: this.meters, settings, quality });
    this.viewmodel = new Viewmodel({ shared, scene: renderer.viewScene });
    /** the slide, the leap, hard landings and the look-back (parkour.js) */
    this.parkour = new Parkour(this);

    input.on('Sprint', (phase) => this._setSprint(phase === 'Begin'));
    input.on('Crouch', (phase) => {
      if (phase === 'Begin' && !this.isLocked()) this.crouchPresses++;
    });
    input.on('Flashlight', (phase) => {
      if (phase === 'Begin' && this.isAlive()) this.flashlight.toggle(engine.loop.realTime);
    });
    input.on('Jump', (phase) => {
      this.jumpHeld = phase === 'Begin';
      if (phase === 'Begin') this.jumpLatched = true;
    });
    // a press still waiting for its tick is void once its action is no longer live (the pause menu opened, a cutscene
    // or a locker took the controls): the input layer ends held actions on a context change the same way, and a jump
    // pressed just before the pause must not fire when the game resumes
    input.contextChanged.connect(() => {
      if (!input.isLive('Jump')) this.jumpLatched = false;
      if (!input.isLive('Crouch')) this.crouchPresses = 0;
    });
  }

  // ------------------------------------------------------------------ public API

  /** Holds `state` (an override MoveState) under `token`. */
  pushOverride(token, state) {
    if (!OVERRIDE_RANK[state]) {
      console.warn('[player] not an override state', state);
      return;
    }
    this.overrides.set(token, state);
  }

  popOverride(token) {
    this.overrides.delete(token);
  }

  /** The winning override (or null). */
  getOverride() {
    let best = null;
    let rank = 0;
    for (const s of this.overrides.values()) {
      if (OVERRIDE_RANK[s] > rank) {
        rank = OVERRIDE_RANK[s];
        best = s;
      }
    }
    return best;
  }

  /** Base locomotion mode: 'OnFoot' | 'Vent'. */
  setMode(mode) {
    if (!['OnFoot', 'Vent'].includes(mode) || mode === this.mode) return;
    this.mode = mode;
    this.intent.crouch = false;
    this.crouchPresses = 0;
    this.body.shape = mode === 'Vent' ? 'Ball' : 'Biped';
    this.body.gravity = mode === 'OnFoot';
  }

  /** ControlLock: anchors the body and ignores movement input while any reason is held. */
  lock(reason = 'Anchor') {
    this.locks.set(reason, true);
    this.body.anchored = true;
    this.intent.sprint = false;
  }

  unlock(reason = 'Anchor') {
    this.locks.delete(reason);
    this.body.anchored = this.locks.size > 0;
  }

  isLocked() {
    return this.locks.size > 0;
  }

  isAlive() {
    return this.lifeState === 'Alive' || this.lifeState === 'Lobby' || this.lifeState === 'Downed';
  }

  /** LifeStateService's state as the game sets it: 'Lobby' | 'Alive' | 'Downed' | 'Dead' | 'Spectating'. */
  setLifeState(state) {
    this.lifeState = state;
    if (state === 'Downed') this.pushOverride('LifeState', 'DownedCrawling');
    else this.popOverride('LifeState');
  }

  /** Whether the meters run (a run is live and the player takes part). Inactive meters are held full. */
  setMetersActive(active) {
    this.metersActive = !!active;
    if (!active) {
      this.meters.stamina.set(this.meters.stamina.max);
      this.exhausted = false;
      this.drainEndedAt = null;
    }
  }

  /**
   * Moves the root (HumanoidRootPart centre) to a CFrame and faces its look direction.
   * @param {THREE.Matrix4|number[]|{position: any, yaw?: number}} cframe
   */
  teleport(cframe) {
    const m = toMatrix(cframe, _m);
    _v.setFromMatrixPosition(m);
    this.parkour.reset();
    this.body.teleport(_v);
    this._snapDrawn();
    _d.set(-m.elements[8], -m.elements[9], -m.elements[10]);
    if (_d.lengthSq() > 1e-6) {
      this.yaw = yawPitchFromVector(_d).yaw;
      this.pitch = 0;
    }
    this.snapNext = true;
    this.lastRoot = null;
    this.world.lastZone = null;
    if (this.engine.lighting) this.engine.lighting.snapFilm();
    if (this.engine.volumetrics) this.engine.volumetrics.snapNow();
  }

  /** Root (HumanoidRootPart centre) position: the tick state (what gameplay reads). */
  rootPosition() {
    return this.body.position;
  }

  /** Feet position (on the floor). */
  feetPosition(out = new THREE.Vector3()) {
    return out.set(this.body.position.x, this.body.feetY, this.body.position.z);
  }

  /** The eye this frame, from the drawn root (no bob, shake or overrides). */
  eye(out = new THREE.Vector3()) {
    return out.copy(this.eyePosition);
  }

  /** The look: yaw (0 faces -Z), pitch (up positive) and the unit direction. */
  look() {
    const cp = Math.cos(this.pitch);
    return {
      yaw: this.yaw,
      pitch: this.pitch,
      direction: new THREE.Vector3(-Math.sin(this.yaw) * cp, Math.sin(this.pitch), -Math.cos(this.yaw) * cp),
    };
  }

  setLook(yaw, pitch) {
    if (!Number.isFinite(yaw) || !Number.isFinite(pitch)) return;
    this.yaw = wrapAngle(yaw);
    this.pitch = Math.max(-1.553, Math.min(1.553, pitch));
  }

  /**
   * A camera override layer (Cutscene > Jumpscare > Spectating > Trapped by default priority).
   * `fn()` returns the camera frame each frame: a Matrix4, 12 CFrame numbers, {position, quaternion} or
   * {position, lookAt}; it may carry `fov`. null removes (blends out) the layer.
   * @param {string} token
   * @param {Function|null} fn
   * @param {number|{priority?: number, fov?: number, blendIn?: number, blendOut?: number}} [priority]
   */
  setCameraOverride(token, fn, priority) {
    this.stack.set(token, fn, priority);
  }

  /** Pins a camera state (LockerPeeking, ParachuteLookback, ...) under `token`; null releases it. */
  forceCameraState(token, state) {
    if (!state) this.forcedStates.delete(token);
    else this.forcedStates.set(token, { state, order: ++this.forceOrder });
  }

  /** Overrides the camera state's pitch range (degrees); null restores a bound. */
  setPitchLimits(minDeg, maxDeg) {
    this.pitchMin = Number.isFinite(minDeg) ? Math.max(-89, Math.min(89, minDeg)) : null;
    this.pitchMax = Number.isFinite(maxDeg) ? Math.max(-89, Math.min(89, maxDeg)) : null;
  }

  /** A shake impulse (degrees, seconds). */
  shake(amplitudeDeg, seconds) {
    this.bob.shake(amplitudeDeg, seconds);
  }

  /** Hand pose: Flashlight (default), Free, Pry, Ripcord, SlitGrip, Flask (target frame for all but the first two). */
  setHandPose(pose, target) {
    this.viewmodel.setPose(pose, target ? toMatrix(target) : null);
  }

  /**
   * Replaces the walking physics while held (vent rails, the parachute). `fn(dt, player)` moves the
   * body itself (player.body.move(delta) collides; body.position.copy() teleports). Highest priority wins. It runs
   * inside the 30 Hz tick, once per physics substep (dt = 1/60 s), never per rendered frame.
   */
  setMotionOverride(token, fn, priority = 0) {
    if (!fn) this.motionOverrides.delete(token);
    else this.motionOverrides.set(token, { fn, priority });
  }

  addStamina(delta) {
    if (!this.metersActive) return;
    this.meters.stamina.add(delta);
    if (delta < 0) this.drainEndedAt = this.engine.loop.time;
  }

  refillStamina() {
    if (this.metersActive) this.meters.stamina.set(this.meters.stamina.max);
  }

  addBattery(delta) {
    this.meters.battery.add(delta);
  }

  /** A noise pulse of the player's own body at the feet (a slide, a landing), heard as the locomotion is. */
  emitNoise(kind) {
    if (!this.isAlive() || this.lifeState === 'Lobby' || this.inLobby) return null;
    const zone = this.world.zoneAt(this.body.position);
    const level = zone ? zone.level : this.world.levelAt(this.body.position);
    return this.engine.noise.emit(this.feetPosition(_f), kind, { source: 'player', level });
  }

  /** One of the body's own sounds (the slide's scrape, the leap's whoosh, a hard landing). */
  playSound(preset) {
    if (this.audio) this.audio.play(preset, { volume: SELF_MOVE_VOLUME });
  }

  /** The footstep surface under the feet (the zone's surface, the floor material, else Concrete). */
  surfaceAt(position) {
    const zone = this.world.zoneAt(position);
    if (zone && zone.surface) return zone.surface;
    const hit = this.world.raycast(_o.set(position.x, position.y + 0.5, position.z), _down, 1.5);
    if (hit && hit.material && this.world.data.materials[hit.material]) {
      const info = this.world.data.materials[hit.material];
      if (info.surface) return info.surface;
      if (info.material && MaterialSurface[info.material]) return MaterialSurface[info.material];
    }
    return 'Concrete';
  }

  // ------------------------------------------------------------------ simulation

  _setSprint(held) {
    if (held && this.isLocked()) return;
    this.intent.sprint = held;
    if (held && this.intent.crouch && this.moving) this.intent.crouch = false;
  }

  _derive() {
    const override = this.getOverride();
    if (override) return override;
    if (this.parkour.leap) return 'Leaping';
    if (this.parkour.slide) return 'Sliding';
    const st = this.meters.stamina;
    const canSprint = this.intent.sprint && st.value > 0 && !this.exhausted;
    if (this.mode === 'Vent') return canSprint ? 'VentScurrying' : 'VentCrawling';
    if (this.intent.crouch) return 'Crouching';
    // under a low ceiling (a crawlway) a crouched body cannot stand up: it stays crouched until there is room
    if (this.moveState === 'Crouching' && this.mode === 'OnFoot' && !this.body.headroom()) {
      this.intent.crouch = true;
      return 'Crouching';
    }
    return canSprint && this.moving ? 'Sprinting' : 'Standing';
  }

  /**
   * Fixed 30 Hz: the latched presses (a Crouch press starts a slide or toggles the crouch; the Jump press is read
   * against the leap strips and may start a leap), meters, MoveState, the body's motion, landings, locomotion noise.
   */
  tick(dt) {
    const now = this.engine.loop.time;
    const st = this.meters.stamina;
    // sprinting: at a sprint since the last tick, Sprint still held
    const sprinting = this.moveState === 'Sprinting' && this.input.isHeld('Sprint') && !this.isLocked();
    if (this.crouchPresses % 2 === 1 && !this.parkour.crouchPress(sprinting)) {
      this.intent.crouch = !this.intent.crouch;
    }
    this.crouchPresses = 0;
    const sprintHeld = this.input.isHeld('Sprint') && !this.isLocked();
    if (!sprintHeld) this.intent.sprint = false;
    if (this.metersActive) {
      // exhaustion latch (PlayerStateService.updateExhausted)
      if (!this.intent.sprint || st.value >= st.max) this.exhausted = false;
      else if (st.value <= 0) this.exhausted = true;
      const drain = StaminaDrain[this.moveState] || 0;
      if (drain > 0) {
        st.value = Math.max(0, st.value - drain * dt);
      } else if (st.value < st.max) {
        const regenAt = this.drainEndedAt === null ? now : this.drainEndedAt + GameConfig.StaminaRegenDelay;
        if (now >= regenAt) st.value = Math.min(st.max, st.value + GameConfig.StaminaRegen * dt);
      }
    }
    const press = this.jumpLatched;
    this.jumpLatched = false;
    const wantsJump = this.parkour.beforeMove(now, press, this.jumpHeld);
    const next = this._derive();
    if (next !== this.moveState) {
      const prev = this.moveState;
      if ((StaminaDrain[prev] || 0) > 0 && !(StaminaDrain[next] > 0)) this.drainEndedAt = now;
      this.moveState = next;
      this.moveStateChanged.fire(next, prev);
    }
    // the crouched and the sliding body are shorter (crawlways, slide bars): physics.js CrouchHeight
    this.body.height = LOW_BODY.has(this.moveState) ? CrouchHeight : PhysicsConfig.BodyHeight;
    const jump = wantsJump && !this.isLocked() && !NO_JUMP.has(this.moveState) && this.lifeState !== 'Downed';
    const driven = this._simulate(dt, jump, now);
    this.parkour.afterMove(now, dt, driven);
    this.noiseClock += dt;
    if (this.noiseClock >= 1 / NOISE_HZ) {
      this.noiseClock = 0;
      const zone = this.world.zoneAt(this.body.position);
      const level = zone ? zone.level : this.world.levelAt(this.body.position);
      this.inLobby = level === 'Lobby';
      if (this.isAlive() && this.lifeState !== 'Lobby') {
        this.engine.noise.sampleLocomotion(this.feetPosition(_f), this.moveState, this.speed,
          { inLobby: this.inLobby, level });
      }
    }
  }

  /**
   * The body's motion for one tick, in SUBSTEPS substeps: the strongest motion override (the leap's among them), else
   * the slide (its speed profile and steering), else the walking physics (the wish from the yaw and the move input at
   * this tick, slowed by a hard landing; the jump), else the Vent mode without a driver. Then the tick's speed, moving
   * and landing, and the tick states the frame interpolates between. Returns whether a motion override other than the
   * leap moved the body.
   */
  _simulate(dt, jump, now) {
    const body = this.body;
    const locked = this.isLocked();
    const state = this.moveState;
    // the state before this tick: the last tick's end, or wherever the body was put since (teleports, scripts)
    this.tickPrevious.copy(body.position);
    const mv = locked || !this.isAlive() ? { x: 0, y: 0 } : this.input.moveVector();
    const sy = Math.sin(this.yaw);
    const cy = Math.cos(this.yaw);
    const speedCap = (WalkSpeeds[state] ?? GameConfig.WalkSpeed) * this.parkour.speedFactor(now);
    _wish.set((-sy * mv.y + cy * mv.x) * speedCap, 0, (-cy * mv.y - sy * mv.x) * speedCap);
    // the slide steers toward the move input's heading (a yaw), none without input
    const steer = Math.hypot(mv.x, mv.y) > MOVE_DIRECTION_MIN ? Math.atan2(-_wish.x, -_wish.z) : null;
    const sub = dt / SUBSTEPS;
    let driven = false;
    for (let i = 0; i < SUBSTEPS; i++) {
      // a driver may end itself mid-tick: the next substep walks
      let driver = null;
      let token = null;
      for (const [t, d] of this.motionOverrides) {
        if (!driver || d.priority > driver.priority) {
          driver = d;
          token = t;
        }
      }
      if (driver) {
        driver.fn(sub, this);
        if (token !== 'Leap') driven = true;
      } else if (this.parkour.slide && this.mode === 'OnFoot') {
        const slide = this.parkour.slideWish(this.parkour.slide.ticks * SUBSTEPS + i, sub, steer, _slideWish);
        body.step(sub, slide, { accel: Infinity });
      } else if (this.mode === 'OnFoot') body.step(sub, _wish, { jump: jump && body.grounded });
      // Vent without a driver: move along the look (the game's vent rail driver replaces this)
      else body.step(sub, _wish, { accel: 10 });
    }
    const moved = _d.subVectors(body.position, this.tickPrevious);
    this.speed = body.anchored ? 0 : Math.hypot(moved.x, moved.z) / dt;
    this.moving = this.speed >= MOVING_SPEED || Math.hypot(mv.x, mv.y) > MOVE_DIRECTION_MIN;
    if (body.grounded && !this.wasGrounded) this.landed.fire();
    this.wasGrounded = body.grounded;
    this.tickCurrent.copy(body.position);
    return driven;
  }

  /** The drawn root jumps to the body (a teleport): no interpolation from where it was. */
  _snapDrawn() {
    this.tickPrevious.copy(this.body.position);
    this.tickCurrent.copy(this.body.position);
    this.drawnRoot.copy(this.body.position);
  }

  /** Per frame: the drawn root, camera, hands, torch, panic. The body itself moves on the tick (tick / _simulate). */
  frame(dt, camera) {
    if (dt <= 0) dt = 1e-4;
    const input = this.input;
    const engine = this.engine;
    const ctxName = input.getContext();
    const state = this.moveState;

    // the drawn root: between the last two tick states; a body moved outside a tick is drawn where it is
    if (!this.body.position.equals(this.tickCurrent)) this._snapDrawn();
    else this.drawnRoot.lerpVectors(this.tickPrevious, this.tickCurrent, engine.loop.alpha);

    // camera state and pitch range
    let forced = null;
    let order = -1;
    for (const f of this.forcedStates.values()) if (f.order > order) {
      order = f.order;
      forced = f.state;
    }
    this.cameraState = forced || CameraStates.fromMoveState(state);
    const lim = CameraStates.pitchLimits(this.cameraState);
    let minP = ((this.pitchMin ?? lim[0]) * Math.PI) / 180;
    let maxP = ((this.pitchMax ?? lim[1]) * Math.PI) / 180;
    if (minP > maxP) [minP, maxP] = [maxP, minP];

    // look
    const raw = input.consumeLook();
    const lookAllowed = this.cameraEnabled && ctxName !== 'Menu' && ctxName !== 'Cutscene' &&
      !input.isCursorFree() && !this.locks.has('Jumpscare') && !this.locks.has('Cutscene') &&
      (input.device !== 'KeyboardMouse' || input.pointerLocked || raw.mouse.x !== 0 || raw.mouse.y !== 0);
    if (lookAllowed) {
      const s = this.settings;
      const d = this.lookInput.consume(dt, raw, {
        mouse: s.get('MouseSensitivity'), gamepad: s.get('GamepadSensitivity'), touch: s.get('TouchSensitivity'),
        invertY: s.get('InvertY'),
      });
      this.yaw = wrapAngle(this.yaw + d.yaw);
      this.pitch = applyPitch(this.pitch, d.pitch, minP, maxP);
    } else {
      this.lookInput.reset();
    }
    this.pitch = settlePitch(this.pitch, minP, maxP, dt);
    // the view's yaw: the look, turned by the look-back (movement keeps the look's heading)
    this.viewYaw = wrapAngle(this.yaw + this.parkour.lookYaw(engine.loop.alpha));

    // eye (a hard landing dips it)
    const motionScale = clamp01(this.settings.get('MotionScale'));
    this._computeEye(dt, state, forced);
    this.eyePosition.y += this.parkour.dip(engine.loop.time) * motionScale;
    const dead = this.lifeState === 'Dead' || this.lifeState === 'Spectating';

    // panic + bob
    this.panic.sense(dt, dead ? null : this.eyePosition);
    const level = this.panic.step(dt, this.lifeState === 'Downed');
    const bob = this.bob.step(dt, {
      speed: dead ? 0 : this.speed,
      profile: CameraStates.bob(state),
      panic: level,
      motionScale,
      chase: this.panic.chased ? level : 0,
      grounded: this.body.grounded || this.mode !== 'OnFoot',
    });
    if (bob.footfall && this.body.grounded && FOOTSTEPS[state] && this.mode === 'OnFoot') this._footstep(state);

    // FOV
    const F = CameraConfig.FieldOfView;
    const sprintBonus = state === 'Sprinting' && this.moving ? F.SprintBonus * motionScale : 0;
    const fovTarget = this.settings.get('BaseFov') + sprintBonus + this.panic.fovBonus(motionScale) +
      this.panic.fovWarp(motionScale);
    this.fov = dampNumber(this.fov, fovTarget, F.LerpSpeed, dt);

    // compose: eye x look x bob, then the override stack
    _e.set(this.pitch, this.viewYaw, 0, 'YXZ');
    this.eyeQuat.setFromEuler(_e);
    _base.compose(this.eyePosition, this.eyeQuat, _one).multiply(bob.matrix);
    _base.decompose(_bp, _bq, _bs);
    this.stack.step(dt);
    const out = this.stack.evaluate(_bp, _bq, this.fov);
    if (this.cameraEnabled) {
      camera.position.copy(out.position);
      camera.quaternion.copy(out.quaternion);
      if (Math.abs(camera.fov - out.fov) > 1e-3) {
        camera.fov = out.fov;
        camera.updateProjectionMatrix();
      }
      camera.updateMatrixWorld();
    }

    // hands, torch, panic visuals
    const alive = !dead;
    const probe = this.world.probeAt(this.eyePosition, _probe);
    this.viewmodel.update({
      dt, eye: this.eyePosition, yaw: this.viewYaw, pitch: this.pitch, moveState: state,
      lit: this.flashlight.output > 0.05, active: this.cameraEnabled && alive && this.stack.coverage() < 0.5, probe,
    });
    this.flashlight.update({
      dt, time: engine.loop.realTime, eye: this.eyePosition, quaternion: this.eyeQuat, lowered: this.viewmodel.lowered,
      allowed: this.cameraEnabled && alive, playing: this.metersActive,
    });
    const film = engine.lighting ? engine.lighting.film : null;
    this.flashlight.filmShafts = film ? film.shafts : 1;
    this.panic.apply({
      visible: this.cameraEnabled && alive,
      flashScale: this.settings.get('FlashScale'),
      exertion: clamp01((EXERTION_BELOW - this.meters.stamina.fraction) / EXERTION_BELOW),
      restVignette: film ? film.vignette : undefined,
    });
  }

  _computeEye(dt, state, forced) {
    const root = this.drawnRoot;
    let snap = this.snapNext;
    if (this.lastRoot && this.lastRoot.distanceTo(root) > SNAP_DISTANCE) snap = true;
    if (!this.lastRoot) this.lastRoot = new THREE.Vector3();
    this.lastRoot.copy(root);
    this.snapNext = false;
    const grounded = this.body.grounded;
    if (snap) this.heightSpring.reset(root.y);
    else {
      this.heightSpring.target = root.y;
      this.heightSpring.speed = grounded ? HEIGHT_SPEED : HEIGHT_SPEED_AIR;
      this.heightSpring.step(dt);
      const lag = this.heightSpring.position - root.y;
      if (Math.abs(lag) > MAX_HEIGHT_LAG) this.heightSpring.position = root.y + Math.sign(lag) * MAX_HEIGHT_LAG;
    }
    const target = CameraStates.offset(state, forced, _off);
    if (snap) this.offsetSpring.reset(target);
    else {
      this.offsetSpring.target.copy(target);
      this.offsetSpring.step(dt);
    }
    const sy = Math.sin(this.viewYaw);
    const cy = Math.cos(this.viewYaw);
    const o = this.offsetSpring.position;
    // rotate the state offset by the view's yaw (x right, z back)
    const ox = o.x * cy + o.z * sy;
    const oz = -o.x * sy + o.z * cy;
    eyeOffset(CameraRig.DefaultEye, this.viewYaw, this.pitch, _eo);
    const desired = _des.set(root.x + _eo.x + ox, this.heightSpring.position + _eo.y + o.y, root.z + _eo.z + oz);
    if (grounded && this.mode === 'OnFoot') {
      const floorY = root.y - ROOT_ABOVE_FEET;
      if (desired.y < floorY + MIN_EYE_ABOVE_FLOOR) desired.y = floorY + MIN_EYE_ABOVE_FLOOR;
    }
    // pull the eye in front of whatever lies between the root centre and it
    const from = _from.set(root.x, this.heightSpring.position, root.z);
    _dir.subVectors(desired, from);
    const len = _dir.length();
    if (len > 1e-3) {
      _dir.divideScalar(len);
      const hit = this.world.raycast(from, _dir, len + CAMERA_SKIN, { ignoreEntities: false });
      const allowed = hit ? Math.max(0, hit.distance - CAMERA_SKIN) : len;
      if (snap || allowed < this.collisionDistance) this.collisionDistance = allowed;
      else this.collisionDistance = Math.min(allowed, this.collisionDistance + COLLISION_RELEASE * dt);
      if (!hit && this.collisionDistance >= len) {
        this.collisionDistance = Infinity;
        this.eyePosition.copy(desired);
      } else {
        this.eyePosition.copy(from).addScaledVector(_dir, Math.min(this.collisionDistance, len));
      }
    } else {
      this.eyePosition.copy(desired);
    }
  }

  _footstep(state) {
    const feet = this.feetPosition(_ft);
    const surface = this.surfaceAt(feet);
    const sprint = state === 'Sprinting';
    const nominal = CameraStates.bob(state).nominalSpeed || GameConfig.WalkSpeed;
    const volume = FOOTSTEPS[state] * Math.min(1, Math.max(0.3, this.speed / nominal));
    const preset = `Footstep${sprint ? 'Sprint' : ''}${surface}`;
    if (this.audio) this.audio.play(preset, { volume: volume * SELF_FOOTSTEP_VOLUME });
    this.footstep.fire(feet.clone(), surface, sprint);
  }

  /** Ends run-scoped camera state (CameraStack layers blend out, floors, forced states, pitch limits, hand pose). */
  resetForRun() {
    this.stack.clear(false);
    this.panic.clearFloors();
    this.forcedStates.clear();
    this.pitchMin = this.pitchMax = null;
    this.viewmodel.setPose('Flashlight');
    this.overrides.clear();
    this.motionOverrides.clear();
    this.locks.clear();
    this.body.anchored = false;
    this.setMode('OnFoot');
    this.intent = { crouch: false, sprint: false };
    this.crouchPresses = 0;
    this.jumpLatched = false;
    this.exhausted = false;
    this.parkour.reset();
  }
}

const _m = new THREE.Matrix4();
const _v = new THREE.Vector3();
const _d = new THREE.Vector3();
const _o = new THREE.Vector3();
const _f = new THREE.Vector3();
const _ft = new THREE.Vector3();
const _down = new THREE.Vector3(0, -1, 0);
const _wish = new THREE.Vector3();
const _slideWish = new THREE.Vector3();
const _e = new THREE.Euler();
const _base = new THREE.Matrix4();
const _bp = new THREE.Vector3();
const _bq = new THREE.Quaternion();
const _bs = new THREE.Vector3();
const _one = new THREE.Vector3(1, 1, 1);
const _probe = new THREE.Color();
const _off = new THREE.Vector3();
const _eo = new THREE.Vector3();
const _des = new THREE.Vector3();
const _from = new THREE.Vector3();
const _dir = new THREE.Vector3();

export { ROOT_ABOVE_FEET, PhysicsConfig };
