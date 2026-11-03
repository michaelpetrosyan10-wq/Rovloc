// Locomotion: how the Creature gets anywhere. One Mover runs a plan: a queue of legs stepped every motion tick, so
// kinematic motion is smooth.
//
// Mediums. Floor (the walker walks an unanchored root) and Water (the root is anchored and glides under a pool's
// surface, PoseMode Swim). It never enters a duct or a crawlway (Tunnels: VentChase is gone). goTo(point) plans what
// the change of medium needs: a pool is entered and left only by a Warp (the service's FadeOut, a placement out of
// everyone's sight, a FadeIn), never by walking down the deck or climbing out.
//
// Legs.
//   Walk     floor pathfinding (FloorNav: the zone graph's portals, agent radius 2); waypoints followed with MoveTo,
//            recomputed on the repath interval when the goal moved and after a stall. Close to a goal with a clear
//            straight line it walks straight at it. Two failed computations fail the plan ("Failed"); no progress for
//            Repath.StuckSeconds forces a fresh route, and a second stall soon after reports "Stuck" (the brain then
//            repositions the Creature out of everyone's sight).
//   Swim     a straight glide under the surface, clamped inside the basin's water, at most the water pace
//            (setWaterSpeedCap: the AquaticStalk speed) unless the leg is a telegraphed lunge.
//   Warp     into or out of the water: engine.warp(goal, medium) starts the service's fade relocation; the leg ends
//            when it is over (the body placed there, the medium switched).
//   Hold     stand still for a moment, optionally facing a direction.
// Warp and Hold are uninterruptible: a new plan asked for while one runs replaces the rest once it ends.

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { CreatureConfig } from './config.js';
import { StuckTracker } from './body.js';
import { flatDirection, horizontalDistance } from './util.js';
import { SWIM_DEPTH, clampToWater, inWater } from './water.js';

const WAYPOINT_REACH = 2.5;
const ARRIVE_VERTICAL = 6;
const GOAL_JUMP = 4;
const GOAL_DRIFT = 2;
const DIRECT_RANGE = 10;
const CLEAR_RECHECK = 0.2;
const REISSUE_SECONDS = 2;
const MAX_PATH_FAILURES = 2;
const STALL_WINDOW = 12;
const RETREAT_DISTANCE = 9;
const RETREAT_ANGLES = [0, 35, -35, 70, -70];
const SWIM_RETREAT = 12;
const DEFAULT_REPATH = CreatureConfig.Repath.PatrolInterval;
const BUSY_KINDS = new Set(['Warp', 'Hold']);

export { SWIM_DEPTH };

/**
 * @typedef {'Floor'|'Water'} Medium
 * @typedef {'Idle'|'Moving'|'Failed'|'Stuck'} MoveStatus
 * @typedef {{computePath: (from: THREE.Vector3, to: THREE.Vector3) => ({waypoints: THREE.Vector3[]}|null),
 *   clear: (from: THREE.Vector3, to: THREE.Vector3) => boolean,
 *   warp?: (goal: THREE.Vector3, medium: Medium) => boolean, warping?: () => boolean}} Engine
 * @typedef {{arrive?: number, depth?: number, lunge?: boolean}} GoOptions
 */

function newLeg(kind) {
  return { kind, goal: null, arrive: 1.5, depth: SWIM_DEPTH, lunge: false, medium: null, seconds: 0, elapsed: 0,
    face: null, started: false };
}

function walkLeg(goal, arrive = 1.5) {
  const leg = newLeg('Walk');
  leg.goal = goal.clone();
  leg.arrive = arrive;
  return leg;
}

function swimLeg(goal, arrive = 1.5, depth = SWIM_DEPTH, lunge = false) {
  const leg = newLeg('Swim');
  leg.goal = goal.clone();
  leg.arrive = arrive;
  leg.depth = depth;
  leg.lunge = lunge;
  return leg;
}

function warpLeg(goal, medium) {
  const leg = newLeg('Warp');
  leg.goal = goal.clone();
  leg.medium = medium;
  return leg;
}

function holdLeg(seconds, face) {
  const leg = newLeg('Hold');
  leg.seconds = seconds;
  leg.face = face ? face.clone() : null;
  return leg;
}

export class Mover {
  /**
   * @param {import('./body.js').CreatureBody} body
   * @param {Engine} engine
   * @param {() => number} now
   */
  constructor(body, engine, now) {
    this.body = body;
    this.engine = engine;
    this.now = now;
    /** @type {import('./water.js').Basin[]} */
    this.basins = [];
    /** @type {Medium} */
    this.medium = 'Floor';
    this.legs = [];
    this.queued = null;
    /** @type {MoveStatus} */
    this.status = 'Idle';
    this.speed = CreatureConfig.Speeds.Patrol;
    /** The most any swim but a lunge moves (studs/s). */
    this.waterSpeed = Infinity;
    this.repathInterval = DEFAULT_REPATH;
    this.walk = this._newWalk();
    this.stuck = new StuckTracker(CreatureConfig.Repath.StuckSeconds);
  }

