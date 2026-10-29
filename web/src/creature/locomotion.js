// Locomotion (MonsterAIService/Locomotion.luau): how the Creature gets anywhere. One Mover runs a plan: a queue of
// legs stepped every motion tick, so kinematic motion is smooth.
//
// Mediums. Floor (the walker walks an unanchored root), Water (the root is anchored and glides under a pool's surface,
// PoseMode Swim) and Vent (the root is anchored on the duct centreline, PoseMode Quadruped). GoTo(point) plans what the
// change of medium needs: out of the ducts first through the best open grate, then a walk to the pool deck and a slip
// into the water, or a swim to the deck edge and a climb out. From a VentExitOnly pool (Level 4) there is no climbing
// out: the way out is its own vent route, a swim to the nearest pool grate and in; the ducts give no exit back onto
// the land from there, so the plan ends in the duct and the brain moves the Creature on unseen ("Failed" in a vent).
//
// Legs.
//   Walk     floor pathfinding (FloorNav: the zone graph's portals, agent radius 2); waypoints followed with MoveTo,
//            recomputed on the repath interval when the goal moved and after a stall. Close to a goal with a clear
//            straight line it walks straight at it. Two failed computations fail the plan ("Failed"); no progress for
//            Repath.StuckSeconds forces a fresh route, and a second stall soon after reports "Stuck" (the brain then
//            repositions the Creature out of everyone's sight).
//   Swim     a straight glide under the surface, clamped inside the basin's water, at most the water pace
//            (setWaterSpeedCap: the AquaticStalk speed) unless the leg is a telegraphed lunge.
//   Transit  a short kinematic tween between two CFrames (through a grate mouth, into or out of a pool).
//   Rail     the root steps along a polyline of VentGraph points at the vent speed, facing its travel (or a threat
//            while it backs away), on the centreline.
//   Hold     stand still for a moment, optionally facing a direction.
//   Do       run a callback (kicking a grate).
// Transit, Hold and Do are uninterruptible: a new plan asked for while one runs replaces the rest once it ends.

import * as THREE from 'three';
import { CFrame } from './cframe.js';
import { CreatureConfig, ROOT_HEIGHT } from './config.js';
import { StuckTracker } from './body.js';
import { flatDirection, horizontalDistance, smoothstep } from './util.js';
import { nearest as railNearest, nearestNode, path as ventPath, retreatPath } from './ventgraph.js';
import { SWIM_DEPTH, clampToWater, deckCrossing, inWater } from './water.js';

const WAYPOINT_REACH = 2.5;
const ARRIVE_VERTICAL = 6;
const GOAL_JUMP = 4;
const GOAL_DRIFT = 2;
const DIRECT_RANGE = 10;
const CLEAR_RECHECK = 0.2;
const REISSUE_SECONDS = 2;
const MAX_PATH_FAILURES = 2;
const STALL_WINDOW = 12;
const SLIP_SECONDS = 0.9;
const CLIMB_SECONDS = 1.1;
export const SQUEEZE_SECONDS = 0.8;
const FACE_SECONDS = 0.3;
export const KICK_RECOVER = 0.55;
const RETREAT_DISTANCE = 9;
const RETREAT_ANGLES = [0, 35, -35, 70, -70];
const SWIM_RETREAT = 12;
const VERTICAL_TRAVEL = 0.95;
const DEFAULT_REPATH = CreatureConfig.Repath.PatrolInterval;
const BUSY_KINDS = new Set(['Transit', 'Hold', 'Do']);

export { SWIM_DEPTH };

/**
 * @typedef {'Floor'|'Water'|'Vent'} Medium
 * @typedef {'Idle'|'Moving'|'Failed'|'Stuck'} MoveStatus
 * @typedef {{computePath: (from: THREE.Vector3, to: THREE.Vector3) => ({waypoints: THREE.Vector3[]}|null),
 *   clear: (from: THREE.Vector3, to: THREE.Vector3) => boolean}} Engine
 * @typedef {{state: (id: string) => string, standPoint: (grate: import('./ventgraph.js').Grate) => CFrame,
 *   kick: (id: string) => void}} Grates
 * @typedef {{arrive?: number, depth?: number, lunge?: boolean}} GoOptions
 */

