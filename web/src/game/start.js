// start.js: builds the game on a running engine (the web ClientMain + ServerMain bootstrap) and opens the title.
// main.js calls start(engine) through index.js once the engine is up.

import { createCreatureApi } from './creatureApi.js';
import { Dev } from './dev.js';
import { Env } from './env.js';
import { Game } from './game.js';
import { BatteryPickups, DownedHud, Life } from './life.js';
import { Lobby } from './lobby.js';
import { Match } from './match.js';
import { Menu } from './menu.js';
import { Profile } from './profile.js';
import { registerSceneTracks } from './sceneTracks.js';
import { WorldData } from './worldData.js';
import { Airlock } from './mechanics/airlock.js';
import { Doors } from './mechanics/doors.js';
import { Traps } from './mechanics/traps.js';
import { Vents } from './mechanics/vents.js';
import { Flasks } from './mechanics/flasks.js';
import { Lockers } from './mechanics/lockers.js';
import { Pool } from './mechanics/pool.js';
import { Parachute } from './mechanics/parachute.js';
import { Debris } from './mechanics/debris.js';
import { Level0 } from './levels/level0.js';
import { Level1 } from './levels/level1.js';
import { Level2 } from './levels/level2.js';
import { Level3 } from './levels/level3.js';
import { Level4 } from './levels/level4.js';
import { Level5 } from './levels/level5.js';
import { FloorObjectives } from './objectives/index.js';
import { Hints } from './ui/hints.js';
import { Nav } from './ui/nav.js';
import { Objectives } from './ui/objectives.js';
import { Results } from './ui/results.js';
import { installStyle } from './ui/style.js';
import { Onboarding } from './ui/title.js';

/**
 * @param {any} engine the W2 Engine
 * @param {{creature?: any}} [opts] a Creature to use instead of W3's (null: none)
 * @returns {Promise<Game>}
 */
export async function start(engine, opts = {}) {
  installStyle();
  const env = new Env(engine);
  const creature = createCreatureApi(engine, opts.creature);
  const world = new WorldData(env.meta);
  const profile = new Profile(env);
  const nav = new Nav();
  const game = new Game(env, creature, world, profile, nav);

  // systems, in dependency order (beginRun runs forward, endRun in reverse)
  game.match = game.add(new Match(game));
  game.life = game.add(new Life(game));
  game.add(new BatteryPickups(game));
  game.doors = game.add(new Doors(game));
  game.traps = game.add(new Traps(game));
  game.vents = game.add(new Vents(game));
  game.flasks = game.add(new Flasks(game));
  game.lockers = game.add(new Lockers(game));
  game.pool = game.add(new Pool(game));
  game.parachute = game.add(new Parachute(game));
  game.add(new Debris(game));
  game.airlock = game.add(new Airlock(game));
  game.add(new CreatureLevels(game));
  game.level0 = game.add(new Level0(game));
  game.level1 = game.add(new Level1(game));
  game.level2 = game.add(new Level2(game));
  game.level3 = game.add(new Level3(game));
  game.level4 = game.add(new Level4(game));
  game.level5 = game.add(new Level5(game));
  game.floors = game.add(new FloorObjectives(game));
  game.lobby = game.add(new Lobby(game));
  game.onboarding = game.add(new Onboarding(game));
  game.objectives = game.add(new Objectives(game));
  game.hints = game.add(new Hints(game));
  game.downed = game.add(new DownedHud(game));
  game.results = game.add(new Results(game));
  const dev = new Dev(game);
  game.menu = game.add(new Menu(game, /[?&]dev\b/.test(location.search) ? dev : null));
  registerSceneTracks(game);
  wireCreature(game);

  env.onTick((dt) => game.tick(dt));
  env.onFrame((dt) => game.frame(dt));

  game.setPhase('Lobby');
  game.lobby.arrive(false);
  game.onboarding.onPlay = () => env.requestPointerLock();
  game.onboarding.openTitle();
  window.__rovlocGame = { game, dev };
  return game;
}

/**
 * The Creature's run (BeginRun on the run's difficulty), its level activation (MonsterAIService's LevelActivated
 * handler, before the level controllers take it for their scenes) and the run's teardown, and the game state it reads
 * (W3's GameHooks: the life state, the duct crawl, the grates, the fixture doors, the locker and the level).
 */
class CreatureLevels {
  constructor(game) {
    this.name = 'CreatureLevels';
    this.game = game;
    game.creature.bindGame({
      lifeState: () => game.life.state,
      downedCount: () => game.life.downedCount,
      isInVent: () => game.vents.inVent(),
      grateState: (id) => game.vents.stateOf(id),
      forceGrate: (id, state) => {
        game.vents.force(id, state);
      },
      doorOpen: (id) => {
        const door = game.doors.get(id);
        return !door || door.state === 'Open' || door.state === 'Smashed';
      },
      lockerOccupied: (id) => game.lockers.occupiedId() === id,
      playerLevel: () => game.level,
    });
  }

  beginRun(run) {
    this.game.creature.beginRun(run.difficulty);
  }

  levelActivated(level) {
    this.game.creature.activateLevel(level);
  }

  endRun() {
    this.game.creature.deactivate();
  }
}

/** The game's side of a catch: JumpscareHandler's outcome rule applied to the life state. */
function wireCreature(game) {
  const { creature, life } = game;
  let applied = false;
  const outcome = () => (life.state === 'Alive' && life.downedCount <= 0 ? 'Down' : 'Execute');
  const apply = (result) => {
    if (applied || !game.live()) return;
    applied = true;
    if (result === 'Down') life.down('Creature');
    else if (result === 'Execute') life.execute('Creature');
  };
  creature.setCatchHooks({
    canCatch: () => game.playing() && game.controlLock() !== 'Cutscene',
    outcome,
    apply,
  });
  creature.caught.connect(() => {
    applied = false;
  });
  creature.jumpscareFinished.connect((kind, result) => {
    if (result === 'Aborted') return;
    apply(result === 'Down' || result === 'Execute' ? result : outcome());
  });
}
