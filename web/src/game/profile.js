// profile.js: saved progress (MatchAndDataService's PlayerData + DataMigration) in the browser's localStorage, through
// the engine's save blob (key "profile"). Schema v2 (docs/design/game-spec-v2.md 4.10):
//   { v = 2, Escapes = 0, SurvivalCredits = 0, EndingsSeen = { Sunrise?, Fall? }, BestTimeSunrise = { Standard?,
//     Nightmare? }, PerkStock = {}, LastRunId = "" }
// Escapes stays, the count of runs that saw the Sunrise (old saves' escapes count as having seen it). The migration
// from v1: EndingsSeen.Sunrise from Escapes; v1's BestTime is not carried over (it timed the four-level school, the
// Sunrise's time runs from the Basement to the wheels up). Reads are sanitized (lenient: every field coerced into
// range, unknown fields dropped); a record from a newer build is read-only for the session. Rewards are idempotent
// through LastRunId. Settings (incl. the walkthrough and hint flags) live in the engine's settings blob, as the Roblox
// game keeps them in its Settings field.

import { Difficulties, GameConfig, MaxPerkStock, PerkIds, Perks } from './config.js';
import { Signal } from './util.js';

export const SCHEMA_VERSION = 2;
const ENDINGS = ['Sunrise', 'Fall'];
const MAX_CREDITS = 1_000_000_000;
const MAX_ESCAPES = 1_000_000_000;
const MAX_STOCK = 9_999;
const MAX_RUN_ID_LENGTH = 64;
const MAX_BEST_TIME = 7 * 24 * 3600;
const BEST_TIME_PRECISION = 100;
const KEY = 'profile';

/**
 * @typedef {{v: number, Escapes: number, SurvivalCredits: number, EndingsSeen: {Sunrise?: boolean, Fall?: boolean},
 *   BestTimeSunrise: {Standard?: number, Nightmare?: number}, PerkStock: Record<string, number>, LastRunId: string}}
 *   PlayerData
 */

/** @returns {PlayerData} */
export function defaults() {
  return { v: SCHEMA_VERSION, Escapes: 0, SurvivalCredits: 0, EndingsSeen: {}, BestTimeSunrise: {}, PerkStock: {}, LastRunId: '' };
}

function whole(value, max) {
  return typeof value === 'number' && Number.isFinite(value) ? Math.min(max, Math.max(0, Math.floor(value))) : 0;
}

/** DataMigration.sanitize */
export function sanitize(raw) {
  const out = defaults();
  if (!raw || typeof raw !== 'object') return out;
  out.Escapes = whole(raw.Escapes, MAX_ESCAPES);
  out.SurvivalCredits = whole(raw.SurvivalCredits, MAX_CREDITS);
  if (raw.EndingsSeen && typeof raw.EndingsSeen === 'object') {
    for (const e of ENDINGS) if (raw.EndingsSeen[e] === true) out.EndingsSeen[e] = true;
  }
  if (raw.BestTimeSunrise && typeof raw.BestTimeSunrise === 'object') {
    for (const d of Difficulties) {
      const t = raw.BestTimeSunrise[d];
      if (typeof t === 'number' && Number.isFinite(t) && t > 0 && t <= MAX_BEST_TIME) out.BestTimeSunrise[d] = t;
    }
  }
  if (raw.PerkStock && typeof raw.PerkStock === 'object') {
    for (const id of PerkIds) {
      const n = whole(raw.PerkStock[id], MAX_STOCK);
      if (n > 0) out.PerkStock[id] = n;
    }
  }
  out.LastRunId = typeof raw.LastRunId === 'string' ? raw.LastRunId.slice(0, MAX_RUN_ID_LENGTH) : '';
  return out;
}

