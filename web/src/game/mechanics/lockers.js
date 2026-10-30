// lockers.js: the Level 3 hideable lockers and the hold-breath check (LockerHidingService + LockerMotion +
// LockerController), for the one player. The only writer of a locker's door pose and its OccupantUserId / DoorOpen.
//
// A locker is Free, Entering, Hidden, Exiting or Smashed (its door torn off by the Creature: never usable again this
// run). The Hide prompt (0.25 s hold) serves every unsmashed locker, except one Floor 3's key search holds ajar
// (setSearchOpen).
//
// Getting in (canHide: the run is live, Alive, no control lock, on foot, not hiding already, the locker Free, the
// Creature not chasing you; Hud.LockerOccupied / Hud.LockerSeen tell the refusals that matter). At once: the Locker
// lock and the Hiding MoveState, the torch off, the door swinging open (LockerMotion.enterSchedule from OneShotLead);
// when it is open the body is moved inside (HideAnchor, facing out); then the door shuts and the occupant is settled
// (LockersHidden + 1). The camera glides to the door, turns round as it backs in and settles behind the middle slit;
// behind the slits the look is free within YAW_LIMIT of straight out, with a slow breathing sway; the hands hook into
// the slits; every prompt is suppressed (Interact steps out); the lungs meter and a leave hint show.
//
// Getting out (Interact, or LEAVE on touch): only while settled and not under a check, to a clear spot (the ExitAnchor,
// else a step to either side, else one further out; none clear: Hud.LockerBlocked). The door opens, the camera leans
// to it and steps out, the body is put there facing away from the locker, the lock and override are released, the door
// shuts. Going Downed releases the occupant outside; dying or the run ending drops them where they are.
//
// The inspector (the Creature's registerLockerInspector; InvestigateNoise calls it hunched at the door):
//   * Empty (nobody inside): "Empty" after EmptyPeekSeconds.
//   * Occupied: the hold-breath check. The peek lasts a seeded PeekMin..PeekMax; the window opens WarnSeconds after the
//     check starts (after the occupant is settled, for one still climbing in). HOLD YOUR BREATH (with the HoldBreath
//     glyph in a ring that fills toward the window and drains with the peek), the heartbeat up through the panic
//     floor, the vignette closing in, the CreatureSniff at the slits and a jolt as its breath first hits them. Holding
//     drains the lungs one second per second, letting go recovers BreathRecoverPerSecond. judge: a held breath running
//     out ("OutOfBreath"), a release inside the window with less than CalmFraction left ("Gasp"), or not holding
//     inside the window for longer than ReholdGrace ("Breathing") is caught; holding through it is "HiddenSafe". The
//     Creature leaving the door (not investigating, or more than AT_DOOR from it) ends the check safe.
//   * Caught: the Gasp cue at the slits and the Gasp noise, then "Caught". When the Creature's catch takes over (its
//     caught event, kind Locker), the door is ripped off (the torn door flung to its DoorLanding), the lock and the
//     override are released (the catch holds the body), and the locker is Smashed; when the catch ends with the
//     player still playing, they are put down outside it. A catch that did not take leaves them hidden.
// Holding a breath until it runs out outside a check is a gasp too (the cue and the noise).

import * as THREE from 'three';
import { GameConfig } from '../config.js';
import { S } from '../strings.js';
import { Palette, el, meter } from '../ui/style.js';
import { cfMatrix, clamp01, frameAt, horizontalDistance, lerpFrame, seededRandom, smoothstep, wrapAngle, yawOf } from '../util.js';
import { valueAt } from './doors.js';

// LockerMotion
export const OpenSeconds = 0.34;
export const StepInSeconds = 0.55;
export const StepOutSeconds = 0.5;
export const CloseSeconds = 0.38;
export const RipSeconds = 0.75;
export const BreathMax = GameConfig.BreathHoldMaxSeconds;
export const CalmFraction = 0.3;
export const ReholdGrace = 0.5;
export const WarnSeconds = 0.9;
export const PeekMin = 3.5;
export const PeekMax = 6;
export const EmptyPeekSeconds = 1.3;
const DRAIN = 1;
const RECOVER = GameConfig.BreathRecoverPerSecond;

// LockerHidingService
const LEAD = GameConfig.OneShotLead;
const SLIT_OUT = 0.45;
const EXIT_SIDE = 1.6;
const EXIT_FURTHER = 1.2;
const ROOT_HEIGHT = 3;
const AT_DOOR = 8;
const DEV_CHECK_SECONDS = 5;
const ON_FOOT = new Set(['Standing', 'Sprinting', 'Crouching']);
const CHASES = new Set(['WallChase', 'VentChase']);
const CLEAR_HALF_WIDTH = 0.9;
const SEARCH_OPEN = 0.42; // Floor 3's key search (objectives/floor3.js): a searched locker's door stands this far open

// LockerBuilder
const DOOR_OPEN_ANGLE = (110 * Math.PI) / 180;
const DOOR_BOTTOM = 0.4;
const DOOR_TOP = 7.0;
const DOOR_WIDTH = 2.64;
const DOOR_T = 0.1;
const DOOR_PROUD = 0.12;
const FLOOR_CLEARANCE = 0.005;
const RIP_WRENCH = 0.3;
const RIP_WRENCH_ANGLE = (72 * Math.PI) / 180;
const RIP_ARC = 1.4;

// LockerController
const YAW_LIMIT = (38 * Math.PI) / 180;
const DOOR_STAND = 1.55;
const ENTER_DIP = 0.35;
const EXHALE_AFTER = 1.2;
const RESULT_LINGER = 1.4;
const HAND_IN = 0.28;
const SWAY_PITCH = (0.55 * Math.PI) / 180;
const SWAY_ROLL = (0.4 * Math.PI) / 180;
const SWAY_LIFT = 0.025;
const TREMBLE_BELOW = 0.35;
const TREMBLE_DEGREES = 0.9;
const FLINCH_DEGREES = 0.7;
const FLINCH_SECONDS = 0.35;
const RIP_SHAKE_RADIUS = 22;
const RIP_SHAKE = 2.6;
const RIP_LANDS = 0.55;
const HIDDEN_PANIC = 0.3;
const WARN_PANIC = 0.78;
const WINDOW_PANIC = 0.97;
const SAFE_PANIC = 0.45;
const EYE_ABOVE_ROOT = 1.5;

/** @typedef {{value: number, held: boolean, at: number}} Breath */