/**
 * The cheapest route on the rail between two rail points: [points ending at the target, length] or [null, Infinity].
 * @param {import('./ventgraph.js').Graph} graph
 * @param {import('./ventgraph.js').RailPoint} from
 * @param {import('./ventgraph.js').RailPoint} target
 * @returns {[THREE.Vector3[]|null, number]}
 */
export function railRoute(graph, from, target) {
  const ends = (point) => {
    const a = graph.nodes[point.a];
    if (!a) return [];
    const out = [{ id: point.a, lead: point.position.distanceTo(a.position) }];
    if (point.b && graph.nodes[point.b]) out.push({ id: point.b, lead: point.position.distanceTo(graph.nodes[point.b].position) });
    return out;
  };
  if (from.b !== null && from.a === target.a && from.b === target.b) {
    return [[target.position.clone()], target.position.distanceTo(from.position)];
  }
  if (from.b === null && target.b === null && from.a === target.a) {
    const n = graph.nodes[from.a].position;
    return [[n.clone(), target.position.clone()], from.position.distanceTo(n) + target.position.distanceTo(n)];
  }
  let bestNodes = null;
  let bestCost = Infinity;
  for (const start of ends(from)) {
    for (const goal of ends(target)) {
      const [nodes, cost] = ventPath(graph, start.id, goal.id);
      if (nodes && start.lead + cost + goal.lead < bestCost) {
        bestNodes = nodes;
        bestCost = start.lead + cost + goal.lead;
      }
    }
  }
  if (!bestNodes) return [null, Infinity];
  const points = bestNodes.map((id) => graph.nodes[id].position.clone());
  points.push(target.position.clone());
  return [points, bestCost];
}

/**
 * Moves along `points` from `position` by `budget` studs starting at points[index]: [position, next index, heading].
 * @returns {[THREE.Vector3, number, THREE.Vector3|null]}
 */
export function advance(points, index, position, budget) {
  const at = position.clone();
  let next = index;
  let left = Math.max(0, budget);
  let heading = null;
  while (next < points.length) {
    const target = points[next];
    const delta = target.clone().sub(at);
    const distance = delta.length();
    if (distance > 1e-6) heading = delta.clone().divideScalar(distance);
    if (distance <= left) {
      at.copy(target);
      left -= distance;
      next++;
    } else {
      if (distance > 1e-6) at.addScaledVector(delta, left / distance);
      break;
    }
  }
  return [at, next, heading];
}

