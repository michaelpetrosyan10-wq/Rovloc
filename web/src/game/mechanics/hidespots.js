// hidespots.js: the rules every hiding spot shares (Tunnels §1.2 and §2.3): lockers, and the tunnel maps' barrels and
// steel cabinets. Pure and engine-free, so the creature sim tests them; lockers.js plays them (the door or lid, the
// camera behind the gap, the breath check, the co-op claims).
//
//   * Kinds. A hiding spot is an entity tagged Hideable with attribute HideKind 'Locker' | 'Barrel' | 'Cabinet' (a
//     missing HideKind is a Locker); today's lockers are tagged HideableLocker. hideSpotKind / isHideSpot read them.
//   * Fake-outs (DOORS' Jack). fakeoutSpots(seed, ids): about one spot in CreatureConfig.FakeoutOneIn (12) holds one,
//     seeded per run (every page agrees). FakeoutBudget: at most one per floor per player; once one has played, that
//     spot is an ordinary one again.
//   * The stay limit (DOORS' Hide). StayClock: a spot used for KickOutWarning (35 s) gets the warning knock; at
//     KickOutSeconds (45 s) the hider is shoved out, unhurt. A breath check in progress holds the shove until it ends.
//   * The pull-out (THRESHOLD's throw). canPull: a teammate on foot within PullReach of a spot a squadmate hides in
//     may hold PullSeconds on it to drag them out (the hider lands beside the puller; the Creature, if it was waiting
//     there, is startled and takes no catch for it).

import { CreatureConfig } from '../../creature/config.js';
import { seededRandom } from '../util.js';

export const HideKinds = Object.freeze(['Locker', 'Barrel', 'Cabinet']);
export const KickOutWarning = CreatureConfig.Hiding.KickOutWarning;
export const KickOutSeconds = CreatureConfig.Hiding.KickOutSeconds;
export const PullSeconds = 1.2;
export const PullReach = 7;
/** Sprinting this recently before getting in makes it a hurried (louder) entry. */
export const HurriedWindow = 1;

/** Whether an exported entity is a hiding spot. */
export function isHideSpot(entity) {
  if (!entity) return false;
  const tags = entity.tags || [];
  return tags.includes('Hideable') || tags.includes('HideableLocker') || HideKinds.includes(entity.type);
}

/** The kind of a hiding spot entity ('Locker' when it does not say). */
export function hideSpotKind(entity) {
  const a = (entity && entity.attributes) || {};
  if (HideKinds.includes(a.HideKind)) return a.HideKind;
  return entity && HideKinds.includes(entity.type) ? entity.type : 'Locker';
}

/** The hiding spots of world.json (all levels, or one), in id order. */
export function hideSpotEntities(meta, level) {
  return (meta.entities || []).filter((e) => isHideSpot(e) && (!level || e.level === level))
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

/**
 * The run's fake-out spots: each id rolls its own seeded stream (so adding a spot elsewhere never reshuffles the rest).
 * @param {number} seed the run seed @param {string[]} ids @returns {Set<string>}
 */
export function fakeoutSpots(seed, ids) {
  const out = new Set();
  for (const id of ids) if (seededRandom(seed, `Fakeout|${id}`).next() < 1 / CreatureConfig.FakeoutOneIn) out.add(id);
  return out;
}

/** At most one fake-out per floor per player (one budget per player). */
export class FakeoutBudget {
  constructor() {
    this.floors = new Set();
  }

  /** Spends the floor's fake-out: true when it had not been used yet. */
  take(level) {
    if (!level || this.floors.has(level)) return false;
    this.floors.add(level);
    return true;
  }

  has(level) {
    return !this.floors.has(level);
  }

  reset() {
    this.floors.clear();
  }
}

/** The time in a hiding spot: the warning at KickOutWarning, the shove at KickOutSeconds (held while a check runs). */
export class StayClock {
  /** @param {number} since when they got in */
  constructor(since) {
    this.since = since;
    this.warned = false;
    this.out = false;
  }

  /**
   * What happens at `now`: 'Warn' (once), 'KickOut' (once) or null.
   * @param {number} now @param {boolean} checking a breath check runs (the shove waits for it)
   */
  step(now, checking) {
    if (this.out) return null;
    const held = now - this.since;
    if (!this.warned && held >= KickOutWarning) {
      this.warned = true;
      return 'Warn';
    }
    if (held >= KickOutSeconds && !checking) {
      this.out = true;
      return 'KickOut';
    }
    return null;
  }
}

/**
 * Whether `puller` may drag the hider out of a spot.
 * @param {{alive: boolean, onFoot: boolean, distance: number, occupiedByOther: boolean, hiding: boolean}} check
 */
export function canPull(check) {
  return check.alive && check.onFoot && !check.hiding && check.occupiedByOther && check.distance <= PullReach;
}

/** Whether getting in was hurried (the louder HideEnterHurried noise). */
export function hurried(lastSprintAt, now) {
  return now - lastSprintAt <= HurriedWindow;
}
