// carry.js: what the player carries for the floor objective (fuses, keys, reagents, the coach's key, the valve wheel,
// the bolt cutters) and its HUD: one small chip per kind ("FUSE ×2"), bottom-left above the status bars on a keyboard
// or gamepad, under them top-left on touch. The acid flask rides the hand like a chemical flask (flasks.js) and gets a
// chip too while held. Carried items survive being downed and a grab; the run ending (death included) empties them.
// Shown while Alive or Downed in a run with the HUD visible, outside the Cutscene / Menu / Struggle contexts and under
// no Cutscene / Jumpscare lock; hidden inside a locker (the locker view owns the bottom of the screen).

import { S } from '../strings.js';
import { Palette, el } from '../ui/style.js';

const HIDDEN_CONTEXTS = new Set(['Cutscene', 'Menu', 'Struggle', 'Locker', 'Parachute']);
const HIDDEN_LOCKS = new Set(['Cutscene', 'Jumpscare']);
const FADE = 5;

export class Carry {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.game = game;
    this.env = game.env;
    /**
     * Co-op: each player carries their own (keyed by member id; '' played alone). The carrier is the player whose
     * action is being applied (coop.actor), else this page's own player.
     * @type {Map<string, {items: Map<string, number>, ids: Array<{kind: string, id: string}>, last: string|null}>}
     */
    this.bags = new Map();
    this.alpha = 0;
    this.shownKey = '';
    this.root = el('div', '', this.env.uiRoot());
    Object.assign(this.root.style, { position: 'absolute', left: '22px', bottom: '104px', display: 'none',
      flexDirection: 'column', alignItems: 'flex-start', gap: '4px', pointerEvents: 'none', zIndex: '9' });
  }

  /** Whose carry the calls below read and write. */
  _owner() {
    const coop = this.game.coop;
    if (!coop || !coop.active) return '';
    return coop.actor || coop.localId || '';
  }

  _bag(owner = this._owner()) {
    let bag = this.bags.get(owner);
    if (!bag) {
      bag = { items: new Map(), ids: [], last: null };
      this.bags.set(owner, bag);
    }
    return bag;
  }

  /** @type {Map<string, number>} kind -> count, in the order first carried (the current carrier's) */
  get items() {
    return this._bag().items;
  }

  /** Carries `n` more of a kind (Carry.<kind> names it). */
  add(kind, n = 1) {
    const bag = this._bag();
    bag.items.set(kind, (bag.items.get(kind) || 0) + n);
    bag.last = kind;
  }

  /** The item entity just added (the one picked up): it drops where its carrier dies or leaves. */
  noteEntity(entityId) {
    const bag = this._bag();
    if (bag.last && entityId) bag.ids.push({ kind: bag.last, id: entityId });
  }

  /** Uses `n` of a kind; false (nothing taken) when there are not that many. */
  take(kind, n = 1) {
    const bag = this._bag();
    const have = bag.items.get(kind) || 0;
    if (have < n) return false;
    if (have === n) bag.items.delete(kind);
    else bag.items.set(kind, have - n);
    for (let k = 0; k < n; k++) {
      const i = bag.ids.findIndex((e) => e.kind === kind);
      if (i >= 0) bag.ids.splice(i, 1);
    }
    return true;
  }

  count(kind) {
    return this.items.get(kind) || 0;
  }

  has(kind) {
    return this.count(kind) > 0;
  }

  clear() {
    this.bags.clear();
  }

  /** Empties a carrier's bag: the item entities they held ([{kind, id}]) to be dropped. */
  dropAll(owner) {
    const bag = this.bags.get(owner);
    if (!bag) return [];
    this.bags.delete(owner);
    return bag.ids;
  }

  /** What a carrier holds (kind -> count). */
  of(owner) {
    const bag = this.bags.get(owner);
    return bag ? bag.items : new Map();
  }

  /** The chips' text lines (the HUD and the checks). */
  lines() {
    const out = [];
    for (const [kind, n] of this.items) {
      const label = S(`Carry.${kind}`);
      out.push(n > 1 ? S('Carry.Count', label, n) : label);
    }
    const held = this.game.flasks && this.game.flasks.held;
    if (held && held.objective) out.push(S('Carry.AcidFlask'));
    return out;
  }

  _visible() {
    const g = this.game;
    const life = g.life ? g.life.state : 'Lobby';
    return g.live() && (life === 'Alive' || life === 'Downed') && this.env.hudVisible() &&
      !HIDDEN_CONTEXTS.has(this.env.context()) && !HIDDEN_LOCKS.has(g.controlLock()) &&
      !(g.onboarding && g.onboarding.busy());
  }

  frame(dt) {
    const lines = this.lines();
    const want = lines.length && this._visible() ? 1 : 0;
    this.alpha += Math.sign(want - this.alpha) * Math.min(Math.abs(want - this.alpha), FADE * dt);
    if (this.alpha <= 0.001) {
      this.root.style.display = 'none';
      return;
    }
    const touch = this.env.device() === 'Touch';
    // touch: the status bars sit top-left from 104 px (three meters and the pips, about 64 px tall)
    this.root.style.bottom = touch ? 'auto' : '104px';
    this.root.style.top = touch ? '176px' : 'auto';
    this.root.style.display = 'flex';
    this.root.style.opacity = String(this.alpha);
    const key = lines.join('|');
    if (key === this.shownKey) return;
    this.shownKey = key;
    this.root.textContent = '';
    for (const line of lines) {
      const chip = el('div', 'rg-panel rg-caps', this.root, line);
      Object.assign(chip.style, { padding: '4px 9px', fontSize: '12px', color: Palette.Amber, letterSpacing: '0.16em',
        borderRadius: '4px' });
    }
  }
}
