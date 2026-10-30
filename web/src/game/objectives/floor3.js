// floor3.js: Floor 3's "Gym generator" (ObjectiveConfig floor 3).
//
// The coach's key hangs inside one locker of the two locker rooms (the run's pick; its `ref` names the locker). Every
// locker in those rooms has a Search prompt (SearchHold, a soft creak) beside its Hide prompt: Search is the Kick
// action (R / Y / tap the row), Hide stays Interact, so the two never compete. A search swings the door ajar
// (lockers.setSearchOpen): an empty locker says so and shuts again; the key's locker stays open with the key showing
// until it is taken (the item's hold). Hiding works in every locker throughout (not in the one standing open). A locker
// the Creature smashed shows its key if it held it.
// The equipment store's padlock (StoreLock): Locked prompt without the key, Unlock (2 s) with it; it drops and the
// store's steel door (StoreDoor, Locked from the run start) swings open. The generator's pull start (Generator, 3 s,
// the cord yanked out with the hold) starts it: the Critical noise at the generator (the Creature comes, fast across
// the court), the pull and then the running loop, the work lamp lit, exhaust smoke. Then WindMotor: the stairwell
// door's motor winds for its 45 s (the whine looped at the door, the tracker counting down): survive (lockers with a
// held breath, the vents, out of sight) until it unlocks.

import * as THREE from 'three';
import { FloorObjective } from './base.js';
import { ObjectiveTuning, holdOf, stepOf } from './config.js';
import { holdCallbacks } from './kit.js';
import { LockFixture } from './locks.js';
import { S } from '../strings.js';
import { cfMatrix } from '../util.js';

const STORE_LOCK = 'StoreLock';
const STORE_DOOR = 'StoreDoor';
const GENERATOR = 'Generator';
const WORK_LAMP = 'LampLens';
const EXHAUST = [0.36, 0.36, 0.34];

export class Floor3 extends FloorObjective {
  constructor(system, spec) {
    super(system, spec);
    const rooms = new Set(this.world.objectiveCandidates(this.level).map((c) => c.room));
    this.lockers = this.world.entities('Locker', this.level).filter((e) => rooms.has(e.attributes.ZoneId))
      .sort((a, b) => (a.id < b.id ? -1 : 1));
    this.refs = new Map(this.world.objectiveCandidates(this.level).map((c) => [c.anchorId, c.ref]));
    const lock = this.world.entities(STORE_LOCK, this.level)[0];
    this.storeLockId = lock ? lock.id : null;
    const door = this.world.entities(STORE_DOOR, this.level)[0];
    this.storeDoorId = door ? door.id : null;
    const gen = this.world.entities(GENERATOR, this.level)[0];
    this.generator = gen ? gen.id : null;
    this.cordRest = gen && gen.attachments.PullCordRest ? cfMatrix(gen.attachments.PullCordRest) : null;
    this.cordOut = gen && gen.attachments.PullOut ? cfMatrix(gen.attachments.PullOut) : null;
  }

  /** The key hangs out of sight until its locker is searched. */
  itemStartsVisible() {
    return false;
  }