  _newWalk() {
    return {
      goal: null,
      waypoints: [],
      index: 0,
      computedAt: -Infinity,
      computedGoal: null,
      failures: 0,
      repath: true,
      issued: null,
      issuedAt: -Infinity,
      clearAt: -Infinity,
      clearGoal: null,
      clearResult: false,
      stalls: 0,
      stalledAt: -Infinity,
    };
  }

  // ------------------------------------------------------------------ helpers

  basinAt(position) {
    for (const basin of this.basins) if (inWater(basin, position)) return basin;
    return null;
  }

  _nearestBasin(position) {
    let best = null;
    let bestDistance = Infinity;
    for (const basin of this.basins) {
      const centre = new THREE.Vector3((basin.minX + basin.maxX) / 2, position.y, (basin.minZ + basin.maxZ) / 2);
      const d = horizontalDistance(centre, position);
      if (d < bestDistance) {
        best = basin;
        bestDistance = d;
      }
    }
    return best;
  }

  _stopWalking() {
    const w = this.walk;
    w.goal = null;
    w.waypoints = [];
    w.index = 0;
    w.failures = 0;
    w.repath = true;
    w.computedGoal = null;
    if (w.issued !== null && !this.body.anchored) this.body.moveTo(null);
    w.issued = null;
  }

  _install(plan) {
    const current = this.legs[0];
    if (current && BUSY_KINDS.has(current.kind) && current.started) {
      this.queued = plan;
    } else {
      if (current && current.kind === 'Walk') {
        const first = plan[0];
        if (!(first && first.kind === 'Walk')) this._stopWalking();
      }
      this.legs = plan;
      this.queued = null;
    }
    this.status = plan.length > 0 ? 'Moving' : 'Idle';
  }

  _fail(reason) {
    this.legs = [];
    this.queued = null;
    this._stopWalking();
    this.status = reason;
  }

  _issue(target) {
    const t = this.now();
    const w = this.walk;
    if (w.issued === null || w.issued.distanceTo(target) > 0.5 || t - w.issuedAt >= REISSUE_SECONDS) {
      this.body.moveTo(target);
      w.issued = target.clone();
      w.issuedAt = t;
    }
  }

  _request(from, goal) {
    const w = this.walk;
    w.repath = false;
    w.computedAt = this.now();
    w.computedGoal = goal.clone();
    const result = this.engine.computePath(from, goal);
    if (result && result.waypoints.length > 0) {
      w.failures = 0;
      w.waypoints = result.waypoints;
      w.index = 0;
    } else {
      w.failures += 1;
      w.repath = true;
    }
  }

  _directClear(position, goal) {
    const t = this.now();
    const w = this.walk;
    if (w.clearGoal !== null && w.clearGoal.distanceTo(goal) < 1 && t - w.clearAt < CLEAR_RECHECK) return w.clearResult;
    w.clearAt = t;
    w.clearGoal = goal.clone();
    w.clearResult = this.engine.clear(position, goal);
    return w.clearResult;
  }

  _ensureFloor(leg) {
    if (!leg.started) {
      leg.started = true;
      this.body.face(null);
    }
    if (this.body.anchored) this.body.setAnchored(false);
    if (this.body.pose === 'Quadruped' || this.body.pose === 'Swim') this.body.setPose('Biped');
    this.medium = 'Floor';
  }

  // ------------------------------------------------------------------ legs

