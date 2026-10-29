// level5.js: the roof and the ending (Level5_RoofController). The packs, the jump and the canopy are parachute.js;
// this runs the level around them and owns the finale.
//
// Arrival. On activation the Creature is taken (acquireScripted; asked for again at the tick rate while busy, only
// taken while the player cannot see it) and kept hidden in the stair housing. The RoofStairDoor (Closed) swings open
// OPEN_DELAY after the player reaches the housing.
//
// The door smash (Scenes.RoofDoor, from startAt S): the Creature waits behind the door for its grace once the player
// has stepped out of the housing (SpawnTuning.Grace: 20 s Standard, 12 s Nightmare), ended early by a High / Critical
// noise of the player's on the roof or at once by the crate's chain being cut (crateCut, the roof objective), or
// ARRIVAL_TIMEOUT after activation: "L5_DoorSmash". The wind slams the door shut so it lands at Slam (skipped while the
// player is inside or within DOOR_CLEAR of the doorway), the hidden Creature is moved in right behind it (Stage), three
// blows, it is shown behind the door at Reveal (only while that spot is out of sight), the door Smashed at Smash (the
// DoorSmash action), its cry, and at Release it is let go: into WallChase when it can see the player from the doorway,
// else into Patrol (its senses find them, it is never told where they are); Hud.RoofRun once the crate is open.
//
// The final sprint: the Creature's pace follows its gap to the player (chaseScale: it runs a straggler down but never
// quite outruns a sprinter on Standard) and an Alive player on the roof sprints on adrenaline (stamina topped up under
// STAMINA_FLOOR).
//
// The finale (Scenes.Finale, from startAt F): once the player has jumped and is under an open canopy that has settled
// (Finale.Settle), or down, or FINALE_WAIT after the first landing. The Creature is taken back (up to ACQUIRE_WAIT;
// without it only the storm plays, "L5_FinaleSky"), hidden, put on the ledge the player jumped from facing out over
// them and staring at them. Lightning at Flash1 and Flash2; it is shown just before the first flash's main strike and
// hidden just before the second's; the screen fades to black. At Land a jumper still under a canopy is landed in the
// dark, the player escapes and the hold ends (the ESCAPED summary takes over). Anyone still on the roof is hunted again.
// A jumper who lands after the finale gets their own fade ("L5_Touchdown") and their hold ends TouchdownRelease later.

import * as THREE from 'three';
import { CreatureMetrics } from '../creatureApi.js';
import { DifficultyConfig, GameConfig } from '../config.js';
import * as Scenes from '../scenes.js';
import { Schedule, horizontalDistance, lookAtMatrix } from '../util.js';
import { edgePoint, outward } from '../mechanics/parachute.js';
import { SpawnTuning } from '../objectives/config.js';

const LEVEL = 'Level5_Roof';
const TOKEN = 'L5_RoofFinale';
const DOOR_ID = 'RoofStairDoor';
const HOUSING_ROOM = 'L5_RoofAccess';
const ROOF_SIDE_ROOM = 'L5_Roof_East';
const TICK = 1 / GameConfig.ServerTickHz;
const LEAD = GameConfig.OneShotLead;
const OPEN_DELAY = 1.2;
const OPEN_SECONDS = 1.4;
const DOOR_CLEAR = 9;
const ARRIVAL_TIMEOUT = 75;
const BEHIND_DOOR = 3;
const STAMINA_FLOOR = 55;
const FINALE_WAIT = 40;
const ACQUIRE_WAIT = 1.5;
const FINALE_PRE = 0.3;
const LEDGE_INSET = 1.2;
const NEAR_GAP = 14;
const FAR_GAP = 40;
const SCALE_STEP = 0.02;
const CHEST_HEIGHT = 1.2;
const DOOR = Scenes.RoofDoor;
const FINALE = Scenes.Finale;
const ROOF_ARGS = Scenes.RoofArgs;
const ON_ROOF = new Set(['None', 'Packed']);
const PACE = { Standard: { near: 0.96, far: 1.3 }, Nightmare: { near: 1.02, far: 1.45 } };

const inRect = (r, p) => p.x >= r.minX && p.x <= r.maxX && p.z >= r.minZ && p.z <= r.maxZ;