  setup() {
    this.keyEntity = this.items.find((e) => this.picked(e.id)) || null;
    this.keyLocker = this.keyEntity ? this.refs.get(this.keyEntity.id) : null;
    this.keyShown = false;
    this.searched = new Set();
    this.running = false;
    this.motorEndsAt = null;
    this.searches = new Map();
    for (const locker of this.lockers) {
      const spec = locker.prompts.find((p) => p.name === 'Hide');
      const p = this.env.addPrompt({
        entity: locker.id, attachment: spec ? spec.host : 'HidePrompt', action: 'Kick', text: S('Obj.Prompt.Search'),
        objectText: S('Prompt.Locker'), holdSeconds: ObjectiveTuning.SearchHold, distance: spec ? spec.maxDistance : 7,
        requiresLineOfSight: false, enabled: false, net: 'world',
        onHoldBegan: () => this.game.playAt('ObjLockerSearch', this.pointOf(locker.id, spec ? spec.host : null)),
        onTriggered: () => this._search(locker.id),
      });
      this.prompts.push(p);
      this.searches.set(locker.id, p);
    }
    if (this.keyEntity) this.keyPrompt = this.itemPrompt(this.keyEntity, (item) => this._takeKey(item));
    if (this.storeLockId) {
      this.storeLock = new LockFixture(this.game, this.storeLockId, this.tweens, this.fx);
      this.storeLock.reset();
      this.storeLocked = this.prompt(this.storeLockId, 'Locked', { holdSeconds: 0, net: 'local',
        onTriggered: () => this.storeLock.rattle() });
      this.storeUnlock = this.prompt(this.storeLockId, 'Unlock', {
        holdSeconds: holdOf(this.spec, 'Unlock'),
        onHoldBegan: () => this.game.playAt('ObjKeyJingle', this.storeLock.promptPoint(), { volume: 0.7 }),
        onTriggered: () => this._unlockStore(),
      });
    }
    if (this.generator) {
      this.env.setNodeTransform(this.generator, 'PullCord', null);
      this.pull = this.work({
        prompt: null, seconds: holdOf(this.spec, 'Generator'), at: () => this.pointOf(this.generator, 'PullPrompt'),
        onProgress: (t) => this._cord(t),
        onEnd: (done) => {
          if (!done) this._cord(0);
        },
        onDone: () => this._start(),
      });
      this.pullPrompt = this.prompt(this.generator, 'Generator', holdCallbacks(() => this.pull));
      this.pull.opts.prompt = this.pullPrompt;
    }
    this.env.setLightOverride(WORK_LAMP, null);
  }

  teardown() {
    this.env.setLightOverride(WORK_LAMP, null);
    this.searches = new Map();
    this.storeLock = this.storeLocked = this.storeUnlock = this.pullPrompt = this.keyPrompt = null;
  }

  onDeactivate() {
    for (const v of this.voices) v.stop(0.5);
    this.voices = [];
  }

  _search(lockerId) {
    if (!this.game.alive() || this.searched.has(lockerId)) return;
    const lockers = this.game.lockers;
    const hasKey = lockerId === this.keyLocker && !this.done('FindCoachKey');
    const state = lockers.stateOf(lockerId);
    this.searched.add(lockerId);
    if (hasKey) {
      if (state === 'Free') lockers.setSearchOpen(lockerId, true);
      this._showKey();
      this.notify('Obj.KeyFound');
    } else {
      if (state === 'Free') {
        lockers.setSearchOpen(lockerId, true);
        this.tweens.add({ seconds: 0, delay: ObjectiveTuning.SearchEmptySeconds, update: () => {},
          done: () => lockers.setSearchOpen(lockerId, false) });
      }
      this.notify('Obj.LockerEmpty');
    }
    this.refresh();
  }

  _showKey() {
    if (this.keyShown || !this.keyEntity) return;
    this.keyShown = true;
    this.env.setEntityVisible(this.keyEntity.id, true);
  }

  _takeKey(item) {
    if (!this.keyShown) return false;
    this.env.setEntityVisible(item.id, false);
    this.carry.add('CoachKey');
    this.game.playAt('ObjKeyJingle', this.pointOf(item.id, 'PromptPoint'));
    if (this.keyLocker) this.game.lockers.setSearchOpen(this.keyLocker, false);
    this.advance('FindCoachKey');
  }

  _unlockStore() {
    if (!this.game.alive() || !this.carry.has('CoachKey') || this.done('UnlockStore')) return;
    this.carry.take('CoachKey');
    const door = this.storeDoorId ? this.game.doors.get(this.storeDoorId) : null;
    this.storeLock.release(() => {
      this.storeLock.detach();
      if (door) this.game.doors.setState(door, 'Open');
    });
    this.advance('UnlockStore');
  }

  _cord(t) {
    if (!this.cordRest || !this.cordOut) return;
    // yanks: the cord comes out in three pulls with the hold, snapping back a little between them
    const pulls = 3;
    const phase = t * pulls;
    const within = phase - Math.floor(phase);
    const reach = t >= 1 ? 0 : Math.min(1, within * 1.6) * (0.55 + 0.45 * (Math.floor(phase) / pulls));
    const a = new THREE.Vector3().setFromMatrixPosition(this.cordRest);
    const b = new THREE.Vector3().setFromMatrixPosition(this.cordOut);
    this.env.setNodePivot(this.generator, 'PullCord', _m.copy(this.cordRest).setPosition(a.lerp(b, reach)));
  }

