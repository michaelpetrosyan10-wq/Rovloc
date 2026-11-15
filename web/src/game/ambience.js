// ambience.js: the building at night (DreadConfig.Ambience, meta.dreadConfig.Ambience): on the floors it names, a bed
// of the building's own sound under the floor's drone, and now and then one distant event (a door slamming far off,
// steel groaning in the walls, a dead PA speaker crackling, a locker rattling once, a thump on the floor above, a
// phone buzzing somewhere), each from a point far from the listener and out of their sight.
//
//   * Never closer together than MinGap; the next one Gap seconds on (uniform, the run's seeded stream).
//   * While the Creature is within DuckRadius of the listener, the gap stretches by DuckGapScale, an event plays at
//     DuckVolume and the bed dips to DuckBed; while it chases the listener nothing plays at all: its own sounds are
//     never masked (I1).
//   * The building at night belongs to the school's floors in play: while a cutscene plays (cinematics.active()) the
//     building holds still under its lines and sounds (no event, the bed at DuckBed) and nothing plays for MinGap
//     after it; on the Back Lot (the opening by day and at night, the prologue: a set, never a level) there is no bed
//     and no director at all.
//   * Only sound: no event is a NoiseKind, nothing here emits a noise pulse or touches anything the Creature reads
//     (I1, I3). Nothing reads the graphics tier, so every tier hears the same events at the same times.
// The recipes are SynthPresets' own, carried in meta.dreadConfig.Ambience.Presets and registered at start-up.
// The decisions are the AmbienceDirector's (pure: the time, the listener, the Creature's distance and a point picker
// in, the events out), which web/tools/ambience-test.mjs replays; the Ambience system feeds it the game's state and
// plays what it decides.

import * as THREE from 'three';
import { Presets } from '../engine/audio/presets.js';
import { seededRandom } from './util.js';

/**
 * The pure scheduler.
 * @param {any} config meta.dreadConfig.Ambience
 * @param {string} level the floor
 * @param {number} seed the run's seed
 */
export class AmbienceDirector {
  constructor(config, level, seed) {
    this.config = config;
    this.level = level;
    this.random = seededRandom(seed, `ambience:${level}`);
    /** the weighted events of this floor */
    this.events = (config.Events || []).filter((e) => (e[level] || 0) > 0).map((e) => ({ preset: e.preset, weight: e[level] }));
    this.total = this.events.reduce((sum, e) => sum + e.weight, 0);
    this.lastAt = -Infinity;
    this.nextAt = null;
    /** every event decided: {at, preset, position, volume, ducked} */
    this.log = [];
  }

  /** Whether this floor has a bed and events. */
  active() {
    return !!this.config.Beds && !!this.config.Beds[this.level];
  }

  /**
   * The bed's volume for a Creature `distance` studs away (chasing: the listener is being chased; held: a cutscene
   * plays).
   */
  bedVolume(distance, chasing, held = false) {
    const near = held || chasing || distance <= this.config.DuckRadius;
    return this.config.BedVolume * (near ? this.config.DuckBed : 1);
  }

  _gap(near) {
    const [a, b] = this.config.Gap;
    return Math.max(this.config.MinGap, this.random.number(a, b) * (near ? this.config.DuckGapScale : 1));
  }

  _pick() {
    let roll = this.random.number(0, this.total);
    for (const e of this.events) {
      roll -= e.weight;
      if (roll <= 0) return e.preset;
    }
    return this.events[this.events.length - 1].preset;
  }

  /**
   * One step at time `now`. `distance`: the Creature's distance from the listener (Infinity when it is not on this
   * floor); `chasing`: it chases the listener; `place(preset)` -> a world position for the event or null (none out of
   * sight); `held`: a cutscene plays (nothing now, and nothing for MinGap after it). Returns the event decided now, or
   * null.
   */
  step(now, distance, chasing, place, held = false) {
    if (!this.total) return null;
    if (held) {
      this.nextAt = Math.max(this.nextAt ?? -Infinity, now + this.config.MinGap);
      return null;
    }
    const near = chasing || distance <= this.config.DuckRadius;
    if (this.nextAt === null) this.nextAt = now + this._gap(near);
    if (now < this.nextAt) return null;
    if (chasing) {
      // its own sounds carry the chase: the building holds still until it is over
      this.nextAt = now + this.config.MinGap;
      return null;
    }
    const preset = this._pick();
    const position = place(preset);
    this.nextAt = now + this._gap(near);
    if (!position) return null;
    if (now - this.lastAt < this.config.MinGap) return null;
    this.lastAt = now;
    const event = { at: now, preset, position, volume: this.config.EventVolume * (near ? this.config.DuckVolume : 1), ducked: near };
    this.log.push(event);
    return event;
  }
}

