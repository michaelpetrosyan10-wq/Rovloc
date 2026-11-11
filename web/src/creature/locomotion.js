// Locomotion: how the Creature gets anywhere. One Mover runs a plan: a queue of legs stepped every motion tick, so
// kinematic motion is smooth. The walker walks an unanchored root; it never enters a duct or a crawlway (Tunnels:
// VentChase is gone).
//
// Legs.
//   Walk     floor pathfinding (FloorNav: the zone graph's portals, agent radius 2); waypoints followed with MoveTo,
//            recomputed on the repath interval when the goal moved and after a stall. Close to a goal with a clear
//            straight line it walks straight at it. Two failed computations fail the plan ("Failed"); no progress for
//            Repath.StuckSeconds forces a fresh route, and a second stall soon after reports "Stuck" (the brain then
//            repositions the Creature out of everyone's sight).
//   Hold     stand still for a moment, optionally facing a direction.
// Hold is uninterruptible: a new plan asked for while one runs replaces the rest once it ends.

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { CreatureConfig } from './config.js';
import { StuckTracker } from './body.js';
import { flatDirection, horizontalDistance } from './util.js';

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
const DEFAULT_REPATH = CreatureConfig.Repath.PatrolInterval;
const BUSY_KINDS = new Set(['Hold']);

/**
 * @typedef {'Idle'|'Moving'|'Failed'|'Stuck'} MoveStatus
 * @typedef {{computePath: (from: THREE.Vector3, to: THREE.Vector3) => ({waypoints: THREE.Vector3[]}|null),
 *   clear: (from: THREE.Vector3, to: THREE.Vector3) => boolean}} Engine
 * @typedef {{arrive?: number}} GoOptions
 */

function newLeg(kind) {
  return { kind, goal: null, arrive: 1.5, seconds: 0, elapsed: 0, face: null, started: false };
}

function walkLeg(goal, arrive = 1.5) {
  const leg = newLeg('Walk');
  leg.goal = goal.clone();
  leg.arrive = arrive;
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
    this.legs = [];
    this.queued = null;
    /** @type {MoveStatus} */
    this.status = 'Idle';
    this.speed = CreatureConfig.Speeds.Patrol;
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
    if (this.body.pose === 'Quadruped') this.body.setPose('Biped');
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
      default:
        return this._stepHold(leg, dt);
    }
  }

  // ------------------------------------------------------------------ API

  setSpeed(speed) {
    this.speed = Math.max(0, speed);
  }

  setRepathInterval(seconds) {
    this.repathInterval = Math.max(0.1, seconds);
  }

  /** @param {THREE.Vector3} position @param {GoOptions} [options] */
  goTo(position, options) {
    const leg = walkLeg(position, options && options.arrive ? options.arrive : 1.5);
    // the same walk goal keeps its route (the Walk leg re-plans on its own as the goal drifts)
    const current = this.legs[0];
    if (current && current.kind === 'Walk' && this.queued === null) {
      current.goal = leg.goal;
      current.arrive = leg.arrive;
      this.legs = [current];
      this.status = 'Moving';
      return;
    }
    this._install([leg]);
  }

  /** Stumbles back away from `awayFrom` (a stun): straight back, veering off a wall behind, flailing when boxed in. */
  retreat(awayFrom) {
    const position = this.body.getPosition();
    const away = flatDirection(position.clone().sub(awayFrom)) ||
      flatDirection(this.body.getCFrame().lookVector.negate()) || new THREE.Vector3(0, 0, 1);
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
    this.legs = [];
    this._stopWalking();
    this.queued = null;
    this.status = 'Idle';
  }

  reset() {
    this.legs = [];
    this.queued = null;
    this._stopWalking();
    this.stuck.reset();
    this.walk.stalls = 0;
    this.status = 'Idle';
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

  busy() {
    const current = this.legs[0];
    return (!!current && BUSY_KINDS.has(current.kind)) || this.queued !== null;
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
