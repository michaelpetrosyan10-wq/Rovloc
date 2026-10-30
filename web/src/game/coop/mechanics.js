// mechanics.js: what a player does with their own body, shared with the squad. The page whose player did it applies it
// at once (it is their body: no waiting on the network) and tells the host, which passes it on to the other pages
// ({t: 'mech', k, d, a}); there the world's side of it is shown.
//
//   trap     sprung ('snap': spent everywhere, the jaws shut on the teammate's leg) or pried open ('free')
//   locker   torn open by the Creature on its occupant's page ('rip': smashed everywhere)
//   flask    thrown ('throw': its flight drawn everywhere, breaking where it hits; only the thrower's page clouds and
//            stuns, through the host's Creature)
//   floor    a floor objective's outcome decided on one page (Floor 2's acid flask: burnt the chain or missed)
// And the host's own shared world: a flask set out by Level 2's restock ('restock', host -> clients).

export class MechanicsNet {
  /** @param {import('./index.js').Coop} coop */
  constructor(coop) {
    this.coop = coop;
    this.game = coop.game;
    this.handlers = {
      mech: (from, msg) => this._onEvent(from, msg),
    };
  }

  /** This page's player did something the squad should see. */
  share(kind, data) {
    const coop = this.coop;
    if (!coop.active || !this.game.run) return;
    if (coop.isHost()) coop.broadcast({ t: 'mech', k: kind, d: data, a: coop.localId });
    else coop.toHost({ t: 'mech', k: kind, d: data });
  }

  /** Back compatible name for the traps (traps.js). */
  trapEvent(id, ev) {
    this.share('trap', { id, ev });
  }

  _onEvent(from, msg) {
    const coop = this.coop;
    if (!this.game.run) return;
    if (coop.isHost()) {
      if (msg.a !== undefined) return;
      const m = coop.squad.get(from);
      if (!m || !m.participant) return;
      this._apply(msg.k, msg.d || {}, from);
      for (const other of coop.squad.list()) {
        if (!other.local && other.id !== from) coop.send(other.id, { t: 'mech', k: msg.k, d: msg.d, a: from });
      }
      return;
    }
    if (msg.a !== coop.localId) this._apply(msg.k, msg.d || {}, msg.a);
  }

  _apply(kind, d, actor) {
    const g = this.game;
    if (kind === 'trap' && g.traps) {
      if (d.ev === 'snap') g.traps.remoteSnap(d.id);
      else if (d.ev === 'free') g.traps.remoteFree(d.id);
    } else if (kind === 'locker' && g.lockers) {
      if (d.ev === 'rip') g.lockers.remoteRip(d.id);
    } else if (kind === 'flask' && g.flasks) {
      if (d.ev === 'throw') g.flasks.remoteThrow(d);
      else if (d.ev === 'restock') g.flasks.spawnAt(d.level, d.m, d.id);
    } else if (kind === 'floor' && g.floors) {
      const f = g.floors.floor(d.level);
      if (f && f.onSharedEvent) f.onSharedEvent(d.name, d.data || {}, actor);
    }
  }
}
