// Search (Tunnels §2.3): a chase lost its quarry (or someone slipped away from a hiding spot it was watching). For
// 12..18 s the Creature checks the hiding spots within Search.Radius of the last seen point, in a random order,
// sniffing at each (the breath check, states/sniff.js: lockers, barrels and cabinets alike); with none left it turns
// on the spot, listening, until the time is up. Then it stalks on (Patrol). Seeing someone (WallChase), a High noise
// (InvestigateNoise) or seeing someone hide (HidingResponse) breaks it off (the brain).

import { CreatureConfig } from '../config.js';
import * as Sniff from './sniff.js';

export const Name = 'Search';
const TUNING = CreatureConfig.Search;
const ARRIVE = 2.5;
const SPOT_ARRIVE = 1.2;
const LOOK_SECONDS = 1.2;
const APPROACH_SECONDS = 15;

const runs = new WeakMap();

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { at: null, phase: 'Approach', spots: [], index: 0, stage: 'Start', deadline: 0, approachUntil: 0, inspection: null,
      turn: 0 };
    runs.set(ctx, run);
  }
  return run;
}

/** A seeded shuffle (Fisher-Yates over ctx.random). */
export function shuffled(list, random) {
  const out = list.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(random.nextNumber() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = runOf(ctx);
  const speed = ctx.speedOf(Name);
  ctx.mover.setSpeed(speed);
  ctx.body.setWalkSpeed(speed);
  ctx.mover.setRepathInterval(CreatureConfig.Repath.PatrolInterval / 2);
  ctx.body.face(null);
  ctx.body.setPose('Biped');
  const at = ctx.searchFrom ? ctx.searchFrom.clone() : ctx.body.getPosition().clone();
  run.at = at;
  run.phase = 'Approach';
  run.index = 0;
  run.stage = 'Start';
  run.inspection = null;
  run.turn = 0;
  run.approachUntil = ctx.now() + APPROACH_SECONDS;
  run.deadline = ctx.now() + ctx.random.nextNumber(TUNING.MinSeconds, TUNING.MaxSeconds);
  run.spots = shuffled(ctx.hideSpotsNear(at, TUNING.Radius), ctx.random).slice(0, TUNING.Spots);
  ctx.mover.goTo(at, { arrive: ARRIVE });
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runOf(ctx);
  const mover = ctx.mover;
  const busy = mover.busy();
  const status = mover.getStatus();
  const now = ctx.now();
  if (now > run.deadline) {
    if (!Sniff.waiting(ctx, run.inspection)) ctx.stateDone = true;
    return;
  }
  if (run.phase === 'Approach') {
    if ((busy || status === 'Moving') && now < run.approachUntil) return;
    run.phase = 'Spots';
    return;
  }
  const spot = run.spots[run.index];
  if (!spot) {
    // nothing left to check: it turns where it stands, listening
    if (busy) return;
    run.turn += 1;
    const look = ctx.body.getCFrame().lookVector.clone();
    const a = (run.turn % 2 === 0 ? 1 : -1) * 2.1;
    mover.hold(LOOK_SECONDS, look.set(look.x * Math.cos(a) - look.z * Math.sin(a), 0, look.x * Math.sin(a) + look.z * Math.cos(a)));
    return;
  }
  if (run.stage === 'Start') {
    if (busy) return;
    run.stage = 'Travel';
    mover.goTo(spot.front.position, { arrive: SPOT_ARRIVE });
    return;
  }
  if (run.stage === 'Travel') {
    if (busy || status === 'Moving') return;
    if (status === 'Failed' || status === 'Stuck') {
      run.index += 1;
      run.stage = 'Start';
      return;
    }
    run.stage = 'Hold';
    ctx.body.setPose('Hunched');
    mover.hold(Sniff.SniffSeconds, spot.front.lookVector.clone().negate());
    run.inspection = Sniff.inspect(ctx, spot.id);
    return;
  }
  if (Sniff.waiting(ctx, run.inspection)) return;
  if (busy) return;
  run.index += 1;
  run.stage = 'Start';
  run.inspection = null;
  ctx.body.setPose('Biped');
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  const run = runOf(ctx);
  run.inspection = null;
  ctx.body.setPose('Biped');
  ctx.body.face(null);
  ctx.searchFrom = null;
}
