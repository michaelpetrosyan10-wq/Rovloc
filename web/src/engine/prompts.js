// Proximity prompts (ProximityPrompt + InteractionService's hold timing + PromptRenderer), single-player.
//
// add({position | entity, text, holdSeconds, distance, onTriggered, ...}) registers a prompt. Each frame the one
// prompt that may answer the Interact key is chosen (Roblox's OnePerButton exclusivity): enabled, within `distance`
// of the player's root, in front of the camera and, unless requiresLineOfSight is false, visible from the eye; the
// nearest wins (ties go to the one nearer the centre of the view). Holding Interact fills its ring over holdSeconds
// (0 = instant); releasing drains it; leaving range cancels. onTriggered fires once per completed hold. Touch / a free
// cursor press the row itself. The input context must have Interact live (on foot, in a vent, swimming, trapped,
// in a locker).

import * as THREE from 'three';

const FADE_IN = 9;
const FADE_OUT = 7;
const DRAIN = 5;

/**
 * @typedef {Object} PromptSpec
 * @property {THREE.Vector3|(() => THREE.Vector3)} [position] world anchor (or a function giving it every frame)
 * @property {string} [entity] an entity id: the prompt rides its pivot (plus `offset` in entity space)
 * @property {string} [attachment] an attachment name on that entity
 * @property {THREE.Vector3|number[]} [offset]
 * @property {string} text the action ("Unscrew", "Hide")
 * @property {string} [objectText] the object ("Vent Grate")
 * @property {number} [holdSeconds]
 * @property {number} [distance] MaxActivationDistance (default 10)
 * @property {boolean} [requiresLineOfSight] default true
 * @property {string} [action] input action (default 'Interact'; e.g. 'Kick')
 * @property {(prompt: PromptHandle) => void} onTriggered
 * @property {(prompt: PromptHandle) => void} [onHoldBegan]
 * @property {(prompt: PromptHandle) => void} [onHoldEnded]
 * @property {boolean} [enabled]
 */

/**
 * @typedef {Object} PromptHandle
 * @property {number} id
 * @property {() => void} remove
 * @property {(on: boolean) => void} setEnabled
 * @property {(text: string, objectText?: string) => void} setText
 * @property {(seconds: number) => void} setHoldSeconds
 * @property {() => boolean} isHolding
 */

export class Prompts {
  /** @param {import('./index.js').Engine} engine */
  constructor(engine) {
    this.engine = engine;
    /** @type {Map<number, any>} */
    this.list = new Map();
    this.nextId = 1;
    this.active = new Map(); // action -> prompt
    this.holding = null;
    this.held = new Map(); // action -> pressed
    for (const action of ['Interact', 'Kick']) {
      engine.input.on(action, (phase) => {
        this.held.set(action, phase === 'Begin');
        const p = this.active.get(action);
        if (phase === 'Begin' && p) this._begin(p);
        if (phase === 'End' && this.holding && this.holding.action === action) this._end();
      });
    }
  }

  /** @param {PromptSpec} spec @returns {PromptHandle} */
  add(spec) {
    const id = this.nextId++;
    const p = {
      id,
      spec,
      action: spec.action || 'Interact',
      text: spec.text || '',
      objectText: spec.objectText || '',
      hold: Math.max(0, spec.holdSeconds || 0),
      distance: spec.distance ?? 10,
      los: spec.requiresLineOfSight !== false,
      enabled: spec.enabled !== false,
      alpha: 0,
      progress: 0,
      shown: false,
      world: new THREE.Vector3(),
      screen: { x: 0, y: 0 },
    };
    const handle = {
      id,
      remove: () => {
        if (this.holding === p) this._end();
        this.list.delete(id);
      },
      setEnabled: (on) => {
        p.enabled = !!on;
        if (!on && this.holding === p) this._end();
      },
      setText: (text, objectText) => {
        p.text = text;
        if (objectText !== undefined) p.objectText = objectText;
      },
      setHoldSeconds: (s) => {
        p.hold = Math.max(0, s);
      },
      isHolding: () => this.holding === p,
    };
    p.handle = handle;
    this.list.set(id, p);
    return handle;
  }

  /** Removes every prompt (run reset). */
  clear() {
    this.list.clear();
    this.holding = null;
    this.active.clear();
  }

