// floor5.js: the roof's "Cut the crate open" (ObjectiveConfig floor 5). The crate is the roof's lock.
//
// The parachute packs stay chained in their crate (parachute.setCrateOpen(false): no pack can be taken) until the
// chain is cut. The bolt cutters lean at the run's pick among the HVAC units, the water tank and the maintenance box
// (the item's hold). At the crate the chain's Locked prompt says why; with the cutters it is CutChain (4 s: the strain
// is the Normal working noise once a second). Done: the snap (the loud noise at the crate), the chain slithers off and
// the padlock drops, the packs can be taken, and if the Creature is still waiting behind the roof door the door smash
// starts at once (level5.crateCut); otherwise its own timer stands. The parachute flow after that is unchanged.

import { FloorObjective } from './base.js';
import { ObjectiveTuning, holdOf } from './config.js';
import { holdCallbacks } from './kit.js';
import { LockFixture } from './locks.js';

const CRATE_CHAIN = 'CrateChain';

export class Floor5 extends FloorObjective {
  constructor(system, spec) {
    super(system, spec);
    const chain = this.world.entities(CRATE_CHAIN, this.level)[0];
    this.chainId = chain ? chain.id : null;
  }

  setup() {
    this.cutters = this.items.find((e) => this.picked(e.id)) || null;
    if (this.cutters) this.itemPrompt(this.cutters, (item) => this._take(item));
    if (this.game.parachute) this.game.parachute.setCrateOpen(false);
    if (!this.chainId) return;
    this.crate = new LockFixture(this.game, this.chainId, this.tweens, this.fx);
    this.crate.reset();
    this.crateLocked = this.prompt(this.chainId, 'Locked', { holdSeconds: 0, onTriggered: () => this.crate.rattle() });
    this.cut = this.work({
      prompt: null, seconds: holdOf(this.spec, 'CutChain'), at: () => this.crate.chainCentre(), noise: true,
      onBegin: () => this.game.playAt('ObjLockRattle', this.crate.chainCentre()),
      onDone: () => this._cut(),
    });
    this.cutPrompt = this.prompt(this.chainId, 'CutChain', holdCallbacks(() => this.cut));
    this.cut.opts.prompt = this.cutPrompt;
  }

  teardown() {
    this.crate = this.crateLocked = this.cutPrompt = null;
    if (this.game.parachute) this.game.parachute.setCrateOpen(true);
  }

  _take(item) {
    this.env.setEntityVisible(item.id, false);
    this.carry.add('BoltCutters');
    this.game.playAt('ObjItemPickup', this.pointOf(item.id, 'PromptPoint'));
    this.advance('FindCutters');
  }

  _cut() {
    const at = this.crate.chainCentre();
    this.game.playAt('ObjBoltSnap', at);
    this.game.noise(at, ObjectiveTuning.LoudNoise);
    this.advance('CutChain');
  }

  /** The crate's unlock: the chain off, the packs free, the door smash brought forward. */
  unlock() {
    if (this.unlocked) return;
    this.unlocked = true;
    this.carry.take('BoltCutters');
    if (this.crate) this.crate.release(null);
    if (this.game.parachute) this.game.parachute.setCrateOpen(true);
    if (this.game.level5) this.game.level5.crateCut();
    this.notify('Obj.CrateOpen');
  }

  refresh() {
    super.refresh();
    const have = this.carry.has('BoltCutters');
    if (this.crateLocked) this.crateLocked.setEnabled(this.active && !this.unlocked && !have);
    if (this.cutPrompt) this.cutPrompt.setEnabled(this.active && !this.unlocked && have);
  }

  targets() {
    if (!this.done('FindCutters') && this.cutters && !this.env.entity(this.cutters.id).hidden) {
      const c = this.world.objectiveCandidates(this.level).find((x) => x.anchorId === this.cutters.id);
      return [{ point: this.pointOf(this.cutters.id, 'PromptPoint'), room: c ? c.room : null }];
    }
    return this.crate ? [{ point: this.crate.chainCentre() }] : [];
  }

  hintSpots() {
    return this.crate && !this.unlocked ? [{ key: 'Hint.Obj.CrateChain', point: this.crate.chainCentre() }] : [];
  }
}
