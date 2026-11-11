// level3.js: the roof (Level3_RoofController). The packs, the jump and the canopy are parachute.js; this runs the
// level around them.
//
// Arrival. The run arrives in one of three stair housings: the route's Stairwell_2_3 candidate (L3_RoofAccess,
// L3_RoofAccessNorth or L3_RoofAccessSouth, each with its own roof door RoofStairDoor / RoofStairDoorNorth /
// RoofStairDoorSouth, the tower below it and the Creature's spot behind it, L3_CreatureSpawn / _North / _South); the
// door smash plays at that one (geometry, per run). On activation the Creature is taken (acquireScripted; asked for
// again at the tick rate while busy, only taken while nobody can see it) and kept hidden in that housing at its
// CreatureSpawn. Its roof door (Closed) swings open OPEN_DELAY after the first playing participant reaches the housing.
//
// The door smash (Scenes.RoofDoor, from startAt S): the Creature waits behind the door for its grace once the first
// playing participant has stepped out of the housing (SpawnTuning.Grace: 20 s Standard, 12 s Nightmare), ended early
// by a High / Critical noise of a participant's on the roof after that, or ARRIVAL_TIMEOUT after activation whoever is
// where (smashDue): "L3_DoorSmash". The wind slams the door shut so it lands at Slam (skipped while anyone is inside or
// within DOOR_CLEAR of the doorway: they are never shut in with it), the hidden Creature is moved in right behind it
// (Stage), three blows, it is shown behind the door at Reveal (only while nobody can see that spot), the door Smashed at
// Smash (the DoorSmash action), its cry, and at Release it is let go: into WallChase when someone can be seen from
// behind the doorway, else into Patrol (its senses find them, it is never told where they are); everyone on the roof
// is told to run (Hud.RoofRun).
//
// The ledge staging. Once someone has jumped and no Alive participant is left on the roof to jump (a Downed one does
// not hold it), LEDGE_DELAY after the last one left (ledgeReady), the Creature is taken back (a busy one is asked for
// again at the tick rate), put on the ledge the squad jumped from (revealPose: on the edge, facing out over them),
// shown, and turned to stare at the jumper nearest under it (stareTarget): the look-back camera of everyone under a
// canopy finds it there. It stays there, held, until the roof is done.
//
// The touchdown. A jumper is done with the roof the moment they are down below (or set down by parachute.forceLand),
// and their landing hold ends at once (parachute.releaseHold). Alone the roof is done then and the run moves on to the
// next stage; in a squad once every participant still playing has landed (a Downed or dead one does not hold it).
// Nobody jumps without a pack: parachute.js buckles a spare one onto anyone who leaves the roof without one. Anyone
// who stays on the roof keeps playing: the Creature hunts them until they jump, bleed out or are caught. Co-op: this
// runs on the host; a client's page tells the host its own player's landing (coop/run.js), and a teammate's jump is
// read from their root leaving the roof (offRoof, the rule parachute.js judges a jump by).
//
// Deactivate and endRun cancel everything scheduled and let a held Creature go (Dormant).

import * as THREE from 'three';
import { CreatureMetrics } from '../creatureApi.js';
import { GameConfig, previousLevel } from '../config.js';
import * as Scenes from '../scenes.js';
import { Schedule, horizontalDistance, lookAtMatrix } from '../util.js';
import { edgePoint, offRoof, outward } from '../mechanics/parachute.js';
import { SpawnTuning } from '../objectives/config.js';

const LEVEL = 'Level3_Roof';
const TOKEN = 'L3_Roof';
const DOOR_ID = 'RoofStairDoor';
const HOUSING_ROOM = 'L3_RoofAccess';
const ROOF_SIDE_ROOM = 'L3_Roof_East';
const TICK = 1 / GameConfig.ServerTickHz;
const LEAD = GameConfig.OneShotLead;
const OPEN_DELAY = 1.2;
const OPEN_SECONDS = 1.4;
const DOOR_CLEAR = 9;
const ARRIVAL_TIMEOUT = 75;
const BEHIND_DOOR = 3;
const LEDGE_DELAY = 2;
const LEDGE_INSET = 1.2;
const CHEST_HEIGHT = 1.2;
const DOOR = Scenes.RoofDoor;
const ROOF_ARGS = Scenes.RoofArgs;
const ON_ROOF = new Set(['None', 'Packed']);
const LIVE_PHASES = new Set(['Arrival', 'Smash', 'Chase']);

const inRect = (r, p) => p.x >= r.minX && p.x <= r.maxX && p.z >= r.minZ && p.z <= r.maxZ;