  _anchor(p, out) {
    const s = p.spec;
    if (s.entity) {
      const entities = this.engine.entities;
      const e = entities.get(s.entity);
      if (!e || e.hidden) return null;
      const frame = (s.attachment && entities.attachmentWorld(s.entity, s.attachment, _m)) || _m.copy(e.pivot);
      out.setFromMatrixPosition(frame);
      if (s.offset) {
        const o = Array.isArray(s.offset) ? _o.set(s.offset[0], s.offset[1], s.offset[2]) : _o.copy(s.offset);
        out.add(o.applyMatrix3(_n.setFromMatrix4(frame)));
      }
      return out;
    }
    if (typeof s.position === 'function') {
      const v = s.position();
      return v ? out.copy(v) : null;
    }
    if (s.position) {
      return Array.isArray(s.position) ? out.set(s.position[0], s.position[1], s.position[2]) : out.copy(s.position);
    }
    return null;
  }

  _begin(p) {
    if (this.holding) return;
    this.holding = p;
    if (p.spec.onHoldBegan) safe(p.spec.onHoldBegan, p.handle);
    if (p.hold <= 0) this._trigger(p);
  }

  _end() {
    const p = this.holding;
    this.holding = null;
    if (p && p.spec.onHoldEnded) safe(p.spec.onHoldEnded, p.handle);
  }

  _trigger(p) {
    p.progress = p.hold > 0 ? 1 : 0;
    p.flash = 1;
    this.holding = null;
    if (p.spec.onHoldEnded) safe(p.spec.onHoldEnded, p.handle);
    safe(p.spec.onTriggered, p.handle);
  }

  /** Per frame: choose, hold, render. */
  update(dt, camera, viewport) {
    const engine = this.engine;
    const player = engine.player;
    const input = engine.input;
    const root = player.rootPosition();
    const eye = player.eyePosition;
    camera.getWorldDirection(_fwd);
    const best = new Map();
    for (const p of this.list.values()) {
      p.shown = false;
      if (!p.enabled || !input.isLive(p.action) || player.lifeState === 'Dead') continue;
      if (!this._anchor(p, p.world)) continue;
      const d = p.world.distanceTo(root);
      if (d > p.distance) continue;
      _to.subVectors(p.world, eye);
      const dist = _to.length();
      const facing = dist > 1e-3 ? _to.dot(_fwd) / dist : 1;
      if (facing < 0.2) continue;
      if (p.los && dist > 0.5) {
        _to.divideScalar(dist);
        const hit = engine.world.raycast(eye, _to, Math.max(0, dist - 0.6), { ignoreEntities: true });
        if (hit) continue;
      }
      const score = d - facing * 2;
      const cur = best.get(p.action);
      if (!cur || score < cur.score) best.set(p.action, { p, score });
    }
    this.active.clear();
    for (const [action, b] of best) {
      this.active.set(action, b.p);
      b.p.shown = true;
    }
    // hold progress
    const h = this.holding;
    if (h && (!h.shown || !h.enabled)) this._end();
    for (const p of this.list.values()) {
      if (this.holding === p && p.hold > 0) {
        p.progress += dt / p.hold;
        if (p.progress >= 1) this._trigger(p);
      } else if (p.progress > 0) {
        p.progress = Math.max(0, p.progress - DRAIN * dt);
      }
      const target = p.shown ? 1 : 0;
      const rate = target > p.alpha ? FADE_IN : FADE_OUT;
      p.alpha += Math.sign(target - p.alpha) * Math.min(Math.abs(target - p.alpha), rate * dt);
    }
    // render
    const rows = [];
    for (const p of this.list.values()) {
      if (p.alpha <= 0.001) continue;
      _ndc.copy(p.world).project(camera);
      if (_ndc.z > 1) continue;
      rows.push({
        id: p.id,
        x: (_ndc.x * 0.5 + 0.5) * viewport.width,
        y: (-_ndc.y * 0.5 + 0.5) * viewport.height,
        visible: true,
        alpha: p.alpha,
        progress: p.hold > 0 ? Math.min(1, p.progress) : 0,
        text: p.text,
        objectText: p.objectText,
        action: p.action,
        onPress: () => {
          if (p.shown) this._begin(p);
        },
        onRelease: () => {
          if (this.holding === p) this._end();
        },
      });
    }
    engine.ui.renderPrompts(rows);
  }
}

function safe(fn, arg) {
  try {
    fn(arg);
  } catch (err) {
    console.error('[prompts] callback failed', err);
  }
}

const _m = new THREE.Matrix4();
const _o = new THREE.Vector3();
const _n = new THREE.Matrix3();
const _fwd = new THREE.Vector3();
const _to = new THREE.Vector3();
const _ndc = new THREE.Vector3();
