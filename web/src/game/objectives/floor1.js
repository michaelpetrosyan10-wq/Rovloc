// floor1.js: Floor 1's "Master keys" (ObjectiveConfig floor 1).
//
// The janitor's master keys hang on a nail at the run's pick among the candidates past the gate (only reachable by the
// gate's bypass vent once the classroom scare has slammed it; the Creature is hunting by then). Taking them (the
// item's hold) jingles. At the west stairwell door the padlock's Locked prompt gives way to Unlock (4 s) while the
// keys are carried: the keys work in the lock (their rattle looped) with the Normal working noise once a second, so a
// careful player waits for the Creature to be elsewhere. Done, the padlock springs and drops and the door unlocks.

import { FloorObjective } from './base.js';
import { holdOf } from './config.js';
import { holdCallbacks } from './kit.js';

export class Floor1 extends FloorObjective {
  setup() {
    for (const e of this.items) if (this.picked(e.id)) this.itemPrompt(e, (item) => this._take(item));
    if (!this.lock) return;
    this.unlockHold = this.work({
      prompt: null, seconds: holdOf(this.spec, 'Unlock'), at: () => this.lock.promptPoint(), sound: 'ObjKeysWork', noise: true,
      onDone: () => this.advance('UnlockExit'),
    });
    this.unlockPrompt = this.prompt(this.lock.id, 'Unlock', holdCallbacks(() => this.unlockHold));
    this.unlockHold.opts.prompt = this.unlockPrompt;
  }

  _take(item) {
    this.env.setEntityVisible(item.id, false);
    this.carry.add('MasterKeys');
    this.game.playAt('ObjKeyJingle', this.pointOf(item.id, 'PromptPoint'));
    this.advance('FindKeys');
  }

  lockedWanted() {
    return !this.carry.has('MasterKeys');
  }

  onUnlock() {
    this.carry.take('MasterKeys');
  }

  refresh() {
    super.refresh();
    if (this.unlockPrompt) this.unlockPrompt.setEnabled(this.active && !this.unlocked && this.carry.has('MasterKeys'));
  }

  targets() {
    if (!this.done('FindKeys')) {
      return this.items.filter((e) => this.picked(e.id) && !this.env.entity(e.id).hidden)
        .map((e) => ({ point: this.pointOf(e.id, 'PromptPoint') }));
    }
    return this.lock ? [{ point: this.lock.promptPoint() }] : [];
  }
}
