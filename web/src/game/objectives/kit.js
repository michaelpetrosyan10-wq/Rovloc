// kit.js: what every floor objective is built from: prompts made from an entity's exported ProximityPrompt specs, the
// working hold (a hold prompt with a looping sound, the Creature-audible noise once a second, a progress the floor can
// animate by and, optionally, progress kept when the hold is let go), small tweens on the game clock, and the pose
// maths that seat one entity's attachment on another's (a fuse's Grip in its slot, the wheel's Hub on the stem).

import * as THREE from 'three';
import { ObjectiveTuning } from './config.js';
import { cfMatrix } from '../util.js';

/**
 * The exported prompt spec named `name` on an entity (the builders' ProximityPrompt: host attachment, ActionText,
 * ObjectText, HoldDuration, MaxActivationDistance, attributes), or null. With `match`, the first whose attributes match.
 */
export function promptSpec(world, entityId, name, match) {
  const info = world.entity(entityId);
  if (!info) return null;
  return info.prompts.find((p) => p.name === name &&
    (!match || Object.entries(match).every(([k, v]) => p.attributes && p.attributes[k] === v))) || null;
}

/**
 * A prompt on an entity from its exported spec, with overrides (text, objectText, holdSeconds, action, enabled and the
 * callbacks). Throws when the export has no such prompt, so a data change cannot silently drop a step.
 */
export function entityPrompt(game, entityId, name, opts = {}) {
  const spec = promptSpec(game.world, entityId, name, opts.match);
  if (!spec) throw new Error(`objectives: ${entityId} has no ${name} prompt`);
  return game.env.addPrompt({
    entity: entityId,
    attachment: spec.host,
    text: opts.text ?? spec.actionText,
    objectText: opts.objectText ?? spec.objectText,
    holdSeconds: opts.holdSeconds ?? spec.holdDuration,
    distance: opts.distance ?? spec.maxDistance,
    action: opts.action,
    requiresLineOfSight: false,
    enabled: opts.enabled ?? false,
    onHoldBegan: opts.onHoldBegan,
    onHoldEnded: opts.onHoldEnded,
    onTriggered: opts.onTriggered || (() => {}),
  });
}

/**
 * A working hold: a prompt whose hold plays `sound` (looped) at `at`, emits the WorkNoise there when it starts and once
 * a second while it runs (when `noise`), reports its progress (0..1) every tick, and with `keep` remembers how far it
 * got when let go (the prompt's hold is set to what is left; reset() starts it over).
 */
export class WorkHold {
  /**
   * @param {import('../game.js').Game} game
   * @param {{prompt: any, seconds: number, at: () => THREE.Vector3, sound?: string, noise?: boolean, keep?: boolean,
   *   onProgress?: (p: number) => void, onBegin?: () => void, onEnd?: (done: boolean) => void, onDone: () => void}} opts
   */
  constructor(game, opts) {
    this.game = game;
    this.opts = opts;
    this.seconds = opts.seconds;
    this.done = 0;
    this.since = null;
    this.nextNoiseAt = Infinity;
    this.voice = null;
    this.finished = false;
    /** @type {number|null} seconds of the hold just let go, settled on the next tick */
    this.pendingEnd = null;
  }

  /** Progress 0..1 at `now` (kept progress plus the running hold). */
  progress(now) {
    const running = this.since !== null ? Math.max(0, now - this.since) : 0;
    return Math.min(1, (this.done + running) / this.seconds);
  }

  /** The prompt's onHoldBegan. */
  begin() {
    const g = this.game;
    if (this.finished || this.since !== null || !g.alive()) return;
    const now = g.env.now();
    this.since = now;
    this.nextNoiseAt = now;
    if (this.opts.sound) this.voice = g.playAt(this.opts.sound, this.opts.at(), { loop: true });
    if (this.opts.onBegin) this.opts.onBegin();
  }

  /**
   * The prompt's onHoldEnded. The engine also ends a hold just before it triggers, so the let-go is settled on the next
   * tick unless the trigger came in first.
   */
  end() {
    if (this.since === null) return;
    const now = this.game.env.now();
    this.pendingEnd = Math.max(0, now - this.since);
    this.since = null;
    this.nextNoiseAt = Infinity;
    if (this.voice) this.voice.stop(0.15);
    this.voice = null;
  }

  _settleEnd(now) {
    const ran = this.pendingEnd;
    this.pendingEnd = null;
    if (this.finished || ran === null || ran === undefined) return;
    if (this.opts.keep) {
      this.done = Math.min(this.seconds - 0.05, this.done + ran);
      this.opts.prompt.setHoldSeconds(Math.max(0.05, this.seconds - this.done));
    }
    if (this.opts.onEnd) this.opts.onEnd(false);
    if (this.opts.onProgress) this.opts.onProgress(this.progress(now));
  }