/** DataMigration.migrate: [data, status] with status New | Current | Migrated | Future | Corrupt. */
export function migrate(raw) {
  if (raw === undefined || raw === null) return [defaults(), 'New'];
  if (typeof raw !== 'object') return [defaults(), 'Corrupt'];
  const v = raw.v === undefined ? 0 : raw.v;
  if (typeof v !== 'number' || !Number.isInteger(v) || v < 0) return [defaults(), 'Corrupt'];
  if (v > SCHEMA_VERSION) return [sanitize(raw), 'Future'];
  if (v === SCHEMA_VERSION) return [sanitize(raw), 'Current'];
  // v0 / v1 -> v2: an escape of the old run counts as the Sunrise seen; its best time timed another run
  const stepped = { ...raw, v: SCHEMA_VERSION, BestTimeSunrise: {},
    EndingsSeen: { Sunrise: whole(raw.Escapes, MAX_ESCAPES) > 0 } };
  return [sanitize(stepped), 'Migrated'];
}

/** MatchAndDataService.rewardFor: credits per floor sealed + the escape bonus. */
export function rewardFor(escaped, floorsCleared) {
  const floors = Number.isFinite(floorsCleared) ? Math.max(0, Math.floor(floorsCleared)) : 0;
  return GameConfig.CreditsPerLevelCleared * floors + (escaped ? GameConfig.CreditsEscapeBonus : 0);
}

/**
 * MatchAndDataService.applyReward: pays a run once (LastRunId).
 * @param {PlayerData} data
 * @param {{runId: string, credits: number, escaped: boolean, difficulty: string, time?: number}} reward
 */
export function applyReward(data, reward) {
  const runId = reward.runId.slice(0, MAX_RUN_ID_LENGTH);
  if (runId === '' || data.LastRunId === runId) return { applied: false, newBest: false };
  data.SurvivalCredits = Math.min(data.SurvivalCredits + Math.max(0, reward.credits), MAX_CREDITS);
  let newBest = false;
  if (reward.escaped) {
    data.Escapes += 1;
    data.EndingsSeen.Sunrise = true;
    const t = reward.time;
    if (t && Number.isFinite(t) && t > 0) {
      const rounded = Math.max(1 / BEST_TIME_PRECISION, Math.round(t * BEST_TIME_PRECISION) / BEST_TIME_PRECISION);
      const best = data.BestTimeSunrise[reward.difficulty];
      if (best === undefined || rounded < best) {
        data.BestTimeSunrise[reward.difficulty] = rounded;
        newBest = true;
      }
    }
  }
  data.LastRunId = runId;
  return { applied: true, newBest };
}

export class Profile {
  /** @param {import('./env.js').Env} env */
  constructor(env) {
    this.env = env;
    const [data, status] = migrate(env.saveGet(KEY, null));
    /** @type {PlayerData} */
    this.data = data;
    this.status = status;
    /** Read-only for the session (a record from a newer build or a corrupt value is never written back). */
    this.readOnly = status === 'Future' || status === 'Corrupt';
    /** Equipped perks (Player.Loadout: kept for the session, like the Roblox attribute). @type {string[]} */
    this.loadout = [];
    /** @type {Signal<[]>} */
    this.changed = new Signal();
    if (status === 'New' || status === 'Migrated') this._write();
  }

  get credits() {
    return this.data.SurvivalCredits;
  }

  get escapes() {
    return this.data.Escapes;
  }

  /** The best Sunrise time on `difficulty` (seconds), or undefined. */
  bestTime(difficulty) {
    return this.data.BestTimeSunrise[difficulty];
  }

  stock(perk) {
    return this.data.PerkStock[perk] || 0;
  }

  /** Whether saves reach the browser's storage. */
  persistent() {
    return !this.readOnly && this.env.savePersistent();
  }

  /**
   * MatchAndDataService.Update: hands `mutate` a draft; true commits it (validated), false discards it.
   * @param {(draft: PlayerData) => boolean} mutate
   */
  update(mutate) {
    if (this.readOnly) return false;
    const draft = JSON.parse(JSON.stringify(this.data));
    let ok = false;
    try {
      ok = mutate(draft) === true;
    } catch (err) {
      console.error('[profile] update failed', err);
      return false;
    }
    if (!ok) return false;
    if (!valid(draft)) {
      console.warn('[profile] refused an invalid commit');
      return false;
    }
    this.data = draft;
    this._write();
    this.changed.fire();
    return true;
  }