/** Seconds of breath at `now`. @param {Breath} breath */
export function breathAt(breath, now) {
  const elapsed = Math.max(0, now - breath.at);
  return breath.held ? Math.max(0, breath.value - DRAIN * elapsed) : Math.min(BreathMax, breath.value + RECOVER * elapsed);
}

/** The lungs from `now` on, holding or not (the same `held` keeps the record). */
export function setHeld(breath, held, now) {
  if (breath.held === held) return breath;
  const at = Math.max(now, breath.at);
  return { value: breathAt(breath, at), held, at };
}

/** When a held breath runs out (null while not holding). */
export function emptyAt(breath) {
  return breath.held ? breath.at + breath.value / DRAIN : null;
}

/** Whether letting go with `value` left is a quiet breath out. */
export function calm(value) {
  return value >= CalmFraction * BreathMax - 1e-9;
}

export function enterSchedule(startAt) {
  const moveAt = startAt + OpenSeconds;
  const closeAt = moveAt + StepInSeconds;
  return { openAt: startAt, moveAt, closeAt, settledAt: closeAt + CloseSeconds };
}

export function exitSchedule(startAt) {
  const moveAt = startAt + OpenSeconds;
  const closeAt = moveAt + StepOutSeconds;
  return { openAt: startAt, moveAt, closeAt, settledAt: closeAt + CloseSeconds };
}

/** canHide: whether the player may climb in, and the refusal shown when it matters. */
export function canHide(check) {
  if (!check.live) return [false, 'NotLive'];
  if (check.lifeState !== 'Alive') return [false, 'LifeState'];
  if (check.hiding) return [false, 'Hiding'];
  if (check.lockerState !== 'Free') return [false, 'Hud.LockerOccupied'];
  if (check.controlLock !== 'None') return [false, 'Locked'];
  if (!ON_FOOT.has(check.moveState)) return [false, 'Posture'];
  if (check.chasedBy) return [false, 'Hud.LockerSeen'];
  return [true, null];
}

/**
 * judge: the verdict of a breath check at `now`, if it has one: [verdict, reason, the instant it was decided].
 * @param {{startedAt: number, windowStart: number, windowEnd: number, breath: Breath}} view
 */
export function judge(view, now) {
  const breath = view.breath;
  const empty = emptyAt(breath);
  if (empty !== null && empty <= now && empty >= view.startedAt && empty < view.windowEnd) return ['Caught', 'OutOfBreath', empty];
  if (now < view.windowStart) return [null, null, null];
  if (!breath.held) {
    const inWindow = breath.at >= view.windowStart && breath.at < view.windowEnd;
    if (inWindow && !calm(breath.value)) return ['Caught', 'Gasp', breath.at];
    const heard = Math.max(breath.at, view.windowStart) + ReholdGrace;
    if (heard < view.windowEnd && heard <= now) return ['Caught', 'Breathing', heard];
  }
  if (now >= view.windowEnd) return ['HiddenSafe', 'Held', view.windowEnd];
  return [null, null, null];
}

/** The door's transform about its hinge for `openness` (LockerBuilder.doorTransform). */
function doorTransform(swing, openness, out) {
  return out.makeRotationY(swing * clamp01(openness) * DOOR_OPEN_ANGLE);
}

/** LockerBuilder.rippedTransform: wrenched against the hinge, torn free and flung in an arc to `landed`. */
function rippedTransform(swing, landed, t, out) {
  const progress = clamp01(t);
  _wrench.makeRotationY(swing * RIP_WRENCH_ANGLE).setPosition(swing * 0.06, 0.18, -0.3);
  if (progress <= RIP_WRENCH) {
    const s = progress / RIP_WRENCH;
    return lerpFrame(_identity, _wrench, 1 - (1 - s) * (1 - s), out);
  }
  const s = (progress - RIP_WRENCH) / (1 - RIP_WRENCH);
  lerpFrame(_wrench, landed, s, out);
  out.premultiply(_lift.makeTranslation(0, 4 * RIP_ARC * s * (1 - s), 0));
  // never through the floor
  let lowest = Infinity;
  const latch = swing * DOOR_WIDTH;
  for (const [x, y] of [[0, DOOR_BOTTOM], [latch, DOOR_BOTTOM], [latch, DOOR_TOP], [0, DOOR_TOP]]) {
    for (const z of [-DOOR_PROUD, DOOR_T]) lowest = Math.min(lowest, _c.set(x, y, z).applyMatrix4(out).y);
  }
  if (lowest < FLOOR_CLEARANCE) out.premultiply(_lift.makeTranslation(0, FLOOR_CLEARANCE - lowest, 0));
  return out;
}

