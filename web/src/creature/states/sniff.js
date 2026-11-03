// Sniff: the breath check at a hiding spot, shared by InvestigateNoise and Search. The Creature stands at the spot's
// front, hunched, and peeks in through the game's inspector hook (registerLockerInspector: lockers, barrels and
// cabinets alike): "Caught" is a ReachIn and a Locker jumpscare on the occupant, "HiddenSafe" and "Empty" move on;
// without a hook it only looks.

import { GameConfig } from '../config.js';

export const SniffSeconds = 1.6;
const INSPECT_TIMEOUT = GameConfig.BreathHoldMaxSeconds + 4;
const SPOT_REACH = 8;

/**
 * Starts the peek into `spot` (asynchronously: a hiding player's breath check takes a while).
 * @param {import('../service.js').Context} ctx @param {string} spot
 * @returns {{spot: string, started: number, verdict: string|null}|null}
 */
export function inspect(ctx, spot) {
  const inspector = ctx.lockerInspector();
  if (!inspector) return null;
  const inspection = { spot, started: ctx.now(), verdict: null };
  let pending;
  try {
    pending = Promise.resolve(inspector(spot));
  } catch (err) {
    pending = Promise.reject(err);
  }
  pending.then((verdict) => (verdict === 'Caught' || verdict === 'HiddenSafe' ? verdict : 'Empty'), () => 'Empty')
    .then((result) => {
      inspection.verdict = result;
      if (result !== 'Caught') return;
      const occupant = ctx.hideSpotOccupant(spot);
      const front = ctx.hideSpotFront(spot);
      const near = front !== null && front.position.distanceTo(ctx.body.getPosition()) <= SPOT_REACH;
      if (occupant && near) ctx.reachIn(occupant, spot);
    });
  return inspection;
}

/** Whether a running peek still holds the Creature at the spot. */
export function waiting(ctx, inspection) {
  return !!inspection && inspection.verdict === null && ctx.now() - inspection.started < INSPECT_TIMEOUT;
}
