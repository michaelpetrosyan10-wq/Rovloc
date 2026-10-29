// traps.js: the Level 0 bear-trap gauntlet (BearTrapService + BearTrapController), single player.
//
// The plan's traps start Armed (jaws laid flat) on the anchors the run's plan chose (an exported trap is moved to an
// anchor it was not built on: the guard traps of the run's fuses, the seeded rest); every other trap is hidden. At
// 10 Hz, while the player may spring one (the run live, Alive, not caught, no control lock, on foot:
// Standing / Sprinting / Crouching, no
// teleport in the last 0.35 s) their foot point is tested against each armed trap's pan zone (the 2.2 x 2.2 trigger
// footprint from 0.5 under the floor up to 0.75 over it), including the segment from the previous sample (a
// sprinter covers two studs a sample) unless that step is a teleport (> 8 studs).
// Snap: the root is moved so the caught foot lands on the LegPoint, held (ControlLock "Trap", MoveState override
// Trapped); the pan drops and the jaws slam shut in 0.07 s after the lead; the 130-stud TrapSnap noise, the TrapSnap
// and BoneCrunch cues; RunStats TrapsTriggered; TrapDamage (35) last (lethal: downed, still caught).
// Pry: hold Interact on the Pry Open prompt for TrapSoloPrySeconds while looking down (pitch <= TrapLookDownPitch to
// start; a running pry tolerates 10 degrees more). Freed: the jaws are forced to 0.45 open with a MetalCreak (never
// re-armed), the lock and override released.
// Presentation: the Trapped input context, the kneel (camera Crouching), the look tilted down to the leg (the pitch
// cap eases to the leg, then the head may lift to just below the horizon), a sharp shake with the jaws, the hint,
// a panic floor; prying trembles the camera and the hands (HandRig "Pry") harder as the hold fills.

import * as THREE from 'three';
import { GameConfig } from '../config.js';
import { S } from '../strings.js';
import { cfMatrix, cfPos, clamp01, deg, horizontalDistance, lerp, rad, smoothstep } from '../util.js';

const SNAP_SECONDS = 0.07;
const PRY_OPEN_SECONDS = 0.6;
const PRIED_OPENNESS = 0.45;
const CRUNCH_DELAY = 0.03;
const PRY_REARM = 0.05;
const TELEPORT_GRACE = 0.35;
const LOOK_UP_SLACK = 10;
const PRESS_HEIGHT = 0.75;
const MAX_SWEEP_STEP = 8;
const TRIGGER_SIZE = [2.2, 4, 2.2];
const TRIGGER_BOTTOM = -0.5;
const JAW_OPEN_ANGLE = Math.PI / 2;
const SPRING_TRAVEL = rad(14) - rad(2);
const PAN_TILT = rad(8);
const CAUGHT_FOOT_SIDE = 1.05;
const CAUGHT_FOOT_AHEAD = 0.32;
const HIP_X = 0.5;
const LEG_LENGTH = 2;
const ROOT_TO_FEET = 3;
const LEAD = 0.2;
const POLL = 0.1;
const ON_FOOT = new Set(['Standing', 'Sprinting', 'Crouching']);
// client presentation
const PITCH_MIN = -80;
const TRAPPED_LOOK_DOWN = -55;
const TRAPPED_PITCH_MAX = TRAPPED_LOOK_DOWN + 45;
const TILT_SETTLED = 1.5;
const TILT_MAX_SECONDS = 1.2;
const TRAPPED_PANIC = 0.35;
const SNAP_SHAKE = 1.6 * 2;
const SNAP_SHAKE_SECONDS = 0.55;
const TREMBLE_INTERVAL = 0.12;
const TREMBLE_PULSE = 0.3;
const TREMBLE_FLOOR = 0.25;
const PRY_HAND_RISE = 0.4;
const HINT_REPEAT = 4;

/** BearTrapService.lookingDown (pitch in radians). */
export function lookingDown(pitch, sustaining) {
  return Number.isFinite(pitch) && pitch <= rad(GameConfig.TrapLookDownPitch + (sustaining ? LOOK_UP_SLACK : 0));
}

