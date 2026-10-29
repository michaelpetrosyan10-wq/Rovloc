// base.js: what every floor objective shares (the per-floor modules extend FloorObjective).
//
// Per run (beginRun): the floor's picks from the run plan (worldData.pickObjective by the run seed) are shown and every
// other candidate of the floor's item is hidden; the steps start at 0; floors 0-4 shut their exit (the run route's
// fire doors, snapped Locked) and reset its ExitLock with the Locked prompt. Prompts answer only while the floor is the
// active level. Items are hold prompts (the item's hold from ObjectiveConfig) that put the item in the carry.
// Completing the floor's lockStep unlocks it: the lock comes off, the stairwell door's bolts clunk (the loud High noise
// at the door: the Creature hears it), the door swings open DoorDelay later and the tracker switches to the stairwell.
// The airlock (airlock.js) only starts once the floor is unlocked. Carried items, kept progress and a dropped item's
// spot all live in the floor's run state, so being downed, grabbed or revived never loses a step; the run ending
// (death, the results, Play Again) resets everything for the next run.

import * as THREE from 'three';
import { S } from '../strings.js';
import { ObjectiveTuning, roomName, stepOf } from './config.js';
import { LockFixture } from './locks.js';
import { Tweens, WorkHold, entityPrompt } from './kit.js';
import { cfPos } from '../util.js';

export class FloorObjective {
  /**
   * @param {import('./index.js').FloorObjectives} system
   * @param {any} spec meta.objectives.floors entry
   */
  constructor(system, spec) {
    this.sys = system;
    this.game = system.game;
    this.env = system.game.env;
    this.world = system.game.world;
    this.spec = spec;
    this.level = spec.levelId;
    this.fx = system.fx;
    this.carry = system.carry;
    this.tweens = new Tweens(this.env);
    const order = new Map(this.world.objectiveCandidates(this.level).map((c, i) => [c.anchorId, i]));
    /** every candidate entity of the floor's item, in layout order */
    this.items = this.world.entities(spec.item.prop, this.level)
      .sort((a, b) => (order.get(a.id) ?? 99) - (order.get(b.id) ?? 99));
    /** @type {Map<string, number>} */
    this.progress = new Map();
    this.prompts = [];
    /** @type {Map<string, any>} the picked items' Pickup prompts */
    this.itemPrompts = new Map();
    /** @type {Set<string>} items taken this run */
    this.taken = new Set();
    /** @type {WorkHold[]} */
    this.holds = [];
    this.voices = [];
    this.picks = { anchors: [], slots: {}, guards: [] };
    this.lock = null;
    this.lockedPrompt = null;
    this.route = null;
    this.unlocked = false;
    this.active = false;
    this.activatedAt = null;
  }

  // ---------------------------------------------------------------------------------------------------- helpers

  /** An exported prompt of an entity (kit.entityPrompt), removed with the run. */
  prompt(entityId, name, opts = {}) {
    const p = entityPrompt(this.game, entityId, name, opts);
    this.prompts.push(p);
    return p;
  }

  /** A working hold (kit.WorkHold) ticked with the floor. */
  work(opts) {
    const w = new WorkHold(this.game, opts);
    this.holds.push(w);
    return w;
  }

  /** A looping sound kept until the floor's run ends. */
  loop(preset, at, opts = {}) {
    const v = this.game.playAt(preset, at, { loop: true, ...opts });
    if (v) this.voices.push(v);
    return v;
  }

  count(stepId) {
    return this.progress.get(stepId) || 0;
  }

  done(stepId) {
    const s = stepOf(this.spec, stepId);
    return !!s && this.count(stepId) >= s.count;
  }

  /** One more of a step (up to its count); completing the lock step unlocks the floor. */
  advance(stepId, n = 1) {
    const s = stepOf(this.spec, stepId);
    if (!s) return;
    this.progress.set(stepId, Math.min(s.count, this.count(stepId) + n));
    if (stepId === this.spec.lockStep && this.done(stepId)) this.unlock();
    this.refresh();
  }

  /** Undoes a step (an acid flask lost): it reads undone again. */
  undo(stepId) {
    this.progress.set(stepId, 0);
    this.refresh();
  }