/**
 * The roof's door geometry from the export's roof layout for a run arriving by `arrival` (Level3.geometry: a
 * Stairwell_2_3 route candidate, {toRoom, tower, creatureSpawn}; null: the middle one).
 */
export function geometry(meta, arrival) {
  const layout = meta.layouts[LEVEL];
  const origin = new THREE.Vector3(...meta.levels[LEVEL].origin);
  const rooms = new Map(layout.rooms.map((r) => [r.id, r]));
  const housingId = (arrival && (arrival.entryRoomOfNextLevel || arrival.toRoom)) || HOUSING_ROOM;
  const housing = rooms.get(housingId);
  const side = rooms.get(ROOF_SIDE_ROOM);
  const door = layout.doors.find((d) => d.kind === 'RoofDoor' && d.scriptedId && (d.rooms || []).includes(housingId)) ||
    layout.doors.find((d) => d.scriptedId === DOOR_ID);
  if (!housing || !side || !door) throw new Error(`the roof has no roof door geometry for ${housingId}`);
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
  const stair = arrival || meta.stairwells.find((s) => s.to === LEVEL && s.toRoom === housingId) ||
    meta.stairwells.find((s) => s.to === LEVEL);
  const tower = meta.worldConfig.Towers[stair && stair.tower ? stair.tower : 'East'];
  const school = meta.worldConfig.SchoolOrigin || [0, 0, 0];
  const below = previousLevel(LEVEL);
  const spawnId = (arrival && arrival.creatureSpawn) ||
    ((meta.routes && meta.routes[below]) || []).find((c) => c.toRoom === housingId)?.creatureSpawn;
  const spawn = spawnId ? meta.anchors.find((x) => x.id === spawnId) : null;
  const wait = spawn ? new THREE.Vector3(spawn.cframe[0], spawn.cframe[1], spawn.cframe[2]) : spot.clone();
  return {
    origin,
    housingId,
    doorId: door.scriptedId,
    // the Creature's hidden wait in the housing (its CreatureSpawn), facing the door
    wait: lookAtMatrix(wait, new THREE.Vector3(doorway.x, wait.y, doorway.z)),
    housing: { minX: origin.x + a.x, maxX: origin.x + a.x + a.w, minZ: origin.z + a.z, maxZ: origin.z + a.z + a.d },
    tower: { minX: school[0] + tower.minX, maxX: school[0] + tower.maxX, minZ: school[2] + tower.minZ, maxZ: school[2] + tower.maxZ },
    doorway,
    out,
    behind: lookAtMatrix(spot, spot.clone().add(out)),
    behindPosition: spot,
    cue: doorway.clone().add(out).add(new THREE.Vector3(0, 4, 0)),
  };
}

/** Level3.smashDue */
export function smashDue(input) {
  if (input.smashNow) return true;
  if (input.firstOutAt !== null && input.now >= input.firstOutAt + input.grace) return true;
  return input.now >= input.activatedAt + ARRIVAL_TIMEOUT;
}

/** Level3.ledgeReady: someone has jumped, no Alive participant is left on the roof, LEDGE_DELAY after the last left. */
export function ledgeReady(input) {
  if (input.jumped === 0 || input.roofAlive > 0) return false;
  return input.lastLeftAt === null || input.now >= input.lastLeftAt + LEDGE_DELAY;
}

/**
 * Level3.revealPose: nearest where the squad left the roof (the average of `leftFrom`; the jump gap when nobody did),
 * LEDGE_INSET in from the edge, facing out over them. `roof` is parachute.js's roof geometry.
 */
export function revealPose(roof, leftFrom) {
  const from = leftFrom.length
    ? leftFrom.reduce((sum, p) => sum.add(p), new THREE.Vector3()).divideScalar(leftFrom.length)
    : new THREE.Vector3(roof.gap.minX, roof.deckY, (roof.gap.minZ + roof.gap.maxZ) / 2);
  const out = outward(roof, from);
  const spot = edgePoint(roof, from).addScaledVector(out, -LEDGE_INSET).add(new THREE.Vector3(0, CreatureMetrics.rootHeight, 0));
  return { matrix: lookAtMatrix(spot, spot.clone().add(out)), position: spot, out };
}

/** Level3.stareTarget: the jumper whose root is nearest the ledge horizontally, or null. */
export function stareTarget(jumpers, ledge) {
  let best = null;
  let bestDistance = Infinity;
  for (const j of jumpers) {
    const d = horizontalDistance(j.position, ledge);
    if (d < bestDistance) {
      best = j.who;
      bestDistance = d;
    }
  }
  return best;
}

