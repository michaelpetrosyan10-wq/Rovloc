// floor4.js: Floor 4's "Valve wheel" (ObjectiveConfig floor 4).
//
// The maintenance hatch over the duct's west grate is shut (its Hatch at HatchRest) and that grate is blocked while it
// is (vents.setBlocked: no prompts, no crawling in, impassable). The valve wheel lies on the deep end's floor at the
// run's pick: dive for it and take it (the item's hold, underwater; the oxygen drains as ever). It stays carried
// through a grab, the struggle and a down. At the half-submerged hatch valve, FitValve (3 s) seats it (its Hub on
// WheelSeat, a heavy clank); without the wheel the prompt reads "Needs the valve wheel". TurnValve (4 s) turns the
// wheel and the stem together (ValveTurns turns over the hold) with the squeal and the Normal working noise once a
// second; letting go keeps how far it turned. Done, the hatch swings up to HatchOpen, the grate is usable again and the
// stairwell door unlocks.

import * as THREE from 'three';
import { FloorObjective } from './base.js';
import { ObjectiveTuning, holdOf } from './config.js';
import { Ease, holdCallbacks, rotateAbout, seatPivot } from './kit.js';
import { S } from '../strings.js';
import { cfMatrix } from '../util.js';

const VALVE = 'HatchValve';

export class Floor4 extends FloorObjective {
  constructor(system, spec) {
    super(system, spec);
    const valve = this.world.entities(VALVE, this.level)[0];
    this.valve = valve ? valve.id : null;
    this.grate = valve ? valve.attributes.GrateId : null;
    const a = valve ? valve.attachments : {};
    this.seat = a.WheelSeat ? cfMatrix(a.WheelSeat) : null;
    this.seatPos = this.seat ? new THREE.Vector3().setFromMatrixPosition(this.seat) : null;
    this.axis = this.seat ? new THREE.Vector3().setFromMatrixColumn(this.seat, 1).normalize() : null;
    this.stemRest = a.StemRest ? cfMatrix(a.StemRest) : null;
    this.hatchRest = a.HatchRest ? cfMatrix(a.HatchRest) : null;
    this.hatchOpen = a.HatchOpen ? cfMatrix(a.HatchOpen) : null;
  }

  setup() {
    this.wheel = this.items.find((e) => this.picked(e.id)) || null;
    this.fitted = false;
    if (this.wheel) this.itemPrompt(this.wheel, (item) => this._take(item));
    if (!this.valve) return;
    this.env.setNodeTransform(this.valve, 'Hatch', null);
    this.env.setNodeTransform(this.valve, 'Stem', null);
    if (this.grate && this.game.vents) this.game.vents.setBlocked(this.grate, true);
    this.fitPrompt = this.prompt(this.valve, 'FitValve', { onTriggered: () => this._fit() });
    this.turn = this.work({
      prompt: null, seconds: holdOf(this.spec, 'TurnValve'), at: () => this.seatPos, sound: 'ObjValveSqueal', noise: true,
      keep: true, onProgress: (t) => this._turnTo(t), onEnd: () => this.refresh(), onDone: () => this._turned(),
    });
    this.turnPrompt = this.prompt(this.valve, 'TurnValve', holdCallbacks(() => this.turn));
    this.turn.opts.prompt = this.turnPrompt;
  }

  teardown() {
    if (this.grate && this.game.vents) this.game.vents.setBlocked(this.grate, false);
    this.fitPrompt = this.turnPrompt = null;
  }

  _take(item) {
    this.env.setEntityVisible(item.id, false);
    this.carry.add('ValveWheel');
    this.game.playAt('ObjItemPickup', this.pointOf(item.id, 'PromptPoint'));
    this.advance('FindWheel');
  }