/** Slab clipping: whether the segment a -> b passes through the box (frame inverse + half sizes). */
function segmentInBox(inv, half, a, b) {
  _a.copy(a).applyMatrix4(inv);
  _d.copy(b).applyMatrix4(inv).sub(_a);
  let t0 = 0;
  let t1 = 1;
  for (const ax of ['x', 'y', 'z']) {
    const p = _a[ax];
    const d = _d[ax];
    const h = half[ax];
    if (Math.abs(d) < 1e-9) {
      if (Math.abs(p) > h) return false;
      continue;
    }
    let enter = (-h - p) / d;
    let exit = (h - p) / d;
    if (enter > exit) [enter, exit] = [exit, enter];
    t0 = Math.max(t0, enter);
    t1 = Math.min(t1, exit);
    if (t0 > t1) return false;
  }
  return t0 <= t1;
}

function inBox(inv, half, p) {
  _a.copy(p).applyMatrix4(inv);
  return Math.abs(_a.x) <= half.x && Math.abs(_a.y) <= half.y && Math.abs(_a.z) <= half.z;
}

export class Traps {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Traps';
    this.game = game;
    this.env = game.env;
    /** @type {any[]} */
    this.traps = [];
    this.caught = null;
    this.lastFoot = null;
    this.graceUntil = -Infinity;
    this.pollClock = 0;
    // presentation
    this.tiltStarted = null;
    this.tiltDone = false;
    this.trembleClock = 0;
    this.hintAt = -Infinity;
    this.shakeAt = null;
    /** @type {{at: number, point: THREE.Vector3}|null} the bone crunch after the snap (game clock) */
    this.crunch = null;
    /** @type {{at: number, trap: object}|null} a pry refused for the head being up comes back on (game clock) */
    this.pryRearm = null;
    this.holdSince = null;
    for (const info of game.world.entities('BearTrap')) this.traps.push(this._make(info));
  }

  _make(info) {
    const a = info.attachments;
    const trap = {
      id: info.id,
      info,
      level: info.level,
      built: cfMatrix(info.pivot),
      builtRest: {
        JawA: cfMatrix(a.JawARest), JawB: cfMatrix(a.JawBRest), SpringA: cfMatrix(a.SpringARest),
        SpringB: cfMatrix(a.SpringBRest), Pan: cfMatrix(a.PanRest),
      },
      builtLeg: cfPos(a.LegPoint),
      prompt: info.prompts.find((p) => p.name === 'TrapPry'),
      cull: Math.hypot(TRIGGER_SIZE[0], TRIGGER_SIZE[2]) / 2 + 0.5,
      state: 'Armed',
      live: false,
      motion: null,
      handle: null,
    };
    this._layout(trap, trap.built);
    return trap;
  }

  /**
   * Lays a trap out at a pivot (its built one, or the anchor the run's plan moved it to): the floor and leg points, the
   * leaves' rest frames and the pan zone (the trigger footprint from its bottom up to PressHeight over the floor).
   */
  _layout(trap, pivot) {
    const delta = _m.copy(pivot).multiply(_m2.copy(trap.built).invert());
    const zone = pivot.clone().multiply(new THREE.Matrix4().makeTranslation(0, TRIGGER_BOTTOM + TRIGGER_SIZE[1] / 2, 0));
    const floorLocalY = -(TRIGGER_BOTTOM + TRIGGER_SIZE[1] / 2);
    const bottom = -TRIGGER_SIZE[1] / 2;
    const top = Math.min(TRIGGER_SIZE[1] / 2, Math.max(bottom, floorLocalY + PRESS_HEIGHT));
    const panFrame = zone.clone().multiply(new THREE.Matrix4().makeTranslation(0, (bottom + top) / 2, 0));
    trap.pivot = pivot.clone();
    trap.floor = new THREE.Vector3().setFromMatrixPosition(pivot);
    trap.leg = trap.builtLeg.clone().applyMatrix4(delta);
    trap.rest = {};
    for (const [k, m] of Object.entries(trap.builtRest)) trap.rest[k] = delta.clone().multiply(m);
    trap.panInv = panFrame.clone().invert();
    trap.panHalf = new THREE.Vector3(TRIGGER_SIZE[0] / 2, (top - bottom) / 2, TRIGGER_SIZE[2] / 2);
    trap.centre = new THREE.Vector3().setFromMatrixPosition(panFrame);
  }

  // ---------------------------------------------------------------------------------------------------- poses

  /** BearTrapBuilder.setJaws (1 = armed flat, 0 = snapped). */
  _setJaws(trap, openness) {
    const open = clamp01(openness);
    const angle = open * JAW_OPEN_ANGLE;
    const press = open * SPRING_TRAVEL;
    const env = this.env;
    env.setNodePivot(trap.id, 'JawA', _m.copy(trap.rest.JawA).multiply(_r.makeRotationX(angle)));
    env.setNodePivot(trap.id, 'JawB', _m.copy(trap.rest.JawB).multiply(_r.makeRotationX(-angle)));
    env.setNodePivot(trap.id, 'SpringA', _m.copy(trap.rest.SpringA).multiply(_r.makeRotationZ(press)));
    env.setNodePivot(trap.id, 'SpringB', _m.copy(trap.rest.SpringB).multiply(_r.makeRotationZ(-press)));
  }

  _setPan(trap, depressed) {
    this.env.setNodePivot(trap.id, 'Pan', _m.copy(trap.rest.Pan).multiply(_r.makeRotationX(-clamp01(depressed) * PAN_TILT)));
  }

  _startMotion(trap, from, to, seconds, ease) {
    trap.motion = { from, to, seconds, ease, startAt: this.env.now() + LEAD };
  }

  // ---------------------------------------------------------------------------------------------------- run

  beginRun(run) {
    for (const trap of this.traps) {
      trap.live = run.plan.props.has(trap.id);
      trap.state = trap.live ? 'Armed' : 'Spent';
      trap.motion = null;
      // the run's plan may serve another anchor with this trap (worldData.plan placements)
      const placed = run.plan.placements ? run.plan.placements.get(trap.id) : null;
      this._layout(trap, placed || trap.built);
      this.env.setEntityPivot(trap.id, trap.pivot);
      this.env.setEntityVisible(trap.id, trap.live);
      if (trap.live) {
        this._setJaws(trap, 1);
        this._setPan(trap, 0);
        const spec = trap.prompt;
        trap.handle = this.env.addPrompt({
          entity: trap.id,
          attachment: spec ? spec.host : 'PromptPoint',
          text: S('Prompt.TrapPry'),
          objectText: S('Prompt.Trap'),
          holdSeconds: GameConfig.TrapSoloPrySeconds,
          distance: spec ? spec.maxDistance : 7,
          requiresLineOfSight: false,
          enabled: false,
          onHoldBegan: (h) => this._pryBegan(trap, h),
          onTriggered: () => this._free(trap, 'Pry'),
        });
      }
    }
    this.caught = null;
    this.lastFoot = null;
    this.graceUntil = this.env.now() + TELEPORT_GRACE;
  }

  endRun() {
    if (this.caught) this._free(this.caught, 'Release');
    for (const trap of this.traps) {
      if (trap.handle) trap.handle.remove();
      trap.handle = null;
      trap.motion = null;
    }
  }

  /** A teleport the game made (spawns, checkpoints): the foot springs nothing for a moment. */
  noteTeleport() {
    this.graceUntil = this.env.now() + TELEPORT_GRACE;
    this.lastFoot = null;
  }

  /** The trap holding the player, or null. */
  trapOfPlayer() {
    return this.caught;
  }

  // ---------------------------------------------------------------------------------------------------- snap / free

  _canTrigger() {
    const g = this.game;
    return g.live() && g.life.state === 'Alive' && !this.caught && g.controlLock() === 'None' &&
      ON_FOOT.has(this.env.moveState()) && this.env.now() >= this.graceUntil;
  }

  /** Springs a trap on the player (also the dev shortcut). */
  snap(trap) {
    if (trap.state !== 'Armed' || this.caught) return false;
    const env = this.env;
    const g = this.game;
    trap.state = 'Caught';
    this.caught = trap;
    env.setEntityAttribute(trap.id, 'Armed', false);
    // the caught foot onto the leg point, the heading kept
    const yaw = env.look().yaw;
    _off.set(HIP_X * CAUGHT_FOOT_SIDE, -ROOT_TO_FEET, -LEG_LENGTH * CAUGHT_FOOT_AHEAD).applyAxisAngle(_up, yaw);
    _root.set(trap.leg.x, trap.floor.y, trap.leg.z).sub(_off);
    env.teleport({ position: _root, yaw });
    env.setLook(yaw, env.look().pitch);
    g.lock('Trap');
    env.pushOverride('BearTrap', 'Trapped');
    this._setPan(trap, 1);
    this._startMotion(trap, 1, 0, SNAP_SECONDS, 'In');
    trap.handle.setEnabled(true);
    // moments
    g.noise(trap.floor, 'TrapSnap');
    g.playAt('TrapSnap', trap.floor);
    this.crunch = { at: env.now() + CRUNCH_DELAY, point: trap.leg };
    g.stats.increment('TrapsTriggered');
    this._present(true);
    this.shakeAt = env.now() + LEAD;
    g.life.damage(GameConfig.TrapDamage, 'BearTrap');
    return true;
  }

  _pryBegan(trap, handle) {
    if (this.caught !== trap) return;
    if (!lookingDown(this.env.look().pitch, false)) {
      const now = this.env.realNow();
      if (now - this.hintAt >= HINT_REPEAT) {
        this.hintAt = now;
        this.env.hint(S('Hud.Trapped'), 4);
      }
      handle.setEnabled(false);
      this.pryRearm = { at: this.env.now() + PRY_REARM, trap };
    }
  }

  _free(trap, event) {
    if (trap.state !== 'Caught' || this.caught !== trap) return false;
    trap.state = 'Spent';
    this.caught = null;
    if (trap.handle) trap.handle.setEnabled(false);
    this.game.unlock('Trap');
    this.env.popOverride('BearTrap');
    if (event !== 'Release') {
      this._startMotion(trap, 0, PRIED_OPENNESS, PRY_OPEN_SECONDS, 'Out');
      this.game.playAt('MetalCreak', trap.leg);
    }
    this._present(false);
    this.graceUntil = this.env.now() + TELEPORT_GRACE;
    return true;
  }

  // ---------------------------------------------------------------------------------------------------- presentation

  _present(on) {
    const env = this.env;
    if (on) {
      env.pushContext('BearTrap', 'Trapped');
      env.forceCameraState('BearTrap', 'Crouching');
      env.setPanicFloor('BearTrap', TRAPPED_PANIC);
      env.hint(S('Hud.Trapped'), 6);
      this.tiltStarted = env.realNow();
      this.tiltDone = false;
    } else {
      env.popContext('BearTrap');
      env.forceCameraState('BearTrap', null);
      env.setPanicFloor('BearTrap', null);
      env.setPitchLimits(null, null);
      env.setHandPose('Flashlight');
      env.clearHint();
      this.tiltStarted = null;
    }
  }

  // ---------------------------------------------------------------------------------------------------- drive

  tick(dt, now) {
    const g = this.game;
    // releases: the victim died / left play
    if (this.caught && !g.life.playing()) this._free(this.caught, 'Release');
    if (!g.live()) return;
    this.pollClock += dt;
    if (this.pollClock >= POLL) {
      this.pollClock = 0;
      if (!this._canTrigger()) {
        this.lastFoot = null;
      } else {
        const foot = this.env.feetPosition(_foot);
        let from = this.lastFoot;
        if (from && horizontalDistance(from, foot) > MAX_SWEEP_STEP) from = null;
        const reach = from ? horizontalDistance(from, foot) : 0;
        let best = null;
        let bestD = Infinity;
        for (const trap of this.traps) {
          if (trap.state !== 'Armed' || trap.level !== g.level) continue;
          const d = horizontalDistance(trap.centre, foot);
          if (d > trap.cull + reach || d >= bestD) continue;
          if (inBox(trap.panInv, trap.panHalf, foot) || (from && segmentInBox(trap.panInv, trap.panHalf, from, foot))) {
            best = trap;
            bestD = d;
          }
        }
        this.lastFoot = this.lastFoot ? this.lastFoot.copy(foot) : foot.clone();
        if (best) this.snap(best);
      }
    }
    // a running pry breaks once the head lifts past the slack
    const trap = this.caught;
    if (trap && trap.handle && trap.handle.isHolding() && !lookingDown(this.env.look().pitch, true)) {
      trap.handle.setEnabled(false);
      trap.handle.setEnabled(true);
      this.env.hint(S('Hud.Trapped'), 4);
    }
  }

  frame(dt, now) {
    const env = this.env;
    for (const trap of this.traps) {
      const m = trap.motion;
      if (!m || now < m.startAt) continue;
      const t = clamp01((now - m.startAt) / Math.max(m.seconds, 1e-3));
      const eased = m.ease === 'In' ? t * t : 1 - (1 - t) ** 3;
      this._setJaws(trap, m.from + (m.to - m.from) * eased);
      if (t >= 1) trap.motion = null;
    }
    if (this.shakeAt !== null && now >= this.shakeAt) {
      this.shakeAt = null;
      env.shake(SNAP_SHAKE * clamp01(env.setting('MotionScale') ?? 1), SNAP_SHAKE_SECONDS);
    }
    if (this.crunch && now >= this.crunch.at) {
      this.game.playAt('BoneCrunch', this.crunch.point);
      this.crunch = null;
    }
    if (this.pryRearm && now >= this.pryRearm.at) {
      const { trap: refused } = this.pryRearm;
      this.pryRearm = null;
      if (this.caught === refused && refused.handle) refused.handle.setEnabled(true);
    }
    const trap = this.caught;
    if (!trap) return;
    // the tilt toward the leg
    if (this.tiltStarted !== null && !this.tiltDone) {
      const eye = env.eye(_eye);
      const target = tiltPitch(eye, trap.leg);
      env.setPitchLimits(PITCH_MIN, target);
      const pitch = deg(env.look().pitch);
      if (pitch <= target + TILT_SETTLED || env.realNow() - this.tiltStarted >= TILT_MAX_SECONDS) {
        this.tiltDone = true;
        env.setPitchLimits(PITCH_MIN, TRAPPED_PITCH_MAX);
      }
    }
    // the pry's tremble
    if (trap.handle && trap.handle.isHolding()) {
      if (this.holdSince === null) this.holdSince = now;
      const progress = clamp01((now - this.holdSince) / GameConfig.TrapSoloPrySeconds);
      const intensity = TREMBLE_FLOOR + (1 - TREMBLE_FLOOR) * smoothstep(0, 1, progress);
      this.trembleClock += dt;
      if (this.trembleClock >= TREMBLE_INTERVAL) {
        this.trembleClock = 0;
        env.shake(lerp(0.12, 0.9, intensity) * clamp01(env.setting('MotionScale') ?? 1), TREMBLE_PULSE);
      }
      const yaw = env.look().yaw;
      _hand.makeRotationY(yaw).setPosition(trap.leg.x, trap.leg.y + PRY_HAND_RISE, trap.leg.z);
      env.setHandPose('Pry', _hand);
    } else {
      this.holdSince = null;
      env.setHandPose('Flashlight');
    }
  }
}

/** BearTrapController.tiltPitch (degrees). */
export function tiltPitch(eye, leg) {
  _d.subVectors(leg, eye);
  const len = _d.length();
  if (len < 1e-3) return TRAPPED_LOOK_DOWN;
  const pitch = deg(Math.asin(Math.max(-1, Math.min(1, _d.y / len))));
  return Math.min(TRAPPED_LOOK_DOWN, Math.max(PITCH_MIN, pitch));
}

const _a = new THREE.Vector3();
const _d = new THREE.Vector3();
const _m = new THREE.Matrix4();
const _r = new THREE.Matrix4();
const _m2 = new THREE.Matrix4();
const _off = new THREE.Vector3();
const _up = new THREE.Vector3(0, 1, 0);
const _root = new THREE.Vector3();
const _foot = new THREE.Vector3();
const _eye = new THREE.Vector3();
const _hand = new THREE.Matrix4();
