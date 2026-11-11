// dev.js: the dev shortcuts (DevToolsService's level skip and the per-system commands), on window.__rovlocGame.dev
// for the headless checks and in the pause menu with ?dev. Any state-changing shortcut during a run makes it a dev
// run (no credits, escapes or best time), as DevRun does.
//
//   skipTitle()            past the title screen (the walkthrough marked done) into the lobby
//   deploy(difficulty?)    straight into a run
//   gotoStage(stage)       go to a stage: enter it (a level: at its first spawn slot; a stand-in: its card)
//   gotoLevel(level)       the level skip (gotoStage for a level of the school)
//   respawns(n)            set your respawns left: n stage respawns, none from the run or the syringe
//   radar(n)               set your radar charges (up to the difficulty's most)
//   snapTrap()             spring the nearest armed trap on yourself          seal()  seal the current airlock now
//   seed(n)                pin the next runs' seed (null: random)          completeObjective(level?) the floor done at once
//   beat(kind?)            a basement beat now
//   roof(smash|ledge)      the roof door sequence now, or the Creature on the ledge once someone has jumped
//   signature(level)       the level's signature moment: the basement a trap, the Hallways the classroom scare, the
//                          roof the jump (a pack on, off the gap, the cord pulled)

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

  /** Go to a stage: entered (and activated); on a level of the school the player stands at its first spawn slot. */
  gotoStage(stage) {
    const g = this.game;
    if (!g.run || !g.stages.get(stage)) return false;
    this._mark();
    if (g.traps.caught) g.traps._free(g.traps.caught, 'Release');
    if (g.vents.inVent()) g.vents.leave();
    g.lockers.release();
    if (g.stages.isLevel(stage)) {
      g.match.spawnAt(stage, 0);
      g.traps.noteTeleport();
    }
    g.enterStage(stage);
    return true;
  }

  /** The level skip (a level of the school). */
  gotoLevel(level) {
    return this.game.stages.isLevel(level) && this.gotoStage(level);
  }

  /** Sets this player's respawns left: `n` stage respawns, none from the run or the syringe (alone, or the host). */
  respawns(n) {
    const life = this.game.life;
    if (!this.game.run || !life.authority() || !Number.isInteger(n) || n < 0) return false;
    this._mark();
    life.setLives({ ...life.lives, stage: n, run: 0, syringe: 0 });
    return true;
  }

  /** Sets this player's radar charges (0 to the difficulty's most). */
  radar(n) {
    if (!this.game.run || !Number.isInteger(n) || n < 0) return false;
    this._mark();
    this.game.radar.setCharges(n);
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

  /**
   * The roof's dev command (`roof smash | ledge`): the door sequence now (only while the squad is arriving), or the
   * Creature on the ledge once someone is off the roof.
   */
  roof(action) {
    this._mark();
    if (action === 'smash') return this.game.level3.devSmash();
    if (action === 'ledge') return this.game.level3.devLedge();
    return false;
  }

  /** The level's signature moment, set up around the player. */
  signature(level) {
    const g = this.game;
    this._mark();
    switch (level) {
      case 'Level0_Basement': return this.snapTrap();
      case 'Level1_Hallways': return g.level1.devScare();
      case 'Level3_Roof': return g.level3.devJump();
      default: return false;
    }
  }
}