/** The roof's door geometry from the export's Level 5 layout (Level5.geometry). */
export function geometry(meta) {
  const layout = meta.layouts[LEVEL];
  const origin = new THREE.Vector3(...meta.levels[LEVEL].origin);
  const rooms = new Map(layout.rooms.map((r) => [r.id, r]));
  const housing = rooms.get(HOUSING_ROOM);
  const side = rooms.get(ROOF_SIDE_ROOM);
  const door = layout.doors.find((d) => d.scriptedId === DOOR_ID);
  if (!housing || !side || !door) throw new Error('Level 5 has no roof door geometry');
  const a = housing.rect;
  const b = side.rect;
  let doorway;
  let axis;
  if (Math.abs(a.x - (b.x + b.w)) < 1e-6 || Math.abs(a.x + a.w - b.x) < 1e-6) {
    axis = 'X';
    doorway = origin.clone().add(new THREE.Vector3(Math.abs(a.x - (b.x + b.w)) < 1e-6 ? a.x : a.x + a.w, 0, door.at));
  } else {
    axis = 'Z';
    doorway = origin.clone().add(new THREE.Vector3(door.at, 0, Math.abs(a.z - (b.z + b.d)) < 1e-6 ? a.z : a.z + a.d));
  }
  const centre = origin.clone().add(new THREE.Vector3(a.x + a.w / 2, 0, a.z + a.d / 2));
  const from = doorway.clone().sub(centre);
  const out = axis === 'X' ? new THREE.Vector3(from.x < 0 ? -1 : 1, 0, 0) : new THREE.Vector3(0, 0, from.z < 0 ? -1 : 1);
  const spot = doorway.clone().addScaledVector(out, -BEHIND_DOOR).add(new THREE.Vector3(0, CreatureMetrics.rootHeight, 0));
  const stair = meta.stairwells.find((s) => s.to === LEVEL);
  const tower = meta.worldConfig.Towers[stair ? stair.tower : 'East'];
  const school = meta.worldConfig.SchoolOrigin || [0, 0, 0];
  return {
    origin,
    housing: { minX: origin.x + a.x, maxX: origin.x + a.x + a.w, minZ: origin.z + a.z, maxZ: origin.z + a.z + a.d },
    tower: { minX: school[0] + tower.minX, maxX: school[0] + tower.maxX, minZ: school[2] + tower.minZ, maxZ: school[2] + tower.maxZ },
    doorway,
    out,
    behind: lookAtMatrix(spot, spot.clone().add(out)),
    behindPosition: spot,
    cue: doorway.clone().add(out).add(new THREE.Vector3(0, 4, 0)),
  };
}

/** Level5.chaseScale: the pace for a gap to the target (never quite outrunning a sprinter on Standard). */
export function chaseScale(gap, difficulty) {
  if (gap === null) return 1;
  const pace = PACE[difficulty] || PACE.Standard;
  const spec = DifficultyConfig[difficulty] || DifficultyConfig.Standard;
  const base = CreatureMetrics.speeds.WallChase * spec.creatureSpeedMultiplier;
  const share = pace.near + (pace.far - pace.near) * Math.min(1, Math.max(0, (gap - NEAR_GAP) / (FAR_GAP - NEAR_GAP)));
  const scale = (share * GameConfig.SprintSpeed) / base;
  return Math.min(2, Math.max(0.5, Math.round(scale / SCALE_STEP) * SCALE_STEP));
}

/** Level5.finaleReady (one player: jumped and settled, or FINALE_WAIT after landing). */
export function finaleReady(input) {
  if (input.jumpers + input.falling === 0) return false;
  if (input.firstLandedAt !== null && input.now >= input.firstLandedAt + FINALE_WAIT) return true;
  if (input.jumpers === 0 || input.roofAlive > 0 || input.falling > 0) return false;
  return input.lastDeployAt === null || input.now >= input.lastDeployAt + FINALE.Settle;
}