export class Level3 {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Level3';
    this.game = game;
    this.env = game.env;
    this.geo = geometry(game.world.meta, game.world.route(previousLevel(LEVEL)));
    this.schedule = new Schedule();
    this.handle = null;
    /** @type {Map<string, {leftFrom: THREE.Vector3, leftAt: number}>} teammates seen off the roof (co-op host) */
    this.remoteLeft = new Map();
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
    this.ledgeAt = null;
    this.nextTickAt = -Infinity;
    this.escaped = false;
    this.devPull = false;
    this.remoteLeft.clear();
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
    h.setTarget(null);
    if (state) h.release(state);
  }

  _seen(root) {
    return this.game.seenByAnyone(_a.copy(root).add(_b.set(0, CreatureMetrics.eye.Biped, 0))) ||
      this.game.seenByAnyone(_a.copy(root).add(_b.set(0, CHEST_HEIGHT, 0)));
  }

  _seenCreature() {
    const p = this.game.creature.position(new THREE.Vector3());
    return !!p && !this.game.creature.isHidden() && this._seen(p);
  }

  _door() {
    return this.game.doors.find(LEVEL, this.geo.doorId);
  }

  /** The run's roof door (the arrival housing's RoofStairDoor*). */
  roofDoor() {
    return this._door();
  }

  /** The run's arrival housing (room id). */
  housingRoom() {
    return this.geo.housingId;
  }

  /** Takes the Creature and keeps it hidden at its spot in the arrival housing. */
  _takeHidden() {
    const h = this._take();
    if (!h) return null;
    h.setHidden(true);
    h.setPose('Biped');
    h.teleport(this.geo.wait);
    return h;
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
    // never slammed on anyone: the whole squad counts (co-op, on the host), not just this page's player
    const blocked = g.subjects().some((s) => this._inside(s.root) || horizontalDistance(s.root, this.geo.doorway) < DOOR_CLEAR);
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
      // it runs down someone it can see from the doorway; anyone out of sight is left to its senses (it patrols)
      const sees = g.playing() && this._seen(this.geo.behindPosition);
      this._letGo(sees ? 'WallChase' : 'Patrol');
      if (ON_ROOF.has(g.parachute.state)) g.notify('Hud.RoofRun');
    });
  }

  _stepArrival(now) {
    const g = this.game;
    if (!this.handle && !this._seenCreature()) this._takeHidden();
    const roots = g.subjects().map((s) => s.root);
    if (this.arrivedAt === null && roots.some((p) => inRect(this.geo.housing, p))) this.arrivedAt = now;
    if (!this.doorOpened && this.arrivedAt !== null && now >= this.arrivedAt + OPEN_DELAY) {
      this.doorOpened = true;
      const door = this._door();
      if (door && door.state === 'Closed') g.doors.setState(door, 'Open', OPEN_SECONDS);
    }
    if (this.firstOutAt === null && roots.some((p) => !this._inside(p))) this.firstOutAt = now;
    const difficulty = g.run ? g.run.difficulty : 'Standard';
    const grace = SpawnTuning.Grace[difficulty] ?? SpawnTuning.Grace.Standard;
    if (smashDue({ smashNow: this.smashNow, firstOutAt: this.firstOutAt, grace, activatedAt: this.activatedAt, now })) {
      this._startSmash(now);
    }
  }

  /** A High / Critical noise of a participant's on the roof, once someone has stepped out, ends the wait behind the door. */
  _noise(e) {
    if (!this.active || this.phase !== 'Arrival' || this.firstOutAt === null || e.source !== 'player') return;
    if (e.level === LEVEL && (e.priority === 'High' || e.priority === 'Critical')) this.smashNow = true;
  }

  // ---------------------------------------------------------------------------------------------------- the ledge

  /**
   * Every playing participant's jump: [{who, root, alive, jumped, leftFrom, leftAt}] (who: true for this page's
   * player, else the member id). This page's player from parachute.js; a teammate (co-op host) is off the roof from
   * the first tick their root is (offRoof).
   */
  _jumps(now) {
    const g = this.game;
    const p = g.parachute;
    const out = [];
    for (const s of g.subjects()) {
      if (s.local) {
        out.push({ who: true, root: s.root, alive: g.life.state === 'Alive', jumped: !ON_ROOF.has(p.state),
          leftFrom: p.leftFrom, leftAt: p.leftAt });
        continue;
      }
      let left = this.remoteLeft.get(s.id);
      if (!left && offRoof(p.geo, s.root)) {
        left = { leftFrom: s.root.clone(), leftAt: now };
        this.remoteLeft.set(s.id, left);
      }
      out.push({ who: s.id, root: s.root, alive: s.life === 'Alive', jumped: !!left, leftFrom: left ? left.leftFrom : null,
        leftAt: left ? left.leftAt : null });
    }
    return out;
  }

  _checkLedge(now) {
    const jumps = this._jumps(now);
    let jumped = 0;
    let roofAlive = 0;
    let lastLeftAt = null;
    for (const j of jumps) {
      if (j.jumped) {
        jumped++;
        if (j.leftAt !== null && (lastLeftAt === null || j.leftAt > lastLeftAt)) lastLeftAt = j.leftAt;
      } else if (j.alive) roofAlive++;
    }
    if (ledgeReady({ jumped, roofAlive, lastLeftAt, now })) this._stageLedge(now, jumps);
  }

  /** Puts the Creature on the ledge over the jumpers, shown, staring at the nearest. False while it cannot be taken. */
  _stageLedge(now, jumps) {
    const h = this._take();
    if (!h) return false;
    // a door sequence still running is called off: nobody is left up there to chase
    this.schedule.clear();
    this.phase = 'Ledge';
    this.ledgeAt = now;
    const off = jumps.filter((j) => j.jumped && j.leftFrom);
    const pose = revealPose(this.game.parachute.geo, off.map((j) => j.leftFrom));
    h.setPose('Biped');
    h.teleport(pose.matrix);
    h.face(pose.position.clone().addScaledVector(pose.out, 6));
    h.setHidden(false);
    const target = stareTarget(off.map((j) => ({ who: j.who, position: j.root })), pose.position);
    if (target !== null) h.setTarget(target === true ? true : this.game.coop.creatureNet.handleOf(target));
    return true;
  }

  // ---------------------------------------------------------------------------------------------------- escapes

  /**
   * The roof is done at the touchdown: alone this page's landing moves the run on (the next stage) and the landing
   * hold ends at once; in a squad (on the host) once every participant still playing is down below.
   */
  _noteLanding() {
    const g = this.game;
    const p = g.parachute;
    const coop = g.coop && g.coop.active ? g.coop : null;
    if (p.state === 'Landed' && !this.escaped) {
      this.escaped = true;
      p.releaseHold();
      g.stats.increment('FloorsCleared');
      if (coop) coop.runNet.localLanded();
      else {
        g.advance();
        return;
      }
    }
    if (coop && coop.runNet.squadLanded()) coop.runNet.stageDone(LEVEL);
  }

  // ---------------------------------------------------------------------------------------------------- lifecycle

  levelActivated(level) {
    if (level !== LEVEL) return;
    this._resetState();
    this.active = true;
    this.phase = 'Arrival';
    this.activatedAt = this.env.now();
    this._takeHidden();
  }

  levelDeactivated(level) {
    if (level !== LEVEL) return;
    this.active = false;
    this.phase = 'Idle';
    this.schedule.clear();
    this._letGo('Dormant');
  }

  beginRun(run) {
    this.schedule.clear();
    this._letGo(null);
    this._resetState();
    this.geo = geometry(this.game.world.meta, run && run.routes ? run.routes[previousLevel(LEVEL)] : null);
  }

  endRun() {
    this.schedule.clear();
    this._letGo('Dormant');
    this._resetState();
  }

  tick(dt, now) {
    this.schedule.run(now);
    if (!this.active || now < this.nextTickAt || this.game.phase !== 'InRun') return;
    this.nextTickAt = now + TICK;
    this._noteLanding();
    if (this.phase === 'Arrival') this._stepArrival(now);
    if (LIVE_PHASES.has(this.phase)) this._checkLedge(now);
  }

  // ---------------------------------------------------------------------------------------------------- dev

  /** Dev `roof smash`: the door sequence now (only while the squad is arriving). */
  devSmash() {
    if (!this.active || this.phase !== 'Arrival') return false;
    this._startSmash(this.env.now());
    return true;
  }

  /** Dev `roof ledge`: the Creature on the ledge now, once someone is off the roof and it is not there yet. */
  devLedge() {
    if (!this.active || !LIVE_PHASES.has(this.phase)) return false;
    const now = this.env.now();
    const jumps = this._jumps(now);
    return jumps.some((j) => j.jumped) && this._stageLedge(now, jumps);
  }

  /** Dev: the roof's moment. A pack on and a step off the gap, the cord pulled once falling (the ledge follows). */
  devJump() {
    if (!this.active) return false;
    this.devPull = true;
    return this.game.parachute.devJump();
  }

  /** The dev jump's cord: pulled the frame the jumper is falling. */
  frame() {
    if (this.devPull && this.game.parachute.state === 'Freefall') {
      this.devPull = false;
      this.game.parachute.pull();
    }
  }
}

const _a = new THREE.Vector3();
const _b = new THREE.Vector3();
