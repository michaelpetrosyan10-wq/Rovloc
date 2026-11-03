// Teleport (Tunnels §2.3, THRESHOLD's jumpscare engine). Every minute or two, when nobody has been seen for
// UnseenSeconds and it is only stalking, the Creature relocates next to a player:
//
//   * the service picks the target (weighted: isolated from the squad, loud lately, not targeted last time) and the
//     spot (12..24 studs of walking from them, behind them in the tunnel they came through 60 % of the time, else round
//     the next corner ahead; out of every player's view, never within 12 studs of anyone, never in a crawlway or in
//     the keep-room they stand in), then runs the warp: FadeOut where it is, hidden, placed, the WarningSeconds
//     warning (the lights near the spot flicker, the target's torch stutters, a static hiss rises), the spot checked
//     again (in view now: another spot, another warning), FadeIn, and the Stare: StareSeconds standing still, staring.
//     A target who turns and looks at it then gets the reveal scare (no damage).
//   * Then it stalks the target at the Teleport pace for StalkSeconds; meanwhile sight alone does not start a chase,
//     only a held stare or the target coming within StalkNear (the service's summary). Then it patrols.
// Never during a chase, a search, a hiding response or a scripted beat; never within AfterCatch of a catch or of
// someone going down; never during an objective's survive countdown or the roof's finale chase (the game's
// teleportBlocked hook); the first on a floor no sooner than its grace + FirstAfterGrace.

import { CreatureConfig } from '../config.js';

export const Name = 'Teleport';
const T = CreatureConfig.Teleport;
const REGOAL_SECONDS = 1;
const ISOLATED_WEIGHT = 2;
const LOUD_WEIGHT = 1.6;
const FRESH_WEIGHT = 1.5;
const BEHIND_TRAIL = 6;
const AHEAD_DOT = 0.25;

const runs = new WeakMap();

/** A target's weight: isolated from teammates, loud lately, and not the last one picked all weigh more. */
export function targetWeight({ isolated, loud, lastTarget }) {
  return (isolated ? ISOLATED_WEIGHT : 1) * (loud ? LOUD_WEIGHT : 1) * (lastTarget ? 1 : FRESH_WEIGHT);
}

/** The item a roll in [0, 1) lands on, by weight (null for an empty list). */
export function pickWeighted(items, weights, roll) {
  let total = 0;
  for (const w of weights) total += Math.max(0, w);
  if (!(total > 0)) return items.length ? items[0] : null;
  let at = roll * total;
  for (let i = 0; i < items.length; i++) {
    at -= Math.max(0, weights[i]);
    if (at < 0) return items[i];
  }
  return items[items.length - 1];
}

/**
 * Where a candidate lies for a target: 'Behind' (on the way they came: near their trail of the last seconds, not in
 * front of their look), 'Ahead' (in front of their travel or look) or 'Side'.
 * @param {import('three').Vector3} point floor point
 * @param {import('three').Vector3} target their root
 * @param {import('three').Vector3[]} trail where they were (oldest first), the last second left out
 * @param {import('three').Vector3} look their look direction
 * @param {import('three').Vector3|null} travel their recent travel direction (flat), or null standing still
 */
export function classify(point, target, trail, look, travel) {
  const dx = point.x - target.x;
  const dz = point.z - target.z;
  const len = Math.hypot(dx, dz) || 1;
  const lookDot = (look.x * dx + look.z * dz) / (len * (Math.hypot(look.x, look.z) || 1));
  let nearTrail = false;
  for (const p of trail) {
    if (Math.hypot(p.x - point.x, p.z - point.z) <= BEHIND_TRAIL) {
      nearTrail = true;
      break;
    }
  }
  if (nearTrail && lookDot < AHEAD_DOT) return 'Behind';
  const ahead = travel ? (travel.x * dx + travel.z * dz) / len : lookDot;
  if (ahead > AHEAD_DOT) return 'Ahead';
  return lookDot < -AHEAD_DOT ? 'Behind' : 'Side';
}

function runOf(ctx) {
  let run = runs.get(ctx);
  if (!run) {
    run = { plan: null, phase: 'Warp', stalkUntil: 0, nextGoalAt: 0 };
    runs.set(ctx, run);
  }
  return run;
}

/** Whether the stalk after the stare runs (the summary's sight rule). @param {any} ctx */
export function stalking(ctx) {
  const run = runs.get(ctx);
  return !!run && run.plan !== null;
}

/** @param {import('../service.js').Context} ctx */
export function enter(ctx) {
  const run = runOf(ctx);
  run.plan = ctx.teleportPlan;
  run.phase = 'Warp';
  run.nextGoalAt = 0;
  if (!run.plan || !ctx.startTeleport(run.plan)) {
    run.plan = null;
    ctx.stateDone = true;
  }
}

/** @param {import('../service.js').Context} ctx */
export function update(ctx) {
  const run = runOf(ctx);
  const plan = run.plan;
  if (!plan) {
    ctx.stateDone = true;
    return;
  }
  if (ctx.warping()) return;
  const now = ctx.now();
  if (run.phase === 'Warp') {
    run.phase = 'Stalk';
    run.stalkUntil = now + T.StalkSeconds;
    const speed = ctx.speedOf(Name);
    ctx.mover.setSpeed(speed);
    ctx.body.setWalkSpeed(speed);
    ctx.mover.setRepathInterval(CreatureConfig.Repath.PatrolInterval / 2);
    ctx.setTarget(plan.target);
  }
  const target = plan.target;
  if (now > run.stalkUntil || !ctx.playing(target) || ctx.isHiding(target) || ctx.inVent(target)) {
    ctx.stateDone = true;
    return;
  }
  if (now < run.nextGoalAt || ctx.mover.busy()) return;
  run.nextGoalAt = now + REGOAL_SECONDS;
  const root = ctx.rootOf(target);
  if (root) ctx.mover.goTo(ctx.floorPointNear(root), { arrive: 2 });
}

/** @param {import('../service.js').Context} ctx */
export function exit(ctx) {
  const run = runOf(ctx);
  run.plan = null;
  ctx.teleportPlan = null;
  ctx.body.face(null);
}