/**
 * A point for `preset` round `listener` on `level`: a thump comes from straight over the listener's floor; anything
 * else from a tunnel centreline point (meta.teleportPoints) Distance studs away with no clear line from the listener.
 * @param {any} config meta.dreadConfig.Ambience
 * @param {Array<{pos: number[]}>} points
 * @param {THREE.Vector3} listener the listener's eye
 * @param {number} floorY the listener's floor
 * @param {any} random the director's stream
 * @param {(a: THREE.Vector3, b: THREE.Vector3) => boolean} lineClear
 */
export function placeEvent(preset, config, points, listener, floorY, random, lineClear) {
  if (preset === 'DreadThumpAbove') {
    const a = random.number(0, Math.PI * 2);
    const r = random.number(6, 18);
    return new THREE.Vector3(listener.x + Math.cos(a) * r, floorY + config.Above + 4, listener.z + Math.sin(a) * r);
  }
  const [near, far] = config.Distance;
  const candidates = points.filter((p) => {
    const dx = p.pos[0] - listener.x;
    const dz = p.pos[2] - listener.z;
    const d = Math.hypot(dx, dz);
    return d >= near && d <= far && Math.abs(p.pos[1] - floorY) < 6;
  });
  for (let i = 0; i < config.Tries && candidates.length; i++) {
    const p = candidates[random.integer(0, candidates.length - 1)];
    const at = new THREE.Vector3(p.pos[0], p.pos[1] + 3, p.pos[2]);
    if (!lineClear(listener, at)) return at;
  }
  return null;
}

/** The game system: feeds the director and plays what it decides. */
export class Ambience {
  /** @param {import('./game.js').Game} game */
  constructor(game) {
    this.name = 'Ambience';
    this.game = game;
    this.env = game.env;
    const meta = game.world.meta;
    this.config = meta.dreadConfig ? meta.dreadConfig.Ambience : null;
    this.points = meta.teleportPoints || {};
    this.director = null;
    this.bed = null;
    for (const [name, preset] of Object.entries((this.config && this.config.Presets) || {})) if (!Presets[name]) Presets[name] = preset;
  }

  levelActivated(level) {
    this._stop();
    if (!this.config || !this.config.Beds || !this.config.Beds[level]) return;
    const run = this.game.run;
    this.director = new AmbienceDirector(this.config, level, run ? run.seed : 1);
    this.bed = this.env.play(this.config.Beds[level], { loop: true, fadeIn: 4, volume: this.config.BedVolume });
  }

  levelDeactivated() {
    this._stop();
  }

  endRun() {
    this._stop();
  }

  tick() {
    const director = this.director;
    if (!director || !this.game.playing()) return;
    const game = this.game;
    const eye = game.eye(_eye);
    const creature = game.creature;
    const snap = creature.snapshot ? creature.snapshot() : null;
    const onFloor = snap && snap.levelId === director.level && !creature.isHidden();
    const distance = onFloor && creature.position(_creature) ? _creature.distanceTo(eye) : Infinity;
    const chasing = !!creature.chasingPlayer();
    const held = this.held();
    if (this.bed) this.bed.setVolume(director.bedVolume(distance, chasing, held), 1.5);
    const floorY = game.feet(_feet).y;
    const points = this.points[director.level] || [];
    const event = director.step(this.env.now(), distance, chasing, (preset) =>
      placeEvent(preset, this.config, points, eye, floorY, director.random, (a, b) => this.env.lineClear(a, b, { ignoreEntities: true })),
    held);
    if (event) this.env.play(event.preset, { position: event.position, volume: event.volume });
  }

  /** Whether the building holds still: a cutscene plays (its lines and sounds are never stepped on). */
  held() {
    const cinematics = this.game.cinematics;
    return !!(cinematics && cinematics.active());
  }

  _stop() {
    if (this.bed) this.bed.stop(2);
    this.bed = null;
    this.director = null;
  }
}

const _eye = new THREE.Vector3();
const _feet = new THREE.Vector3();
const _creature = new THREE.Vector3();