  _stepWalk(leg) {
    const goal = leg.goal;
    if (!goal) return true;
    this._ensureFloor(leg);
    this.body.setWalkSpeed(this.speed);
    const position = this.body.getPosition();
    const t = this.now();
    const w = this.walk;
    if (this.basinAt(position)) {
      // fell off the coping: it swims from here (and leaves the water only by a warp)
      this._stopWalking();
      this.medium = 'Water';
      this.body.setAnchored(true);
      this.body.setPose('Swim');
      const rest = this.legs.slice(1);
      const replan = this._planTo(goal, { arrive: leg.arrive });
      this.legs = replan.concat(rest);
      return false;
    }
    if (horizontalDistance(position, goal) <= leg.arrive && Math.abs(position.y - goal.y) <= ARRIVE_VERTICAL) {
      this._stopWalking();
      this.stuck.reset();
      return true;
    }
    const previous = w.goal;
    if (previous === null || previous.distanceTo(goal) > GOAL_JUMP) {
      w.goal = goal.clone();
      w.waypoints = [];
      w.index = 0;
      w.repath = true;
    } else {
      w.goal = goal.clone();
    }
    if (this.stuck.sample(position, t, true)) {
      if (t - w.stalledAt > STALL_WINDOW) w.stalls = 0;
      w.stalls += 1;
      w.stalledAt = t;
      if (w.stalls >= 2) {
        this._fail('Stuck');
        return false;
      }
      w.waypoints = [];
      w.index = 0;
      w.repath = true;
    }
    if (horizontalDistance(position, goal) <= DIRECT_RANGE && this._directClear(position, goal)) {
      this._issue(goal);
      return false;
    }
    const drifted = w.computedGoal === null || w.computedGoal.distanceTo(goal) >= GOAL_DRIFT;
    if (w.repath || (t - w.computedAt >= this.repathInterval && drifted)) {
      if (w.failures >= MAX_PATH_FAILURES) {
        this._fail('Failed');
        return false;
      }
      this._request(position, goal);
    }
    const waypoints = w.waypoints;
    while (w.index < waypoints.length && horizontalDistance(position, waypoints[w.index]) <= WAYPOINT_REACH) w.index++;
    if (waypoints.length > 0) this._issue(waypoints[w.index] || goal);
    return false;
  }

  _stepSwim(leg, dt) {
    const goal = leg.goal;
    if (!goal) return true;
    if (!leg.started) {
      leg.started = true;
      this._stopWalking();
    }
    if (!this.body.anchored) this.body.setAnchored(true);
    this.body.setPose('Swim');
    this.medium = 'Water';
    const position = this.body.getPosition();
    const basin = this.basinAt(goal) || this.basinAt(position) || this._nearestBasin(position);
    const target = basin ? clampToWater(basin, goal, leg.depth) : goal;
    const delta = target.clone().sub(position);
    const distance = delta.length();
    if (distance <= leg.arrive) return true;
    const speed = leg.lunge ? this.speed : Math.min(this.speed, this.waterSpeed);
    const step = Math.min(distance, speed * dt);
    const next = position.clone().addScaledVector(delta, step / distance);
    const f = flatDirection(delta);
    if (f) this.body.setCFrame(CFrame.lookAt(next, next.clone().add(f)));
    else this.body.setCFrame(this.body.getCFrame().withPosition(next));
    return false;
  }

  _stepWarp(leg) {
    if (!leg.started) {
      leg.started = true;
      this._stopWalking();
      const started = !!(this.engine.warp && this.engine.warp(leg.goal, leg.medium));
      if (!started) {
        this._fail('Failed');
        return false;
      }
      return false;
    }
    if (this.engine.warping && this.engine.warping()) return false;
    this.medium = leg.medium;
    return true;
  }

  _stepHold(leg, dt) {
    if (!leg.started) {
      leg.started = true;
      this._stopWalking();
      if (leg.face) this.body.face(leg.face);
    }
    leg.elapsed += dt;
    return leg.elapsed >= leg.seconds;
  }

  _stepLeg(leg, dt) {
    switch (leg.kind) {
      case 'Walk':
        return this._stepWalk(leg);
      case 'Swim':
        return this._stepSwim(leg, dt);
      case 'Warp':
        return this._stepWarp(leg);
      default:
        return this._stepHold(leg, dt);
    }
  }

  _planTo(goal, options) {
    const arrive = options && options.arrive ? options.arrive : 1.5;
    const depth = options && options.depth ? options.depth : SWIM_DEPTH;
    const from = this.medium;
    const goalBasin = this.basinAt(goal);
    if (from === 'Floor' && goalBasin) {
      // into the water: fade out here, in under the surface out of everyone's sight
      return [warpLeg(clampToWater(goalBasin, goal, depth), 'Water')];
    }
    if (from === 'Water' && !goalBasin) {
      // out of the water: never climbing out at the deck; fade out under it and in on land out of sight
      return [warpLeg(goal, 'Floor')];
    }
    if (from === 'Water') return [swimLeg(goal, arrive, depth, !!(options && options.lunge))];
    return [walkLeg(goal, arrive)];
  }

  // ------------------------------------------------------------------ API

  /** The most any swim but a lunge may move (the AquaticStalk pace). */
  setWaterSpeedCap(speed) {
    this.waterSpeed = Number.isFinite(speed) && speed > 0 ? speed : Infinity;
  }

  /** @param {any} _graph (unused: the Creature never enters the ducts) @param {import('./water.js').Basin[]} basins */
  setLevel(_graph, basins) {
    this.basins = basins;
  }

  setSpeed(speed) {
    this.speed = Math.max(0, speed);
  }

  setRepathInterval(seconds) {
    this.repathInterval = Math.max(0.1, seconds);
  }