  /** The first step not done, or null once all are. */
  current() {
    return this.spec.steps.find((s) => !this.done(s.id)) || null;
  }

  picked(entityId) {
    return this.picks.anchors.includes(entityId);
  }

  /** The room of a world point on this level (layout id) or null. */
  roomOf(point) {
    const r = this.world.roomAt(point, this.level);
    return r ? r.id : null;
  }

  /** An entity's attachment (current pose) as a point, or its pivot. */
  pointOf(entityId, attachment, out = new THREE.Vector3()) {
    const m = attachment ? this.env.attachmentWorld(entityId, attachment, _m) : null;
    if (m) return out.setFromMatrixPosition(m);
    const e = this.env.entity(entityId);
    return e ? out.setFromMatrixPosition(e.pivot) : cfPos(this.world.entity(entityId).pivot, out);
  }

  notify(key, ...args) {
    this.game.notify(key, ...args);
  }

  // ---------------------------------------------------------------------------------------------------- run

  beginRun(run) {
    this._teardown();
    this.run = run;
    this.picks = (run.plan.objectives && run.plan.objectives[this.level]) || { anchors: [], slots: {}, guards: [] };
    this.progress.clear();
    this.unlocked = false;
    this.active = false;
    this.activatedAt = null;
    for (const e of this.items) {
      this.env.setEntityPivot(e.id, e.pivot);
      this.env.setEntityVisible(e.id, this.picked(e.id) && this.itemStartsVisible(e));
    }
    this.route = this.game.route(this.level);
    const lockId = this.route ? this.route.lockEntity : null;
    for (const e of this.world.entities('ExitLock', this.level)) if (e.id !== lockId) this.env.setEntityVisible(e.id, false);
    if (lockId && this.spec.lockVariant) {
      this.lock = new LockFixture(this.game, lockId, this.tweens, this.fx);
      this.lock.reset();
      for (const id of this.route.exitDoorIds) {
        const door = this.game.doors.get(id);
        if (door) this.game.doors.setState(door, 'Locked', 0);
      }
      this.lockedPrompt = this.prompt(lockId, 'Locked', { holdSeconds: 0, onTriggered: () => this.lock.rattle() });
    }
    this.setup(run);
    this.refresh();
  }

  endRun() {
    this._teardown();
    this.active = false;
  }

  _teardown() {
    for (const p of this.prompts) p.remove();
    this.prompts = [];
    this.itemPrompts.clear();
    this.taken.clear();
    for (const h of this.holds) h.reset();
    this.holds = [];
    for (const v of this.voices) v.stop(0.3);
    this.voices = [];
    this.tweens.clear();
    this.lock = null;
    this.lockedPrompt = null;
    this.teardown();
  }

  activate() {
    this.active = true;
    this.activatedAt = this.env.now();
    this.onActivate();
    this.refresh();
  }

  deactivate() {
    this.active = false;
    this.tweens.finish();
    this.onDeactivate();
    this.refresh();
  }

  /** Whether the floor's exit may be used (its lock step is done). */
  exitOpen() {
    return this.unlocked;
  }

  unlock() {
    if (this.unlocked) return;
    this.unlocked = true;
    const g = this.game;
    const doors = this.route ? this.route.exitDoorIds.map((id) => g.doors.get(id)).filter(Boolean) : [];
    const at = doors.length ? doors[0].centre.clone() : this.lock ? this.lock.promptPoint() : g.env.rootPosition();
    if (this.lock) this.lock.release(null);
    g.playAt('ObjExitClunk', at);
    g.noise(at, ObjectiveTuning.LoudNoise);
    this.tweens.add({ seconds: 0, delay: ObjectiveTuning.DoorDelay, update: () => {}, done: () => {
      if (this.lock) this.lock.detach();
      for (const d of doors) g.doors.setState(d, 'Open');
    } });
    this.notify(this.spec.lockVariant ? 'Obj.ExitUnlocked' : 'Obj.CrateOpen');
    this.onUnlock();
  }

