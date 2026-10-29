// dev.js: the dev shortcuts (DevToolsService's level skip and the per-system commands), on window.__rovlocGame.dev
// for the headless checks and in the pause menu with ?dev. Any state-changing shortcut during a run makes it a dev
// run (no credits, escapes or best time), as DevRun does.
//
//   skipTitle()            past the title screen (the walkthrough marked done) into the lobby
//   deploy(difficulty?)    straight into a run
//   gotoLevel(level)       the level skip: enter the level, stand at its first spawn slot
//   snapTrap()             spring the nearest armed trap on yourself          seal()  seal the current airlock now
//   seed(n)                pin the next runs' seed (null: random)          completeObjective(level?) the floor done at once
//   beat(kind?)            a basement beat now                                 escape() count yourself escaped
//   signature(level)       the level's signature moment: L0 a trap, L1 the classroom scare, L2 a flask throw,
//                          L3 a locker check, L4 a pool grab, L5 the door smash and the finale

import * as THREE from 'three';
import { TutorialConfig } from './config.js';

export class Dev {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.game = game;
  }

  _mark() {
    const run = this.game.run;
    if (run) run.devRun = true;
    this.game.match.devRun = true;
  }

  skipTitle() {
    const g = this.game;
    g.env.setSetting(TutorialConfig.TutorialSetting, true);
    if (g.onboarding.busy()) g.onboarding.pressPlay();
  }

  async deploy(difficulty) {
    const g = this.game;
    if (g.onboarding.busy()) this.skipTitle();
    this.game.match.devRun = true;
    return g.match.deploy(difficulty || g.lobby.difficulty());
  }

  /** The level skip: the level entered (and activated), the player at its first spawn slot. */
  gotoLevel(level) {
    const g = this.game;
    if (!g.run) return false;
    this._mark();
    if (g.traps.caught) g.traps._free(g.traps.caught, 'Release');
    if (g.vents.inVent()) g.vents.leave();
    g.lockers.release();
    if (g.pool.grab) g.pool.releaseGrab('Ended');
    g.pool.leaveWater(true);
    g.match.spawnAt(level, 0);
    g.traps.noteTeleport();
    g.enterLevel(level);
    return true;
  }

  snapTrap() {
    const g = this.game;
    const root = g.env.rootPosition(new THREE.Vector3());
    let best = null;
    let bd = Infinity;
    for (const t of g.traps.traps) {
      if (t.state !== 'Armed' || t.level !== g.level) continue;
      const d = t.floor.distanceTo(root);
      if (d < bd) {
        bd = d;
        best = t;
      }
    }
    if (!best) return false;
    this._mark();
    return g.traps.snap(best);
  }

  seal() {
    this._mark();
    return this.game.airlock.seal();
  }

  /** Pins the seed of the runs that follow (null: a fresh random seed per run again). */
  seed(n) {
    this.game.match.nextSeed = n === undefined ? null : n;
    return true;
  }

  /** The current floor's objective done at once, through its own unlock (the exit opens). */
  completeObjective(level) {
    this._mark();
    return this.game.floors.devComplete(level || this.game.level);
  }

  beat(kind) {
    return this.game.level0.tryBeat(this.game.env.now(), kind || null);
  }

  escape() {
    this._mark();
    return this.game.match.markEscaped();
  }

  /** The level's signature moment, set up around the player. */
  signature(level) {
    const g = this.game;
    this._mark();
    switch (level) {
      case 'Level0_Basement': return this.snapTrap();
      case 'Level1_Hallways': return g.level1.devScare();
      case 'Level2_ScienceHall': return g.flasks.devThrow();
      case 'Level3_Gymnasium': return g.lockers.devCheck();
      case 'Level4_FloodedPool': return g.pool.devGrab();
      case 'Level5_Roof': return g.level5.devFinale();
      default: return false;
    }
  }
}
