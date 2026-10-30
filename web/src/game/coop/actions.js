// actions.js: the prompts of a co-op run (InteractionService on the host). Every prompt the game adds goes through
// env.addPrompt, which hands it here (env.promptHook); its `net` policy decides what a trigger does:
//
//   'local' (the default)  this page only: the lobby terminals, a locked door's rattle, the trapped player's own pry.
//   'world'                shared world state (the objectives' items and stations, the vent grates, the floodlights):
//                          the page that pressed it asks the host ({t: 'act', k, ph}); the host checks the actor is
//                          in the run, alive and within reach of the prompt (their last pose) and sends it to every
//                          page, its own included ({t: 'act', k, ph, a}); each page then runs the prompt's own
//                          callback with `coop.actor` set to the actor, so the same code applies the same change
//                          everywhere (the carry and game.alive() read the actor while it runs). Holds replicate their
//                          begin ('b') and end ('e') too, so a working hold's sound, noise and progress run on every
//                          page.
//   'claim'                something one player takes for themselves (a battery, a flask, a locker, a parachute
//                          pack): the host grants it to the first asker ({t: 'claimed', k, a}); the taker's page runs
//                          the callback, every other page runs the prompt's `netRemote(member)` (by default the prompt
//                          is switched off for good). `netRelease` frees it again ({t: 'unclaimed'}, a locker left).
//
// Keys. A prompt's key is its entity, attachment, action text and anchor, plus a count among identical ones, from the
// run's start: every page builds the run's prompts in the same order from the same plan, so keys match across pages.
// The key carries the run id, so nothing from another run is ever applied.

import { C } from './strings.js';

const REACH_SLACK = 7;

export class Actions {
  /** @param {import('./index.js').Coop} coop */
  constructor(coop) {
    this.coop = coop;
    this.game = coop.game;
    /** @type {Map<string, {spec: any, raw: any, entry: any, policy: string, key: string}>} */
    this.prompts = new Map();
    /** @type {Map<string, number>} signature -> count */
    this.counts = new Map();
    /** @type {Map<string, string>} key -> member id holding the claim */
    this.claims = new Map();
    /** the run id the keys belong to */
    this.generation = '';
    this.handlers = {
      act: (from, msg) => this._onAct(from, msg),
      claim: (from, msg) => this._onClaim(from, msg),
      claimed: (from, msg) => this._onClaimed(msg),
      unclaim: (from, msg) => this._onUnclaim(from, msg),
      unclaimed: (from, msg) => this._onUnclaimed(msg),
      deny: (from, msg) => this._onDeny(msg),
    };
    this.game.env.promptHook = (spec, rawSpec, entry) => this.wrap(spec, rawSpec, entry);
  }

  beginRun(run) {
    this.prompts.clear();
    this.counts.clear();
    this.claims.clear();
    this.generation = run.runId;
  }

  endRun() {
    this.prompts.clear();
    this.counts.clear();
    this.claims.clear();
  }

  sessionEnding() {
    this.claims.clear();
  }

  _signature(spec) {
    let anchor = '';
    const p = spec.position;
    if (p && typeof p !== 'function' && Number.isFinite(p.x)) anchor = `${Math.round(p.x)},${Math.round(p.y)},${Math.round(p.z)}`;
    return `${spec.entity || ''}|${spec.attachment || ''}|${spec.action || 'Interact'}|${spec.text || ''}|${anchor}`;
  }

  /**
   * env.addPrompt's hook: registers the prompt and returns the spec the engine gets (callbacks wrapped).
   * @param {any} spec the game's spec
   * @param {any} rawSpec the spec as env passes it to the engine
   * @param {{raw: any}} entry env's record (entry.raw is the engine handle once added)
   */
  wrap(spec, rawSpec, entry) {
    const policy = spec.net === 'world' || spec.net === 'claim' ? spec.net : 'local';
    if (policy === 'local') return rawSpec;
    const sig = this._signature(spec);
    const n = (this.counts.get(sig) || 0) + 1;
    this.counts.set(sig, n);
    const key = `${this.generation}#${sig}#${n}`;
    const record = { spec, rawSpec, entry, policy, key };
    this.prompts.set(key, record);
    const out = { ...rawSpec };
    const on = (phase, fn) => (handle) => {
      if (!this.coop.active || !this.game.run) {
        if (fn) fn(handle);
        return;
      }
      this._local(record, phase, fn, handle);
    };
    out.onTriggered = on('t', spec.onTriggered);
    if (spec.onHoldBegan) out.onHoldBegan = on('b', spec.onHoldBegan);
    if (spec.onHoldEnded) out.onHoldEnded = on('e', spec.onHoldEnded);
    return out;
  }

  /** This page's player pressed / held / let go of a networked prompt. */
  _local(record, phase, fn, handle) {
    const coop = this.coop;
    if (record.policy === 'claim') {
      // only the take is claimed; a claim prompt's hold runs on this page alone
      if (phase !== 't') {
        if (fn) fn(handle);
        return;
      }
      if (coop.isHost()) this._grant(record, coop.localId);
      else coop.toHost({ t: 'claim', k: record.key });
      return;
    }
    if (coop.isHost()) this._apply(record, phase, coop.localId);
    else coop.toHost({ t: 'act', k: record.key, ph: phase });
  }

