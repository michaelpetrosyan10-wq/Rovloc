// floor2.js: Floor 2's "Burn the chain" (ObjectiveConfig floor 2).
//
// Three reagents, one of each kind (the run's picks), are taken with the item's hold into the carry. At the fume hood
// in L2_ChemPrep_205 the Mix prompt (5 s) reads "Needs 3 reagents (n/3)" until all three are carried. The first hold
// loads the jars into the hood's ReagentSlot1..3 and slides the sash up to SashOpen; while held it bubbles (the loop)
// with the Normal working noise once a second. Letting go pauses the mix and keeps its progress (the prompt's hold is
// what is left); walking away or hiding ends the hold, so mixing never happens hidden. Done, the acid flask stands at
// the hood's AcidFlaskSpot: its Pickup (0.4 s) puts it in the hand like a chemical flask (flasks.js holdObjective).
// Two ways to use it at the chained stairwell door:
//   throw  the flask throw: a break within ChainHitRadius of the lock's ChainCentre burns the chain;
//   pour   the Pour prompt (2 s) at the door while it is in hand.
// A miss (it breaks anywhere else or flies out) loses only the flask: the reagents are still loaded, so the hood brews
// one more (MixAcid reads undone, a full 5 s mix) and a toast says so; every miss can be brewed again. The burn: acid
// fumes and the sizzle at the chain, the chain eaten through BurnSeconds later, and the door unlocks. Regular chemical
// flasks stay in play (level2.js keeps two out) and stun as ever; with one in hand the acid waits (hands full).

import * as THREE from 'three';
import { FloorObjective } from './base.js';
import { ObjectiveTuning, holdOf } from './config.js';
import { Ease, holdCallbacks, promptSpec } from './kit.js';
import { S } from '../strings.js';
import { cfMatrix } from '../util.js';

const HOOD = 'FumeHood';
const ACID = 'AcidFlask';
const BURN_SECONDS = 1.3;
const ACID_TINT = [0.78, 1, 0.22];
const FUME = [0.62, 0.7, 0.32];

export class Floor2 extends FloorObjective {
  constructor(system, spec) {
    super(system, spec);
    const hood = this.world.entities(HOOD, this.level)[0];
    this.hood = hood ? hood.id : null;
    const acid = this.world.entities(ACID, this.level)[0];
    this.acid = acid ? acid.id : null;
    this.sashBuilt = hood ? cfMatrix(hood.nodes.find((n) => n.path === 'Sash').pivot) : null;
    this.sashOpen = hood && hood.attachments.SashOpen ? cfMatrix(hood.attachments.SashOpen) : null;
  }

  setup() {
    this.loaded = false;
    this.acidState = 'None';
    this.burning = false;
    if (this.acid) this.env.setEntityVisible(this.acid, false);
    for (const e of this.items) if (this.picked(e.id)) this.itemPrompt(e, (item) => this._take(item));
    if (this.hood) {
      this.env.setNodeTransform(this.hood, 'Sash', null);
      this.mix = this.work({
        prompt: null, seconds: holdOf(this.spec, 'Mix'), at: () => this.pointOf(this.hood, 'MixPrompt'), sound: 'ObjBubbling',
        noise: true, keep: true,
        onBegin: () => this._load(),
        onEnd: () => this.refresh(),
        onDone: () => this._brewed(),
      });
      this.mixPrompt = this.prompt(this.hood, 'Mix', {
        ...holdCallbacks(() => this.mix),
        onHoldBegan: () => {
          if (this._reagentsReady()) this.mix.begin();
        },
        onTriggered: () => {
          if (this._reagentsReady()) this.mix.trigger();
          else this._needReagents();
        },
      });
      this.mix.opts.prompt = this.mixPrompt;
    }
    if (this.acid) {
      const spec = promptSpec(this.world, this.acid, 'Pickup');
      this.acidPrompt = this.prompt(this.acid, 'Pickup', { holdSeconds: spec ? spec.holdDuration : 0.4, onTriggered: () => this._takeAcid() });
    }
    if (this.lock) {
      this.pour = this.work({
        prompt: null, seconds: holdOf(this.spec, 'Pour'), at: () => this.lock.chainCentre(), sound: 'ObjAcidSizzle',
        onDone: () => this._pour(),
      });
      this.pourPrompt = this.prompt(this.lock.id, 'Pour', holdCallbacks(() => this.pour));
      this.pour.opts.prompt = this.pourPrompt;
    }
  }