  /** The prompt's onTriggered. */
  trigger() {
    if (this.finished) return;
    this.finished = true;
    this.pendingEnd = null;
    if (this.since !== null) {
      this.since = null;
      if (this.voice) this.voice.stop(0.15);
      this.voice = null;
    }
    if (this.opts.onProgress) this.opts.onProgress(1);
    if (this.opts.onEnd) this.opts.onEnd(true);
    this.opts.onDone();
  }

  /** Starts over (a re-mix, a new run). */
  reset() {
    if (this.voice) this.voice.stop(0.1);
    this.voice = null;
    this.done = 0;
    this.since = null;
    this.pendingEnd = null;
    this.finished = false;
    this.nextNoiseAt = Infinity;
    this.opts.prompt.setHoldSeconds(this.seconds);
  }

  /** Whether the hold is running now. */
  holding() {
    return this.since !== null;
  }

  tick(now) {
    if (this.pendingEnd !== null && this.pendingEnd !== undefined) this._settleEnd(now);
    if (this.since === null) return;
    if (this.opts.noise && now >= this.nextNoiseAt) {
      this.nextNoiseAt = now + ObjectiveTuning.WorkNoisePeriod;
      this.game.noise(this.opts.at(), ObjectiveTuning.WorkNoise);
    }
    if (this.opts.onProgress) this.opts.onProgress(this.progress(now));
  }
}

/** Wires a WorkHold into prompt callbacks: returns {onHoldBegan, onHoldEnded, onTriggered} for entityPrompt. */
export function holdCallbacks(get) {
  return {
    onHoldBegan: () => get() && get().begin(),
    onHoldEnded: () => get() && get().end(),
    onTriggered: () => get() && get().trigger(),
  };
}

/** Tweens on the game clock: add({seconds, ease, update(t), done?}); cleared with the floor. */
export class Tweens {
  constructor(env) {
    this.env = env;
    this.list = [];
  }

  /** @param {{seconds: number, delay?: number, ease?: (t: number) => number, update: (t: number) => void, done?: () => void}} spec */
  add(spec) {
    this.list.push({ ...spec, startAt: this.env.now() + (spec.delay || 0) });
  }

  clear() {
    this.list.length = 0;
  }

  /** Every tween to its end at once (a floor left mid-animation). */
  finish() {
    const list = this.list;
    this.list = [];
    for (const t of list) {
      t.update(1);
      if (t.done) t.done();
    }
  }

  tick(now) {
    for (let i = this.list.length - 1; i >= 0; i--) {
      const t = this.list[i];
      if (now < t.startAt) continue;
      const raw = t.seconds > 0 ? Math.min(1, (now - t.startAt) / t.seconds) : 1;
      t.update(t.ease ? t.ease(raw) : raw);
      if (raw >= 1) {
        this.list.splice(i, 1);
        if (t.done) t.done();
      }
    }
  }
}

export const Ease = Object.freeze({
  inOut: (t) => t * t * (3 - 2 * t),
  out: (t) => 1 - (1 - t) * (1 - t),
  in: (t) => t * t,
  /** A drop with one small bounce on landing. */
  bounce: (t) => (t < 0.8 ? (t / 0.8) ** 2 : 1 - 0.08 * Math.sin(((t - 0.8) / 0.2) * Math.PI)),
});

/**
 * The pivot that puts an entity's attachment `name` (as built) on the world frame `seat`: seat x (pivot^-1 x attachment).
 * @param {import('../worldData.js').WorldData} world
 */
export function seatPivot(world, entityId, name, seat, out = new THREE.Matrix4()) {
  const local = attachmentLocal(world, entityId, name, _local);
  if (!local) return out.copy(seat);
  return out.copy(seat).multiply(_inv.copy(local).invert());
}

/** An attachment's frame in its entity's pivot space (as built). */
export function attachmentLocal(world, entityId, name, out = new THREE.Matrix4()) {
  const info = world.entity(entityId);
  const cf = info && info.attachments[name];
  if (!cf) return null;
  return out.copy(world.restInverse(entityId)).multiply(cfMatrix(cf, _att));
}

/** A rotation of `angle` about the world `axis` through `point`, applied to `frame` (T(p) R T(-p) x frame). */
export function rotateAbout(frame, point, axis, angle, out = new THREE.Matrix4()) {
  _r.makeRotationAxis(_ax.copy(axis).normalize(), angle);
  _t.makeTranslation(point.x, point.y, point.z);
  _ti.makeTranslation(-point.x, -point.y, -point.z);
  return out.copy(_t).multiply(_r).multiply(_ti).multiply(frame);
}

const _local = new THREE.Matrix4();
const _inv = new THREE.Matrix4();
const _att = new THREE.Matrix4();
const _r = new THREE.Matrix4();
const _t = new THREE.Matrix4();
const _ti = new THREE.Matrix4();
const _ax = new THREE.Vector3();
