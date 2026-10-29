// locks.js: the lock props (LockBuilder's ExitLock, StoreLock and CrateChain entities) as the game drives them.
//
// A LockFixture is reset Locked at every run start (every node back to its built pose, shown). Its Locked prompt
// (hold 0, the floor's "Locked — <reason>") rattles the padlock or chain, or beeps the keypad's denial, and makes no
// noise. release() takes it off: Padlock: the padlock springs and drops to the floor; Chain: the chain slithers off the
// leaves (or the crate) and the padlock drops; Keypad: the LED turns green with the accept chirp and the bar slides
// clear along its X. detach() hides the parts that ride the door leaves once the door swings (a dropped padlock and
// chain stay where they fell).

import * as THREE from 'three';
import { Ease } from './kit.js';
import { ObjectiveTuning } from './config.js';
import { cfMatrix, cfPos } from '../util.js';

const KEYPAD_GREEN = [0.25, 1, 0.35];
const BAR_SLIDE = 2.6;
const DROP_TILT = (75 * Math.PI) / 180;

export class LockFixture {
  /**
   * @param {import('../game.js').Game} game
   * @param {string} entityId
   * @param {import('./kit.js').Tweens} tweens
   * @param {import('./fx.js').ObjectiveFx} fx
   */
  constructor(game, entityId, tweens, fx) {
    this.game = game;
    this.env = game.env;
    this.id = entityId;
    this.info = game.world.entity(entityId);
    this.variant = (this.info && this.info.attributes.LockVariant) || 'Padlock';
    this.tweens = tweens;
    this.fx = fx;
    this.floorY = this.info ? this.info.pivot[1] : 0;
    /** @type {Map<string, THREE.Matrix4>} node -> built world frame */
    this.built = new Map((this.info ? this.info.nodes : []).map((n) => [n.path, cfMatrix(n.pivot)]));
    this.state = 'Locked';
  }

  /** The lock's prompt point (LockPrompt) and its chain centre (the acid's target). */
  promptPoint(out = new THREE.Vector3()) {
    const m = this.env.attachmentWorld(this.id, 'LockPrompt', _m);
    return m ? out.setFromMatrixPosition(m) : cfPos(this.info.pivot, out);
  }

  chainCentre(out = new THREE.Vector3()) {
    const a = this.info && this.info.attachments.ChainCentre;
    return a ? cfPos(a, out) : this.promptPoint(out);
  }

  reset() {
    this.state = 'Locked';
    this.env.setEntityVisible(this.id, true);
    for (const node of ['', ...this.built.keys()]) {
      this.env.setEntityVisible(this.id, true, node);
      if (node) this.env.setNodeTransform(this.id, node, null);
    }
  }

  /** The Locked prompt's answer: a rattle or the keypad's denial (no noise). */
  rattle() {
    this.game.playAt(this.variant === 'Keypad' ? 'ObjKeypadDenied' : 'ObjLockRattle', this.promptPoint(_p));
  }

  /** Takes the lock off (see the header); `done` once it is clear. */
  release(done) {
    if (this.state !== 'Locked') return;
    this.state = 'Released';
    const g = this.game;
    const at = this.promptPoint(new THREE.Vector3());
    const seconds = ObjectiveTuning.LockOffSeconds;
    if (this.variant === 'Keypad') {
      g.playAt('ObjKeypadAccept', at);
      this.fx.glow(at, KEYPAD_GREEN, 0.9, 7, 6, 1.5);
      this._slide('Bar', BAR_SLIDE, seconds);
    } else {
      g.playAt('ObjPadlockClack', at);
      if (this.built.has('Padlock')) this._drop('Padlock', seconds * 0.7, 0);
      if (this.built.has('Chain')) {
        g.playAt('ObjChainDrop', this.chainCentre(_p));
        this._drop('Chain', seconds, 0.12);
      }
    }
    this.tweens.add({ seconds, update: () => {}, done: () => done && done() });
  }

  /** Hides the parts riding the door leaves (the hasp, the brackets, the keypad and its bar). */
  detach() {
    this.env.setEntityVisible(this.id, false, '');
    if (this.variant === 'Keypad') this.env.setEntityVisible(this.id, false);
  }

  _slide(node, distance, seconds) {
    const base = this.built.get(node);
    if (!base) return;
    this.tweens.add({ seconds, ease: Ease.inOut, update: (t) => {
      this.env.setNodePivot(this.id, node, _f.copy(base).multiply(_t.makeTranslation(distance * t, 0, 0)));
    } });
  }

  /** Drops a node to the floor under it, tipping over as it falls. */
  _drop(node, seconds, delay) {
    const base = this.built.get(node);
    if (!base) return;
    const p = new THREE.Vector3().setFromMatrixPosition(base);
    const fall = Math.max(0, p.y - this.floorY - 0.12);
    const tilt = node === 'Chain' ? DROP_TILT : DROP_TILT * 0.8;
    this.tweens.add({ seconds, delay, ease: Ease.bounce, update: (t) => {
      _f.makeTranslation(0, -fall * t, 0).multiply(base).multiply(_r.makeRotationX(tilt * Math.min(1, t * 1.2)));
      this.env.setNodePivot(this.id, node, _f);
    } });
  }
}

const _m = new THREE.Matrix4();
const _f = new THREE.Matrix4();
const _t = new THREE.Matrix4();
const _r = new THREE.Matrix4();
const _p = new THREE.Vector3();