  /** @param {THREE.Vector3} position @param {GoOptions} [options] */
  goTo(position, options) {
    const plan = this._planTo(position, options);
    if (plan.length === 0) {
      this._fail('Failed');
      return;
    }
    // the same walk goal keeps its route (the Walk leg re-plans on its own as the goal drifts)
    const current = this.legs[0];
    const first = plan[0];
    if (plan.length === 1 && current && current.kind === first.kind && (current.kind === 'Walk' || current.kind === 'Swim') &&
      this.queued === null) {
      current.goal = first.goal;
      current.arrive = first.arrive;
      current.depth = first.depth;
      current.lunge = first.lunge;
      this.legs = [current];
      this.status = 'Moving';
      return;
    }
    this._install(plan);
  }

  /** Stumbles back away from `awayFrom` (a stun): straight back, veering off a wall behind, flailing when boxed in. */
  retreat(awayFrom) {
    const position = this.body.getPosition();
    const away = flatDirection(position.clone().sub(awayFrom)) ||
      flatDirection(this.body.getCFrame().lookVector.negate()) || new THREE.Vector3(0, 0, 1);
    if (this.medium === 'Water') {
      this._install([swimLeg(position.clone().addScaledVector(away, SWIM_RETREAT), 1, SWIM_DEPTH)]);
      return;
    }
    for (const degrees of RETREAT_ANGLES) {
      const direction = CFrame.angles(0, (degrees * Math.PI) / 180, 0).vectorToWorld(away);
      const goal = position.clone().addScaledVector(direction, RETREAT_DISTANCE);
      if (this.engine.clear(position, goal)) {
        this._install([walkLeg(goal, 1.5)]);
        return;
      }
    }
    this._install([holdLeg(RETREAT_DISTANCE / Math.max(this.speed, 1), null)]);
  }

  hold(seconds, face) {
    this._install([holdLeg(seconds, face || null)]);
  }

  stop() {
    const current = this.legs[0];
    if (current && current.kind === 'Warp' && current.started) {
      this.legs = [current];
    } else {
      this.legs = [];
      this._stopWalking();
    }
    this.queued = null;
    this.status = this.legs.length ? 'Moving' : 'Idle';
  }

  /** @param {Medium} [medium] */
  reset(medium) {
    this.legs = [];
    this.queued = null;
    this._stopWalking();
    this.stuck.reset();
    this.walk.stalls = 0;
    this.status = 'Idle';
    this.medium = medium || (this.basinAt(this.body.getPosition()) ? 'Water' : 'Floor');
  }

  face(direction) {
    this.body.face(direction);
  }

  /** One motion step. @param {number} dt */
  step(dt) {
    let leg = this.legs[0];
    if (!leg && this.queued) {
      this.legs = this.queued;
      this.queued = null;
      leg = this.legs[0];
    }
    if (!leg) {
      this.stuck.sample(this.body.getPosition(), this.now(), false);
      if (this.status === 'Moving') this.status = 'Idle';
      return;
    }
    if (leg.kind !== 'Walk') this.stuck.sample(this.body.getPosition(), this.now(), false);
    const done = this._stepLeg(leg, dt);
    if (done && this.legs[0] === leg) {
      this.legs.shift();
      if (this.queued) {
        this.legs = this.queued;
        this.queued = null;
      }
      if (this.legs.length === 0) this.status = 'Idle';
    }
  }

  getStatus() {
    return this.status;
  }

  getMedium() {
    return this.medium;
  }

  busy() {
    const current = this.legs[0];
    return (!!current && BUSY_KINDS.has(current.kind)) || this.queued !== null;
  }

  /** Whether a Warp leg is running or waiting. */
  warpPending() {
    return this.legs.some((l) => l.kind === 'Warp') || (!!this.queued && this.queued.some((l) => l.kind === 'Warp'));
  }

  goal() {
    const last = this.legs[this.legs.length - 1];
    if (!last) return null;
    return last.goal || null;
  }

  /**
   * Where the walker is heading, in order: the point it walks at now (its MoveTo target), then the rest of its route.
   * Empty when it is not walking (the service's head room looks ahead along this).
   * @returns {THREE.Vector3[]}
   */
  routeAhead() {
    const leg = this.legs[0];
    const w = this.walk;
    if (!leg || leg.kind !== 'Walk' || w.issued === null) return [];
    const out = [w.issued];
    const current = w.waypoints[w.index];
    if (current && horizontalDistance(current, w.issued) < 0.5) {
      for (let i = w.index + 1; i < w.waypoints.length; i++) out.push(w.waypoints[i]);
    }
    return out;
  }

  /** The Creature never rides the duct rail now (kept for the readers of the old API). */
  railPoint() {
    return null;
  }

  segment() {
    return null;
  }

  nearestNode() {
    return null;
  }
}