export class Lockers {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Lockers';
    this.game = game;
    this.env = game.env;
    /** @type {Map<string, any>} */
    this.lockers = new Map();
    for (const info of game.world.entities('Locker')) this.lockers.set(info.id, this._make(info));
    this.occupied = null;
    /** @type {Breath|null} */
    this.breath = null;
    this.peeks = [];
    this.taken = null;
    this.random = seededRandom(1, 'Lockers');
    this.session = null;
    /** @type {{at: number, preset: string, position: THREE.Vector3}[]} door cues waiting for their motion's start */
    this.cues = [];
    this.devCheckPending = false;
    this.ui = this._buildUi();
    this.env.onAction('HoldBreath', (phase) => this._onHoldBreath(phase === 'Begin'));
    this.env.onAction('Interact', (phase) => {
      if (phase === 'Begin' && this.session && this.session.phase === 'Hidden') this.requestExit();
    });
    game.life.changed.connect((state) => this._onLife(state));
    game.creature.caught.connect((kind) => this._onCaught(kind));
    game.creature.jumpscareFinished.connect((kind) => this._onCatchFinished(kind));
    game.creature.registerLockerInspector((id) => this.inspect(id));
  }

  _make(info) {
    const a = info.attachments;
    const base = cfMatrix(info.pivot);
    const rest = cfMatrix(a.DoorRest);
    const local = new THREE.Vector3().setFromMatrixPosition(rest).applyMatrix4(base.clone().invert());
    const swing = local.x <= 0 ? 1 : -1;
    const restInv = rest.clone().invert();
    return {
      id: info.id,
      info,
      level: info.level,
      zone: info.attributes.ZoneId,
      base,
      rest,
      swing,
      landed: a.DoorLanding ? restInv.clone().multiply(cfMatrix(a.DoorLanding)) : rest.clone().identity(),
      peek: cfMatrix(a.PeekAnchor),
      hide: cfMatrix(a.HideAnchor),
      exit: cfMatrix(a.ExitAnchor),
      prompt: info.prompts.find((p) => p.name === 'Hide') || null,
      state: 'Free',
      motion: null,
      schedule: null,
      moved: false,
      closing: false,
      exitSpot: null,
      check: null,
      handle: null,
    };
  }

  // ---------------------------------------------------------------------------------------------------- geometry

  _peekPoint(locker, out) {
    return out.setFromMatrixPosition(locker.peek);
  }

  /** The slits' outer face, where the Creature breathes in at you. */
  _slit(locker, out = new THREE.Vector3()) {
    return out.set(0, 0, -SLIT_OUT).applyMatrix4(locker.peek);
  }

  _doorPoint(locker, out = new THREE.Vector3()) {
    return out.set(0, -1.2, -SLIT_OUT).applyMatrix4(locker.peek);
  }

  /** Whether a standing body fits at a floor frame: a clear line from the door and nothing within a body's width. */
  _spotClear(locker, floor) {
    const env = this.env;
    const chest = _a.set(0, ROOT_HEIGHT, 0).applyMatrix4(floor);
    if (!env.lineClear(this._doorPoint(locker, _b), chest, { ignoreEntities: false })) return false;
    for (const lift of [1.2, 3.6]) {
      _o.set(0, lift, 0).applyMatrix4(floor);
      for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        _d.set(dx, 0, dz);
        const hit = env.raycast(_o, _d, CLEAR_HALF_WIDTH, { ignoreEntities: false });
        if (hit) return false;
      }
    }
    return true;
  }

  /** The first clear spot a body can step out to (root frame facing away from the locker), or null. */
  _exitSpot(locker) {
    const e = locker.exit;
    const candidates = [e.clone(), e.clone().multiply(_t.makeTranslation(EXIT_SIDE, 0, 0)),
      e.clone().multiply(_t.makeTranslation(-EXIT_SIDE, 0, 0)), e.clone().multiply(_t.makeTranslation(0, 0, -EXIT_FURTHER))];
    for (const floor of candidates) {
      if (this._spotClear(locker, floor)) return floor.multiply(_t.makeTranslation(0, ROOT_HEIGHT, 0));
    }
    return null;
  }

  // ---------------------------------------------------------------------------------------------------- doors

  _pose(locker, mode, value) {
    const m = mode === 'Smash' ? rippedTransform(locker.swing, locker.landed, value, _m) : doorTransform(locker.swing, value, _m);
    this.env.setNodePivot(locker.id, 'Door', _m2.copy(locker.rest).multiply(m));
  }

  _startDoor(locker, mode, from, to, seconds, startAt) {
    locker.motion = { mode, from, to, startAt, seconds, ease: mode === 'Smash' ? 'Linear' : 'InOut' };
    if (mode === 'Smash' || to > 0) this.env.setEntityAttribute(locker.id, 'DoorOpen', true);
    this.cues.push({ at: startAt, preset: mode === 'Smash' ? 'LockerRip' : 'LockerDoor', position: this._doorPoint(locker) });
    if (mode === 'Smash') locker.ripShakeAt = startAt + seconds * RIP_LANDS;
  }

  _stepDoor(locker, now) {
    const motion = locker.motion;
    if (!motion) return;
    const [value, done] = valueAt(motion, now);
    this._pose(locker, motion.mode, value);
    if (done) {
      locker.motion = null;
      if (motion.mode === 'Swing' && motion.to <= 0) this.env.setEntityAttribute(locker.id, 'DoorOpen', false);
    }
  }

  // ---------------------------------------------------------------------------------------------------- run

  beginRun(run) {
    this.random = seededRandom(run.seed, 'Lockers');
    this._clear();
    for (const locker of this.lockers.values()) {
      locker.state = 'Free';
      locker.searchOpen = false;
      locker.motion = null;
      locker.schedule = null;
      locker.check = null;
      locker.ripShakeAt = null;
      locker.remote = null;
      locker.remoteCloseAt = null;
      this._pose(locker, 'Swing', 0);
      this.env.setEntityAttribute(locker.id, 'DoorOpen', false);
      this.env.setEntityAttribute(locker.id, 'OccupantUserId', 0);
      const spec = locker.prompt;
      locker.handle = this.env.addPrompt({
        entity: locker.id,
        attachment: spec ? spec.host : 'HidePrompt',
        text: S('Prompt.Hide'),
        objectText: S('Prompt.Locker'),
        holdSeconds: spec ? spec.holdDuration : 0.25,
        distance: spec ? spec.maxDistance : 7,
        requiresLineOfSight: false,
        // co-op: one hider per locker (the host grants it); the others see its door open and shut on a teammate
        net: 'claim',
        netRemote: (member) => this.remoteOccupy(locker, member),
        netRelease: (member) => this.remoteVacate(locker, member),
        onTriggered: () => this.hide(locker),
      });
    }
  }

  endRun() {
    this._clear();
    for (const locker of this.lockers.values()) {
      if (locker.handle) locker.handle.remove();
      locker.handle = null;
      locker.motion = null;
      locker.schedule = null;
      this._pose(locker, 'Swing', 0);
    }
  }

  _clear() {
    this.cues = [];
    this.devCheckPending = false;
    if (this.occupied) this._drop(this.occupied, false);
    for (const peek of this.peeks) peek.resolve('Empty');
    this.peeks = [];
    this.taken = null;
    this._endSession();
  }

  // ---------------------------------------------------------------------------------------------------- in and out

  _hideCheck(locker) {
    const g = this.game;
    return {
      live: g.live(),
      lifeState: g.life.state,
      controlLock: g.controlLock(),
      moveState: this.env.moveState(),
      hiding: this.occupied !== null,
      lockerState: locker.state,
      chasedBy: CHASES.has(g.creature.getState()) && g.creature.hasTarget(),
    };
  }

  /** The Hide prompt (and the dev `hide`): climbs into `locker` when the rules allow it. */
  hide(locker) {
    const [ok, reason] = canHide(this._hideCheck(locker));
    if (!ok) {
      if (reason === 'Hud.LockerOccupied' || reason === 'Hud.LockerSeen') this.env.hint(S(reason), 3);
      // co-op: a locker granted but not entered goes back to the squad
      const coop = this.game.coop;
      if (coop && coop.active && locker.handle && this.occupied !== locker) coop.actions.release(locker.handle.id);
      return false;
    }
    this._enter(locker);
    return true;
  }

  _enter(locker) {
    const env = this.env;
    const g = this.game;
    const now = env.now();
    locker.state = 'Entering';
    locker.moved = false;
    locker.closing = false;
    this.occupied = locker;
    this.breath = { value: BreathMax, held: false, at: now };
    env.setEntityAttribute(locker.id, 'OccupantUserId', 1);
    g.lock('Locker');
    env.pushOverride('Locker', 'Hiding');
    env.setFlashlight(false);
    const startAt = now + LEAD;
    locker.schedule = enterSchedule(startAt);
    this._startDoor(locker, 'Swing', 0, 1, OpenSeconds, startAt);
    this._beginSession(locker);
  }

  /** ExitHide: steps out when settled, not under a check and a clear spot exists. */
  requestExit() {
    const locker = this.occupied;
    if (!locker) return false;
    const s = this.session;
    if (s && s.window) {
      const stage = promptStage(s.window, this.env.now());
      if (stage === 'Warn' || stage === 'Window') return false;
    }
    if (locker.state !== 'Hidden' || locker.check) return false;
    const spot = this._exitSpot(locker);
    if (!spot) {
      this.env.hint(S('Hud.LockerBlocked'), 3);
      return false;
    }
    this._beginExit(locker, spot);
    return true;
  }

  _beginExit(locker, spot) {
    const now = this.env.now();
    if (locker.check) this._finishCheck(locker.check, 'Empty', 'Gone', now);
    locker.state = 'Exiting';
    locker.exitSpot = spot;
    locker.moved = false;
    locker.closing = false;
    const startAt = now + LEAD;
    locker.schedule = exitSchedule(startAt);
    const from = locker.motion ? valueAt(locker.motion, now)[0] : 0;
    this._startDoor(locker, 'Swing', from, 1, OpenSeconds * (1 - from), startAt);
    if (this.session) {
      this.session.phase = 'Exiting';
      this.session.schedule = locker.schedule;
      this.session.exitEye = spot.clone().multiply(_t.makeTranslation(0, EYE_ABOVE_ROOT, 0));
    }
  }

  /** The occupant is out (moved out, or let go where they are). */
  _vacate(locker) {
    const env = this.env;
    if (this.occupied !== locker) return;
    this.occupied = null;
    this.breath = null;
    env.setEntityAttribute(locker.id, 'OccupantUserId', 0);
    env.popOverride('Locker');
    this.game.unlock('Locker');
    // co-op: the locker is free for the squad again
    const coop = this.game.coop;
    if (coop && coop.active && locker.handle) coop.actions.release(locker.handle.id);
  }

  /** Lets the occupant go at once: out to a clear spot when `outside`, else where they are. */
  _release(locker, outside) {
    if (this.occupied !== locker) return;
    const spot = outside ? this._exitSpot(locker) : null;
    if (locker.state !== 'Exiting') this._beginExit(locker, spot);
    if (!locker.moved) {
      locker.moved = true;
      const target = spot || locker.exitSpot;
      if (target) this._teleport(target);
      this._vacate(locker);
      this._endSession();
    }
  }

  /** Lets the occupant go where they are (dead, the run ending); a door left open swings shut while the run is live. */
  _drop(locker, live = this.game.live()) {
    const now = this.env.now();
    if (locker.check) this._finishCheck(locker.check, 'Empty', 'Gone', now);
    locker.check = null;
    locker.schedule = null;
    this._vacate(locker);
    this._endSession();
    if (locker.state === 'Smashed') return;
    locker.state = 'Free';
    const motion = locker.motion;
    const openness = motion ? valueAt(motion, now)[0] : 0;
    if ((openness > 1e-3 || (motion && motion.to > 0)) && live) {
      this._startDoor(locker, 'Swing', openness, 0, CloseSeconds * openness, now + LEAD);
    }
  }

  _teleport(rootFrame) {
    _p.setFromMatrixPosition(rootFrame);
    const yaw = yawOf(_d.set(-rootFrame.elements[8], 0, -rootFrame.elements[10]));
    this.env.teleport({ position: _p.clone(), yaw });
    if (this.game.traps) this.game.traps.noteTeleport();
  }

  _stepSchedule(locker, now) {
    const schedule = locker.schedule;
    if (!schedule) return;
    if (!locker.moved && now >= schedule.moveAt) {
      locker.moved = true;
      if (locker.state === 'Entering' && this.occupied === locker) {
        const root = locker.hide.clone().multiply(_t.makeTranslation(0, ROOT_HEIGHT, 0));
        _p.setFromMatrixPosition(root);
        this.env.teleport({ position: _p.clone(), yaw: yawOf(_d.set(-locker.peek.elements[8], 0, -locker.peek.elements[10])) });
      } else if (locker.state === 'Exiting') {
        if (this.occupied === locker && locker.exitSpot) this._teleport(locker.exitSpot);
        this._vacate(locker);
      }
    }
    if (!locker.closing && now >= schedule.closeAt - LEAD) {
      locker.closing = true;
      this._startDoor(locker, 'Swing', 1, 0, CloseSeconds, Math.max(schedule.closeAt, now));
    }
    if (now >= schedule.settledAt && locker.closing && !locker.motion) {
      locker.schedule = null;
      if (locker.state === 'Entering') {
        locker.state = 'Hidden';
        if (this.occupied === locker) this.game.stats.increment('LockersHidden');
        if (this.session) this.session.phase = 'Hidden';
      } else if (locker.state === 'Exiting') {
        locker.state = 'Free';
        this._endSession();
      }
    }
  }

  // ---------------------------------------------------------------------------------------------------- the check

  /** registerLockerInspector: the Creature peeks into a locker; resolves with its verdict. */
  inspect(id) {
    const locker = this.lockers.get(id);
    if (!locker || !this.game.live()) return Promise.resolve('Empty');
    const now = this.env.now();
    if (locker.check && !locker.check.verdict) return new Promise((resolve) => locker.check.waiters.push(resolve));
    if (this.occupied === locker && (locker.state === 'Hidden' || locker.state === 'Entering')) {
      const check = this._startCheck(locker, now, this.random.number(PeekMin, PeekMax), false);
      if (check.verdict) return Promise.resolve(check.verdict);
      return new Promise((resolve) => check.waiters.push(resolve));
    }
    return new Promise((resolve) => this.peeks.push({ locker, resolveAt: now + EmptyPeekSeconds, resolve }));
  }

  _startCheck(locker, now, peek, scripted) {
    const schedule = locker.schedule;
    const warnAt = locker.state === 'Entering' && schedule ? Math.max(now, schedule.settledAt) : now;
    const windowStart = warnAt + WarnSeconds;
    const check = { locker, startedAt: warnAt, windowStart, windowEnd: windowStart + peek, verdict: null, reason: null,
      waiters: [], sniff: null, sniffAt: null, scripted, cued: false };
    locker.check = check;
    check.sniffAt = scripted ? null : warnAt;
    this._advance(check, now);
    return check;
  }

  _creatureAtDoor(locker) {
    const c = this.game.creature;
    if (c.getState() !== 'InvestigateNoise') return false;
    const at = c.position(_a);
    return !!at && horizontalDistance(at, _b.setFromMatrixPosition(locker.exit)) <= AT_DOOR;
  }

  _advance(check, now) {
    if (check.verdict) return;
    const locker = check.locker;
    if (this.occupied !== locker) {
      this._finishCheck(check, 'Empty', 'Gone', now);
      return;
    }
    if (!check.scripted && !this._creatureAtDoor(locker)) {
      this._finishCheck(check, 'HiddenSafe', 'Left', now);
      return;
    }
    if (check.sniffAt !== null && now >= check.sniffAt) {
      check.sniffAt = null;
      check.sniff = this.game.playAt('CreatureSniff', this._slit(locker), { loop: true });
    }
    if (!check.cued && now >= check.startedAt) {
      check.cued = true;
      if (this.session) this.session.window = { warnAt: check.startedAt, startAt: check.windowStart, endsAt: check.windowEnd, verdict: null, resultAt: null };
    }
    const [verdict, reason, at] = judge({ startedAt: check.startedAt, windowStart: check.windowStart, windowEnd: check.windowEnd,
      breath: this.breath }, now);
    if (verdict) this._finishCheck(check, verdict, reason, at);
  }

  _gasp(locker, at) {
    if (this.breath) this.breath = { value: breathAt(this.breath, at), held: false, at };
    const mouth = this._peekPoint(locker, new THREE.Vector3());
    this.game.playAt('Gasp', mouth);
    this.game.noise(mouth, 'Gasp');
    if (this.session) {
      this.session.held = false;
      this.env.setBreathSuppressed('Locker', false);
    }
  }

  _finishCheck(check, verdict, reason, at) {
    if (check.verdict) return;
    check.verdict = verdict;
    check.reason = reason;
    if (check.sniff) check.sniff.stop(0.4);
    check.sniff = null;
    if (verdict === 'Caught') this._gasp(check.locker, at);
    if (verdict !== 'Empty' && this.session && this.session.window) {
      this.session.window.verdict = verdict;
      this.session.window.resultAt = this.env.now();
    }
    if (check.locker.check === check) check.locker.check = null;
    this.pendingCatch = verdict === 'Caught' && !check.scripted ? check.locker : null;
    for (const resolve of check.waiters.splice(0)) resolve(verdict);
  }

  /** The Creature's catch started: a Locker catch on the gasping occupant tears the door off. */
  _onCaught(kind) {
    const locker = this.pendingCatch;
    this.pendingCatch = null;
    if (kind !== 'Locker' || !locker || this.occupied !== locker) return;
    const now = this.env.now();
    locker.state = 'Smashed';
    locker.schedule = null;
    locker.check = null;
    this._startDoor(locker, 'Smash', 0, 1, RipSeconds, now + LEAD);
    if (locker.handle) locker.handle.setEnabled(false);
    const coop = this.game.coop;
    if (coop && coop.active) coop.mechanics.share('locker', { ev: 'rip', id: locker.id });
    this._vacate(locker);
    this._endSession();
    this.taken = locker;
  }

  // ---------------------------------------------------------------------------------------------------- co-op

  /** Co-op: a teammate climbs into `locker` on their page: its door swings open and shut on them here. */
  remoteOccupy(locker, member) {
    if (locker.state === 'Smashed') return;
    const now = this.env.now();
    locker.state = 'Hidden';
    locker.remote = member ? member.id : true;
    if (member) member.lockerId = locker.id;
    this.env.setEntityAttribute(locker.id, 'OccupantUserId', member ? member.slot + 1 : 2);
    this._startDoor(locker, 'Swing', 0, 1, OpenSeconds, now + LEAD);
    locker.remoteCloseAt = now + LEAD + OpenSeconds + StepInSeconds;
    if (locker.handle) locker.handle.setEnabled(false);
  }

  /** Co-op: the teammate stepped out (or was let go): the door swings for them and the locker is free. */
  remoteVacate(locker, member) {
    if (member && member.lockerId === locker.id) member.lockerId = null;
    if (!locker.remote || locker.state === 'Smashed') return;
    const now = this.env.now();
    locker.remote = null;
    locker.state = 'Free';
    this.env.setEntityAttribute(locker.id, 'OccupantUserId', 0);
    const from = locker.motion ? valueAt(locker.motion, now)[0] : 0;
    this._startDoor(locker, 'Swing', from, 1, OpenSeconds * (1 - from), now + LEAD);
    locker.remoteCloseAt = now + LEAD + OpenSeconds + StepOutSeconds;
    if (locker.handle) locker.handle.setEnabled(true);
  }

  /** Co-op: the Creature tore this locker open on its occupant's page: smashed here too. */
  remoteRip(id) {
    const locker = this.lockers.get(id);
    if (!locker || locker.state === 'Smashed') return;
    const now = this.env.now();
    locker.state = 'Smashed';
    locker.remote = null;
    locker.remoteCloseAt = null;
    this._startDoor(locker, 'Smash', 0, 1, RipSeconds, now + LEAD);
    if (locker.handle) locker.handle.setEnabled(false);
    for (const m of this.game.coop.squad.list()) if (m.lockerId === id) m.lockerId = null;
  }

  /** The Locker catch ended: a victim still playing is put down outside the torn locker. */
  _onCatchFinished(kind) {
    const locker = this.taken;
    if (kind !== 'Locker' || !locker) return;
    this.taken = null;
    const state = this.game.life.state;
    if (state !== 'Alive' && state !== 'Downed') return;
    const spot = this._exitSpot(locker);
    if (spot) this._teleport(spot);
  }

  _onLife(state) {
    const locker = this.occupied;
    if (locker && state === 'Downed') this._release(locker, true);
    else if (locker && state !== 'Alive') this._drop(locker);
    if (state !== 'Alive' && state !== 'Downed') this.taken = null;
  }

  _onHoldBreath(held) {
    const s = this.session;
    const locker = this.occupied;
    if (!s || !locker || s.phase === 'Exiting' || locker.state === 'Exiting' || locker.state === 'Smashed') return;
    if (held === s.held) return;
    const now = this.env.now();
    if (locker.check) this._advance(locker.check, now);
    if (this.occupied !== locker || !this.breath) return;
    s.held = held;
    this.env.setBreathSuppressed('Locker', held);
    if (held) s.heldSince = now;
    else {
      const since = s.heldSince;
      s.heldSince = null;
      if (since !== null && now - since >= EXHALE_AFTER) {
        const left = clamp01(breathAt(this.breath, now) / BreathMax);
        this.env.play('BreathExhale', { volume: 0.55 + 0.65 * (1 - left) });
      }
    }
    this.breath = setHeld(this.breath, held, now);
    if (locker.check) this._advance(locker.check, now);
  }

  // ---------------------------------------------------------------------------------------------------- drive

  tick(dt, now) {
    for (let i = this.cues.length - 1; i >= 0; i--) {
      const cue = this.cues[i];
      if (now < cue.at) continue;
      this.cues.splice(i, 1);
      this.game.playAt(cue.preset, cue.position);
    }
    if (this.devCheckPending && this.occupied && this.occupied.state === 'Hidden') {
      this.devCheckPending = false;
      this.startCheck(DEV_CHECK_SECONDS);
    }
    for (const locker of this.lockers.values()) {
      this._stepDoor(locker, now);
      this._stepSchedule(locker, now);
      if (locker.remoteCloseAt && now >= locker.remoteCloseAt) {
        locker.remoteCloseAt = null;
        if (locker.state !== 'Smashed') this._startDoor(locker, 'Swing', 1, 0, CloseSeconds, now);
      }
      if (locker.ripShakeAt !== null && locker.ripShakeAt !== undefined && now >= locker.ripShakeAt) {
        locker.ripShakeAt = null;
        const d = this.env.eye(_a).distanceTo(_b.setFromMatrixPosition(locker.base));
        if (d < RIP_SHAKE_RADIUS) this.env.shake(RIP_SHAKE * (1 - d / RIP_SHAKE_RADIUS) * (this.env.setting('MotionScale') ?? 1), 0.5);
      }
    }
    const locker = this.occupied;
    if (locker && this.breath) {
      if (locker.check) this._advance(locker.check, now);
      const empty = emptyAt(this.breath);
      if (empty !== null && empty <= now && this.occupied === locker) {
        this._gasp(locker, empty);
      }
    }
    for (const l of this.lockers.values()) if (l.check) this._advance(l.check, now);
    for (let i = this.peeks.length - 1; i >= 0; i--) {
      if (now >= this.peeks[i].resolveAt) this.peeks.splice(i, 1)[0].resolve('Empty');
    }
  }

  // ---------------------------------------------------------------------------------------------------- the view

  _beginSession(locker) {
    const env = this.env;
    const look = env.look();
    const fromEye = frameAt(env.eye(new THREE.Vector3()), look.yaw, look.pitch);
    const out = _d.set(-locker.peek.elements[8], -locker.peek.elements[9], -locker.peek.elements[10]);
    const s = {
      locker,
      phase: 'Entering',
      schedule: locker.schedule,
      fromEye,
      peek: locker.peek.clone(),
      outYaw: yawOf(out),
      exitEye: null,
      held: false,
      heldSince: null,
      window: null,
      seed: this.random.number(0, 1000),
      started: env.realNow(),
      flinched: false,
      alpha: 0,
      promptAlpha: 0,
      lastView: null,
    };
    this.session = s;
    env.pushContext('Locker', 'Locker');
    env.suppressPrompts('Locker', true);
    env.setCameraOverride('Locker', () => this._view(s), { priority: 4, blendIn: 0, blendOut: 0.15 });
    env.setPanicFloor('Locker', HIDDEN_PANIC);
  }

  _endSession() {
    const s = this.session;
    if (!s) return;
    this.session = null;
    const env = this.env;
    if (s.lastView) {
      _d.set(-s.lastView.elements[8], -s.lastView.elements[9], -s.lastView.elements[10]);
      env.setLook(yawOf(_d), Math.asin(Math.max(-1, Math.min(1, _d.y))));
    }
    env.setCameraOverride('Locker', null);
    env.popContext('Locker');
    env.suppressPrompts('Locker', false);
    env.setPanicFloor('Locker', null);
    env.setBreathSuppressed('Locker', false);
    env.setHandPose('Flashlight');
    this.ui.root.style.display = 'none';
  }

  /** The camera this frame: in, behind the slits (the player's look kept facing out, the sway) or out. */
  _view(s) {
    const env = this.env;
    const now = env.renderNow();
    const schedule = s.schedule;
    let view;
    if (s.phase === 'Entering' && schedule && now < schedule.closeAt) view = enterView(schedule, s.fromEye, s.peek, now, _view);
    else if (s.phase === 'Exiting' && schedule && s.exitEye) view = exitView(schedule, s.peek, s.exitEye, now, _view);
    else {
      const look = env.look();
      const yaw = s.outYaw + Math.max(-YAW_LIMIT, Math.min(YAW_LIMIT, wrapAngle(look.yaw - s.outYaw)));
      if (Math.abs(wrapAngle(yaw - look.yaw)) > 1e-4) env.setLook(yaw, look.pitch);
      _p.setFromMatrixPosition(s.peek);
      view = frameAt(_p, yaw, look.pitch, _view);
      const fraction = this.breath ? clamp01(breathAt(this.breath, env.now()) / BreathMax) : 1;
      view.multiply(sway(env.realNow() - s.started, s.held, fraction, env.setting('MotionScale') ?? 1, s.seed, _sw));
      const w = s.window;
      if (w && !w.verdict && now >= w.startAt) {
        const t = now - w.startAt;
        if (t < FLINCH_SECONDS) view.multiply(_fl.makeRotationX(((FLINCH_DEGREES * Math.PI) / 180) * Math.sin((Math.PI * t) / FLINCH_SECONDS)));
      }
    }
    s.lastView = (s.lastView || new THREE.Matrix4()).copy(view);
    return view;
  }

  frame(dt) {
    const s = this.session;
    const ui = this.ui;
    if (!s) return;
    const env = this.env;
    const now = env.now();
    // the hands hooked into the slits once behind them
    if (s.phase === 'Hidden') env.setHandPose('SlitGrip', _h.copy(s.peek).multiply(_t.makeTranslation(0, -0.15, -HAND_IN)));
    const stage = promptStage(s.window, now);
    const panic = stage === 'Warn' ? WARN_PANIC : stage === 'Window' ? WINDOW_PANIC : stage === 'Result' &&
      s.window && s.window.verdict === 'HiddenSafe' ? SAFE_PANIC : HIDDEN_PANIC;
    env.setPanicFloor('Locker', panic);
    // the HUD
    ui.root.style.display = '';
    const target = s.phase === 'Hidden' ? 1 : 0;
    s.alpha += Math.sign(target - s.alpha) * Math.min(Math.abs(target - s.alpha), 4 * dt);
    const fraction = this.breath ? clamp01(breathAt(this.breath, now) / BreathMax) : 1;
    ui.meter.set(fraction);
    ui.meter.color(fraction < CalmFraction ? Palette.Ember : fraction < 0.5 ? Palette.Amber : Palette.Bone);
    ui.lungs.style.opacity = String(s.alpha * (stage === 'Idle' && !s.held ? 0.55 : 1));
    const device = env.device();
    ui.leave.textContent = S(`Hud.LockerLeave.${device}`);
    ui.leaveButton.style.display = device === 'Touch' && s.phase === 'Hidden' ? '' : 'none';
    const vignette = stage === 'Window' ? 0.95 : stage === 'Warn' ? 0.75 : 0.45;
    ui.vignette.style.opacity = String(s.alpha * vignette);
    const showPrompt = stage !== 'Idle';
    s.promptAlpha += Math.sign((showPrompt ? 1 : 0) - s.promptAlpha) * Math.min(Math.abs((showPrompt ? 1 : 0) - s.promptAlpha), 6 * dt);
    ui.prompt.style.opacity = String(s.promptAlpha);
    ui.prompt.style.display = s.promptAlpha > 0.01 ? '' : 'none';
    if (s.window && showPrompt) {
      const w = s.window;
      if (stage === 'Result') {
        ui.title.textContent = w.verdict === 'HiddenSafe' ? S('Hud.BreathSafe') : S('Hud.HoldBreathNow');
        ui.title.style.color = w.verdict === 'HiddenSafe' ? Palette.Bone : Palette.Ember;
        ui.ring.setProgress(0);
      } else {
        ui.title.textContent = S('Hud.HoldBreathNow');
        ui.title.style.color = s.held ? Palette.Bone : Palette.Ember;
        ui.ring.setProgress(ringProgress(w, now));
      }
      ui.sub.textContent = stage === 'Result' ? '' : S('Hud.HoldBreath');
    }
  }

  _buildUi() {
    const env = this.env;
    const root = el('div', 'rg-layer', env.uiRoot());
    root.style.display = 'none';
    const vignette = el('div', 'rg-layer', root);
    vignette.style.background = `radial-gradient(ellipse at center, rgba(0,0,0,0) 38%, ${Palette.Ink} 100%)`;
    vignette.style.opacity = '0';
    const lungs = el('div', '', root);
    Object.assign(lungs.style, { position: 'absolute', left: '50%', bottom: '54px', transform: 'translateX(-50%)',
      width: '240px', textAlign: 'center' });
    const label = el('div', 'rg-caps', lungs, S('Hud.Breath'));
    label.style.color = Palette.Ash;
    const bar = meter(lungs, Palette.Bone, 240);
    bar.root.style.marginTop = '4px';
    const leave = el('div', 'rg-body rg-outline', lungs, '');
    Object.assign(leave.style, { fontSize: '13px', color: Palette.Smoke, marginTop: '6px' });
    const leaveButton = el('button', 'rg-btn', root, S('Input.LeaveLocker'));
    Object.assign(leaveButton.style, { position: 'absolute', left: '96px', bottom: '120px', pointerEvents: 'auto' });
    leaveButton.addEventListener('click', () => this.requestExit());
    leaveButton.addEventListener('touchstart', (e) => {
      e.preventDefault();
      this.requestExit();
    });
    const prompt = el('div', '', root);
    Object.assign(prompt.style, { position: 'absolute', left: '50%', top: '60%', transform: 'translate(-50%, -50%)',
      width: 'min(420px, 92vw)', display: 'none', flexDirection: 'column', alignItems: 'center', textAlign: 'center' });
    prompt.style.display = 'none';
    const ringWrap = el('div', '', prompt);
    Object.assign(ringWrap.style, { position: 'relative', width: '96px', height: '96px', margin: '0 auto' });
    const ring = env.ring(ringWrap, 96, 5, Palette.Bone);
    const capWrap = el('div', '', ringWrap);
    Object.assign(capWrap.style, { position: 'absolute', inset: '0', display: 'flex', alignItems: 'center', justifyContent: 'center' });
    env.keyCap(capWrap, 'HoldBreath', 54);
    const title = el('div', 'rg-title rg-outline', prompt, S('Hud.HoldBreathNow'));
    Object.assign(title.style, { fontSize: '34px', marginTop: '10px' });
    const sub = el('div', 'rg-body rg-outline', prompt, '');
    Object.assign(sub.style, { fontSize: '15px', color: Palette.Ash, marginTop: '4px' });
    return { root, vignette, lungs, meter: bar, leave, leaveButton, prompt, ring, title, sub };
  }

  // ---------------------------------------------------------------------------------------------------- reads

  /** Whether a breath check (or an empty peek) is running anywhere (LockerHidingService.IsChecking). */
  isChecking() {
    if (this.peeks.length) return true;
    for (const l of this.lockers.values()) if (l.check) return true;
    return false;
  }

  /** A locker's state ('Free' | 'Entering' | 'Hidden' | 'Exiting' | 'Smashed'), or null. */
  stateOf(id) {
    const l = this.lockers.get(id);
    return l ? l.state : null;
  }

  /**
   * Floor 3's key search: swings a free locker's door ajar (SEARCH_OPEN of fully open, the locker creak) or shut again;
   * its Hide prompt waits while it stands open. False when it is not free or already so.
   */
  setSearchOpen(id, open) {
    const locker = this.lockers.get(id);
    if (!locker || locker.state !== 'Free' || !!locker.searchOpen === !!open) return false;
    const now = this.env.now();
    const from = locker.motion ? valueAt(locker.motion, now)[0] : locker.searchOpen ? SEARCH_OPEN : 0;
    locker.searchOpen = !!open;
    this._startDoor(locker, 'Swing', from, open ? SEARCH_OPEN : 0, open ? OpenSeconds : CloseSeconds, now + LEAD);
    if (locker.handle) locker.handle.setEnabled(!open);
    return true;
  }

  /** The locker the player is in (id), or null (the Creature's lockerOccupied hook). */
  occupiedId() {
    return this.occupied ? this.occupied.id : null;
  }

  // ---------------------------------------------------------------------------------------------------- dev

  /** Dev `unhide` (and the level skip): out of the locker where the player is. */
  release() {
    if (!this.occupied) return false;
    this._drop(this.occupied);
    return true;
  }

  /** Dev `breathcheck`: a scripted check of `seconds` on the player's settled locker. */
  startCheck(seconds = DEV_CHECK_SECONDS) {
    const locker = this.occupied;
    if (!locker || !this.game.live() || locker.state !== 'Hidden' || locker.check) return false;
    this._startCheck(locker, this.env.now(), Math.min(PeekMax, Math.max(PeekMin, seconds)), true);
    return true;
  }

  /** Dev: hides in the nearest free locker on this level and, once settled, starts a breath check (Level 3's moment). */
  devCheck() {
    const env = this.env;
    const root = env.rootPosition(new THREE.Vector3());
    let best = null;
    let bestD = Infinity;
    for (const l of this.lockers.values()) {
      if (l.state !== 'Free' || l.level !== this.game.level) continue;
      const d = _a.setFromMatrixPosition(l.exit).distanceTo(root);
      if (d < bestD) {
        bestD = d;
        best = l;
      }
    }
    if (!best) return false;
    if (!this.occupied) {
      // stand at its door facing it, then climb in
      _p.setFromMatrixPosition(best.exit).add(_a.set(0, ROOT_HEIGHT, 0));
      env.teleport({ position: _p.clone(), yaw: yawOf(_d.set(best.exit.elements[8], 0, best.exit.elements[10])) });
      if (this.game.traps) this.game.traps.noteTeleport();
      if (!this.hide(best)) return false;
    }
    this.devCheckPending = true;
    return true;
  }
}

