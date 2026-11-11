// events.js: the co-op message registry (docs/design/game-spec-v2.md 3.7; RemoteRegistry on Roblox). Every message a
// feature adds is registered here by that feature's own module, with its rules, so a later package adds its messages
// in one place and the room applies the same checks to all of them:
//
//   to        who handles it: 'host' (a client's intent; the host checks and decides), 'client' (the host's word to
//             a page; the host's own copy, sent through Coop.everyone / toMember, counts as the host's), 'any'
//   phases    the match phases it is taken in (null: any)
//   life      for an intent: the life states its sender may be in (the host's squad record; null: any)
//   rate      for an intent: at most this many a second from one sender (a burst of the same allowed), the rest dropped
//   validate  (msg) -> boolean: the shape (types, ranges) of its fields; a message that fails is dropped
//   handle    (from, msg): what it does
//
// Messages registered nowhere go to the modules' own handler tables (the ones that came before the registry).

/**
 * @typedef {{to: 'host'|'client'|'any', phases?: string[]|null, life?: string[]|null, rate?: number,
 *   validate?: (msg: any) => boolean, handle: (from: string, msg: any) => void}} EventSpec
 */

export class EventRegistry {
  /** @param {import('./index.js').Coop} coop */
  constructor(coop) {
    this.coop = coop;
    /** @type {Map<string, EventSpec>} */
    this.specs = new Map();
    /** @type {Map<string, {at: number, count: number}>} sender|type -> its window */
    this.windows = new Map();
    /** messages dropped by a rule, by type (tests read it) */
    this.dropped = new Map();
  }

  /**
   * Registers message type `type`. A type is registered once.
   * @param {string} type
   * @param {EventSpec} spec
   */
  register(type, spec) {
    if (this.specs.has(type)) throw new Error(`co-op message ${type} is registered twice`);
    if (typeof spec.handle !== 'function') throw new Error(`co-op message ${type} has no handler`);
    this.specs.set(type, spec);
  }

  has(type) {
    return this.specs.has(type);
  }

  _drop(type) {
    this.dropped.set(type, (this.dropped.get(type) || 0) + 1);
    return true;
  }

  /** Whether `from` may send another `type` now (a one-second window of `rate` messages). */
  _withinRate(from, type, rate) {
    const key = `${from}|${type}`;
    const now = performance.now() / 1000;
    const w = this.windows.get(key);
    if (!w || now - w.at >= 1) {
      this.windows.set(key, { at: now, count: 1 });
      return true;
    }
    w.count += 1;
    return w.count <= rate;
  }

  /**
   * Handles `msg` from member `from` when its type is registered: true when the registry took it (handled or dropped),
   * false for a type it does not know.
   */
  dispatch(from, msg) {
    const spec = this.specs.get(msg.t);
    if (!spec) return false;
    const coop = this.coop;
    const own = from === coop.localId;
    if (spec.to === 'host' && !coop.isHost()) return this._drop(msg.t);
    if (spec.to === 'client' && !coop.isClient() && !own) return this._drop(msg.t);
    if (spec.to === 'client' && coop.isClient() && from !== coop.session.hostId) return this._drop(msg.t);
    if (spec.phases && !spec.phases.includes(coop.game.phase)) return this._drop(msg.t);
    if (spec.to === 'host' && !own) {
      const member = coop.squad.get(from);
      if (!member) return this._drop(msg.t);
      if (spec.life && !spec.life.includes(member.life)) return this._drop(msg.t);
      if (spec.rate && !this._withinRate(from, msg.t, spec.rate)) return this._drop(msg.t);
    }
    if (spec.validate && !spec.validate(msg)) return this._drop(msg.t);
    spec.handle(from, msg);
    return true;
  }

  /** The room closed: the rate windows start over. */
  reset() {
    this.windows.clear();
  }
}

/** A finite number. */
export const isNumber = (v) => typeof v === 'number' && Number.isFinite(v);

/** One of `options`. */
export const oneOf = (options) => (v) => options.includes(v);