  teardown() {
    this.mixPrompt = this.acidPrompt = this.pourPrompt = null;
  }

  _take(item) {
    this.env.setEntityVisible(item.id, false);
    this.carry.add('Reagent');
    this.game.playAt('ObjItemPickup', this.pointOf(item.id, 'PromptPoint'));
    this.advance('FindReagents');
  }

  _reagentsReady() {
    return this.loaded || this.carry.count('Reagent') >= this.spec.item.count;
  }

  _needReagents() {
    this.game.playAt('ObjLockRattle', this.pointOf(this.hood, 'MixPrompt'), { volume: 0.4 });
    this.notify('Obj.NeedReagents', this.carry.count('Reagent'), this.spec.item.count);
  }

  /** The first mix: the jars into the hood's slots, the sash up. */
  _load() {
    if (this.loaded || !this._reagentsReady()) return;
    this.loaded = true;
    this.carry.take('Reagent', this.spec.item.count);
    for (const e of this.items) {
      if (!this.picked(e.id)) continue;
      const slot = this.picks.slots[e.id] || 1;
      const seat = this.world.attachmentRest(this.hood, `ReagentSlot${slot}`);
      if (!seat) continue;
      const turn = cfMatrix(e.pivot).setPosition(0, 0, 0);
      this.env.setEntityPivot(e.id, seat.clone().setPosition(new THREE.Vector3().setFromMatrixPosition(seat)).multiply(turn));
      this.env.setEntityVisible(e.id, true);
    }
    if (this.sashBuilt && this.sashOpen) {
      const from = this.sashBuilt;
      const to = this.sashOpen;
      const a = new THREE.Vector3().setFromMatrixPosition(from);
      const b = new THREE.Vector3().setFromMatrixPosition(to);
      this.tweens.add({ seconds: ObjectiveTuning.SashSeconds, ease: Ease.inOut, update: (t) => {
        this.env.setNodePivot(this.hood, 'Sash', _m.copy(from).setPosition(_v.lerpVectors(a, b, t)));
      } });
      this.game.playAt('ObjLockerSearch', this.pointOf(this.hood, 'MixPrompt'), { volume: 0.8 });
    }
    this.refresh();
  }

  _brewed() {
    this.acidState = 'Ready';
    if (this.acid) {
      this.env.setEntityPivot(this.acid, this.world.entity(this.acid).pivot);
      this.env.setEntityVisible(this.acid, true);
    }
    this.game.playAt('Pickup', this.pointOf(this.hood, 'AcidFlaskSpot'));
    this.advance('MixAcid');
    this.notify('Obj.AcidReady');
  }

  _takeAcid() {
    if (this.acidState !== 'Ready' || !this.game.alive()) return;
    const flasks = this.game.flasks;
    const flask = {
      id: ACID, variant: 0, objective: true, tint: ACID_TINT, color: new THREE.Color(...ACID_TINT),
      gripOffset: this._gripOffset(),
      onShatter: (point) => this._shattered(point),
      onLost: () => this._missed(),
    };
    if (!flasks.holdObjective(flask)) {
      this.env.hint(S('Hud.FlaskHandsFull'), 3);
      return;
    }
    this.acidState = 'Held';
    this.env.setEntityVisible(this.acid, false);
    this.game.playAt('Pickup', this.pointOf(this.acid, 'PromptPoint'));
    this.refresh();
  }

