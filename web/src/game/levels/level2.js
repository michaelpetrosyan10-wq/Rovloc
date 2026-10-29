// level2.js: the Science Hall's chemical flasks stay in play (Level2_ScienceHallController).
//
// Restock. While the player is on Level 2 there are always at least MINIMUM untaken world flasks: when there are
// fewer, one is set out (a seeded yaw) at a FlaskCandidate anchor on the lab counters that no other flask stands on,
// more than MIN_DISTANCE studs from the player and out of their sight, at most one every INTERVAL seconds (checked
// once a second). Nobody ever watches a flask appear.
// Hint. The first time in a run the player comes within HINT_RADIUS studs of an untaken flask, the Hud.FlaskStun
// toast, once.

import * as THREE from 'three';
import { GameConfig } from '../config.js';
import { cfMatrix, seededRandom } from '../util.js';

const LEVEL = 'Level2_ScienceHall';
const CANDIDATE_KIND = 'FlaskCandidate';
const MINIMUM = 2;
const INTERVAL = 45;
const MIN_DISTANCE = 30;
const HINT_RADIUS = 10;
const OCCUPIED_RADIUS = 1.5;
const RESTOCK_CHECK = 1;
const HINT_CHECK = 1 / GameConfig.ServerTickHz;
const SIGHT_LIFT = 0.4;

/** Whether a flask should be set out now (fewer than MINIMUM available and INTERVAL since the last one). */
export function restockDue(now, lastSpawnAt, available) {
  return available < MINIMUM && now - lastSpawnAt >= INTERVAL;
}

/**
 * A candidate (Matrix4) with no flask on it, more than MIN_DISTANCE from every root and unseen, drawn with `random`;
 * null when there is none.
 */
export function pickSpot(candidates, occupied, roots, visible, random) {
  const eligible = [];
  for (const m of candidates) {
    const point = new THREE.Vector3().setFromMatrixPosition(m);
    if (occupied.some((f) => f.distanceTo(point) <= OCCUPIED_RADIUS)) continue;
    if (roots.some((r) => r.distanceTo(point) <= MIN_DISTANCE)) continue;
    if (visible(point.add(new THREE.Vector3(0, SIGHT_LIFT, 0)))) continue;
    eligible.push(m);
  }
  return eligible.length ? eligible[random.integer(0, eligible.length - 1)] : null;
}

/** Whether a root is within HINT_RADIUS of an untaken flask. */
export function hintDue(roots, flasks) {
  return roots.some((r) => flasks.some((f) => r.distanceTo(f) <= HINT_RADIUS));
}

export class Level2 {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Level2';
    this.game = game;
    this.candidates = game.world.anchors(CANDIDATE_KIND, LEVEL).map((a) => cfMatrix(a.cframe));
    this.random = seededRandom(1, 'L2Restock');
    this.active = false;
    this.lastSpawnAt = -Infinity;
    this.nextRestockAt = -Infinity;
    this.nextHintAt = -Infinity;
    this.hinted = false;
    this.spawned = 0;
  }

  beginRun(run) {
    this.random = seededRandom(run.seed, 'L2Restock');
    this.active = false;
    this.lastSpawnAt = -Infinity;
    this.hinted = false;
    this.spawned = 0;
  }

  endRun() {
    this.active = false;
  }

  levelActivated(level) {
    if (level !== LEVEL) return;
    this.active = true;
    this.nextRestockAt = -Infinity;
    this.nextHintAt = -Infinity;
  }

  levelDeactivated(level) {
    if (level === LEVEL) this.active = false;
  }

  _roots() {
    return this.game.playing() ? [this.game.env.rootPosition(new THREE.Vector3())] : [];
  }

  _restock(now) {
    const flasks = this.game.flasks;
    if (!restockDue(now, this.lastSpawnAt, flasks.available(LEVEL))) return;
    const occupied = flasks.pickupsOn(LEVEL).map((f) => f.position);
    const spot = pickSpot(this.candidates, occupied, this._roots(), (p) => this.game.seen(p), this.random);
    if (!spot) return;
    const yaw = this.random.number(0, Math.PI * 2);
    if (flasks.spawnAt(LEVEL, spot.clone().multiply(new THREE.Matrix4().makeRotationY(yaw)))) {
      this.lastSpawnAt = now;
      this.spawned++;
    }
  }

  tick(dt, now) {
    if (!this.active || this.game.phase !== 'InRun') return;
    if (!this.hinted && now >= this.nextHintAt) {
      this.nextHintAt = now + HINT_CHECK;
      if (hintDue(this._roots(), this.game.flasks.pickupsOn(LEVEL).map((f) => f.position))) {
        this.hinted = true;
        this.game.notify('Hud.FlaskStun');
      }
    }
    if (now >= this.nextRestockAt) {
      this.nextRestockAt = now + RESTOCK_CHECK;
      this._restock(now);
    }
  }
}