/** Which part of a check the prompt shows at `now` (LockerController.promptStage). */
export function promptStage(window, now) {
  if (!window) return 'Idle';
  if (window.resultAt !== null && window.resultAt !== undefined) return now - window.resultAt < RESULT_LINGER ? 'Result' : 'Idle';
  if (now < window.warnAt) return 'Idle';
  if (now < window.startAt) return 'Warn';
  if (now < window.endsAt) return 'Window';
  return 'Result';
}

/** The ring: filling toward the window while warned, then draining with the peek. */
export function ringProgress(window, now) {
  if (now < window.startAt) {
    const warn = window.startAt - window.warnAt;
    return warn > 0 ? clamp01((now - window.warnAt) / warn) : 1;
  }
  const peek = window.endsAt - window.startAt;
  return peek > 0 ? 1 - clamp01((now - window.startAt) / peek) : 0;
}

/** The camera climbing in (LockerController.enterView). */
function enterView(schedule, fromEye, peek, now, out) {
  _out.set(-peek.elements[8], -peek.elements[9], -peek.elements[10]);
  _pp.setFromMatrixPosition(peek);
  _stand.copy(_pp).addScaledVector(_out, DOOR_STAND);
  _stand.y -= ENTER_DIP * 0.5;
  const outYaw = yawOf(_out);
  const outPitch = Math.asin(Math.max(-1, Math.min(1, _out.y)));
  if (now <= schedule.openAt) return out.copy(fromEye);
  const facingIn = frameAt(_stand, outYaw + Math.PI, -outPitch, _fi);
  if (now < schedule.moveAt) return lerpFrame(fromEye, facingIn, smoothstep(0, 1, (now - schedule.openAt) / (schedule.moveAt - schedule.openAt)), out);
  const backIn = schedule.closeAt - schedule.moveAt;
  const t = backIn > 0 ? clamp01((now - schedule.moveAt) / backIn) : 1;
  if (t >= 1) return out.copy(peek);
  const turn = smoothstep(0, 1, Math.min(1, t / 0.7));
  _pos.copy(_stand).lerp(_pp, smoothstep(0, 1, t));
  _pos.y -= ENTER_DIP * Math.sin(Math.PI * t);
  return frameAt(_pos, outYaw + Math.PI * (1 - turn), outPitch * turn, out);
}

