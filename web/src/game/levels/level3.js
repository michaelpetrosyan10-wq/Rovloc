// level3.js: the gymnasium and its locker rooms (Level3_GymnasiumController). The lockers are lockers.js; this tunes
// the Creature and plays the locker rooms' ambience.
//
// Stalking. At ServerTickHz, while the Creature is on Level 3 inside the gymnasium (L3_Gymnasium's footprint) in a
// hunting state (Patrol, InvestigateNoise, WallChase), its pace is scaled by GYM_SPEED_SCALE; anywhere else, and once
// the level is left, back to 1. Crossing the court is the danger.
// Pressure (Low alerts, heard like any noise, never at the player):
//   Sweep  once the player has spent SWEEP_DWELL s in a room with hideable lockers while the Creature patrols, every
//          SWEEP_MIN..SWEEP_MAX s it is drawn to the front of a seeded locker in that room (it peeks into the lockers).
//   Prowl  once it has patrolled outside the gym for PROWL_AWAY s with nobody on the court, every PROWL_MIN..PROWL_MAX s
//          it is called back to a seeded point on the court.
// Neither fires while a breath check runs or within CHECK_GAP s of one.
// Ambience beats every INTERVAL_MIN..INTERVAL_MAX s, never the same kind twice in a row, at a point the player cannot
// see within the kind's band of them: ShowerDrip (the showers), LockerBang (a locker door in the changing rooms, with a
// quiet FallingObject noise there), BallBounce (a basketball far off on the dark court). They wait while a breath check
// runs and retry RETRY s later when nothing can be placed.

import * as THREE from 'three';
import { GameConfig } from '../config.js';
import * as Scenes from '../scenes.js';
import { Schedule, horizontalDistance, seededRandom } from '../util.js';

const LEVEL = 'Level3_Gymnasium';
const GYM_ROOM = 'L3_Gymnasium';
const GYM_SPEED_SCALE = 1.3;
const SPEED_TICK = 1 / GameConfig.ServerTickHz;
const INTERVAL_MIN = 22;
const INTERVAL_MAX = 44;
const RETRY = 4;
const CHECK_GAP = 6;
const SWEEP_DWELL = 12;
const SWEEP_MIN = 45;
const SWEEP_MAX = 80;
const PROWL_AWAY = 30;
const PROWL_MIN = 50;
const PROWL_MAX = 85;
const PRESSURE_CHECK = 1;
const GRID = 8;
const INSET = 3;
const FLOOR_LIFT = 0.3;
const LATCH_HEIGHT = 3.6;
const LOCKER_FRONT = 2.2;
const COURT_GRID = 14;
const COURT_INSET = 8;
const LEAD = GameConfig.OneShotLead;
const BANDS = { ShowerDrip: { min: 14, max: 36 }, LockerBang: { min: 22, max: 48 }, BallBounce: { min: 34, max: 90 } };
const HUNTING = new Set(['Patrol', 'InvestigateNoise', 'WallChase']);

function grid(out, origin, rect, step, inset, y) {
  const nx = Math.max(1, Math.floor((rect.w - 2 * inset) / step) + 1);
  const nz = Math.max(1, Math.floor((rect.d - 2 * inset) / step) + 1);
  for (let i = 0; i < nx; i++) {
    for (let j = 0; j < nz; j++) {
      const x = nx === 1 ? rect.x + rect.w / 2 : rect.x + inset + ((rect.w - 2 * inset) * i) / (nx - 1);
      const z = nz === 1 ? rect.z + rect.d / 2 : rect.z + inset + ((rect.d - 2 * inset) * j) / (nz - 1);
      out.push(origin.clone().add(new THREE.Vector3(x, y, z)));
    }
  }
}

/** A point `out` studs in front of a layout anchor (its yaw), `y` above it. */
function anchorFront(origin, anchor, out, y) {
  const yaw = ((anchor.yaw || 0) * Math.PI) / 180;
  // CFrame.Angles(0, yaw, 0) * (0, y, -out)
  return origin.clone().add(new THREE.Vector3(anchor.pos[0] - Math.sin(yaw) * out, anchor.pos[1] + y, anchor.pos[2] - Math.cos(yaw) * out));
}

