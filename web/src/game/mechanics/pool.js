// pool.js: the flooded pool (FloodedPoolService + WaterRules + SwimController + StruggleController), for the one player.
//
// Water. At ServerTickHz the player is in the water while WaterRules.locate puts their root in a PoolWater volume
// (entering within EnterAbove over the surface, staying within StayAbove: a swimmer bobbing at the surface never
// flickers out; the half-flooded duct's water belongs to the crawl and is never swum). Entering sets the Swim mode
// (Treading / Freestyle / Underwater from the intent and stamina), the Swim context and the swim driver; a fall in
// faster than SplashSpeed is a Splash (the noise and the cue). A swimmer only leaves upward by climbing out.
//
// Swimming (the driver, every frame): surface states spring the root to WaterRules.floatRootY with a gentle bob and
// move at the state's WalkSpeed; Underwater (Dive held) swims along the look, a duck dive takes a still swimmer
// DiveDepth under, the jump input swims up, the body never breaches while diving and never presses into the floor.
// The water's drag limits how fast the velocity changes (stroke). Climbing out: at the surface with the head up, a
// walkable top ClimbMin..ClimbMax over the water ClimbReach ahead and room to stand: the jump input climbs at once,
// swimming into the edge for ClimbPush climbs too; a ClimbSeconds haul up and over, then on the feet.
//
// Oxygen (WaterRules.oxygenRate): drains at OxygenDrain with the head under, OxygenDrainGrabbed while grabbed, waits
// while a jumpscare or cutscene holds the body, otherwise recovers at OxygenRegen. Running out downs the player
// ("Drowned").
//
// The view: under the surface a murky teal overlay (darker toward the depths, closing in as the air runs out), the
// muffled bus and the underwater bed (the engine's acoustics), the panic breathing held; at the surface the overlay
// is split at the projected waterline with a bright meniscus. Breaking the surface with less than half the air left
// gasps. Bubbles rise from the mouth every ExhaleMin..Max seconds under water. Strokes and treading are heard. Hints:
// how to dive and swim fast on the first swim of a run, how to climb out at an edge, Hud.OxygenLow when short of air.
//
// The grab (the Creature's registerPoolGrabber; grabCheck: live, nobody held, Alive, swimming, not in a duct, no
// control lock). The Drag lock and the Grabbed override, the lungs topped up to GrabMinOxygen and draining at
// OxygenDrainGrabbed, the body dragged down and back toward the Creature over DragSeconds (dragTarget / dragPosition)
// and shaken there, the thrashing loop, a Splash, the sting. The struggle: the Struggle context (Space / A / the big
// touch button), each press through WaterRules.press (sequence, the rate cap, the decay); the mash panel with its
// escape bar; the view dragged down toward the Creature's face, shaking, yanked down every TugMin..TugMax seconds; the
// screen darkening as the air runs out; bubbles. Ways out: Escaped (StrugglePressesToEscape: the Creature recoils for
// RecoilSeconds), Flask (a shatter within FlaskCloudRadius, not in a duct: stunned), Floodlight (the switch: stunned),
// LetGo (the Creature stopped holding for HoldGrace); each tops the air up to FreedMinOxygen and kicks the swimmer up
// toward the surface with Hud.StruggleFree. Drowning: at DrownFloor the drain stops and the Creature's Underwater
// catch runs (catchGrabbed); if none can start, the air runs out and the player goes down ("Drowned").

import * as THREE from 'three';
import { GameConfig } from '../config.js';
import * as Scenes from '../scenes.js';
import { S } from '../strings.js';
import { Palette, el, meter } from '../ui/style.js';
import { cfMatrix, clamp, clamp01, frameAt, seededRandom, smoothstep } from '../util.js';
import { Billboards } from './flaskFx.js';

// WaterRules
const ENTER_ABOVE = 0.5;
const STAY_ABOVE = 1.8;
const BOTTOM_SLACK = 0.6;
const SUBMERGE_MARGIN = 0.12;
const DECAY_DELAY = 0.6;
const DECAY_PER_SECOND = 2.5;
const PRESS_WINDOW = 1;
const PRESSES = GameConfig.StrugglePressesToEscape;
const MAX_PRESSES = GameConfig.StruggleMaxPressesPerSecond;
const EYE_ABOVE = { Treading: 0.35, Freestyle: 0.2, DownedCrawling: 0.3 };
const DEFAULT_EYE_ABOVE = 0.35;

// FloodedPoolService
const POLL = 1 / GameConfig.ServerTickHz;
const SPLASH_SPEED = 9;
const DRAG_SECONDS = 1.2;
const HOLD_DEPTH = 4.5;
const HOLD_SPACING = 2.4;
const HOLD_BACK = 3;
const HOLD_FLOOR_CLEARANCE = 1.6;
const HOLD_WALL_CLEARANCE = 1.5;
const HOLD_SWAY = 0.25;
const HOLD_GRACE = 1;
const GRAB_MIN_OXYGEN = GameConfig.OxygenDrainGrabbed * 4.5;
const FREED_MIN_OXYGEN = GameConfig.OxygenDrain * 2.5;
const DROWN_FLOOR = 0.5;
const RECOIL = { Escaped: 3.5, Flask: GameConfig.StunSeconds, Floodlight: GameConfig.StunSeconds };
const FREED = new Set(['Escaped', 'Flask', 'Floodlight', 'LetGo']);
const HELD_LOCKS = new Set(['Jumpscare', 'Cutscene']);