  /** Host: whether `member` may use the prompt now (in the run, alive for a press, within reach). */
  _valid(record, member, phase) {
    if (!member) return false;
    if (phase !== 't' && phase !== 'b') return true;
    if (member.local) return true;
    if (!member.participant || member.life !== 'Alive') return false;
    const anchor = this._anchor(record);
    const pose = member.pose;
    if (!anchor || !pose) return !!pose;
    const reach = (record.spec.distance ?? 10) + REACH_SLACK;
    const dx = pose.x - anchor.x;
    const dy = pose.y - anchor.y;
    const dz = pose.z - anchor.z;
    return dx * dx + dy * dy + dz * dz <= reach * reach;
  }

  _anchor(record) {
    const p = record.rawSpec.position;
    if (typeof p === 'function') return p();
    return p || null;
  }

  /** Host: applies a world action everywhere. */
  _apply(record, phase, actor) {
    const member = this.coop.squad.get(actor);
    if (!this._valid(record, member, phase)) {
      if (member && !member.local) this.coop.send(actor, { t: 'deny', k: record.key });
      return;
    }
    this.coop.everyone({ t: 'act', k: record.key, ph: phase, a: actor });
  }

  /** A client's request (no actor yet: the host checks it) or the host's word (with its actor: every page applies it). */
  _onAct(from, msg) {
    const record = this.prompts.get(msg.k);
    if (!record) return;
    if (msg.a === undefined) {
      if (this.coop.isHost()) this._apply(record, msg.ph, from);
      return;
    }
    this.replay(record, msg.ph, msg.a);
  }

  /** Runs a prompt's callback as `actor` did it (every page, the host included). */
  replay(record, phase, actor) {
    const spec = record.spec;
    const fn = phase === 't' ? spec.onTriggered : phase === 'b' ? spec.onHoldBegan : spec.onHoldEnded;
    if (!fn) return;
    const coop = this.coop;
    const before = coop.actor;
    coop.actor = actor;
    try {
      fn(record.entry.raw);
    } catch (err) {
      console.error('[coop] prompt replay failed', record.key, err);
    } finally {
      coop.actor = before;
    }
    this.refreshLocal();
  }

  /** Host-side replay of a prompt by key (a client's action the host applies directly). */
  replayKey(key, phase, actor) {
    const record = this.prompts.get(key);
    if (record) this.replay(record, phase, actor);
  }

  /** After a replay: the floor's prompts re-read this page's own carry and state. */
  refreshLocal() {
    const floors = this.game.floors;
    if (!floors) return;
    for (const f of floors.floors.values()) if (f.active) f.refresh();
  }

  // ---------------------------------------------------------------------------------------------------- claims

  _grant(record, actor) {
    const member = this.coop.squad.get(actor);
    if (this.claims.has(record.key) || !this._valid(record, member, 't')) {
      if (member && !member.local) this.coop.send(actor, { t: 'deny', k: record.key, claim: true });
      else if (member) this._onDeny({ k: record.key, claim: true });
      return;
    }
    this.claims.set(record.key, actor);
    this.coop.everyone({ t: 'claimed', k: record.key, a: actor });
  }

  _onClaim(from, msg) {
    if (!this.coop.isHost()) return;
    const record = this.prompts.get(msg.k);
    if (record) this._grant(record, from);
  }

  _onClaimed(msg) {
    const record = this.prompts.get(msg.k);
    if (!record) return;
    this.claims.set(msg.k, msg.a);
    const coop = this.coop;
    const member = coop.squad.get(msg.a);
    if (coop.me && msg.a === coop.me.id) {
      const before = coop.actor;
      coop.actor = msg.a;
      try {
        if (record.spec.onTriggered) record.spec.onTriggered(record.entry.raw);
      } catch (err) {
        console.error('[coop] claim failed', record.key, err);
      } finally {
        coop.actor = before;
      }
      return;
    }
    if (typeof record.spec.netRemote === 'function') {
      try {
        record.spec.netRemote(member, record.entry.raw);
      } catch (err) {
        console.error('[coop] remote claim failed', record.key, err);
      }
    } else if (record.entry.raw) record.entry.raw.setEnabled(false);
  }

  /** Frees a claim this page holds (a locker left): every page runs the prompt's netRelease. */
  release(handleId) {
    for (const record of this.prompts.values()) {
      if (!record.entry.raw || record.entry.raw.id !== handleId) continue;
      if (!this.coop.active) return;
      if (this.coop.isHost()) this._free(record.key, this.coop.localId);
      else this.coop.toHost({ t: 'unclaim', k: record.key });
      return;
    }
  }

  _free(key, actor) {
    if (this.claims.get(key) !== actor) return;
    this.claims.delete(key);
    this.coop.everyone({ t: 'unclaimed', k: key, a: actor });
  }

  _onUnclaim(from, msg) {
    if (this.coop.isHost()) this._free(msg.k, from);
  }

  _onUnclaimed(msg) {
    this.claims.delete(msg.k);
    const record = this.prompts.get(msg.k);
    if (!record || (this.coop.me && msg.a === this.coop.me.id)) return;
    if (typeof record.spec.netRelease === 'function') record.spec.netRelease(this.coop.squad.get(msg.a), record.entry.raw);
  }

  /** Frees every claim a member held (they left the room). */
  releaseAll(memberId) {
    for (const [key, who] of [...this.claims]) if (who === memberId) this._free(key, memberId);
  }

  _onDeny(msg) {
    if (msg.claim) this.game.env.toast(C('Coop.ItemTaken'));
  }

  memberLeft(member) {
    if (this.coop.isHost()) this.releaseAll(member.id);
  }
}