  _start() {
    if (this.running) return;
    this.running = true;
    const at = this.pointOf(this.generator, 'PullPrompt');
    this.game.playAt('ObjGeneratorPull', at);
    this.game.noise(at, ObjectiveTuning.GeneratorNoise);
    this.tweens.add({ seconds: 0, delay: 1.1, update: () => {}, done: () => {
      if (this.active) this.loop('ObjGeneratorRun', this.pointOf(this.generator, 'Exhaust'));
    } });
    this.env.setLightOverride(WORK_LAMP, ObjectiveTuning.WorkLampBrightness);
    const exhaust = this.pointOf(this.generator, 'Exhaust');
    this.fx.smoke(exhaust, { seconds: 600, rate: 3, color: EXHAUST, size: 0.7, rise: 1.6, life: 2.8, spread: 0.3 });
    const step = stepOf(this.spec, 'WindMotor');
    this.motorEndsAt = this.env.now() + (step ? step.seconds : 0);
    const doorAt = this.route ? this.game.doors.get(this.route.exitDoorIds[0]) : null;
    if (doorAt) this.loop('ObjMotorWhine', doorAt.centre);
    this.advance('StartGenerator');
    this.notify('Obj.GeneratorRunning');
  }

  timerRunning(step) {
    return step.id === 'WindMotor' && this.motorEndsAt !== null && !this.done('WindMotor');
  }

  secondsLeft(step) {
    if (step.id === 'WindMotor' && this.motorEndsAt !== null) return Math.max(0, this.motorEndsAt - this.env.now());
    return step.seconds;
  }

  tickFloor(dt, now) {
    if (this.motorEndsAt !== null && !this.done('WindMotor') && now >= this.motorEndsAt) {
      for (const v of this.voices) if (v.name === 'ObjMotorWhine') v.stop(0.6);
      this.advance('WindMotor');
    }
    // a key locker the Creature tore open shows its key
    if (this.keyLocker && !this.keyShown && !this.done('FindCoachKey') && this.game.lockers.stateOf(this.keyLocker) === 'Smashed') {
      this._showKey();
      this.refresh();
    }
  }

  refresh() {
    super.refresh();
    if (!this.searches) return;
    for (const [id, p] of this.searches) {
      p.setEnabled(this.active && !this.done('FindCoachKey') && !this.searched.has(id) &&
        this.game.lockers.stateOf(id) !== 'Smashed');
    }
    if (this.keyPrompt) this.keyPrompt.setEnabled(this.active && this.keyShown && !this.done('FindCoachKey'));
    const storeOpen = this.done('UnlockStore');
    if (this.storeLocked) this.storeLocked.setEnabled(this.active && !storeOpen && !this.carry.has('CoachKey'));
    if (this.storeUnlock) this.storeUnlock.setEnabled(this.active && !storeOpen && this.carry.has('CoachKey'));
    if (this.pullPrompt) this.pullPrompt.setEnabled(this.active && storeOpen && !this.running);
  }

  targets() {
    if (!this.done('FindCoachKey')) {
      if (this.keyShown && this.keyEntity) return [{ point: this.pointOf(this.keyEntity.id, 'PromptPoint') }];
      // the locker rooms (the key is in one of them): the nearest unsearched locker's room
      return this.lockers.filter((l) => !this.searched.has(l.id)).map((l) => ({ point: this.pointOf(l.id, null), room: l.attributes.ZoneId }));
    }
    if (!this.done('UnlockStore') && this.storeLock) return [{ point: this.storeLock.promptPoint() }];
    if (!this.done('StartGenerator') && this.generator) return [{ point: this.pointOf(this.generator, 'PullPrompt') }];
    return [];
  }

  hintSpots() {
    const out = super.hintSpots();
    if (this.storeLock && !this.done('UnlockStore')) out.push({ key: 'Hint.Obj.StoreLock', point: this.storeLock.promptPoint() });
    if (this.generator && !this.running && this.done('UnlockStore')) {
      out.push({ key: 'Hint.Obj.Generator', point: this.pointOf(this.generator, 'PullPrompt') });
    }
    if (!this.done('FindCoachKey') && this.lockers[0]) {
      for (const l of this.lockers) out.push({ key: 'Hint.Obj.LockerSearch', point: this.pointOf(l.id, null), radius: 8 });
    }
    return out;
  }
}

const _m = new THREE.Matrix4();