  /** The prompt every floor puts on a picked item: take it (into the carry, unless `take` handles it). */
  itemPrompt(entity, take) {
    const p = this.prompt(entity.id, 'Pickup', {
      holdSeconds: this.spec.item.hold,
      onTriggered: () => {
        if (!this.game.alive() || !this.picked(entity.id) || this.taken.has(entity.id)) return;
        if (take(entity, p) === false) return;
        this.taken.add(entity.id);
        this.refresh();
      },
    });
    this.itemPrompts.set(entity.id, p);
    return p;
  }

  /** Whether a picked item can be taken now: not taken yet and showing (Floor 3's key only once its locker is open). */
  itemAvailable(entityId) {
    const e = this.env.entity(entityId);
    return this.picked(entityId) && !this.taken.has(entityId) && !!e && !e.hidden;
  }

  tick(dt, now) {
    this.tweens.tick(now);
    for (const h of this.holds) h.tick(now);
    if (this.active) this.tickFloor(dt, now);
  }

  // ---------------------------------------------------------------------------------------------------- the tracker

  /** The tracker lines: [{text, done, active}] for every step. */
  stepLines(now) {
    const current = this.current();
    return this.spec.steps.map((s) => {
      const n = this.count(s.id);
      let text;
      if (s.seconds) text = S(s.label, Math.ceil(this.secondsLeft(s, now)));
      else text = s.count > 1 ? S(s.label, n, s.count) : S(s.label);
      return { id: s.id, text, done: this.done(s.id), active: current === s, timed: !!s.seconds && this.timerRunning(s) };
    });
  }

  /** A timed step's seconds left (its full length until it starts). */
  secondsLeft(step) {
    return step.seconds;
  }

  /** Whether a timed step's countdown is running. */
  timerRunning() {
    return false;
  }

  /**
   * Where the nearest undone step is worked: [{point, room}] (the station, or the item spots still to find). The Tab
   * nudge points at that room, never the item.
   */
  targets() {
    return [];
  }

  /** The nudge for a player at `root`: the room of the nearest target, at its centre or nearest doorway; or null. */
  nudge(root) {
    let best = null;
    for (const t of this.targets()) {
      const room = t.room || this.roomOf(t.point);
      if (!room) continue;
      const d = t.point.distanceTo(root);
      if (!best || d < best.d) best = { d, room };
    }
    if (!best) return null;
    const here = this.roomOf(root);
    let point = this.world.roomCentre(best.room);
    if (here !== best.room) {
      let bd = Infinity;
      for (const p of this.world.roomPortals(this.level, best.room)) {
        const d = p.pos.distanceTo(root);
        if (d < bd) {
          bd = d;
          point = p.pos;
        }
      }
    }
    return { point: point.clone().add(_lift), room: best.room, label: roomName(best.room) };
  }

  /** First-time hint spots: [{key, point}] (stations and locks of the floor). */
  hintSpots() {
    const out = [];
    if (this.lock && !this.unlocked) out.push({ key: `Hint.Obj.Lock.${this.level}`, point: this.lock.promptPoint() });
    return out;
  }

  // ---------------------------------------------------------------------------------------------------- per floor

  /** Whether a picked item is shown at the run start (Floor 3's key hangs out of sight in its locker). */
  itemStartsVisible() {
    return true;
  }

  setup() {}

  teardown() {}

  onActivate() {}

  onDeactivate() {}

  onUnlock() {}

  /** Enables / relabels the floor's prompts for its state (called after every change). */
  refresh() {
    if (this.lockedPrompt) this.lockedPrompt.setEnabled(this.active && !this.unlocked && this.lockedWanted());
    for (const [id, p] of this.itemPrompts) p.setEnabled(this.active && this.itemAvailable(id));
  }

  /** Whether the exit's Locked prompt shows (floors with an unlock action at the lock hide it when they can act). */
  lockedWanted() {
    return true;
  }

  tickFloor() {}

  /** Dev / tests: the floor's steps all done through their own completion paths. */
  devComplete() {
    for (const s of this.spec.steps) this.progress.set(s.id, s.count);
    this.unlock();
    this.refresh();
  }
}

const _m = new THREE.Matrix4();
const _lift = new THREE.Vector3(0, 3, 0);