// SwimController
const BASE_ACCEL = 22;
const DRAG_GAIN = 6;
const MAX_ACCEL = 420;
const FLOAT_GAIN = 4;
const SINK_MAX = 6;
const RISE_MAX = 6;
const DIVE_DEPTH = 2.4;
const DIVE_SPEED = 4.5;
const DIVE_CEILING = 1.1;
const FLOOR_CLEARANCE = 1.3;
const BOB = { Treading: [0.12, 0.45], Freestyle: [0.05, 1.1], DownedCrawling: [0.05, 0.3] };
const CLIMB_REACH = 1.9;
const CLIMB_MIN = 0.1;
const CLIMB_MAX = 2.3;
const CLIMB_STEP_IN = 1.2;
const CLIMB_SECONDS = 0.7;
const CLIMB_PUSH = 0.35;
const CLIMB_PUSH_DOT = 0.7;
const CLIMB_HEAD_DEPTH = 0.5;
const PROBE_INTERVAL = 0.2;
const ROOT_HEIGHT = 3;
const WATERLINE_BAND = 0.35;
const WATERLINE_AHEAD = 1.4;
const LOW_AIR_FRACTION = 0.3;
const LOW_AIR_REPEAT = 8;
const GASP_BELOW = 0.5;
const PANIC_FROM = 0.6;
const PANIC_MAX = 0.75;
const EXHALE_MIN = 2.4;
const EXHALE_MAX = 4;
const BUBBLE_LIFE = 3;
const BUBBLE_RISE_MIN = 2.6;
const BUBBLE_RISE_MAX = 4.6;
const BUBBLE_POOL = 32;
const FREESTYLE_STROKE = 0.55;
const TREAD_STROKE = 1.25;
const TREAD_IDLE = 2.6;
const STROKE_MOVING = 1.5;
const SWIM_HINT_SECONDS = 6;
const CLIMB_HINT_SECONDS = 3;
const CLIMB_HINT_REPEAT = 20;

// StruggleController
const TUG_MIN = 0.8;
const TUG_MAX = 1.5;
const TUG_SECONDS = 0.3;
const JERK_SECONDS = 0.18;
const PULL_BASE = 0.5;
const PULL_DRAG = 0.85;
const PULL_TUG = 0.3;
const SHAKE_DEGREES = 2.6;
const TUG_PITCH = (8 * Math.PI) / 180;
const TUG_DIP = 0.22;
const JERK_PITCH = (3 * Math.PI) / 180;
const BUBBLE_INTERVAL = 0.45;
const FREE_KICK_SPEED = 7.5;
const FREE_KICK_SECONDS = 0.7;
const FREE_HINT_SECONDS = 2.5;

/** The float height for `state` over water at `surface` (WaterRules.floatRootY, `eyeHeight` the state's eye). */
export function floatRootY(surface, state, eyeHeight) {
  return surface + (EYE_ABOVE[state] ?? DEFAULT_EYE_ABOVE) - eyeHeight;
}

/** WaterRules.submerged */
export function submerged(state, rootY, surface, eyeHeight) {
  if (state === 'Underwater' || state === 'Grabbed') return true;
  if (state === 'DownedCrawling') return false;
  return surface - (rootY + eyeHeight) > SUBMERGE_MARGIN;
}

/** WaterRules.oxygenRate */
export function oxygenRate(input) {
  if (input.held) return 0;
  if (input.grabbed) return -GameConfig.OxygenDrainGrabbed;
  if (input.inWater && input.submerged) return -GameConfig.OxygenDrain;
  return input.oxygen < input.max ? GameConfig.OxygenRegen : 0;
}

export function newStruggle(now) {
  return { progress: 0, at: now, lastPressAt: -Infinity, lastSequence: -1, window: [], counted: 0 };
}

export function progressAt(s, now) {
  const decayFrom = Math.max(s.at, s.lastPressAt + DECAY_DELAY);
  return clamp(s.progress - Math.max(0, now - decayFrom) * DECAY_PER_SECOND, 0, PRESSES);
}

/** WaterRules.press: 'Counted' | 'Stale' | 'TooFast'. */
export function press(s, sequence, now) {
  if (sequence <= s.lastSequence) return 'Stale';
  let recent = 0;
  for (const at of s.window) if (now - at < PRESS_WINDOW) recent++;
  s.lastSequence = sequence;
  for (let i = s.window.length - 1; i >= 0; i--) if (now - s.window[i] >= PRESS_WINDOW) s.window.splice(i, 1);
  if (recent >= MAX_PRESSES) return 'TooFast';
  s.progress = Math.min(PRESSES, progressAt(s, now) + 1);
  s.at = now;
  s.lastPressAt = now;
  s.counted++;
  s.window.push(now);
  return 'Counted';
}

export function escaped(s, now) {
  return progressAt(s, now) >= PRESSES - 1e-6;
}

/** FloodedPoolService.dragTarget */
export function dragTarget(from, creature, volume, facing) {
  const flat = new THREE.Vector3(facing.x, 0, facing.z);
  const back = flat.lengthSq() > 1e-6 ? flat.normalize().negate() : new THREE.Vector3(0, 0, 1);
  let horizontal;
  if (creature) {
    const toVictim = new THREE.Vector3(from.x - creature.x, 0, from.z - creature.z);
    const away = toVictim.lengthSq() > 1e-6 ? toVictim.normalize() : back.clone().negate();
    horizontal = new THREE.Vector3(creature.x, 0, creature.z).addScaledVector(away, HOLD_SPACING);
  } else horizontal = new THREE.Vector3(from.x, 0, from.z).addScaledVector(back, HOLD_BACK);
  const local = new THREE.Vector3(horizontal.x, volume.centreY, horizontal.z).applyMatrix4(volume.inv);
  const hx = Math.max(0, volume.size[0] / 2 - HOLD_WALL_CLEARANCE);
  const hz = Math.max(0, volume.size[2] / 2 - HOLD_WALL_CLEARANCE);
  const clamped = new THREE.Vector3(clamp(local.x, -hx, hx), 0, clamp(local.z, -hz, hz)).applyMatrix4(volume.matrix);
  const y = Math.max(volume.bottom + HOLD_FLOOR_CLEARANCE, Math.min(volume.surface - HOLD_DEPTH, from.y - 1));
  return new THREE.Vector3(clamped.x, y, clamped.z);
}