  _write() {
    if (this.readOnly) return;
    this.env.saveSet(KEY, this.data);
    this.env.saveFlush();
  }

  // ---------------------------------------------------------------------------------------------------- perks

  /** PerkShopService.Purchase: one unit for its cost, inside one Update. Returns [ok, reasonKey]. */
  purchase(perk) {
    const spec = Perks[perk];
    if (!spec) return [false, 'Lobby.PurchaseFailed'];
    if (this.readOnly) return [false, 'Lobby.PurchaseFailed'];
    if (this.credits < spec.cost) return [false, 'Lobby.NotEnoughCredits'];
    if (this.stock(perk) >= MaxPerkStock) return [false, 'Lobby.StockFull'];
    const ok = this.update((d) => {
      if (d.SurvivalCredits < spec.cost || (d.PerkStock[perk] || 0) >= MaxPerkStock) return false;
      d.SurvivalCredits -= spec.cost;
      d.PerkStock[perk] = (d.PerkStock[perk] || 0) + 1;
      return true;
    });
    return ok ? [true, 'Lobby.Purchased'] : [false, 'Lobby.PurchaseFailed'];
  }

  /** Equip / unequip (a perk needs an owned unit; one of each at most). */
  setEquipped(perk, on) {
    if (!Perks[perk]) return [false, 'Lobby.PurchaseFailed'];
    if (on) {
      if (this.stock(perk) < 1) return [false, 'Lobby.NoStock'];
      if (!this.loadout.includes(perk)) this.loadout = PerkIds.filter((id) => id === perk || this.loadout.includes(id));
    } else {
      this.loadout = this.loadout.filter((id) => id !== perk);
    }
    this.changed.fire();
    return [true, null];
  }

  /** The lobby opening again drops equipped perks no longer owned. */
  trimLoadout() {
    const before = this.loadout.length;
    this.loadout = this.loadout.filter((id) => this.stock(id) >= 1);
    if (this.loadout.length !== before) this.changed.fire();
  }

  /** Deploy: one stock unit of each equipped perk is consumed; perks without stock are dropped. Returns the kit. */
  consumeLoadout() {
    const equipped = this.loadout.slice();
    if (!equipped.length) return [];
    let taken = [];
    const ok = this.update((d) => {
      taken = [];
      for (const perk of equipped) {
        const n = d.PerkStock[perk] || 0;
        if (n >= 1) {
          d.PerkStock[perk] = n - 1;
          if (d.PerkStock[perk] === 0) delete d.PerkStock[perk];
          taken.push(perk);
        }
      }
      return taken.length > 0;
    });
    if (!ok) taken = this.readOnly ? equipped.filter((p) => this.stock(p) >= 1) : [];
    if (taken.length !== equipped.length) this.loadout = taken.slice();
    return taken;
  }

  /** Dev: set the credits. */
  setCredits(n) {
    this.update((d) => {
      d.SurvivalCredits = whole(n, MAX_CREDITS);
      return true;
    });
  }
}

/** DataMigration.validate (strict). */
function valid(d) {
  const int = (v, max) => Number.isInteger(v) && v >= 0 && v <= max;
  if (!int(d.Escapes, MAX_ESCAPES) || !int(d.SurvivalCredits, MAX_CREDITS)) return false;
  for (const [k, v] of Object.entries(d.PerkStock)) if (!Perks[k] || !int(v, MAX_STOCK)) return false;
  for (const [k, v] of Object.entries(d.BestTimeSunrise)) {
    if (!Difficulties.includes(k) || !(typeof v === 'number' && v > 0 && v <= MAX_BEST_TIME)) return false;
  }
  for (const [k, v] of Object.entries(d.EndingsSeen)) if (!ENDINGS.includes(k) || v !== true) return false;
  return typeof d.LastRunId === 'string' && d.LastRunId.length <= MAX_RUN_ID_LENGTH;
}
