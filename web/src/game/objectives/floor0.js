// floor0.js: the basement's "Restore power" (ObjectiveConfig floor 0).
//
// The power is out when the run starts: the basement's mains lights (every Level 0 flicker group whose fixtures are
// bulbs or fluorescents; the boilers' glow, the emergency reds and the exit signs keep burning) are held at
// PowerOffFactor of their baked share. The run's fuses (picked by the seed; the first two guarded by a bear trap on
// their approach) are taken with a hold (the item's hold). The breaker panel takes them one slot at a time: the next
// empty slot's FitFuse prompt (2 s) seats a fuse with its Grip on FuseSlot<i>Seat (the fuse click); without a fuse in
// hand it reads "Find a fuse first" and only clicks. With three seated, the Breaker prompt (3 s, loud: the lever creeps
// with the hold) throws the main breaker: the lever swings LeverThrowDegrees about its X, the clunk and the mains hum,
// the loud noise at the panel, and the basement's lights stutter back on over PowerOnSeconds (a seeded stutter per
// group, then their own flicker again). That unlocks the stairwell door (the keypad goes green).

import * as THREE from 'three';
import { FloorObjective } from './base.js';
import { ObjectiveTuning, holdOf } from './config.js';
import { Ease, holdCallbacks, seatPivot } from './kit.js';
import { S } from '../strings.js';
import { cfMatrix, seededRandom } from '../util.js';

const PANEL = 'BreakerPanel';
const MAINS = new Set(['Bulb', 'Fluorescent']);
const LEVER_CREEP = 0.22;

export class Floor0 extends FloorObjective {
  constructor(system, spec) {
    super(system, spec);
    const panel = this.world.entities(PANEL, this.level)[0];
    this.panel = panel ? panel.id : null;
    this.slots = panel ? panel.prompts.filter((p) => p.name === 'FitFuse').map((p) => p.attributes.Slot).sort((a, b) => a - b) : [];
    this.leverRest = panel && panel.attachments.LeverRest ? cfMatrix(panel.attachments.LeverRest) : null;
    const meta = this.world.meta;
    this.mainsGroups = (meta.flickerGroups || []).filter((g) => g.level === this.level && g.id > 0 &&
      list(g.lights).length && list(g.lights).every((i) => meta.lights[i] && MAINS.has(meta.lights[i].kind))).map((g) => g.id);
    this.powered = false;
  }

  setup(run) {
    this.fitted = [];
    this.powered = false;
    this.powerOnAt = null;
    for (const e of this.items) {
      if (this.picked(e.id)) this.itemPrompt(e, (item) => this._take(item));
    }
    if (!this.panel) return;
    this.env.setNodeTransform(this.panel, 'Lever', null);
    for (const slot of this.slots) this.env.setNodeTransform(this.panel, `FuseSlot${slot}`, null);
    this.fitPrompts = new Map();
    for (const slot of this.slots) {
      const p = this.prompt(this.panel, 'FitFuse', {
        match: { Slot: slot },
        onTriggered: () => this._fit(slot),
      });
      this.fitPrompts.set(slot, p);
    }
    this.breaker = this.work({
      prompt: null, seconds: holdOf(this.spec, 'Breaker'), at: () => this.pointOf(this.panel, 'LeverPrompt'),
      onProgress: (t) => this._lever(t * LEVER_CREEP),
      onEnd: (done) => {
        if (!done) this._lever(0);
      },
      onDone: () => this._throw(),
    });
    this.breakerPrompt = this.prompt(this.panel, 'Breaker', holdCallbacks(() => this.breaker));
    this.breaker.opts.prompt = this.breakerPrompt;
    this.random = seededRandom(run.seed, 'PowerOn');
    this._power(false);
  }

  teardown() {
    for (const g of this.mainsGroups || []) this.env.setGroupFactor(g, null);
    this.fitPrompts = null;
  }

  onActivate() {
    if (!this.powered) this._power(false);
  }

  _take(item) {
    this.env.setEntityVisible(item.id, false);
    this.carry.add('Fuse');
    this.game.playAt('ObjFuseClick', this.pointOf(item.id, 'PromptPoint'), { volume: 0.7 });
    this.advance('FindFuses');
  }

  /** The next empty slot (lowest first), or null. */
  _nextSlot() {
    return this.slots.find((s) => !this.fitted.some((f) => f.slot === s)) ?? null;
  }