function newLeg(kind) {
  return {
    kind,
    goal: null,
    arrive: 1.5,
    depth: SWIM_DEPTH,
    to: null,
    from: null,
    seconds: 0,
    elapsed: 0,
    pose: null,
    exitPose: null,
    enterMedium: null,
    exitMedium: null,
    points: [],
    index: 0,
    backward: false,
    face: null,
    run: null,
    started: false,
  };
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

function transitLeg(to, seconds, pose, enterMedium, exitPose, exitMedium) {
  const leg = newLeg('Transit');
  leg.to = to;
  leg.seconds = seconds;
  leg.pose = pose;
  leg.enterMedium = enterMedium;
  leg.exitPose = exitPose;
  leg.exitMedium = exitMedium;
  return leg;
}

function railLeg(points, backward, face) {
  const leg = newLeg('Rail');
  leg.points = points;
  leg.backward = backward;
  leg.face = face ? face.clone() : null;
  return leg;
}

function holdLeg(seconds, face) {
  const leg = newLeg('Hold');
  leg.seconds = seconds;
  leg.face = face ? face.clone() : null;
  return leg;
}

function doLeg(run) {
  const leg = newLeg('Do');
  leg.run = run;
  return leg;
}

export class Mover {
  /**
   * @param {import('./body.js').CreatureBody} body
   * @param {Engine} engine
   * @param {Grates} grates
   * @param {() => number} now
   */
  constructor(body, engine, grates, now) {
    this.body = body;
    this.engine = engine;
    this.grates = grates;
    this.now = now;
    /** @type {import('./ventgraph.js').Graph|null} */
    this.graph = null;
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
      // walked off the coping: it swims from here
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

  _stepTransit(leg, dt) {
    const to = leg.to;
    if (!to) return true;
    if (!leg.started) {
      leg.started = true;
      this._stopWalking();
      leg.from = this.body.getCFrame();
      this.body.setAnchored(true);
      if (leg.pose) this.body.setPose(leg.pose);
      if (leg.enterMedium) this.medium = leg.enterMedium;
    }
    leg.elapsed += dt;
    const from = leg.from || to;
    if (leg.elapsed >= leg.seconds) {
      this.body.setCFrame(to);
      if (leg.exitPose) this.body.setPose(leg.exitPose);
      if (leg.exitMedium) {
        this.medium = leg.exitMedium;
        if (leg.exitMedium === 'Floor') this.body.setAnchored(false);
      }
      return true;
    }
    this.body.setCFrame(from.lerp(to, smoothstep(0, 1, leg.elapsed / leg.seconds)));
    return false;
  }

  _stepRail(leg, dt) {
    if (!leg.started) {
      leg.started = true;
      this._stopWalking();
    }
    if (!this.body.anchored) this.body.setAnchored(true);
    this.body.setPose('Quadruped');
    this.medium = 'Vent';
    const [position, index, heading] = advance(leg.points, leg.index, this.body.getPosition(), this.speed * dt);
    leg.index = index;
    let facing = heading;
    if (leg.backward && leg.face) facing = leg.face.clone().sub(position);
    else if (leg.backward && heading) facing = heading.clone().negate();
    const look = facing && facing.length() > 1e-6 ? facing.clone().normalize() : null;
    if (look && Math.abs(look.y) < VERTICAL_TRAVEL) {
      this.body.setCFrame(CFrame.lookAt(position, position.clone().add(new THREE.Vector3(look.x, 0, look.z))));
    } else {
      this.body.setCFrame(this.body.getCFrame().withPosition(position));
    }
    return index >= leg.points.length;
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
      case 'Transit':
        return this._stepTransit(leg, dt);
      case 'Rail':
        return this._stepRail(leg, dt);
      case 'Hold':
        return this._stepHold(leg, dt);
      default:
        leg.started = true;
        if (leg.run) leg.run();
        return true;
    }
  }

  _railHere() {
    if (this.medium !== 'Vent' || !this.graph) return null;
    return railNearest(this.graph, this.body.getPosition());
  }

  _standCFrame(grate) {
    const stand = this.grates.standPoint(grate);
    const sp = stand.position;
    const basin = this.basinAt(new THREE.Vector3(sp.x, sp.y - 0.6, sp.z));
    if (basin) {
      const point = clampToWater(basin, sp);
      return [CFrame.lookAt(point, point.clone().add(stand.lookVector)), 'Water'];
    }
    const root = new THREE.Vector3(sp.x, sp.y + ROOT_HEIGHT, sp.z);
    return [CFrame.lookAt(root, root.clone().add(stand.lookVector)), 'Floor'];
  }

  /** Legs that crawl out through `grate` (or the best grate toward `toward`): [plan|null, medium, point]. */
  _exitPlan(grate, toward) {
    const level = this.graph;
    const here = this._railHere();
    const position = this.body.getPosition();
    if (!level || !here) return [null, this.medium, position];
    // a goal on land is never reached by dropping back into a pool the Creature may not climb out of
    const landGoal = !!toward && !this.basinAt(toward);
    const intoSealedPool = (candidate) => landGoal && this._sealedBasinAt(this._standCFrame(candidate)[0].position);
    const routeTo = (candidate) => {
      if (!level.nodes[candidate.nodeId]) return [null, Infinity];
      const mouth = { a: candidate.nodeId, b: null, t: 1, position: candidate.mouth.clone(), distance: 0 };
      return railRoute(level, here, mouth);
    };
    let chosen = grate;
    let kick = false;
    let route = null;
    if (chosen) {
      [route] = routeTo(chosen);
      const state = this.grates.state(chosen.id);
      kick = !(state === 'Open' || state === 'Kicked');
      if (state === 'Locked' || intoSealedPool(chosen)) route = null;
    } else {
      let bestCost = Infinity;
      let bestKickCost = Infinity;
      let kickable = null;
      let kickRoute = null;
      for (const id of level.grateIds) {
        const candidate = level.grates[id];
        const state = this.grates.state(id);
        if (state === 'Locked' || intoSealedPool(candidate)) continue;
        const [points, cost] = routeTo(candidate);
        if (!points) continue;
        const stand = this.grates.standPoint(candidate);
        const total = cost + (toward ? horizontalDistance(stand.position, toward) : 0);
        if (state === 'Open' || state === 'Kicked') {
          if (total < bestCost) {
            chosen = candidate;
            route = points;
            bestCost = total;
          }
        } else if (total < bestKickCost) {
          kickable = candidate;
          kickRoute = points;
          bestKickCost = total;
        }
      }
      if (!chosen && kickable) {
        chosen = kickable;
        route = kickRoute;
        kick = true;
      }
    }
    if (!chosen || !route) return [null, this.medium, position];
    const out = chosen;
    const plan = [railLeg(route, false, null)];
    if (kick) {
      plan.push(doLeg(() => this.grates.kick(out.id)));
      plan.push(holdLeg(KICK_RECOVER, null));
    }
    const [stand, outside] = this._standCFrame(out);
    plan.push(transitLeg(stand, SQUEEZE_SECONDS, null, null, outside === 'Water' ? 'Swim' : 'Biped', outside));
    return [plan, outside, stand.position];
  }

  _planTo(goal, options) {
    const arrive = options && options.arrive ? options.arrive : 1.5;
    const depth = options && options.depth ? options.depth : SWIM_DEPTH;
    const plan = [];
    let from = this.medium;
    let position = this.body.getPosition();
    if (from === 'Vent') {
      const [exits, outside, point] = this._exitPlan(null, goal);
      if (!exits) return [];
      for (const leg of exits) plan.push(leg);
      from = outside;
      position = point;
    }
    const goalBasin = this.basinAt(goal);
    if (from === 'Floor' && goalBasin) {
      const [stand, water] = deckCrossing(goalBasin, goal);
      if (stand && water) {
        const sp = stand.position;
        plan.push(walkLeg(new THREE.Vector3(sp.x, sp.y - ROOT_HEIGHT, sp.z), 1.2));
        plan.push(transitLeg(CFrame.lookAt(water, water.clone().sub(stand.lookVector)), SLIP_SECONDS, 'Swim', 'Water', null, null));
        plan.push(swimLeg(goal, arrive, depth));
      } else {
        plan.push(walkLeg(goal, arrive));
      }
    } else if (from === 'Water' && !goalBasin) {
      const basin = this.basinAt(position) || this._nearestBasin(position);
      if (basin && basin.ventExitOnly) return this._poolVentPlan(basin, position);
      let stand = null;
      let water = null;
      if (basin) [stand, water] = deckCrossing(basin, goal);
      if (stand && water) {
        plan.push(swimLeg(water, 1, SWIM_DEPTH));
        plan.push(transitLeg(stand, CLIMB_SECONDS, null, null, 'Biped', 'Floor'));
      }
      plan.push(walkLeg(goal, arrive));
    } else if (from === 'Water') {
      plan.push(swimLeg(goal, arrive, depth, !!(options && options.lunge)));
    } else {
      plan.push(walkLeg(goal, arrive));
    }
    return plan;
  }

  /** A basin the Creature may leave only through its vent route, holding `p` (in its water), or null. */
  _sealedBasinAt(p) {
    const basin = this.basinAt(p);
    return basin && basin.ventExitOnly ? basin : null;
  }

  /**
   * The way out of a VentExitOnly pool: a swim to the nearest pool grate (one whose stand point is in this basin's
   * water), a kick when it is shut, and in to its duct node. Empty when the pool has no usable grate (it stays in).
   */
  _poolVentPlan(basin, position) {
    const level = this.graph;
    if (!level) return [];
    let best = null;
    let bestDistance = Infinity;
    for (const id of level.grateIds) {
      const grate = level.grates[id];
      if (!level.nodes[grate.nodeId] || this.grates.state(id) === 'Locked') continue;
      const [stand, medium] = this._standCFrame(grate);
      if (medium !== 'Water' || this.basinAt(stand.position) !== basin) continue;
      const d = stand.position.distanceTo(position);
      if (d < bestDistance) {
        best = { grate, stand };
        bestDistance = d;
      }
    }
    if (!best) return [];
    const { grate, stand } = best;
    const state = this.grates.state(grate.id);
    const intoWall = stand.lookVector.clone().negate();
    const plan = [swimLeg(stand.position, 1, SWIM_DEPTH), holdLeg(FACE_SECONDS, intoWall)];
    if (!(state === 'Open' || state === 'Kicked')) {
      plan.push(doLeg(() => this.grates.kick(grate.id)));
      plan.push(holdLeg(KICK_RECOVER, intoWall));
    }
    const f = flatDirection(intoWall) || new THREE.Vector3(0, 0, -1);
    plan.push(transitLeg(CFrame.lookAt(grate.mouth, grate.mouth.clone().add(f)), SQUEEZE_SECONDS, 'Quadruped', 'Vent', null, null));
    plan.push(railLeg([level.nodes[grate.nodeId].position.clone()], false, null));
    return plan;
  }

  // ------------------------------------------------------------------ API

  /** The most any swim but a lunge may move (the AquaticStalk pace). */
  setWaterSpeedCap(speed) {
    this.waterSpeed = Number.isFinite(speed) && speed > 0 ? speed : Infinity;
  }

  setLevel(graph, basins) {
    this.graph = graph;
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

  enterVent(grate, kick) {
    const level = this.graph;
    const node = level && level.nodes[grate.nodeId];
    if (!node) {
      this._fail('Failed');
      return;
    }
    const stand = this.grates.standPoint(grate);
    const intoWall = stand.lookVector.negate();
    const plan = this._planTo(stand.position, { arrive: 1.2 });
    plan.push(holdLeg(FACE_SECONDS, intoWall));
    if (kick) {
      plan.push(doLeg(() => this.grates.kick(grate.id)));
      plan.push(holdLeg(KICK_RECOVER, intoWall));
    }
    const f = flatDirection(intoWall) || new THREE.Vector3(0, 0, -1);
    plan.push(transitLeg(CFrame.lookAt(grate.mouth, grate.mouth.clone().add(f)), SQUEEZE_SECONDS, 'Quadruped', 'Vent', null, null));
    plan.push(railLeg([node.position.clone()], false, null));
    this._install(plan);
  }

  exitVent(grate, toward) {
    if (this.medium !== 'Vent') return true;
    const [plan] = this._exitPlan(grate || null, toward || null);
    if (!plan) return false;
    this._install(plan);
    return true;
  }

  railTo(target) {
    const level = this.graph;
    const here = this._railHere();
    if (!level || !here) return false;
    const [points] = railRoute(level, here, target);
    if (!points) return false;
    this._install([railLeg(points, false, null)]);
    return true;
  }

  retreat(awayFrom, hops) {
    const position = this.body.getPosition();
    const level = this.graph;
    if (this.medium === 'Vent' && level) {
      const node = nearestNode(level, position);
      if (!node) return;
      const walkNodes = retreatPath(level, node, awayFrom, hops);
      this._install([railLeg(walkNodes.map((id) => level.nodes[id].position.clone()), true, awayFrom)]);
      return;
    }
    const away = flatDirection(position.clone().sub(awayFrom)) ||
      flatDirection(this.body.getCFrame().lookVector.negate()) || new THREE.Vector3(0, 0, 1);
    if (this.medium === 'Water') {
      this._install([swimLeg(position.clone().addScaledVector(away, SWIM_RETREAT), 1, SWIM_DEPTH)]);
      return;
    }
    // stumble straight back, or veering off when a wall is right behind; flail in place when boxed in
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
    if (current && BUSY_KINDS.has(current.kind) && current.started && current.kind === 'Transit') {
      this.legs = [current];
    } else {
      this.legs = [];
      this._stopWalking();
    }
    this.queued = null;
    this.status = 'Idle';
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

  goal() {
    const last = this.legs[this.legs.length - 1];
    if (!last) return null;
    if (last.goal) return last.goal;
    if (last.to) return last.to.position;
    return last.points[last.points.length - 1] || null;
  }

  railPoint() {
    return this._railHere();
  }

  segment() {
    const here = this._railHere();
    if (!here || !this.graph || !here.b) return null;
    return this.graph.segments[`${here.a}|${here.b}`] || null;
  }

  nearestNode() {
    return this.graph ? nearestNode(this.graph, this.body.getPosition()) : null;
  }
}