  _fit() {
    if (!this.game.alive() || this.fitted) return;
    if (!this.carry.take('ValveWheel')) {
      this.game.playAt('ObjLockRattle', this.seatPos, { volume: 0.5 });
      this.notify('Obj.NeedWheel');
      return;
    }
    this.fitted = true;
    if (this.wheel && this.seat) {
      this.env.setEntityPivot(this.wheel.id, seatPivot(this.world, this.wheel.id, 'Hub', this.seat));
      this.env.setEntityVisible(this.wheel.id, true);
    }
    this.game.playAt('ObjWheelFit', this.seatPos);
    this.advance('FitWheel');
  }

  /** The wheel and the stem turned `share` of the full turn. */
  _turnTo(share) {
    if (!this.fitted || !this.seat) return;
    const angle = share * ObjectiveTuning.ValveTurns * Math.PI * 2;
    if (this.wheel) {
      const base = seatPivot(this.world, this.wheel.id, 'Hub', this.seat, _a);
      this.env.setEntityPivot(this.wheel.id, rotateAbout(base, this.seatPos, this.axis, angle, _b));
    }
    if (this.stemRest) this.env.setNodePivot(this.valve, 'Stem', rotateAbout(this.stemRest, this.seatPos, this.axis, angle, _b));
  }

  _turned() {
    const g = this.game;
    if (this.hatchRest && this.hatchOpen) {
      const qa = new THREE.Quaternion().setFromRotationMatrix(this.hatchRest);
      const qb = new THREE.Quaternion().setFromRotationMatrix(this.hatchOpen);
      const pa = new THREE.Vector3().setFromMatrixPosition(this.hatchRest);
      const pb = new THREE.Vector3().setFromMatrixPosition(this.hatchOpen);
      this.tweens.add({ seconds: ObjectiveTuning.HatchSeconds, ease: Ease.inOut, update: (t) => {
        _q.copy(qa).slerp(qb, t);
        this.env.setNodePivot(this.valve, 'Hatch', _a.compose(_v.lerpVectors(pa, pb, t), _q, _one));
      } });
      g.playAt('MetalCreak', pa);
    }
    if (this.grate && g.vents) g.vents.setBlocked(this.grate, false);
    this.advance('TurnValve');
    this.notify('Obj.HatchOpen');
  }

  refresh() {
    super.refresh();
    if (this.fitPrompt) {
      this.fitPrompt.setEnabled(this.active && !this.fitted);
      const have = this.carry.has('ValveWheel');
      this.fitPrompt.setText(have ? S('Prompt.FitValve') : S('Obj.Prompt.NeedWheel'), S('Prompt.HatchValve'));
      this.fitPrompt.setHoldSeconds(have ? holdOf(this.spec, 'FitValve') : 0);
    }
    if (this.turnPrompt) {
      this.turnPrompt.setEnabled(this.active && this.fitted && !this.done('TurnValve'));
      const turned = this.turn.progress(this.env.now());
      this.turnPrompt.setText(S('Prompt.TurnValve'), turned > 0.01 ? S('Obj.Prompt.Turned', Math.round(turned * 100)) : S('Prompt.HatchValve'));
    }
  }

  targets() {
    if (!this.done('FindWheel') && this.wheel && !this.env.entity(this.wheel.id).hidden) {
      const c = this.world.objectiveCandidates(this.level).find((x) => x.anchorId === this.wheel.id);
      return [{ point: this.pointOf(this.wheel.id, 'PromptPoint'), room: c ? c.room : null }];
    }
    return this.seatPos ? [{ point: this.seatPos.clone() }] : [];
  }

  hintSpots() {
    const out = super.hintSpots();
    if (this.seatPos && !this.fitted) out.push({ key: 'Hint.Obj.HatchValve', point: this.seatPos.clone() });
    return out;
  }
}

const _a = new THREE.Matrix4();
const _b = new THREE.Matrix4();
const _q = new THREE.Quaternion();
const _v = new THREE.Vector3();
const _one = new THREE.Vector3(1, 1, 1);
