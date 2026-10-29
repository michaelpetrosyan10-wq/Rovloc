// level0.js: the basement's ambience beats (Level0_BasementController). No Creature down here; the bear traps are
// traps.js. While the player is on Level 0 a seeded director plays a scare every 25-50 s, never the same kind twice
// in a row, from a point 25-45 studs (horizontally) from the player that they cannot see:
//   PipeBang       a bang in the overhead pipes,          BoilerSurge  a boiler roaring, the lit bulbs near it stuttering,
//   CeilingDrag    something dragged away across the ceiling void,   ChildVoice  a whisper or a giggle in the dark,
//   FallingObject  something clattering to the floor (the FallingObject noise where it lands).
// A beat due within 8 s of a TrapSnap waits until 8 s have passed; when nothing can be placed it retries in 4 s.
// Candidate points: a 10-stud lattice over every room but the airlock, under the ceiling, at child height and just
// above the floor, plus the boilers' glow fixtures (all from the export's rooms and lights).

import * as THREE from 'three';
import * as Scenes from '../scenes.js';
import { Schedule, horizontalDistance, seededRandom } from '../util.js';

const LEVEL = 'Level0_Basement';
const INTERVAL_MIN = 25;
const INTERVAL_MAX = 50;
const BAND_MIN = 25;
const BAND_MAX = 45;
const TRAP_GAP = 8;
const RETRY = 4;
const SURGE_RADIUS = 34;
const GRID = 10;
const INSET = 3;
const CEILING_DROP = 1.2;
const FLOOR_LIFT = 0.4;
const VOICE_HEIGHT = 3.2;
const LEAD = 0.2;
const LIGHT_ARGS = [Scenes.Args.Light1, Scenes.Args.Light2, Scenes.Args.Light3, Scenes.Args.Light4];

