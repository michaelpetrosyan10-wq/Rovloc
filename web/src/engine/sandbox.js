// The engine sandbox: what the build links as the game while src/game/index.js does not exist yet (and what
// `?sandbox` selects in any build). A free walk through the real school at its run state: the player spawns at a
// level's first PlayerSpawn anchor, alive, meters running, torch on. URL parameters:
//   ?level=Level2_ScienceHall   spawn level (default Level1_Hallways)
//   ?at=x,y,z,yawDegrees        exact root position instead
// The pause menu (M / Esc) lists every level to jump to. Nothing here is gameplay: W4's game replaces it.

const LEVELS = ['Lobby', 'Level0_Basement', 'Level1_Hallways', 'Level2_ScienceHall', 'Level3_Gymnasium',
  'Level4_FloodedPool', 'Level5_Roof'];

/** Moves the player to a level's first spawn anchor. */
export function gotoLevel(engine, level) {
  const spawn = engine.spawnPoints(level)[0];
  if (!spawn) return false;
  engine.player.teleport(spawn.cframe);
  engine.setCurrentLevel(level);
  return true;
}

/** @param {import('./index.js').Engine} engine */
export async function start(engine) {
  const params = new URLSearchParams(location.search);
  const player = engine.player;
  player.setLifeState('Alive');
  player.setMetersActive(true);
  const at = params.get('at');
  if (at) {
    const [x, y, z, yaw] = at.split(',').map(Number);
    player.teleport({ position: { x, y, z }, yaw: ((yaw || 0) * Math.PI) / 180 });
  } else {
    gotoLevel(engine, params.get('level') || 'Level1_Hallways');
  }
  player.flashlight.setOn(true);
  engine.ui.setMenuButtons([
    { label: 'Resume', onClick: () => engine.ui.closeMenu() },
    ...LEVELS.map((level) => ({
      label: `Go to ${level.replace(/^Level\d_/, '').replace(/([a-z])([A-Z])/g, '$1 $2')}`,
      onClick: () => {
        gotoLevel(engine, level);
        engine.ui.closeMenu();
      },
    })),
  ]);
  engine.ui.toast('Click to look around. WASD to move, Shift to sprint, C to crouch, F for the torch, M for the menu.', { seconds: 8 });
}
