// base.js: what every floor objective shares (the per-floor modules extend FloorObjective).
//
// Per run (beginRun): the floor's picks from the run plan (worldData.pickObjective by the run seed) are shown and every
// other candidate of the floor's item is hidden; the steps start at 0; a floor with a lock step shuts its exit (the run
// route's fire doors, snapped Locked) and resets its ExitLock with the Locked prompt. Prompts answer only while the
// floor is the active level. Items are hold prompts (the item's hold from ObjectiveConfig) that put the item in the
// carry. Completing the floor's lockStep unlocks it: the lock comes off, the stairwell door's bolts clunk (the loud
// High noise at the door: the Creature hears it), the door swings open DoorDelay later and the tracker switches to the
// stairwell. The airlock (airlock.js) only starts once the floor is unlocked. A floor without an item and without a
// lock step is a plain crossing (the Auditorium's ReachExit): its exit is open from the start and its steps are done
// when the squad leaves it. Carried items, kept progress and a dropped item's spot all live in the floor's run state,
// so being downed or revived never loses a step; the run ending (death, the results, Play Again) resets everything for
// the next run. radarTargets() is what the radar (mechanics/radar.js) asks of a floor: the open step, its items, its
// stations and its exit; each floor names its own stations and the step its item is found for.

import * as THREE from 'three';
import { S } from '../strings/index.js';
import { ObjectiveTuning, stepOf } from './config.js';
import '../strings/kit.js';
import { LockFixture } from './locks.js';
import { Tweens, WorkHold, entityPrompt } from './kit.js';
import { cfMatrix, cfPos } from '../util.js';

/**
 * @typedef {{id: string, step: string, carried: boolean, dropped: boolean, point: THREE.Vector3, name: string}} RadarItem
 * @typedef {{id: string, step: string, done: boolean, point: THREE.Vector3, name: string}} RadarStation
 */