export class Level5 {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Level5';
    this.game = game;
    this.env = game.env;
    this.geo = geometry(game.world.meta);
    this.schedule = new Schedule();
    this.handle = null;
    this._resetState();
    game.env.onNoise((e) => this._noise(e));
  }

  _resetState() {
    this.smashNow = false;
    this.active = false;
    this.phase = 'Idle';
    this.activatedAt = 0;
    this.arrivedAt = null;
    this.firstOutAt = null;
    this.doorOpened = false;
    this.smash = null;
    this.finale = null;
    this.acquireUntil = 0;
    this.nextTickAt = -Infinity;
    this.scaleSet = 1;
    this.escaped = false;
    this.landedAt = null;
    this.touchdown = false;
  }

  // ---------------------------------------------------------------------------------------------------- the Creature

  _take() {
    if (this.handle) return this.handle;
    const h = this.game.creature.acquireScripted(TOKEN);
    if (h) {
      this.handle = h;
      this.game.creatureHandle = h;
    }
    return h;
  }

  _letGo(state) {
    const h = this.handle;
    this.handle = null;
    if (!h) return;
    if (this.game.creatureHandle === h) this.game.creatureHandle = null;
    h.setTarget(false);
    if (state) h.release(state);
  }

  _seen(root) {
    return this.game.seen(_a.copy(root).add(_b.set(0, CreatureMetrics.eye.Biped, 0))) ||
      this.game.seen(_a.copy(root).add(_b.set(0, CHEST_HEIGHT, 0)));
  }

  _setScale(scale) {
    if (Math.abs(scale - this.scaleSet) < 1e-6) return;
    this.scaleSet = scale;
    this.game.creature.setSpeedScale(scale);
  }

  _door() {
    return this.game.doors.find(LEVEL, DOOR_ID);
  }

  _inside(p) {
    return inRect(this.geo.housing, p) || inRect(this.geo.tower, p);
  }

  // ---------------------------------------------------------------------------------------------------- the smash

  _startSmash(now) {
    const g = this.game;
    this.phase = 'Smash';
    const startAt = now + LEAD;
    const run = { startAt, slammed: false, revealed: false, released: false };
    this.smash = run;
    const root = this.env.rootPosition(new THREE.Vector3());
    const blocked = g.playing() && (this._inside(root) || horizontalDistance(root, this.geo.doorway) < DOOR_CLEAR);
    g.seq.play(DOOR.Id, startAt, { [ROOF_ARGS.Door]: this.geo.cue });
    const door = this._door();
    if (door && !blocked && door.state === 'Open') run.slammed = g.doors.setState(door, 'Closed', DOOR.SlamSeconds) !== false;
    this.schedule.at(startAt + DOOR.Stage, 'stage', () => {
      const h = this.handle;
      if (!h) return;
      h.setHidden(true);
      h.setPose('Biped');
      h.teleport(this.geo.behind);
    });
    this.schedule.at(startAt + DOOR.Reveal, 'reveal', () => {
      if (this.handle && !this._seen(this.geo.behindPosition)) {
        this.handle.setHidden(false);
        run.revealed = true;
      }
    });
    this.schedule.at(startAt + DOOR.Smash - LEAD, 'smash', () => {
      const d = this._door();
      if (d) g.doors.setState(d, 'Smashed');
    });
    this.schedule.at(startAt + DOOR.Release, 'release', () => {
      run.released = true;
      if (this.phase === 'Smash') this.phase = 'Chase';
      // it runs down a player it can see from the doorway; one out of sight is left to its senses (it patrols)
      const sees = g.playing() && this._seen(this.geo.behindPosition);
      this._letGo(sees ? 'WallChase' : 'Patrol');
      if (ON_ROOF.has(g.parachute.state) && g.parachute.crateOpen !== false) g.notify('Hud.RoofRun');
    });
  }

  _stepArrival(now) {
    const g = this.game;
    if (!this.handle && !this._seenCreature() && this._take()) this.handle.setHidden(true);
    const root = this.env.rootPosition(new THREE.Vector3());
    const playing = g.playing();
    if (playing && inRect(this.geo.housing, root) && this.arrivedAt === null) this.arrivedAt = now;
    if (!this.doorOpened && this.arrivedAt !== null && now >= this.arrivedAt + OPEN_DELAY) {
      this.doorOpened = true;
      const door = this._door();
      if (door && door.state === 'Closed') g.doors.setState(door, 'Open', OPEN_SECONDS);
    }
    const inside = this._inside(root);
    if (playing && !inside && this.firstOutAt === null) this.firstOutAt = now;
    const grace = SpawnTuning.Grace[g.run ? g.run.difficulty : 'Standard'] ?? SpawnTuning.Grace.Standard;
    const due = this.smashNow || (this.firstOutAt !== null && now >= this.firstOutAt + grace) ||
      now >= this.activatedAt + ARRIVAL_TIMEOUT;
    if (due) this._startSmash(now);
  }

  /** The crate's chain cut (floor5.js): the door smash at once while the Creature still waits behind the door. */
  crateCut() {
    if (this.active && this.phase === 'Arrival') this._startSmash(this.env.now());
  }

  /** A High / Critical noise of the player's out on the roof ends the wait behind the door (the grace) at once. */
  _noise(e) {
    if (!this.active || this.phase !== 'Arrival' || this.firstOutAt === null || e.source !== 'player') return;
    if (e.level === LEVEL && (e.priority === 'High' || e.priority === 'Critical')) this.smashNow = true;
  }


  _seenCreature() {
    const p = this.game.creature.position(new THREE.Vector3());
    return !!p && !this.game.creature.isHidden() && this._seen(p);
  }

  _stepChase() {
    const g = this.game;
    const c = g.creature;
    const creature = c.position(new THREE.Vector3());
    const gap = creature && c.hasTarget() && g.playing() ? horizontalDistance(creature, this.env.rootPosition(_a)) : null;
    this._setScale(chaseScale(gap, g.run ? g.run.difficulty : 'Standard'));
    if (ON_ROOF.has(g.parachute.state) && g.life.state === 'Alive' && this.env.meters().stamina.value < STAMINA_FLOOR) {
      this.env.refillStamina();
    }
  }

  // ---------------------------------------------------------------------------------------------------- the finale

  _checkFinale(now) {
    const g = this.game;
    const p = g.parachute;
    const state = p.state;
    const jumpers = state === 'Canopy' || state === 'Landed' ? 1 : 0;
    const falling = state === 'Freefall' ? 1 : 0;
    const roofAlive = ON_ROOF.has(state) && g.life.state === 'Alive' ? 1 : 0;
    const lastDeployAt = state === 'Canopy' ? p.deployedAt : null;
    if (finaleReady({ jumpers, falling, roofAlive, lastDeployAt, firstLandedAt: this.landedAt, now })) this._startFinale(now);
  }

  _startFinale(now) {
    this.schedule.clear();
    this._setScale(1);
    if (!this._take()) {
      this.phase = 'FinaleWait';
      this.acquireUntil = now + ACQUIRE_WAIT;
      return;
    }
    this._beginFinale(now, true);
  }

  /** Level5.revealPose: on the edge the player left from, facing out over them. */
  _revealPose() {
    const p = this.game.parachute;
    const pg = p.geo;
    const from = p.leftFrom ? p.leftFrom.clone() : new THREE.Vector3(pg.gap.minX, pg.deckY, (pg.gap.minZ + pg.gap.maxZ) / 2);
    const edge = edgePoint(pg, from);
    const out = outward(pg, from);
    const spot = edge.addScaledVector(out, -LEDGE_INSET).add(new THREE.Vector3(0, CreatureMetrics.rootHeight, 0));
    return { matrix: lookAtMatrix(spot, spot.clone().add(out)), position: spot, out };
  }

  _beginFinale(now, withCreature) {
    const g = this.game;
    const env = this.env;
    this.phase = 'Finale';
    const startAt = now + LEAD + FINALE_PRE;
    const run = { startAt, creature: withCreature, done: false };
    this.finale = run;
    const pose = this._revealPose();
    const head = pose.position.clone().add(new THREE.Vector3(0, CreatureMetrics.eye.Biped, 0));
    const h = withCreature ? this.handle : null;
    if (h) {
      h.setHidden(true);
      h.setPose('Biped');
      h.teleport(pose.matrix);
      h.face(pose.position.clone().addScaledVector(pose.out, 6));
      if (g.parachute.jumped()) h.setTarget(true);
    }
    g.seq.play(h ? FINALE.Id : FINALE.SkyId, startAt, { [ROOF_ARGS.Head]: head, [ROOF_ARGS.Ledge]: pose.position });
    this.schedule.at(startAt + FINALE.Flash1, 'flash1', () => env.lightning(FINALE.FlashIntensity, 2));
    this.schedule.at(startAt + FINALE.Flash2, 'flash2', () => env.lightning(FINALE.FlashIntensity, 2));
    if (h) {
      this.schedule.at(startAt + FINALE.Reveal - FINALE.RevealLead, 'reveal', () => {
        if (this.handle) this.handle.setHidden(false);
      });
      this.schedule.at(startAt + FINALE.Hide - FINALE.HideLead, 'vanish', () => {
        if (this.handle) {
          this.handle.setHidden(true);
          this.handle.setTarget(false);
        }
      });
    }
    this.schedule.at(startAt + FINALE.Land, 'land', () => this._land(run));
  }

  _stepFinaleWait(now) {
    if (this._take()) this._beginFinale(now, true);
    else if (now >= this.acquireUntil) this._beginFinale(now, false);
  }

  _land(run) {
    const g = this.game;
    const p = g.parachute;
    if ((p.state === 'Canopy' || p.state === 'Freefall') && p.deployedAt !== null && p.deployedAt <= run.startAt + FINALE.FadeStart) {
      p.forceLand();
    }
    run.done = true;
    this.phase = 'Done';
    if (p.state === 'Landed') {
      if (this.landedAt === null) this.landedAt = this.env.now();
      this._escape();
      p.releaseHold();
      return;
    }
    if (ON_ROOF.has(p.state) && this.handle && g.playing()) {
      this._letGo('Patrol');
      g.creature.alert(this.env.rootPosition(new THREE.Vector3()), 'High');
    }
  }

  _escape() {
    if (this.escaped) return;
    this.escaped = true;
    this.game.match.markEscaped();
  }

  _noteLanding(now) {
    const g = this.game;
    const p = g.parachute;
    if (p.state !== 'Landed' || this.landedAt !== null) return;
    this.landedAt = now;
    this._escape();
    const run = this.finale;
    if (run && run.done && !this.touchdown) {
      this.touchdown = true;
      const startAt = now + LEAD;
      g.seq.play(FINALE.TouchdownId, startAt, { [ROOF_ARGS.Subject]: true });
      this.schedule.at(startAt + FINALE.TouchdownRelease, 'touchdown', () => p.releaseHold());
    }
  }

  // ---------------------------------------------------------------------------------------------------- lifecycle

  levelActivated(level) {
    if (level !== LEVEL) return;
    this._resetState();
    this.active = true;
    this.phase = 'Arrival';
    this.activatedAt = this.env.now();
    if (this._take()) this.handle.setHidden(true);
  }

  levelDeactivated(level) {
    if (level !== LEVEL) return;
    this.active = false;
    this.phase = 'Idle';
    this.schedule.clear();
    this._letGo('Dormant');
    this._setScale(1);
  }

  beginRun() {
    this.schedule.clear();
    this._letGo(null);
    this._resetState();
  }

  endRun() {
    this.schedule.clear();
    this._letGo('Dormant');
    this._setScale(1);
    this._resetState();
  }

  tick(dt, now) {
    this.schedule.run(now);
    if (!this.active || now < this.nextTickAt || this.game.phase !== 'InRun') return;
    this.nextTickAt = now + TICK;
    this._noteLanding(now);
    if (this.phase === 'Arrival') this._stepArrival(now);
    else if (this.phase === 'Chase') this._stepChase();
    else if (this.phase === 'FinaleWait') {
      this._stepFinaleWait(now);
      return;
    }
    if (this.phase === 'Arrival' || this.phase === 'Smash' || this.phase === 'Chase') this._checkFinale(now);
  }

  // ---------------------------------------------------------------------------------------------------- dev

  /** Dev `roof smash`: the door sequence now. */
  devSmash() {
    if (!this.active || this.phase !== 'Arrival') return false;
    this._startSmash(this.env.now());
    return true;
  }

  /**
   * Dev: the roof's moment. A pack on and off the gap: the cord is pulled once falling, and the finale plays over the
   * canopy (the lightning, the Creature on the ledge, the fade).
   */
  devFinale() {
    const g = this.game;
    if (!this.active) return false;
    this.devPull = true;
    return g.parachute.devJump();
  }

  /** The dev finale's cord: pulled the frame the jumper is falling. */
  frame() {
    if (this.devPull && this.game.parachute.state === 'Freefall') {
      this.devPull = false;
      this.game.parachute.pull();
    }
  }
}

const _a = new THREE.Vector3();
const _b = new THREE.Vector3();