/** Where each beat kind may play, and the locker fronts the sweep draws the Creature to. */
export function candidates(meta) {
  const layout = meta.layouts[LEVEL];
  const origin = new THREE.Vector3(...meta.levels[LEVEL].origin);
  const out = { showers: [], lockers: [], court: [], fronts: [], gym: null };
  for (const room of layout.rooms) {
    if (room.kind === 'Restroom') grid(out.showers, origin, room.rect, GRID, INSET, FLOOR_LIFT);
    else if (room.id === GYM_ROOM) {
      grid(out.court, origin, room.rect, COURT_GRID, COURT_INSET, FLOOR_LIFT);
      out.gym = room.rect;
    }
  }
  for (const a of layout.anchors) {
    if (a.kind === 'Locker' || a.kind === 'SmashedLocker') out.lockers.push(anchorFront(origin, a, 0.3, LATCH_HEIGHT));
    if (a.kind === 'Locker') out.fronts.push({ room: a.room, front: anchorFront(origin, a, LOCKER_FRONT, 0) });
  }
  out.origin = origin;
  return out;
}

export function speedScaleFor(inGym, state) {
  return inGym && HUNTING.has(state) ? GYM_SPEED_SCALE : 1;
}

/** The hiding room the player has dwelt in long enough (earliest first). */
export function sweepRoom(since, now) {
  let best = null;
  let bestSince = Infinity;
  for (const [room, at] of since) {
    if (now - at >= SWEEP_DWELL && (at < bestSince || (at === bestSince && best !== null && room < best))) {
      best = room;
      bestSince = at;
    }
  }
  return best;
}