/** How far over the floor point a dropped item is set down (co-op). */
const DROP_LIFT = 0.35;

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
    this.items = (spec.item ? this.world.entities(spec.item.prop, this.level) : [])
      .sort((a, b) => (order.get(a.id) ?? 99) - (order.get(b.id) ?? 99));
    /** @type {Map<string, number>} */
    this.progress = new Map();
    this.prompts = [];
    /** @type {Map<string, any>} the picked items' Pickup prompts */
    this.itemPrompts = new Map();
    /** @type {Set<string>} items taken this run */
    this.taken = new Set();
    /** @type {Set<string>} items set down where their carrier fell (dropItem) and not taken again */
    this.dropped = new Set();
    /** @type {WorkHold[]} */
    this.holds = [];
    this.picks = { anchors: [], guards: [] };
    this.lock = null;
    this.lockedPrompt = null;
    this.route = null;
    this.unlocked = false;
    this.active = false;
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
    this.picks = (run.plan.objectives && run.plan.objectives[this.level]) || { anchors: [], guards: [] };
    this.progress.clear();
    this.unlocked = !this.spec.lockStep;
    this.active = false;
    for (const e of this.items) {
      this.env.setEntityPivot(e.id, e.pivot);
      this.env.setEntityVisible(e.id, this.picked(e.id));
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
      this.lockedPrompt = this.prompt(lockId, 'Locked', { holdSeconds: 0, net: 'local', onTriggered: () => this.lock.rattle() });
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
    this.dropped.clear();
    for (const h of this.holds) h.reset();
    this.holds = [];
    this.tweens.clear();
    this.lock = null;
    this.lockedPrompt = null;
    this.teardown();
  }

  activate() {
    this.active = true;
    this.onActivate();
    this.refresh();
  }

  deactivate() {
    this.active = false;
    this.tweens.finish();
    // a floor with nothing to do but cross it is done once the squad leaves it
    if (!this.spec.item && !this.spec.lockStep) for (const s of this.spec.steps) this.progress.set(s.id, s.count);
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
    this.notify('Obj.ExitUnlocked');
    this.onUnlock();
  }

  /** The prompt every floor puts on a picked item: take it (into the carry, unless `take` handles it). */
  itemPrompt(entity, take) {
    const p = this.prompt(entity.id, 'Pickup', {
      holdSeconds: this.spec.item.hold,
      onTriggered: () => {
        if (!this.game.alive() || !this.picked(entity.id) || this.taken.has(entity.id)) return;
        if (take(entity, p) === false) return;
        this.carry.noteEntity(entity.id);
        this.taken.add(entity.id);
        this.dropped.delete(entity.id);
        this.refresh();
      },
    });
    this.itemPrompts.set(entity.id, p);
    return p;
  }

  /**
   * Co-op: a carried item put back in the world where its carrier died or left (`at`: a floor point); anyone can take
   * it again with its Pickup prompt. Items that are not this floor's are left alone (false).
   */
  dropItem(entityId, at) {
    const info = this.items.find((e) => e.id === entityId);
    if (!info || !this.taken.has(entityId)) return false;
    this.taken.delete(entityId);
    this.dropped.add(entityId);
    const pivot = cfMatrix(info.pivot, _m);
    pivot.setPosition(at.x, at.y + DROP_LIFT, at.z);
    this.env.setEntityPivot(entityId, pivot);
    this.env.setEntityVisible(entityId, true);
    this.refresh();
    return true;
  }

  /** Whether a picked item can be taken now: not taken yet and showing. */
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
  stepLines() {
    const current = this.current();
    return this.spec.steps.map((s) => {
      const text = s.count > 1 ? S(s.label, this.count(s.id), s.count) : S(s.label);
      return { id: s.id, text, done: this.done(s.id), active: current === s };
    });
  }

  // ---------------------------------------------------------------------------------------------------- the radar

  /**
   * What a radar scan can show of this floor (docs/design/game-spec-v2.md 3.2; RadarRules.targets picks from it):
   * the open step, every picked item (the step it is found for, carried or dropped, where it is now, its marker's
   * name), the stations of the floor's steps (done or not) and the exit (unlocked once the floor is). A floor names
   * its item's step and its stations (radarItemStep, radarStations); a plain crossing has neither, its exit open.
   * @returns {{openStep: string, items: RadarItem[], stations: RadarStation[], exit: RadarStation & {unlocked: boolean}|null}}
   */
  radarTargets() {
    const open = this.current();
    const picked = this.items.filter((e) => this.picked(e.id));
    const name = this.spec.item ? S(`Carry.${this.spec.item.prop}`).toUpperCase() : '';
    const items = picked.map((e, i) => ({
      id: e.id,
      step: this.radarItemStep(),
      carried: this.taken.has(e.id),
      dropped: this.dropped.has(e.id),
      point: this.pointOf(e.id, 'PromptPoint'),
      name: this.dropped.has(e.id) ? S('Radar.Marker.Dropped', name) : S('Radar.Marker.Item', name, i + 1, picked.length),
    }));
    const route = this.route;
    const door = route ? this.game.doors.get(route.exitDoorIds[0]) : null;
    const exit = door ? { id: door.id, step: '', done: false, unlocked: this.exitOpen(), point: door.centre.clone(),
      name: S('Radar.Marker.Exit') } : null;
    return { openStep: open ? open.id : '', items, stations: this.radarStations(), exit };
  }

  /** The step the floor's item is found for (its first step). */
  radarItemStep() {
    return this.spec.steps[0].id;
  }

  /** The floor's stations for the radar: [{id, step, done, point, name}] (none on a plain crossing). */
  radarStations() {
    return [];
  }

  /** A station entry of entity `entityId` for step `step` at `point`, named by the entity's first prompt. */
  radarStation(entityId, step, point) {
    const info = this.world.entity(entityId);
    const prompt = info && info.prompts.length ? info.prompts[0].objectText : '';
    return { id: `${entityId}#${step}`, step, done: this.done(step), point, name: String(prompt).toUpperCase() };
  }

  /** First-time hint spots: [{key, point}] (stations and locks of the floor). */
  hintSpots() {
    const out = [];
    if (this.lock && !this.unlocked) out.push({ key: `Hint.Obj.Lock.${this.level}`, point: this.lock.promptPoint() });
    return out;
  }

  // ---------------------------------------------------------------------------------------------------- per floor

  setup() {}

  teardown() {}

  onActivate() {}

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
