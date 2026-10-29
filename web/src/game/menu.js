// menu.js: the pause menu's buttons (the engine draws the menu and the settings under them). In the lobby: Resume
// and How to play; in a run: Resume and Abandon the run (it resolves as a death, as leaving does). With ?dev in the
// URL the dev shortcuts are listed too (each marks the run a dev run: no credits, escapes or best time).
// Web: played alone, the menu really pauses: the game clock stops while it is open (the Roblox menu cannot stop a
// shared server), so the Creature, timers and scenes all wait.

import { LevelOrder } from './config.js';
import { S } from './strings.js';

export class Menu {
  /** @param {import('./game.js').Game} game @param {import('./dev.js').Dev|null} dev */
  constructor(game, dev) {
    this.name = 'Menu';
    this.game = game;
    this.dev = dev;
    /** whether this menu holds the game clock stopped */
    this.paused = false;
    this.restoreButtons();
  }

  restoreButtons() {
    const game = this.game;
    const env = game.env;
    const close = () => env.closeMenu();
    const buttons = [{ label: S('Menu.Resume'), onClick: close }];
    if (game.phase === 'Lobby' || game.phase === 'Countdown') {
      buttons.push({ label: S('Menu.HowToPlay'), onClick: () => {
        close();
        if (game.onboarding) game.onboarding.openWalkthrough('Hidden');
      } });
    }
    if (game.phase === 'InRun') {
      buttons.push({ label: S('Menu.Abandon'), onClick: () => {
        close();
        game.match.abandon();
      } });
    }
    if (this.dev) {
      if (game.phase === 'Lobby' || game.phase === 'Countdown') {
        buttons.push({ label: 'Dev: deploy now', onClick: () => {
          close();
          this.dev.deploy();
        } });
      }
      if (game.phase === 'InRun') {
        for (const level of LevelOrder) {
          buttons.push({ label: `Dev: ${level.replace(/_/g, ' ')}`, onClick: () => {
            close();
            this.dev.gotoLevel(level);
          } });
        }
        buttons.push({ label: 'Dev: signature moment here', onClick: () => {
          close();
          this.dev.signature(game.level);
        } });
      }
    }
    env.setMenuButtons(buttons);
  }

  phaseChanged() {
    this.restoreButtons();
  }

  frame() {
    const open = this.game.env.menuOpen();
    if (open !== this.paused) {
      this.paused = open;
      this.game.env.setPaused(open);
    }
  }

  levelActivated() {
    this.restoreButtons();
  }
}
