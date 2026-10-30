// index.js: the floor objectives system (the web ObjectiveService): one FloorObjective per floor (floor0..5.js) built
// from meta.objectives, the carry, the objective effects and the Creature's start rule (spawns.js), driven by the game
// like every other system. Registered after the doors, the mechanics, the airlock and the Creature's level hook, so
// at a run start the doors are reset before the exits are locked and on a level's activation the Creature has been
// moved there before the start rule takes it.
//
// What the rest of the game asks of it: exitOpen(level) (the airlock waits for it), tracker(level) and nudge(level,
// root) (ui/objectives.js), hintSpots(level) (ui/hints.js), the carry (the HUD chips), devComplete(level) (dev / the
// smoke run's shortcut through a floor).

import { Carry } from './carry.js';
import { ObjectiveFx } from './fx.js';
import { CreatureSpawns } from './spawns.js';
import { registerObjectiveSounds } from './sounds.js';
import { Floor0 } from './floor0.js';
import { Floor1 } from './floor1.js';
import { Floor2 } from './floor2.js';
import { Floor3 } from './floor3.js';
import { Floor4 } from './floor4.js';
import { Floor5 } from './floor5.js';
import { S } from '../strings.js';

const FLOORS = [Floor0, Floor1, Floor2, Floor3, Floor4, Floor5];

export class FloorObjectives {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'FloorObjectives';
    this.game = game;
    registerObjectiveSounds();
    this.carry = new Carry(game);
    this.fx = new ObjectiveFx(game.env);
    this.spawns = new CreatureSpawns(game);
    /** @type {Map<string, import('./base.js').FloorObjective>} */
    this.floors = new Map();
    for (const spec of (game.world.meta.objectives && game.world.meta.objectives.floors) || []) {
      const Kind = FLOORS[spec.floor];
      if (Kind) this.floors.set(spec.levelId, new Kind(this, spec));
    }
  }

  /** The floor objective of a level, or null. */
  floor(level) {
    return this.floors.get(level) || null;
  }

  /** Whether the level's exit may be used (no objective, or its lock step done). */
  exitOpen(level) {
    const f = this.floor(level);
    return !f || f.exitOpen();
  }

  // ---------------------------------------------------------------------------------------------------- run

  beginRun(run) {
    this.carry.clear();
    this.fx.clear();
    for (const f of this.floors.values()) f.beginRun(run);
  }

  endRun() {
    this.spawns.endRun();
    for (const f of this.floors.values()) f.endRun();
    this.carry.clear();
    this.fx.clear();
  }

  levelActivated(level) {
    const f = this.floor(level);
    if (f) f.activate();
    this.spawns.levelActivated(level);
  }

  levelDeactivated(level) {
    const f = this.floor(level);
    if (f) f.deactivate();
    this.spawns.levelDeactivated(level);
  }

  tick(dt, now) {
    for (const f of this.floors.values()) f.tick(dt, now);
    this.spawns.tick(dt, now);
  }

  frame(dt) {
    this.fx.frame();
    this.carry.frame(dt);
  }

  // ---------------------------------------------------------------------------------------------------- for the UI

  /**
   * The tracker's view of a floor: {title, steps [{text, done, active}], unlocked, exit, exitLabel} where `exit` is the
   * "Get to the <compass> stairwell" line once the floor is unlocked (the run route's stairwell) and `exitLabel` the
   * marker's name for it; null for a level without an objective.
   */
  tracker(level) {
    const f = this.floor(level);
    if (!f || !this.game.run) return null;
    const route = this.game.route(level);
    const compass = route && route.compass ? S(`Obj.Compass.${route.compass}`) : null;
    return {
      title: S(f.spec.title),
      steps: f.stepLines(this.game.env.now()),
      unlocked: f.unlocked,
      exit: f.spec.lockVariant ? (compass ? S('Obj.Exit.Named', compass) : S('Objective.Step.Exit')) : null,
      exitLabel: compass ? S('Obj.Exit.Marker', compass) : null,
    };
  }

  /** The Tab nudge's target on a locked floor ({point, label, room}), or null (the tracker then points at the exit). */
  nudge(level, root) {
    const f = this.floor(level);
    if (!f || f.unlocked || !f.active) return null;
    return f.nudge(root);
  }

  /** When the nudge first becomes available on the current floor (game time), or -Infinity. */
  nudgeReadyAt(level, delay) {
    const f = this.floor(level);
    return f && f.activatedAt !== null ? f.activatedAt + delay : -Infinity;
  }

  hintSpots(level) {
    const f = this.floor(level);
    return f && f.active ? f.hintSpots() : [];
  }

  /** Co-op: everything a player carried is set down at `at` (they died or left); returns how many items dropped. */
  dropCarried(owner, at) {
    let dropped = 0;
    for (const { id } of this.carry.dropAll(owner)) {
      for (const f of this.floors.values()) {
        if (f.dropItem(id, at)) {
          dropped++;
          break;
        }
      }
    }
    for (const f of this.floors.values()) if (f.carrierGone) f.carrierGone(owner);
    return dropped;
  }

  // ---------------------------------------------------------------------------------------------------- dev

  /** Dev / the smoke run: completes a floor's objective at once (marks the run a dev run). */
  devComplete(level) {
    const f = this.floor(level || this.game.level);
    if (!f || !this.game.run) return false;
    this.game.run.devRun = true;
    this.game.match.devRun = true;
    f.devComplete();
    return true;
  }
}

