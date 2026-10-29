// InvestigateNoise (States/InvestigateNoise.luau): the Creature goes to where it believes a noise came from (exact for
// loud noises, blurred for quiet ones) at InvestigateNoise speed, then searches.
//
// The search works outward from the spot: a look around; the lockers of that room, nearest first (it stands at each
// door, hunched, and peeks through the locker inspector hook: "Caught" is a Locker jumpscare on the occupant,
// "HiddenSafe" and "Empty" move on; without a hook it only looks); the room's open vent grates (it crouches at the
// mouth and peers in: a crawler on that duct within PeerRange with a clear line from its eyes is spotted, and the
// brain sends it after them); then up to two rooms through open doorways. A louder (or equally loud) noise
// re-targets it; the search gives up after SearchSeconds. Nothing found ends the state (Patrol).

import * as THREE from 'three';
import { CreatureConfig, GameConfig } from '../config.js';
import { roomAt } from '../brain.js';
import { flat } from '../util.js';

export const Name = 'InvestigateNoise';
export const SearchSeconds = 35;
const MAX_LOCKERS = 3;
const MAX_GRATES = 2;
const MAX_ROOMS = 2;
const LOOK_SECONDS = 1.4;
const LOCKER_SECONDS = 1.6;
const PEER_SECONDS = 2.4;
const ROOM_SECONDS = 1.3;
export const PeerRange = 14;
const ARRIVE = 3;
const SPOT_ARRIVE = 1.2;
const INSPECT_TIMEOUT = GameConfig.BreathHoldMaxSeconds + 4;
const LOCKER_REACH = 8;

const runs = new WeakMap();

/**
 * @typedef {{kind: 'Look'|'Locker'|'Grate'|'Room', position: THREE.Vector3, face: THREE.Vector3|null, seconds: number,
 *   locker?: string, grateId?: string}} Step
 * @typedef {{locker: string, front: import('../cframe.js').CFrame}} LockerSpot
 * @typedef {{grateId: string, stand: import('../cframe.js').CFrame}} GrateSpot
 */

function byDistance(list, at, place) {
  return [...list].sort((a, b) => place(a).distanceTo(at) - place(b).distanceTo(at));
}

/**
 * The search around `input.at`: look, lockers, grates, neighbouring rooms.
 * @param {{at: THREE.Vector3, room: any, neighbours: any[], lockers: LockerSpot[], grates: GrateSpot[],
 *   look: THREE.Vector3}} input
 * @returns {Step[]}
 */
export function searchPlan(input) {
  const steps = [];
  const fl = flat(input.look);
  const back = fl.length() > 1e-3 ? fl.normalize().negate() : new THREE.Vector3(0, 0, 1);
  steps.push({ kind: 'Look', position: input.at.clone(), face: back, seconds: LOOK_SECONDS });
  byDistance(input.lockers, input.at, (s) => s.front.position).slice(0, MAX_LOCKERS).forEach((spot) => {
    steps.push({ kind: 'Locker', position: spot.front.position, face: spot.front.lookVector.negate(), seconds: LOCKER_SECONDS,
      locker: spot.locker });
  });
  byDistance(input.grates, input.at, (s) => s.stand.position).slice(0, MAX_GRATES).forEach((spot) => {
    steps.push({ kind: 'Grate', position: spot.stand.position, face: spot.stand.lookVector.negate(), seconds: PEER_SECONDS,
      grateId: spot.grateId });
  });
  byDistance(input.neighbours, input.at, (r) => r.centre).slice(0, MAX_ROOMS).forEach((room) => {
    steps.push({ kind: 'Room', position: room.centre.clone(), face: null, seconds: ROOM_SECONDS });
  });
  return steps;
}

/** Whether a crawler at `rail` is in view of the Creature peering into the grate on `grateNode`. */
export function peerSees(rail, grateNode, mouth, lineClear) {
  if (!lineClear) return false;
  if (rail.a !== grateNode && rail.b !== grateNode) return false;
  return rail.position.distanceTo(mouth) <= PeerRange;
}

function gratesIn(ctx, zoneId) {
  const out = [];
  const graph = ctx.graph;
  if (!graph) return out;
  for (const id of graph.grateIds) {
    const grate = graph.grates[id];
    const state = ctx.grateState(id);
    if (grate.facingZoneId === zoneId && (state === 'Open' || state === 'Kicked')) out.push({ grateId: id, stand: ctx.standPoint(grate) });
  }
  return out;
}

function buildSearch(ctx, at) {
  const level = ctx.level;
  const room = level ? roomAt(level, at) : null;
  const neighbours = [];
  let lockers = [];
  let grates = [];
  if (level && room) {
    for (const id of level.neighbours[room.id] || []) {
      const other = level.rooms[id];
      if (other && other.kind !== 'Chase') neighbours.push(other);
    }
    lockers = ctx.lockersIn(level.levelId, room.id);
    grates = gratesIn(ctx, room.id);
  }
  return searchPlan({ at, room, neighbours, lockers, grates, look: ctx.body.getCFrame().lookVector });
}

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { investigation: null, phase: 'Approach', steps: [], index: 0, stage: 'Start', deadline: 0, inspection: null };
    runs.set(ctx, run);
  }
  return run;
}