export class Level3 {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Level3';
    this.game = game;
    this.set = candidates(game.world.meta);
    this.lockerRooms = new Set(this.set.fronts.map((f) => f.room));
    this.schedule = new Schedule();
    this.random = seededRandom(1, 'L3Beats');
    this.pressure = seededRandom(1, 'L3Pressure');
    this.active = false;
    this.nextAt = Infinity;
    this.previous = null;
    this.played = 0;
    this.speedClock = -Infinity;
    this.applied = 1;
    this.pressureClock = -Infinity;
    this.lastCheckAt = -Infinity;
    this.nextSweepAt = Infinity;
    this.nextProwlAt = Infinity;
    this.awaySince = null;
    /** @type {Map<string, number>} */
    this.roomSince = new Map();
  }

  _inGym(p) {
    const r = this.set.gym;
    if (!r || !p) return false;
    const x = p.x - this.set.origin.x;
    const z = p.z - this.set.origin.z;
    return x >= r.x && x <= r.x + r.w && z >= r.z && z <= r.z + r.d;
  }

  _apply(scale) {
    if (Math.abs(scale - this.applied) < 1e-6) return;
    this.applied = scale;
    this.game.creature.setSpeedScale(scale);
  }

  _creature() {
    const snap = this.game.creature.snapshot();
    return snap && snap.running ? snap : null;
  }

  _pool(kind) {
    return kind === 'ShowerDrip' ? this.set.showers : kind === 'LockerBang' ? this.set.lockers : this.set.court;
  }

  _place(kind, listener) {
    const band = BANDS[kind];
    const eligible = this._pool(kind).filter((p) => {
      const d = horizontalDistance(p, listener);
      return d >= band.min && d <= band.max && !this.game.seen(p);
    });
    return eligible.length ? eligible[this.random.integer(0, eligible.length - 1)] : null;
  }

  _play(kind, at, now) {
    const startAt = now + LEAD;
    const ids = Scenes.GymBeatIds[kind];
    const id = ids[this.random.integer(0, ids.length - 1)];
    this.game.seq.play(id, startAt, { [Scenes.Args.At]: at });
    if (kind === 'LockerBang') this.schedule.at(startAt, 'bang', () => this.game.noise(at, 'FallingObject', { source: 'world' }));
    this.previous = kind;
    this.played++;
  }

  /** One beat now around the player (also the dev `gymbeat`); false when none could be placed. */
  tryBeat(now, only) {
    if (!this.game.playing()) return false;
    const root = this.game.env.rootPosition(new THREE.Vector3());
    let remaining = only ? [only] : Scenes.GymBeatKinds.slice();
    while (remaining.length) {
      const pool = remaining.filter((k) => k !== this.previous);
      const kind = only || (pool.length ? pool[this.random.integer(0, pool.length - 1)] : null);
      if (!kind) return false;
      const point = this._place(kind, root);
      if (point) {
        this._play(kind, point, now);
        return true;
      }
      remaining = remaining.filter((k) => k !== kind);
      if (only) return false;
    }
    return false;
  }

  _stepSpeed(now) {
    if (now - this.speedClock < SPEED_TICK) return;
    this.speedClock = now;
    const c = this._creature();
    const inGym = !!c && c.levelId === LEVEL && this._inGym(c.position);
    this._apply(speedScaleFor(inGym, c ? c.state : 'Dormant'));
  }

  _stepBeats(now, checking) {
    if (now < this.nextAt) return;
    if (checking || now - this.lastCheckAt < CHECK_GAP || !this.game.playing()) {
      this.nextAt = now + RETRY;
      return;
    }
    this.nextAt = this.tryBeat(now, null) ? now + this.random.number(INTERVAL_MIN, INTERVAL_MAX) : now + RETRY;
  }

  _stepPressure(now, checking) {
    if (now - this.pressureClock < PRESSURE_CHECK) return;
    this.pressureClock = now;
    const g = this.game;
    const present = new Set();
    let anyoneInGym = false;
    if (g.playing()) {
      const zone = g.zoneId();
      if (zone && this.lockerRooms.has(zone)) present.add(zone);
      anyoneInGym = this._inGym(g.env.rootPosition(new THREE.Vector3()));
    }
    for (const room of [...this.roomSince.keys()]) if (!present.has(room)) this.roomSince.delete(room);
    for (const room of present) if (!this.roomSince.has(room)) this.roomSince.set(room, now);
    const c = this._creature();
    const onLevel = !!c && c.levelId === LEVEL;
    const patrolling = onLevel && c.state === 'Patrol';
    const creatureInGym = onLevel && this._inGym(c.position);
    this.awaySince = patrolling && !creatureInGym ? (this.awaySince ?? now) : null;
    if (checking || now - this.lastCheckAt < CHECK_GAP || !patrolling) return;
    if (now >= this.nextSweepAt) {
      const room = sweepRoom(this.roomSince, now);
      const fronts = room ? this.set.fronts.filter((f) => f.room === room) : [];
      if (fronts.length) {
        g.creature.alert(fronts[this.pressure.integer(0, fronts.length - 1)].front, 'Low');
        this.nextSweepAt = now + this.pressure.number(SWEEP_MIN, SWEEP_MAX);
        return;
      }
    }
    if (now >= this.nextProwlAt && this.awaySince !== null && now - this.awaySince >= PROWL_AWAY && !anyoneInGym && this.set.court.length) {
      g.creature.alert(this.set.court[this.pressure.integer(0, this.set.court.length - 1)], 'Low');
      this.nextProwlAt = now + this.pressure.number(PROWL_MIN, PROWL_MAX);
      this.awaySince = null;
    }
  }

  levelActivated(level) {
    if (level !== LEVEL) return;
    this.active = true;
    const now = this.game.env.now();
    this.nextAt = now + this.random.number(INTERVAL_MIN, INTERVAL_MAX);
    this.nextSweepAt = now + this.pressure.number(SWEEP_MIN, SWEEP_MAX);
    this.nextProwlAt = now + this.pressure.number(PROWL_MIN, PROWL_MAX);
    this.awaySince = null;
    this.roomSince.clear();
  }

  levelDeactivated(level) {
    if (level !== LEVEL) return;
    this.active = false;
    this.nextAt = Infinity;
    this.schedule.clear();
    this._apply(1);
  }

  beginRun(run) {
    this.random = seededRandom(run.seed, 'L3Beats');
    this.pressure = seededRandom(run.seed, 'L3Pressure');
    this.previous = null;
    this.played = 0;
    this.applied = 1;
    this.lastCheckAt = -Infinity;
    this.roomSince.clear();
  }

  endRun() {
    this.active = false;
    this.nextAt = Infinity;
    this.schedule.clear();
    this.applied = 1;
  }

  tick(dt, now) {
    this.schedule.run(now);
    if (!this.active || this.game.phase !== 'InRun') return;
    const checking = this.game.lockers.isChecking();
    if (checking) this.lastCheckAt = now;
    this._stepSpeed(now);
    this._stepBeats(now, checking);
    this._stepPressure(now, checking);
  }
}