/** FloodedPoolService.dragPosition: down first (the legs go), then back. */
export function dragPosition(from, to, alpha, out = new THREE.Vector3()) {
  const a = clamp01(alpha);
  const down = smoothstep(0, 0.7, a);
  const back = smoothstep(0.15, 1, a);
  return out.set(from.x + (to.x - from.x) * back, from.y + (to.y - from.y) * down, from.z + (to.z - from.z) * back);
}

export class Pool {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Pool';
    this.game = game;
    this.env = game.env;
    const chase = new Set(game.world.meta.rooms.filter((r) => r.kind === 'Chase').map((r) => r.id));
    this.volumes = game.world.triggers('PoolWater').map((t) => {
      const matrix = cfMatrix(t.cframe);
      return {
        id: t.id, level: t.level, matrix, inv: matrix.clone().invert(), size: t.size, centreY: t.cframe[1],
        surface: t.cframe[1] + t.size[1] / 2, bottom: t.cframe[1] - t.size[1] / 2, duct: chase.has(t.room),
      };
    }).sort((a, b) => (a.id < b.id ? -1 : 1));
    this.swimmer = null;
    this.engaged = false;
    this.climb = null;
    this.pushSince = null;
    this.probe = null;
    this.nextProbeAt = 0;
    this.kickUntil = 0;
    this.kickSpeed = 0;
    this.velocity = new THREE.Vector3();
    this.sample = null;
    this.grab = null;
    this.struggle = null;
    this.pollClock = 0;
    this.hintedSwim = false;
    this.climbHintAt = -Infinity;
    this.lowAirHintAt = -Infinity;
    this.wasUnder = false;
    this.nextExhaleAt = Infinity;
    this.strokeAt = 0;
    this.random = seededRandom(1, 'Pool');
    this.bubbles = [];
    this.bubbleFx = new Billboards(BUBBLE_POOL, new THREE.Color(0.75, 0.9, 0.88), true);
    this.env.addToScene(this.bubbleFx.mesh);
    this.ui = this._buildUi();
    this.env.onAction('Struggle', (phase) => {
      if (phase === 'Begin') this._press();
    });
    this.env.onOxygenDepleted(() => {
      if (this.game.live() && this.game.life.state === 'Alive' && !this.grab) this.game.life.down('Drowned');
    });
    game.creature.registerPoolGrabber(() => this.tryGrab(false));
  }

  // ---------------------------------------------------------------------------------------------------- water

  _contains(v, p, above) {
    if (p.y < v.bottom - BOTTOM_SLACK || p.y > v.surface + above) return false;
    _l.copy(p).applyMatrix4(v.inv);
    return Math.abs(_l.x) <= v.size[0] / 2 && Math.abs(_l.z) <= v.size[2] / 2;
  }

  /** WaterRules.locate */
  _locate(p, current) {
    if (current && !current.duct && this._contains(current, p, STAY_ABOVE)) return current;
    for (const v of this.volumes) if (!v.duct && this._contains(v, p, ENTER_ABOVE)) return v;
    return null;
  }

  /** Whether the player swims (the Creature's and the hints' read). */
  swimming() {
    return !!this.swimmer;
  }

  _engage(volume, root, now) {
    const env = this.env;
    this.swimmer = { volume, enteredAt: now };
    this.engaged = true;
    this.velocity.copy(env.body().velocity);
    env.setMode('Swim');
    env.pushContext('Swim', 'Swim');
    env.setMotionOverride('Swim', (dt) => this._drive(dt), 3);
    const s = this.sample;
    if (s && now - s.at <= 0.5 && now > s.at) {
      const fall = (s.y - root.y) / (now - s.at);
      if (fall >= SPLASH_SPEED) {
        const point = new THREE.Vector3(root.x, volume.surface, root.z);
        this.game.noise(point, 'Splash');
        this.game.playAt('Splash', point);
      }
    }
    this.nextExhaleAt = now + this.random.number(EXHALE_MIN, EXHALE_MAX);
    if (!this.hintedSwim) {
      this.hintedSwim = true;
      env.hint(S(`Hud.SwimHint.${env.device()}`), SWIM_HINT_SECONDS);
    }
  }

  /** Ends the swim (out of the water, a climb landing, a duct, death, the run's end). */
  _release(setFoot) {
    if (!this.engaged) {
      this.swimmer = null;
      return;
    }
    const env = this.env;
    this.engaged = false;
    this.swimmer = null;
    this.climb = null;
    this.pushSince = null;
    env.setMotionOverride('Swim', null);
    env.popContext('Swim');
    if (setFoot && env.mode() === 'Swim') env.setMode('OnFoot');
    env.setBreathSuppressed('Swim', false);
    env.setPanicFloor('Swim', null);
    this.wasUnder = false;
  }

  /** Out of the water at once: a vent entered from it (the duct takes the body), or a scripted move (`onFoot`). */
  leaveWater(onFoot = false) {
    this._release(onFoot);
  }

  // ---------------------------------------------------------------------------------------------------- driver

  _drive(dt) {
    const env = this.env;
    const body = env.body();
    const sw = this.swimmer;
    if (!sw) return;
    if (env.isLocked() && !this.climb) {
      this.velocity.set(0, 0, 0);
      return;
    }
    const now = env.now();
    if (this.climb) {
      const c = this.climb;
      const alpha = (now - c.startedAt) / CLIMB_SECONDS;
      climbPath(c.from, c.target, alpha, body.position);
      if (alpha >= 1) {
        const stand = c.target.stand.clone();
        this._release(true);
        env.teleport({ position: stand, yaw: env.look().yaw });
      }
      return;
    }
    const state = env.moveState();
    const look = env.look();
    const mv = env.moveVector();
    const sy = Math.sin(look.yaw);
    const cy = Math.cos(look.yaw);
    _move.set(-sy * mv.y + cy * mv.x, 0, -cy * mv.y - sy * mv.x);
    if (_move.length() > 1) _move.normalize();
    const v = sw.volume;
    const speed = env.walkSpeed(state);
    const root = body.position;
    const target = _target;
    if (state === 'Underwater') {
      _flat.set(look.direction.x, 0, look.direction.z);
      if (_flat.lengthSq() > 1e-6) _flat.normalize();
      else _flat.set(0, 0, -1);
      const forward = _move.dot(_flat);
      _strafe.copy(_move).addScaledVector(_flat, -forward);
      target.copy(look.direction).multiplyScalar(forward).add(_strafe).multiplyScalar(speed);
      const depth = v.surface - root.y;
      if (_move.length() < 0.1) target.y = depth < DIVE_DEPTH ? -DIVE_SPEED : 0;
      if (env.jumpDown()) target.y = Math.max(target.y, speed);
      const ceiling = v.surface - DIVE_CEILING;
      if (root.y > ceiling - 0.5 && target.y > 0) target.y = Math.min(target.y, (ceiling - root.y) * FLOAT_GAIN);
      const flatSpeed = Math.hypot(target.x, target.z);
      if (flatSpeed > speed) {
        target.x *= speed / flatSpeed;
        target.z *= speed / flatSpeed;
      }
    } else {
      const bob = BOB[state] || [0.1, 0.45];
      const floatY = floatRootY(v.surface, state, env.eyeHeight(state)) + bob[0] * Math.sin(2 * Math.PI * bob[1] * now);
      target.set(_move.x * speed, clamp((floatY - root.y) * FLOAT_GAIN, -SINK_MAX, RISE_MAX), _move.z * speed);
    }
    if (now < this.kickUntil) target.y = Math.max(target.y, this.kickSpeed);
    if (root.y < v.bottom + FLOOR_CLEARANCE && target.y < 0) target.y = 0;
    _err.subVectors(target, this.velocity);
    const error = _err.length();
    const accel = Math.min(MAX_ACCEL, BASE_ACCEL + DRAG_GAIN * error);
    const step = accel * dt;
    if (error <= step) this.velocity.copy(target);
    else this.velocity.addScaledVector(_err, step / error);
    body.velocity.copy(this.velocity);
    body.move(_d.copy(this.velocity).multiplyScalar(dt));
    this._climbCheck(now, state, _move);
  }

  /** The ledge ahead (SwimController.climbTarget) and the climb's triggers. */
  _climbCheck(now, state, move) {
    const env = this.env;
    const sw = this.swimmer;
    if (!sw || state === 'Underwater' || state === 'DownedCrawling' || this.game.life.state !== 'Alive') {
      this.pushSince = null;
      return;
    }
    const root = env.body().position;
    const eyeDepth = sw.volume.surface - (root.y + env.eyeHeight(state));
    if (eyeDepth > CLIMB_HEAD_DEPTH) return;
    if (now >= this.nextProbeAt) {
      this.nextProbeAt = now + PROBE_INTERVAL;
      const look = env.look();
      _fwd.set(-Math.sin(look.yaw), 0, -Math.cos(look.yaw));
      this.probe = this._probe(root, _fwd, sw.volume.surface);
      if (this.probe && now - this.climbHintAt >= CLIMB_HINT_REPEAT) {
        this.climbHintAt = now;
        env.hint(S(`Hud.ClimbOut.${env.device()}`), CLIMB_HINT_SECONDS);
      }
    }
    const probe = this.probe;
    if (!probe) {
      this.pushSince = null;
      return;
    }
    if (env.jumpDown()) {
      this._startClimb(probe, now);
      return;
    }
    _fwd.set(probe.edge.x - root.x, 0, probe.edge.z - root.z).normalize();
    if (move.length() > 0.5 && move.dot(_fwd) >= CLIMB_PUSH_DOT) {
      if (this.pushSince === null) this.pushSince = now;
      else if (now - this.pushSince >= CLIMB_PUSH) this._startClimb(probe, now);
    } else this.pushSince = null;
  }

  _probe(root, forward, surface) {
    const env = this.env;
    _o.set(root.x, surface + CLIMB_MAX + 1, root.z).addScaledVector(forward, CLIMB_REACH);
    // the path to the probe point must be open (not through a wall)
    if (!env.lineClear(_a.set(root.x, surface + CLIMB_MAX + 1, root.z), _o, { ignoreEntities: false })) return null;
    const hit = env.raycast(_o, _down, CLIMB_MAX + 2, { ignoreEntities: false });
    if (!hit || hit.normal.y < 0.7) return null;
    const top = hit.point.y;
    const height = top - surface;
    if (height < CLIMB_MIN || height > CLIMB_MAX) return null;
    const edge = new THREE.Vector3(root.x, top, root.z).addScaledVector(forward, CLIMB_REACH);
    const stand = edge.clone().addScaledVector(forward, CLIMB_STEP_IN).add(_a.set(0, ROOT_HEIGHT, 0));
    // room to stand
    if (!env.lineClear(_b.set(edge.x, top + 1, edge.z), _c.set(stand.x, top + 1, stand.z), { ignoreEntities: false })) return null;
    if (env.raycast(_c.set(stand.x, top + 0.3, stand.z), _up, 4.4, { ignoreEntities: false })) return null;
    return { edge, stand, top };
  }

  _startClimb(target, now) {
    this.climb = { from: this.env.body().position.clone(), target, startedAt: now };
    this.pushSince = null;
    this.game.playAt('ClimbOut', target.edge);
  }

  // ---------------------------------------------------------------------------------------------------- the grab

  /** TryGrab (the Creature's PoolGrabber, the dev `pool grab`): false when grabCheck refuses. */
  tryGrab(devHold) {
    const g = this.game;
    const env = this.env;
    if (!g.live() || this.grab || g.life.state !== 'Alive' || !this.swimmer || (g.vents && g.vents.inVent()) ||
      g.controlLock() !== 'None') return false;
    const now = env.now();
    const from = env.rootPosition(new THREE.Vector3());
    const creature = devHold ? null : g.creature.position(new THREE.Vector3());
    const look = env.look();
    const facing = new THREE.Vector3(-Math.sin(look.yaw), 0, -Math.cos(look.yaw));
    const to = dragTarget(from, creature, this.swimmer.volume, facing);
    const toward = creature ? new THREE.Vector3(creature.x - to.x, 0, creature.z - to.z) : facing.clone();
    g.lock('Drag');
    env.pushOverride('Pool', 'Grabbed');
    const ox = env.meters().oxygen;
    if (ox.value < GRAB_MIN_OXYGEN) env.addOxygen(GRAB_MIN_OXYGEN - ox.value);
    env.setOxygenRate(-GameConfig.OxygenDrainGrabbed);
    const head = devHold ? to.clone().add(new THREE.Vector3(0, -2, 0)).addScaledVector(toward.lengthSq() > 1e-6 ? toward.clone().normalize() : facing, HOLD_SPACING)
      : g.creature.eye(new THREE.Vector3()) || to.clone();
    this.grab = {
      startedAt: now, from, to, facing: toward.lengthSq() > 1e-6 ? toward.normalize() : new THREE.Vector3(0, 0, -1),
      volume: this.swimmer.volume, struggle: newStruggle(now), devHold, released: false, heldSince: null,
      thrash: g.playAt('StruggleThrash', from, { loop: true }), head, sequence: 0,
    };
    env.setMotionOverride('Drag', (dt) => this._stepDrag(), 9);
    g.playAt('Splash', new THREE.Vector3(from.x, this.swimmer.volume.surface, from.z), { volume: 1.3 });
    env.play('JumpscareSting');
    this._startStruggle();
    return true;
  }

  _stepDrag() {
    const grab = this.grab;
    if (!grab) return;
    const env = this.env;
    const now = env.now();
    const alpha = (now - grab.startedAt) / DRAG_SECONDS;
    const body = env.body();
    dragPosition(grab.from, grab.to, alpha, body.position);
    if (alpha >= 1) {
      const t = now - grab.startedAt;
      body.position.x += HOLD_SWAY * Math.sin(t * 1.7 * 2.1 + 3.1);
      body.position.y += HOLD_SWAY * 0.6 * Math.sin(t * 2.3 * 1.9 + 7.3);
      body.position.z += HOLD_SWAY * Math.sin(t * 1.9 * 2.3 + 11.7);
    }
    body.velocity.set(0, 0, 0);
    if (grab.thrash) grab.thrash.setPosition(body.position);
  }

  _press() {
    const grab = this.grab;
    if (!grab || grab.released) return;
    const now = this.env.now();
    grab.sequence++;
    const verdict = press(grab.struggle, grab.sequence, now);
    if (verdict === 'Counted') {
      this.struggle.jerkAt = this.env.realNow();
      this._emitBubbles(3);
      if (escaped(grab.struggle, now)) this.releaseGrab('Escaped');
    }
  }

  /** A flask shattered: a grabbed swimmer within FlaskCloudRadius (not in a duct) is let go. */
  noteShatter(point) {
    const grab = this.grab;
    if (!grab || grab.released) return;
    if (point.distanceTo(this.env.rootPosition(_a)) <= GameConfig.FlaskCloudRadius) this.releaseGrab('Flask');
  }

  /** ReleaseGrab (the floodlights, a shatter, the struggle, the Creature letting go); false when nobody is held. */
  releaseGrab(outcome) {
    const grab = this.grab;
    if (!grab || grab.released) return false;
    const g = this.game;
    const env = this.env;
    grab.released = true;
    this.grab = null;
    const position = env.rootPosition(new THREE.Vector3());
    env.setMotionOverride('Drag', null);
    if (grab.thrash) grab.thrash.stop(0.4);
    g.unlock('Drag');
    env.popOverride('Pool');
    if (FREED.has(outcome)) {
      const ox = env.meters().oxygen;
      if (ox.value < FREED_MIN_OXYGEN) env.addOxygen(FREED_MIN_OXYGEN - ox.value);
    }
    const recoil = RECOIL[outcome];
    if (recoil && !grab.devHold) g.creature.stun(recoil, position);
    if (outcome === 'Escaped') g.playAt('Splash', position);
    this._endStruggle(outcome);
    return true;
  }

  _checkGrab(now) {
    const grab = this.grab;
    if (!grab) return;
    const g = this.game;
    if (g.life.state !== 'Alive' || !g.live()) {
      this.releaseGrab('Ended');
      return;
    }
    // drowning: the drain stops at DrownFloor while the catch is tried
    if (this.env.meters().oxygen.value <= DROWN_FLOOR + 1e-6) {
      this._drown();
      return;
    }
    if (grab.devHold) return;
    const snap = g.creature.snapshot();
    if (snap && snap.grabbed) grab.heldSince = null;
    else {
      grab.heldSince = grab.heldSince ?? now;
      if (now - grab.heldSince >= HOLD_GRACE && now - grab.startedAt >= HOLD_GRACE) this.releaseGrab('LetGo');
    }
  }

  _drown() {
    const grab = this.grab;
    if (!grab) return;
    const env = this.env;
    env.setOxygenRate(0);
    const caught = !grab.devHold && this.game.creature.catchGrabbed();
    if (caught) {
      this.releaseGrab('Caught');
      return;
    }
    this.releaseGrab('Drowned');
    env.addOxygen(-GameConfig.OxygenMax);
    if (this.game.life.state === 'Alive') this.game.life.down('Drowned');
  }

  // ---------------------------------------------------------------------------------------------------- the struggle view

  _startStruggle() {
    const env = this.env;
    const s = {
      startedAt: env.realNow(),
      nextTugAt: env.realNow() + TUG_MIN,
      tugAt: -Infinity,
      jerkAt: -Infinity,
      nextBubblesAt: env.realNow(),
      seed: this.random.number(0, 100),
    };
    this.struggle = s;
    env.pushContext('Struggle', 'Struggle');
    env.suppressPrompts('Struggle', true);
    env.setPanicFloor('Struggle', 1);
    env.setBreathSuppressed('Struggle', true);
    env.setCameraOverride('Struggle', () => this._struggleView(s), { priority: 6, blendIn: 0.15, blendOut: 0.3 });
    this.ui.struggle.style.display = '';
  }

  _endStruggle(outcome) {
    const env = this.env;
    if (!this.struggle) return;
    this.struggle = null;
    env.popContext('Struggle');
    env.suppressPrompts('Struggle', false);
    env.setPanicFloor('Struggle', null);
    env.setBreathSuppressed('Struggle', false);
    env.setCameraOverride('Struggle', null);
    this.ui.struggle.style.display = 'none';
    this.ui.dark.style.opacity = '0';
    if (FREED.has(outcome)) {
      this.kickSpeed = FREE_KICK_SPEED;
      this.kickUntil = env.now() + FREE_KICK_SECONDS;
      this._emitBubbles(10);
      env.hint(S('Hud.StruggleFree'), FREE_HINT_SECONDS);
    }
  }

  _struggleView(s) {
    const env = this.env;
    const grab = this.grab;
    const real = env.realNow();
    const t = real - s.startedAt;
    const look = env.look();
    const eye = frameAt(env.eye(_eye), look.yaw, look.pitch, _view);
    const tug = tugEnvelope(real - s.tugAt);
    const scale = clamp01(env.setting('MotionScale') ?? 1);
    const dragging = t < DRAG_SECONDS ? 1 - t / DRAG_SECONDS : 0;
    const weight = clamp01(PULL_BASE + (PULL_DRAG - PULL_BASE) * dragging + PULL_TUG * tug);
    let view = eye;
    if (grab && grab.head) view = Scenes.pulled(eye, grab.head, weight * scale + (1 - scale) * 0.3, _pulled);
    const a = ((SHAKE_DEGREES * Math.PI) / 180) * scale;
    const jerk = 1 - clamp01((real - s.jerkAt) / JERK_SECONDS);
    _e.set(a * Math.sin(t * 9.1 * 2.2 + s.seed) - TUG_PITCH * tug * scale + JERK_PITCH * jerk * scale,
      a * 0.8 * Math.sin(t * 7.3 * 2.1 + s.seed + 17.4), a * 0.6 * Math.sin(t * 11.7 * 1.7 + s.seed + 41.9), 'XYZ');
    _shake.makeRotationFromEuler(_e).setPosition(0, -TUG_DIP * tug * scale, 0);
    return _out.multiplyMatrices(view, _shake);
  }

  // ---------------------------------------------------------------------------------------------------- bubbles

  _emitBubbles(count) {
    const env = this.env;
    const sw = this.swimmer;
    const mouth = env.eye(_a).add(_b.set(-Math.sin(env.look().yaw), -0.25, -Math.cos(env.look().yaw)).multiplyScalar(0.6));
    const surface = sw ? sw.volume.surface : mouth.y + 4;
    for (let i = 0; i < count; i++) {
      if (this.bubbles.length >= BUBBLE_POOL) this.bubbles.shift();
      this.bubbles.push({
        p: mouth.clone().add(new THREE.Vector3(this.random.number(-0.15, 0.15), 0, this.random.number(-0.15, 0.15))),
        rise: this.random.number(BUBBLE_RISE_MIN, BUBBLE_RISE_MAX),
        born: env.realNow(),
        size: this.random.number(0.06, 0.16),
        surface,
        wobble: this.random.number(0, 6),
      });
    }
  }

  _stepBubbles(dt) {
    const now = this.env.realNow();
    let n = 0;
    for (let i = this.bubbles.length - 1; i >= 0; i--) {
      const b = this.bubbles[i];
      b.p.y += b.rise * dt;
      if (now - b.born > BUBBLE_LIFE || b.p.y >= b.surface) this.bubbles.splice(i, 1);
    }
    for (const b of this.bubbles) {
      _c.copy(b.p);
      _c.x += 0.08 * Math.sin((now - b.born) * 7 + b.wobble);
      this.bubbleFx.set(n++, _c, b.size, 0.8);
    }
    this.bubbleFx.commit(n);
  }

  // ---------------------------------------------------------------------------------------------------- drive

  beginRun() {
    this._release(true);
    this.hintedSwim = false;
    this.climbHintAt = -Infinity;
    this.lowAirHintAt = -Infinity;
    this.sample = null;
  }

  endRun() {
    if (this.grab) this.releaseGrab('Ended');
    this._release(true);
    this.env.setOxygenRate(0);
    this.bubbles.length = 0;
  }

  tick(dt, now) {
    const g = this.game;
    const env = this.env;
    this.pollClock += dt;
    if (this.pollClock < POLL) return;
    this.pollClock = 0;
    if (!g.live() || !g.playing()) {
      if (this.engaged) this._release(true);
      if (this.grab) this.releaseGrab('Ended');
      return;
    }
    const root = env.rootPosition(new THREE.Vector3());
    if (g.vents && g.vents.inVent()) {
      if (this.engaged) this._release(false);
      this.sample = { y: root.y, at: now };
      this._oxygen(false, false, false);
      return;
    }
    const grabbed = !!this.grab;
    const lock = g.controlLock();
    if (grabbed) {
      this._checkGrab(now);
      if (this.grab) env.setOxygenRate(-GameConfig.OxygenDrainGrabbed);
      return;
    }
    if (lock !== 'None' && !this.climb) {
      this.sample = null;
      this._oxygen(!!this.swimmer && this._under(root), HELD_LOCKS.has(lock), false);
      return;
    }
    if (!this.climb) {
      const volume = this._locate(root, this.swimmer ? this.swimmer.volume : null);
      if (volume && !this.swimmer) this._engage(volume, root, now);
      else if (this.swimmer && !volume) this._release(true);
      else if (this.swimmer && volume) this.swimmer.volume = volume;
    }
    this.sample = { y: root.y, at: now };
    if (this.swimmer && g.vents) g.vents.trySwimEntry(this.swimmer.volume.surface);
    this._oxygen(!!this.swimmer && this._under(root), false, false);
  }

  _under(root) {
    const state = this.env.moveState();
    return submerged(state, root.y, this.swimmer.volume.surface, this.env.eyeHeight(state));
  }

  _oxygen(under, held, grabbed) {
    const ox = this.env.meters().oxygen;
    this.env.setOxygenRate(oxygenRate({ inWater: !!this.swimmer, submerged: under, grabbed, held, oxygen: ox.value, max: ox.max }));
  }

  frame(dt) {
    const env = this.env;
    const g = this.game;
    this._stepBubbles(dt);
    const sw = this.swimmer;
    const ui = this.ui;
    const ox = env.meters().oxygen;
    const fraction = ox.max > 0 ? clamp01(ox.value / ox.max) : 1;
    // the view against the surface
    const camera = env.camera();
    const volume = sw ? sw.volume : this.grab ? this.grab.volume : null;
    if (!volume || !g.live()) {
      ui.murk.style.opacity = '0';
      ui.line.style.display = 'none';
    } else {
      const depth = volume.surface - camera.position.y;
      const amount = smoothstep(-0.05, 0.25, depth);
      ui.murk.style.opacity = String(amount * (0.55 + 0.35 * (1 - fraction)));
      _fwd.set(0, 0, -1).applyQuaternion(camera.quaternion);
      _fwd.y = 0;
      if (_fwd.lengthSq() > 1e-6) _fwd.normalize();
      _a.copy(camera.position).addScaledVector(_fwd, WATERLINE_AHEAD);
      _a.y = volume.surface;
      const p = env.project(_a);
      const height = env.uiRoot().clientHeight || 720;
      if (Math.abs(depth) <= WATERLINE_BAND && p) {
        const y = clamp(p.y, 0, height);
        ui.murk.style.opacity = String(0.55 + 0.35 * (1 - fraction));
        ui.murk.style.clipPath = `inset(${y}px 0 0 0)`;
        ui.line.style.display = '';
        ui.line.style.top = `${y}px`;
      } else {
        ui.murk.style.clipPath = 'none';
        ui.line.style.display = 'none';
      }
      const under = depth > 0.05;
      if (this.wasUnder && !under && fraction < GASP_BELOW) env.play('SurfaceGasp');
      this.wasUnder = under;
      env.setBreathSuppressed('Swim', under);
      env.setPanicFloor('Swim', under ? PANIC_MAX * smoothstep(PANIC_FROM, 0, fraction) : null);
      const now = env.now();
      if (under && sw && !this.grab) {
        if (now >= this.nextExhaleAt) {
          this.nextExhaleAt = now + this.random.number(EXHALE_MIN, EXHALE_MAX);
          this._emitBubbles(5);
          env.play('Bubbles', { volume: 0.6 });
        }
        if (fraction < LOW_AIR_FRACTION && now - this.lowAirHintAt >= LOW_AIR_REPEAT) {
          this.lowAirHintAt = now;
          env.hint(S('Hud.OxygenLow'), 3);
        }
      }
      // strokes
      if (sw && !this.grab) {
        const state = env.moveState();
        const speed = env.speed();
        const interval = state === 'Freestyle' ? (speed >= STROKE_MOVING ? FREESTYLE_STROKE : TREAD_IDLE)
          : state === 'Treading' || state === 'DownedCrawling' ? (speed >= STROKE_MOVING ? TREAD_STROKE : TREAD_IDLE) : null;
        if (interval !== null && now - this.strokeAt >= interval) {
          this.strokeAt = now;
          env.play(state === 'Freestyle' ? 'SwimStroke' : 'WaterTread', { position: env.rootPosition(new THREE.Vector3()), volume: 0.7 });
        }
      }
    }
    // the struggle
    const s = this.struggle;
    const grab = this.grab;
    if (s && grab) {
      const real = env.realNow();
      if (real >= s.nextTugAt) {
        s.tugAt = real;
        s.nextTugAt = real + TUG_MIN + (TUG_MAX - TUG_MIN) * this.random.number(0, 1);
      }
      if (real >= s.nextBubblesAt) {
        s.nextBubblesAt = real + BUBBLE_INTERVAL;
        this._emitBubbles(2);
      }
      ui.bar.set(clamp01(progressAt(grab.struggle, env.now()) / PRESSES));
      const starving = 1 - smoothstep(0.08, 0.6, fraction);
      ui.dark.style.opacity = String(clamp(0.82 * starving + 0.08 * starving * (0.5 + 0.5 * Math.sin(real * 7)), 0, 0.9));
      const punch = 1 + 0.12 * (1 - clamp01((real - s.jerkAt) / JERK_SECONDS));
      ui.glyph.style.transform = `scale(${punch})`;
    }
  }

  _buildUi() {
    const env = this.env;
    const root = env.uiRoot();
    const murk = el('div', 'rg-layer', root);
    murk.style.background = 'linear-gradient(to bottom, rgba(10,34,32,0.55), rgba(2,8,9,0.9))';
    murk.style.opacity = '0';
    const line = el('div', '', root);
    Object.assign(line.style, { position: 'absolute', left: '0', right: '0', height: '2px', display: 'none',
      background: 'rgba(196,236,230,0.65)', pointerEvents: 'none' });
    const dark = el('div', 'rg-layer', root);
    dark.style.background = Palette.Ink;
    dark.style.opacity = '0';
    const struggle = el('div', 'rg-panel', root);
    Object.assign(struggle.style, { position: 'absolute', left: '50%', bottom: '230px', transform: 'translateX(-50%)',
      width: 'min(320px, 90vw)', padding: '12px 18px', textAlign: 'center', display: 'none', pointerEvents: 'none' });
    const title = el('div', 'rg-title rg-outline', struggle, S('Hud.Struggle'));
    title.style.fontSize = '18px';
    const row = el('div', '', struggle);
    Object.assign(row.style, { display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '10px', margin: '10px 0' });
    const glyph = el('div', '', row);
    Object.assign(glyph.style, { position: 'relative', width: '64px', height: '64px', flex: '0 0 64px' });
    env.keyCap(glyph, 'Struggle', 64);
    const mash = el('div', 'rg-caps', row, S('Hud.StruggleMash'));
    mash.style.color = Palette.Bone;
    const bar = meter(struggle, Palette.Ember, 284);
    return { murk, line, dark, struggle, glyph, bar };
  }

  // ---------------------------------------------------------------------------------------------------- dev

  /** Dev `pool grab`: into the pool and grabbed (a dev hold: no Creature needed). Level 4's moment. */
  devGrab() {
    const env = this.env;
    const g = this.game;
    const v = this.volumes.find((x) => !x.duct && x.level === g.level) || this.volumes.find((x) => !x.duct);
    if (!v || !g.live()) return false;
    if (!this.swimmer) {
      // open water nearest the player: nothing over it between the pool floor and the air (no bridge, no slab)
      const root = env.rootPosition(new THREE.Vector3());
      const y = floatRootY(v.surface, 'Treading', env.eyeHeight('Treading'));
      let p = null;
      let best = Infinity;
      for (let x = -v.size[0] / 2 + 4; x <= v.size[0] / 2 - 4; x += 6) {
        for (let z = -v.size[2] / 2 + 4; z <= v.size[2] / 2 - 4; z += 6) {
          const c = new THREE.Vector3(x, 0, z).applyMatrix4(v.matrix);
          if (!env.lineClear(_a.set(c.x, v.bottom + 1, c.z), _b.set(c.x, v.surface + 6, c.z), { ignoreEntities: false })) continue;
          const d = Math.hypot(c.x - root.x, c.z - root.z);
          if (d < best) {
            best = d;
            p = c.setY(y);
          }
        }
      }
      if (!p) return false;
      env.teleport({ position: p, yaw: env.look().yaw });
      if (g.traps) g.traps.noteTeleport();
      this._engage(v, p, env.now());
    }
    return this.tryGrab(true);
  }
}

