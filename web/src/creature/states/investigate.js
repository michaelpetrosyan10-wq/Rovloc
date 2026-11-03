// InvestigateNoise (Tunnels §2.3): the Creature goes to where it believes a noise came from (exact for loud noises,
// blurred for quiet ones) at the InvestigateNoise pace (9 studs/s), then searches there for 6..10 s: a look around,
// then the hiding spots nearest the spot (lockers, barrels, cabinets: up to Investigate.Spots of them, within the
// search radius), sniffing at each (the breath check, states/sniff.js). A louder (or equally loud) noise re-targets it;
// an approach that takes too long gives up. Nothing found ends the state (Patrol).

import * as THREE from 'three';
import { CreatureConfig } from '../config.js';
import { flat } from '../util.js';
import * as Sniff from './sniff.js';

export const Name = 'InvestigateNoise';
const TUNING = CreatureConfig.Investigate;
const LOOK_SECONDS = 1.4;
const ARRIVE = 3;
const SPOT_ARRIVE = 1.2;
const APPROACH_SECONDS = 30;
const SPOT_RADIUS = CreatureConfig.Search.Radius;

const runs = new WeakMap();

/**
 * @typedef {{kind: 'Look'|'Spot', position: THREE.Vector3, face: THREE.Vector3|null, seconds: number, spot?: string}} Step
 * @typedef {{id: string, front: import('../cframe.js').CFrame}} SpotRef
 */

/**
 * The search at `at`: a look back the way it came, then the nearest hiding spots.
 * @param {{at: THREE.Vector3, spots: SpotRef[], look: THREE.Vector3, max: number}} input
 * @returns {Step[]}
 */
export function searchPlan(input) {
  const steps = [];
  const fl = flat(input.look);
  const back = fl.length() > 1e-3 ? fl.normalize().negate() : new THREE.Vector3(0, 0, 1);
  steps.push({ kind: 'Look', position: input.at.clone(), face: back, seconds: LOOK_SECONDS });
  const near = [...input.spots].sort((a, b) => a.front.position.distanceTo(input.at) - b.front.position.distanceTo(input.at));
  for (const spot of near.slice(0, input.max)) {
    steps.push({ kind: 'Spot', position: spot.front.position, face: spot.front.lookVector.negate(), seconds: Sniff.SniffSeconds,
      spot: spot.id });
  }
  return steps;
}

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { investigation: null, phase: 'Approach', steps: [], index: 0, stage: 'Start', deadline: 0, approachUntil: 0,
      inspection: null };
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
  run.approachUntil = ctx.now() + APPROACH_SECONDS;
  if (ctx.mover.getMedium() === 'Floor') ctx.body.setPose('Biped');
  const goal = investigation ? investigation.position : ctx.body.getPosition();
  ctx.mover.goTo(goal, { arrive: ARRIVE });
}

function startSearch(ctx, run, at) {
  run.phase = 'Search';
  run.steps = searchPlan({ at, spots: ctx.hideSpotsNear(at, SPOT_RADIUS), look: ctx.body.getCFrame().lookVector, max: TUNING.Spots });
  run.index = 0;
  run.stage = 'Start';
  run.deadline = ctx.now() + ctx.random.nextNumber(TUNING.MinSeconds, TUNING.MaxSeconds);
}

function nextStep(ctx, run) {
  run.index += 1;
  run.stage = 'Start';
  run.inspection = null;
  if (ctx.mover.getMedium() === 'Floor') ctx.body.setPose('Biped');
}

function startHold(ctx, run, step) {
  run.stage = 'Hold';
  if (step.kind === 'Spot') ctx.body.setPose('Hunched');
  ctx.mover.hold(step.seconds, step.face);
  if (step.kind === 'Spot' && step.spot) run.inspection = Sniff.inspect(ctx, step.spot);
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
    const fresh = { position: ctx.floorPointNear(heard.position), rank: heard.rank, at: heard.at };
    ctx.investigation = fresh;
    begin(ctx, run, fresh);
    return;
  }
  const mover = ctx.mover;
  const busy = mover.busy();
  const status = mover.getStatus();
  if (run.phase === 'Approach') {
    if (ctx.now() > run.approachUntil) {
      ctx.stateDone = true;
      return;
    }
    if (busy || status === 'Moving') return;
    startSearch(ctx, run, status === 'Idle' && current ? current.position : ctx.body.getPosition());
    return;
  }
  if (ctx.now() > run.deadline) {
    if (!Sniff.waiting(ctx, run.inspection)) ctx.stateDone = true;
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
      mover.goTo(step.position, { arrive: SPOT_ARRIVE });
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
  if (Sniff.waiting(ctx, run.inspection)) return;
  if (busy) return;
  nextStep(ctx, run);
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  const run = runOf(ctx);
  run.inspection = null;
  if (ctx.mover.getMedium() === 'Floor') ctx.body.setPose('Biped');
  ctx.body.face(null);
  ctx.investigation = null;
}