  _fit(slot) {
    if (!this.game.alive() || slot !== this._nextSlot()) return;
    const at = this.pointOf(this.panel, `FuseSlot${slot}Prompt`);
    if (!this.carry.take('Fuse')) {
      this.game.playAt('ObjLockRattle', at, { volume: 0.5 });
      this.notify('Obj.NeedFuse');
      return;
    }
    // a fuse taken this run (hidden in the carry) and not fitted yet is the one seated
    const fuse = this.items.find((e) => this.picked(e.id) && this.env.entity(e.id).hidden &&
      !this.fitted.some((f) => f.id === e.id));
    const seat = this.world.attachmentRest(this.panel, `FuseSlot${slot}Seat`);
    if (fuse && seat) {
      this.env.setEntityPivot(fuse.id, seatPivot(this.world, fuse.id, 'Grip', seat));
      this.env.setEntityVisible(fuse.id, true);
    }
    this.fitted.push({ slot, id: fuse ? fuse.id : null });
    this.game.playAt('ObjFuseClick', at);
    this.advance('FitFuses');
  }

  _lever(share) {
    if (!this.panel || !this.leverRest) return;
    const angle = THREE.MathUtils.degToRad(ObjectiveTuning.LeverThrowDegrees) * share;
    this.env.setNodePivot(this.panel, 'Lever', _m.copy(this.leverRest).multiply(_r.makeRotationX(angle)));
  }

  _throw() {
    const at = this.pointOf(this.panel, 'LeverPrompt');
    this.tweens.add({ seconds: 0.3, ease: Ease.in, update: (t) => this._lever(LEVER_CREEP + (1 - LEVER_CREEP) * t) });
    this.game.playAt('ObjBreakerThrow', at);
    this.game.noise(at, ObjectiveTuning.LoudNoise);
    this.env.shake(0.6 * (this.env.setting('MotionScale') ?? 1), 0.35);
    this.powered = true;
    this.powerOnAt = this.env.now() + 0.25;
    this.stutter = new Map(this.mainsGroups.map((g) => [g, this._stutterFor()]));
    this.advance('ThrowBreaker');
  }

  /** A group's switch-on: on/off edges over PowerOnSeconds (seconds from the throw, alternating), ending on. */
  _stutterFor() {
    const edges = [];
    let t = this.random.number(0, 0.5);
    let on = true;
    while (t < ObjectiveTuning.PowerOnSeconds) {
      edges.push({ at: t, on });
      t += on ? this.random.number(0.04, 0.22) : this.random.number(0.08, 0.4);
      on = !on;
    }
    edges.push({ at: ObjectiveTuning.PowerOnSeconds, on: true });
    return edges;
  }

  _power(on) {
    for (const g of this.mainsGroups) this.env.setGroupFactor(g, on ? null : ObjectiveTuning.PowerOffFactor);
  }

  tickFloor(dt, now) {
    if (this.powerOnAt === null) return;
    const t = now - this.powerOnAt;
    if (t >= ObjectiveTuning.PowerOnSeconds) {
      this.powerOnAt = null;
      this._power(true);
      this.notify('Obj.PowerRestored');
      return;
    }
    for (const [g, edges] of this.stutter) {
      let state = null;
      for (const e of edges) if (e.at <= t) state = e;
      this.env.setGroupFactor(g, state && state.on ? 1.25 : ObjectiveTuning.PowerOffFactor);
    }
  }

  refresh() {
    super.refresh();
    if (!this.fitPrompts) return;
    const next = this._nextSlot();
    const haveFuse = this.carry.has('Fuse');
    for (const [slot, p] of this.fitPrompts) {
      p.setEnabled(this.active && slot === next);
      if (slot === next) {
        p.setText(haveFuse ? S('Prompt.FitFuse') : S('Obj.Prompt.NeedFuse', this.fitted.length, this.slots.length),
          S('Prompt.BreakerPanel'));
        p.setHoldSeconds(haveFuse ? holdOf(this.spec, 'FitFuse') : 0);
      }
    }
    if (this.breakerPrompt) this.breakerPrompt.setEnabled(this.active && next === null && !this.powered);
  }

  targets() {
    if (!this.done('FindFuses') && !(this.carry.count('Fuse') + this.fitted.length >= this.slots.length)) {
      const out = [];
      for (const e of this.items) {
        if (!this.picked(e.id) || this.env.entity(e.id).hidden) continue;
        if (this.fitted.some((f) => f.id === e.id)) continue;
        out.push({ point: this.pointOf(e.id, 'PromptPoint') });
      }
      if (out.length) return out;
    }
    return this.panel ? [{ point: this.pointOf(this.panel, 'LeverPrompt') }] : [];
  }

  hintSpots() {
    const out = super.hintSpots();
    if (this.panel && !this.powered) out.push({ key: 'Hint.Obj.BreakerPanel', point: this.pointOf(this.panel, 'LeverPrompt') });
    return out;
  }
}

function list(v) {
  return Array.isArray(v) ? v : [];
}

const _m = new THREE.Matrix4();
const _r = new THREE.Matrix4();