  _gripOffset() {
    const info = this.world.entity(this.acid);
    const rest = cfMatrix(info.pivot);
    const grip = info.attachments.Grip ? cfMatrix(info.attachments.Grip) : rest;
    return rest.invert().multiply(grip);
  }

  _holding() {
    const held = this.game.flasks && this.game.flasks.held;
    return !!held && held.objective === true && held.id === ACID;
  }

  /** A thrown acid flask broke at `point`: true (the flask's own fumes, no stun cloud). */
  _shattered(point) {
    if (this.lock && !this.burning && point.distanceTo(this.lock.chainCentre(_v)) <= ObjectiveTuning.ChainHitRadius) {
      this.acidState = 'Used';
      this._burn();
    } else this._missed();
    return true;
  }

  _missed() {
    if (this.burning || this.unlocked) return;
    this.acidState = 'None';
    if (this.mix) this.mix.reset();
    this.undo('MixAcid');
    this.notify('Obj.AcidMissed');
  }

  _pour() {
    const flasks = this.game.flasks;
    if (!this._holding()) return;
    flasks.takeHeld();
    this.acidState = 'Used';
    this._burn();
  }

  _burn() {
    if (this.burning) return;
    this.burning = true;
    const at = this.lock.chainCentre(new THREE.Vector3());
    this.fx.smoke(at, { seconds: 3.4, rate: 9, color: FUME, size: 0.9, rise: 1.1, life: 2.4, spread: 0.8 });
    this.fx.glow(at, ACID_TINT, 0.35, 7, 3.2, 1.2);
    this.game.playAt('ObjAcidSizzle', at);
    this.tweens.add({ seconds: 0, delay: BURN_SECONDS, update: () => {}, done: () => this.advance('BurnChain') });
    this.refresh();
  }

  lockedWanted() {
    return !this._holding() && !this.burning;
  }

  refresh() {
    super.refresh();
    if (this.mixPrompt) {
      const ready = this._reagentsReady();
      const mixing = this.acidState === 'None' && !this.burning && !this.unlocked;
      this.mixPrompt.setEnabled(this.active && mixing);
      if (!ready) {
        this.mixPrompt.setText(S('Obj.Prompt.NeedReagents', this.carry.count('Reagent'), this.spec.item.count), S('Prompt.FumeHood'));
        this.mixPrompt.setHoldSeconds(0);
      } else {
        const left = this.mix.progress(this.env.now());
        this.mixPrompt.setText(S('Prompt.Mix'), left > 0.01 ? S('Obj.Prompt.Mixed', Math.round(left * 100)) : S('Prompt.FumeHood'));
        this.mixPrompt.setHoldSeconds(Math.max(0.05, this.mix.seconds - this.mix.done));
      }
    }
    if (this.acidPrompt) this.acidPrompt.setEnabled(this.active && this.acidState === 'Ready');
    if (this.pourPrompt) this.pourPrompt.setEnabled(this.active && !this.unlocked && !this.burning && this._holding());
  }

  tickFloor() {
    // the hand can change under us (thrown, emptied): keep the door's prompts in step
    const holding = this._holding();
    if (holding !== this.wasHolding) {
      this.wasHolding = holding;
      this.refresh();
    }
  }

  targets() {
    if (!this.done('FindReagents')) {
      return this.items.filter((e) => this.picked(e.id) && !this.env.entity(e.id).hidden && !this.loaded)
        .map((e) => ({ point: this.pointOf(e.id, 'PromptPoint') }));
    }
    if (!this.done('MixAcid') || this.acidState === 'Ready') return this.hood ? [{ point: this.pointOf(this.hood, 'MixPrompt') }] : [];
    return this.lock ? [{ point: this.lock.chainCentre() }] : [];
  }

  hintSpots() {
    const out = super.hintSpots();
    if (this.hood && !this.done('MixAcid')) out.push({ key: 'Hint.Obj.FumeHood', point: this.pointOf(this.hood, 'MixPrompt') });
    return out;
  }
}

const _m = new THREE.Matrix4();
const _v = new THREE.Vector3();