export class Level0 {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Level0';
    this.game = game;
    this.active = false;
    this.nextAt = Infinity;
    this.previous = null;
    this.lastTrapAt = -Infinity;
    this.played = 0;
    this.schedule = new Schedule();
    this.random = seededRandom(1, 'L0Beats');
    this.candidates = this._candidates();
    game.env.onNoise((e) => {
      if (e.kind === 'TrapSnap') this.lastTrapAt = Math.max(this.lastTrapAt, game.env.now());
    });
  }

  _candidates() {
    const { meta } = this.game.world;
    const elevation = meta.levels[LEVEL].elevation;
    const out = { ceiling: [], floor: [], voice: [], boilers: [] };
    for (const room of meta.rooms) {
      if (room.level !== LEVEL || room.kind === 'Airlock') continue;
      const r = room.rect;
      const height = room.height ?? meta.levels[LEVEL].height;
      const nx = Math.max(1, Math.floor((r.w - 2 * INSET) / GRID) + 1);
      const nz = Math.max(1, Math.floor((r.d - 2 * INSET) / GRID) + 1);
      for (let i = 0; i < nx; i++) {
        for (let j = 0; j < nz; j++) {
          const x = nx === 1 ? r.x + r.w / 2 : r.x + INSET + ((r.w - 2 * INSET) * i) / (nx - 1);
          const z = nz === 1 ? r.z + r.d / 2 : r.z + INSET + ((r.d - 2 * INSET) * j) / (nz - 1);
          out.ceiling.push(new THREE.Vector3(x, elevation + height - CEILING_DROP, z));
          out.voice.push(new THREE.Vector3(x, elevation + VOICE_HEIGHT, z));
          out.floor.push(new THREE.Vector3(x, elevation + FLOOR_LIFT, z));
        }
      }
    }
    for (const l of meta.lights) {
      if (l.level === LEVEL && l.kind === 'BoilerGlow') out.boilers.push(new THREE.Vector3(...l.pos));
    }
    return out;
  }

  _pool(kind) {
    if (kind === 'BoilerSurge') return this.candidates.boilers;
    if (kind === 'ChildVoice') return this.candidates.voice;
    if (kind === 'FallingObject') return this.candidates.floor;
    return this.candidates.ceiling;
  }

  /** Level0.pickBeat */
  _pick(allowed) {
    const pool = allowed.filter((k) => k !== this.previous);
    return pool.length ? pool[this.random.integer(0, pool.length - 1)] : null;
  }

  /** Level0.place */
  _place(kind, listener) {
    const eligible = [];
    for (const point of this._pool(kind)) {
      const d = horizontalDistance(point, listener);
      if (d >= BAND_MIN && d <= BAND_MAX && !this.game.seen(point)) eligible.push(point);
    }
    if (!eligible.length) return null;
    const from = eligible[this.random.integer(0, eligible.length - 1)];
    if (kind !== 'CeilingDrag') return { from, to: null };
    const away = new THREE.Vector3(from.x - listener.x, 0, from.z - listener.z);
    if (away.lengthSq() < 1e-6) away.set(1, 0, 0);
    away.normalize();
    return { from, to: from.clone().addScaledVector(away, Scenes.CeilingDragDistance) };
  }

  /** Level0.surgeLights: working fixtures within SURGE_RADIUS, nearest first, at most four. */
  _surgeLights(point) {
    const near = [];
    for (const l of this.game.world.meta.lights) {
      if (l.level !== LEVEL || l.broken || !(l.brightness > 0) || l.kind === 'Moonlight') continue;
      const p = new THREE.Vector3(...(l.fixtureCFrame ? l.fixtureCFrame.slice(0, 3) : l.pos));
      const d = p.distanceTo(point);
      if (d <= SURGE_RADIUS && !near.some((n) => n.id === l.id)) near.push({ id: l.id, d });
    }
    near.sort((a, b) => a.d - b.d || (a.id < b.id ? -1 : 1));
    return near.slice(0, Scenes.SurgeLights).map((n) => n.id);
  }

  _play(kind, placement, now) {
    const game = this.game;
    const startAt = now + LEAD;
    const ids = Scenes.BeatIds[kind];
    const id = ids[this.random.integer(0, ids.length - 1)];
    const args = {};
    if (kind === 'CeilingDrag') {
      args[Scenes.Args.From] = placement.from;
      args[Scenes.Args.To] = placement.to || placement.from;
    } else args[Scenes.Args.At] = placement.from;
    if (kind === 'BoilerSurge') this._surgeLights(placement.from).forEach((lightId, i) => (args[LIGHT_ARGS[i]] = lightId));
    game.seq.play(id, startAt, args);
    if (kind === 'FallingObject') {
      const at = placement.from;
      this.schedule.at(startAt + Scenes.FallImpact, 'fall', () => game.noise(at, 'FallingObject'));
    }
    this.previous = kind;
    this.played++;
  }

  /** Plays one beat now around the player (also the dev `beat` command); false when none could be placed. */
  tryBeat(now, only) {
    if (!this.game.playing()) return false;
    const listener = this.game.env.rootPosition(_listener);
    let remaining = only ? [only] : Scenes.BeatKinds.slice();
    while (remaining.length) {
      const kind = only || this._pick(remaining);
      if (!kind) return false;
      const placement = this._place(kind, listener);
      if (placement) {
        this._play(kind, placement, now);
        return true;
      }
      remaining = remaining.filter((k) => k !== kind);
      if (only) return false;
    }
    return false;
  }

  levelActivated(level) {
    if (level !== LEVEL) return;
    this.active = true;
    this.nextAt = this.game.env.now() + this.random.number(INTERVAL_MIN, INTERVAL_MAX);
  }

  levelDeactivated(level) {
    if (level !== LEVEL) return;
    this.active = false;
    this.nextAt = Infinity;
    this.schedule.clear();
  }

  beginRun(run) {
    this.random = seededRandom(run.seed, 'L0Beats');
    this.previous = null;
    this.lastTrapAt = -Infinity;
    this.played = 0;
  }

  endRun() {
    this.active = false;
    this.nextAt = Infinity;
    this.schedule.clear();
  }

  tick(dt, now) {
    this.schedule.run(now);
    if (!this.active || now < this.nextAt) return;
    const due = Math.max(this.nextAt, this.lastTrapAt + TRAP_GAP);
    if (now < due) {
      this.nextAt = due;
      return;
    }
    if (!this.game.playing()) {
      this.nextAt = now + RETRY;
      return;
    }
    this.nextAt = this.tryBeat(now, null) ? now + this.random.number(INTERVAL_MIN, INTERVAL_MAX) : now + RETRY;
  }
}

const _listener = new THREE.Vector3();