/** SwimController.climbPath: hauled up over the edge first, then over it and onto the feet. */
export function climbPath(from, target, alpha, out = new THREE.Vector3()) {
  const a = clamp01(alpha);
  const overY = target.stand.y + 0.15;
  _over.set(from.x, overY, from.z).lerp(_c2.set(target.edge.x, overY, target.edge.z), 0.35);
  if (a < 0.5) return out.copy(from).lerp(_over, smoothstep(0, 1, a / 0.5));
  return out.copy(_over).lerp(target.stand, smoothstep(0, 1, (a - 0.5) / 0.5));
}

/** A yank's envelope `t` seconds after it began: a sharp rise, a slower release. */
export function tugEnvelope(t) {
  if (t < 0 || t >= TUG_SECONDS) return 0;
  return smoothstep(0, 0.05, t) * (1 - smoothstep(0.05, TUG_SECONDS, t));
}

const _l = new THREE.Vector3();
const _move = new THREE.Vector3();
const _target = new THREE.Vector3();
const _flat = new THREE.Vector3();
const _strafe = new THREE.Vector3();
const _err = new THREE.Vector3();
const _d = new THREE.Vector3();
const _fwd = new THREE.Vector3();
const _o = new THREE.Vector3();
const _a = new THREE.Vector3();
const _b = new THREE.Vector3();
const _c = new THREE.Vector3();
const _c2 = new THREE.Vector3();
const _over = new THREE.Vector3();
const _down = new THREE.Vector3(0, -1, 0);
const _up = new THREE.Vector3(0, 1, 0);
const _eye = new THREE.Vector3();
const _view = new THREE.Matrix4();
const _pulled = new THREE.Matrix4();
const _shake = new THREE.Matrix4();
const _out = new THREE.Matrix4();
const _e = new THREE.Euler();