/** The camera stepping out (LockerController.exitView). */
function exitView(schedule, peek, exitEye, now, out) {
  if (now <= schedule.openAt) return out.copy(peek);
  const lean = _lean.copy(peek).multiply(_t2.makeTranslation(0, -0.05, -0.18));
  if (now < schedule.moveAt) return lerpFrame(peek, lean, smoothstep(0, 1, (now - schedule.openAt) / (schedule.moveAt - schedule.openAt)), out);
  const span = schedule.closeAt - schedule.moveAt;
  const t = span > 0 ? clamp01((now - schedule.moveAt) / span) : 1;
  return lerpFrame(lean, exitEye, smoothstep(0, 1, t), out);
}

/** The slow breathing sway behind the slits (LockerController.sway). */
function sway(t, held, fraction, scale, seed, out) {
  const amount = clamp01(scale);
  if (amount <= 0) return out.identity();
  const quiet = held ? 0.25 : 1;
  const phase = t * 2 * Math.PI * 0.24;
  let pitch = SWAY_PITCH * Math.sin(phase) * quiet;
  let roll = SWAY_ROLL * Math.sin(phase * 0.5 + 0.7) * quiet;
  const lift = SWAY_LIFT * Math.sin(phase) * quiet;
  const tremble = held ? clamp01((TREMBLE_BELOW - fraction) / TREMBLE_BELOW) : 0;
  if (tremble > 0) {
    const degrees = ((TREMBLE_DEGREES * Math.PI) / 180) * tremble;
    pitch += degrees * Math.sin(t * 11 * 2.3 + seed);
    roll += degrees * 0.6 * Math.sin(t * 13 * 1.9 + seed + 17);
  }
  return out.makeRotationFromEuler(_e.set(pitch * amount, 0, roll * amount, 'XYZ')).setPosition(0, lift * amount, 0);
}

const _identity = new THREE.Matrix4();
const _wrench = new THREE.Matrix4();
const _lift = new THREE.Matrix4();
const _c = new THREE.Vector3();
const _m = new THREE.Matrix4();
const _m2 = new THREE.Matrix4();
const _t = new THREE.Matrix4();
const _t2 = new THREE.Matrix4();
const _a = new THREE.Vector3();
const _b = new THREE.Vector3();
const _o = new THREE.Vector3();
const _d = new THREE.Vector3();
const _p = new THREE.Vector3();
const _h = new THREE.Matrix4();
const _view = new THREE.Matrix4();
const _sw = new THREE.Matrix4();
const _fl = new THREE.Matrix4();
const _out = new THREE.Vector3();
const _pp = new THREE.Vector3();
const _stand = new THREE.Vector3();
const _pos = new THREE.Vector3();
const _fi = new THREE.Matrix4();
const _lean = new THREE.Matrix4();
const _e = new THREE.Euler();