function begin(ctx, run, investigation) {
  run.investigation = investigation;
  run.phase = 'Approach';
  run.steps = [];
  run.index = 0;
  run.stage = 'Start';
  run.inspection = null;
  run.deadline = ctx.now() + SearchSeconds;
  ctx.body.setPose('Biped');
  const goal = investigation ? investigation.position : ctx.body.getPosition();
  ctx.mover.goTo(goal, { arrive: ARRIVE });
}

/** Peeks into `locker` through the hook (asynchronously: a hiding player's breath check takes a while). */
function inspect(ctx, run, locker) {
  const inspector = ctx.lockerInspector();
  if (!inspector) return;
  const inspection = { locker, started: ctx.now(), verdict: null };
  run.inspection = inspection;
  let pending;
  try {
    pending = Promise.resolve(inspector(locker));
  } catch (err) {
    pending = Promise.reject(err);
  }
  pending.then((verdict) => (verdict === 'Caught' || verdict === 'HiddenSafe' ? verdict : 'Empty'), () => 'Empty')
    .then((result) => {
      inspection.verdict = result;
      if (result !== 'Caught') return;
      const occupant = ctx.lockerOccupant(locker);
      const front = ctx.lockerFront(locker);
      const near = front !== null && front.position.distanceTo(ctx.body.getPosition()) <= LOCKER_REACH;
      if (occupant && near) ctx.tryCatch(occupant, 'Locker');
    });
}

/** While peering into grate `grateId`: any crawler in view is spotted. */
function peer(ctx, grateId) {
  const grate = ctx.graph ? ctx.graph.grates[grateId] : null;
  if (!grate) return;
  const eye = ctx.creatureEye();
  for (const player of ctx.ventOccupants()) {
    const rail = ctx.railPointOf(player);
    const playerEye = ctx.playerEye(player);
    if (rail && playerEye && peerSees(rail, grate.nodeId, grate.mouth, ctx.lineClear(eye, playerEye))) ctx.noteSpotted(player);
  }
}

function nextStep(ctx, run) {
  run.index += 1;
  run.stage = 'Start';
  run.inspection = null;
  ctx.body.setPose('Biped');
}

function startHold(ctx, run, step) {
  run.stage = 'Hold';
  if (step.kind === 'Locker' || step.kind === 'Grate') ctx.body.setPose('Hunched');
  ctx.mover.hold(step.seconds, step.face);
  if (step.kind === 'Locker' && step.locker) inspect(ctx, run, step.locker);
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const speed = ctx.speedOf(Name);
  ctx.mover.setSpeed(speed);
  ctx.body.setWalkSpeed(speed);
  ctx.mover.setRepathInterval(CreatureConfig.Repath.PatrolInterval / 2);
  ctx.body.face(null);
  begin(ctx, runOf(ctx), ctx.investigation);
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runOf(ctx);
  const current = run.investigation;
  const heard = ctx.heard;
  if (heard && (current === null || heard.rank >= current.rank || run.phase === 'Search')) {
    const fresh = { position: heard.position.clone(), rank: heard.rank, at: heard.at };
    ctx.investigation = fresh;
    begin(ctx, run, fresh);
    return;
  }
  if (ctx.now() > run.deadline) {
    ctx.stateDone = true;
    return;
  }
  const mover = ctx.mover;
  const busy = mover.busy();
  const status = mover.getStatus();
  if (run.phase === 'Approach') {
    if (busy || status === 'Moving') return;
    run.phase = 'Search';
    const at = status === 'Idle' && current ? current.position : ctx.body.getPosition();
    run.steps = buildSearch(ctx, at);
    run.index = 0;
    run.stage = 'Start';
    return;
  }
  const step = run.steps[run.index];
  if (!step) {
    ctx.stateDone = true;
    return;
  }
  if (run.stage === 'Start') {
    if (busy) return;
    if (step.kind === 'Look') startHold(ctx, run, step);
    else {
      run.stage = 'Travel';
      mover.goTo(step.position, { arrive: step.kind === 'Room' ? ARRIVE : SPOT_ARRIVE });
    }
    return;
  }
  if (run.stage === 'Travel') {
    if (busy || status === 'Moving') return;
    if (status === 'Failed' || status === 'Stuck') {
      nextStep(ctx, run);
      return;
    }
    startHold(ctx, run, step);
    return;
  }
  if (step.kind === 'Grate' && step.grateId) peer(ctx, step.grateId);
  const inspection = run.inspection;
  if (inspection && inspection.verdict === null && ctx.now() - inspection.started < INSPECT_TIMEOUT) return;
  if (busy) return;
  nextStep(ctx, run);
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  const run = runOf(ctx);
  run.inspection = null;
  ctx.body.setPose('Biped');
  ctx.body.face(null);
  ctx.investigation = null;
}
