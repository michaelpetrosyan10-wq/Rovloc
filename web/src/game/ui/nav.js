// Menu navigation for every game screen on every device (the web stand-in for GuiService selection + the gamepad
// virtual cursor): a stack of focus groups, the top one live. Keyboard: arrows / Tab move, Enter / Space press,
// Escape backs out. Gamepad: d-pad or left stick move, A presses, B backs out, LB / RB page. Mouse and touch press
// the buttons themselves (pointer events), hover moves the focus. Glyph labels for the current device come from
// glyphFor (InputGlyphs.forAction).

const PAD_NAMES = ['A', 'B', 'X', 'Y', 'LB', 'RB', 'LT', 'RT', 'SELECT', 'START', 'L3', 'R3', '▲', '▼', '◀', '▶'];
const KEY_NAMES = {
  ShiftLeft: 'SHIFT', ControlLeft: 'CTRL', Space: 'SPACE', Tab: 'TAB', Escape: 'ESC', Mouse0: 'LMB', Enter: 'ENTER',
  ArrowUp: '↑', ArrowDown: '↓', ArrowLeft: '←', ArrowRight: '→',
};
const REPEAT_DELAY = 0.42;
const REPEAT_EVERY = 0.14;
const STICK = 0.55;

/** The short label of a key code. */
export function keyName(code) {
  if (KEY_NAMES[code]) return KEY_NAMES[code];
  if (code.startsWith('Key')) return code.slice(3);
  if (code.startsWith('Digit')) return code.slice(5);
  return code.toUpperCase();
}

/**
 * The glyph text for an action on a device ('KeyboardMouse' | 'Gamepad' | 'Touch').
 * @param {import('../env.js').Env} env
 */
export function glyphFor(env, action, device = env.device()) {
  const b = env.bindingOf(action);
  if (!b) return '?';
  if (device === 'Gamepad') return PAD_NAMES[b.gamepad[0]] || '?';
  if (device === 'Touch') return b.touch ? b.touch.label : 'TAP';
  return keyName(b.keyboard[0]);
}

/**
 * @typedef {Object} FocusItem
 * @property {HTMLElement} el
 * @property {() => void} press
 * @property {number} [row] grid row (items with the same row sit side by side)
 */

export class Nav {
  constructor() {
    /** @type {FocusGroup[]} */
    this.stack = [];
    this.pad = { buttons: [], dir: null, heldFor: 0, repeatAt: 0 };
    window.addEventListener('keydown', (e) => this._key(e), true);
  }

  /** Pushes a group (it becomes live). */
  push(group) {
    this.stack = this.stack.filter((g) => g !== group);
    this.stack.push(group);
    group.render();
  }

  remove(group) {
    this.stack = this.stack.filter((g) => g !== group);
  }

  top() {
    return this.stack.length ? this.stack[this.stack.length - 1] : null;
  }

  _key(e) {
    const g = this.top();
    if (!g || !g.active) return;
    const t = e.target;
    if (t && (t.tagName === 'INPUT' || t.tagName === 'SELECT' || t.tagName === 'TEXTAREA')) return;
    let used = true;
    switch (e.code) {
      case 'ArrowUp': g.move(0, -1); break;
      case 'ArrowDown': g.move(0, 1); break;
      case 'ArrowLeft': if (!g.page(-1)) g.move(-1, 0); break;
      case 'ArrowRight': if (!g.page(1)) g.move(1, 0); break;
      case 'Tab': g.move(e.shiftKey ? -1 : 1, 0, true); break;
      case 'Enter':
      case 'NumpadEnter':
      case 'Space': if (!e.repeat) g.press(); break;
      case 'Escape': if (!e.repeat && g.back) g.back(); else used = false; break;
      default:
        used = g.onKey ? g.onKey(e.code) === true : false;
    }
    if (used) {
      e.preventDefault();
      e.stopImmediatePropagation();
    }
  }

  /** Per frame: gamepad navigation for the top group. */
  update(dt) {
    const g = this.top();
    const pads = navigator.getGamepads ? navigator.getGamepads() : [];
    let pad = null;
    for (const p of pads) if (p && p.connected) { pad = p; break; }
    if (!pad) return;
    const down = (i) => !!(pad.buttons[i] && (pad.buttons[i].pressed || pad.buttons[i].value > 0.5));
    const edge = (i) => {
      const was = !!this.pad.buttons[i];
      const now = down(i);
      this.pad.buttons[i] = now;
      return now && !was;
    };
    const a = edge(0);
    const b = edge(1);
    const lb = edge(4);
    const rb = edge(5);
    for (const i of [2, 3, 9, 14, 15]) edge(i);
    if (!g || !g.active) return;
    if (a) g.press();
    if (b && g.back) g.back();
    if (lb) g.page(-1);
    if (rb) g.page(1);
    const ax = pad.axes[0] || 0;
    const ay = pad.axes[1] || 0;
    let dir = null;
    if (down(12) || ay < -STICK) dir = 'u';
    else if (down(13) || ay > STICK) dir = 'd';
    else if (down(14) || ax < -STICK) dir = 'l';
    else if (down(15) || ax > STICK) dir = 'r';
    const s = this.pad;
    if (dir !== s.dir) {
      s.dir = dir;
      s.heldFor = 0;
      s.repeatAt = REPEAT_DELAY;
      if (dir) this._dir(g, dir);
    } else if (dir) {
      s.heldFor += dt;
      if (s.heldFor >= s.repeatAt) {
        s.repeatAt += REPEAT_EVERY;
        this._dir(g, dir);
      }
    }
  }

  _dir(g, dir) {
    if (dir === 'u') g.move(0, -1);
    else if (dir === 'd') g.move(0, 1);
    else if (dir === 'l') { if (!g.page(-1)) g.move(-1, 0); } else if (!g.page(1)) g.move(1, 0);
  }
}

/** One screen's focusable buttons. */
export class FocusGroup {
  /**
   * @param {{back?: () => void, page?: (delta: number) => boolean, onKey?: (code: string) => boolean,
   *   onFocus?: (index: number) => void}} [opts]
   */
  constructor(opts = {}) {
    /** @type {FocusItem[]} */
    this.items = [];
    this.index = 0;
    this.active = true;
    this.back = opts.back || null;
    this.pageFn = opts.page || null;
    this.onKey = opts.onKey || null;
    this.onFocus = opts.onFocus || null;
  }

  /** Registers a button; returns it. @param {HTMLElement} el @param {() => void} press */
  add(el, press, row) {
    const item = { el, press, row: row ?? this.items.length };
    this.items.push(item);
    el.addEventListener('pointerenter', (e) => {
      if (e.pointerType === 'mouse') this.focus(this.items.indexOf(item));
    });
    el.addEventListener('click', (e) => {
      e.preventDefault();
      if (el.hasAttribute('disabled')) return;
      this.focus(this.items.indexOf(item));
      press();
    });
    return el;
  }

  clear() {
    this.items = [];
    this.index = 0;
  }

  enabledIndex(i) {
    const it = this.items[i];
    return !!it && !it.el.hasAttribute('disabled') && it.el.offsetParent !== null;
  }

  focus(i) {
    if (i < 0 || i >= this.items.length) return;
    this.index = i;
    this.render();
    if (this.onFocus) this.onFocus(i);
  }

  render() {
    this.items.forEach((it, i) => it.el.classList.toggle('focus', i === this.index));
  }

  /** Moves the focus: dy across rows, dx within a row (or linear with `linear`). */
  move(dx, dy, linear = false) {
    const n = this.items.length;
    if (!n) return;
    if (linear || dy === 0) {
      if (dy === 0 && !linear) {
        const row = this.items[this.index] ? this.items[this.index].row : 0;
        const same = this.items.map((it, i) => (it.row === row ? i : -1)).filter((i) => i >= 0 && this.enabledIndex(i));
        const at = same.indexOf(this.index);
        if (same.length > 1 && at >= 0) {
          const next = same[(at + dx + same.length) % same.length];
          this.focus(next);
          return;
        }
      }
      for (let k = 1; k <= n; k++) {
        const i = (this.index + dx * k + n * k) % n;
        if (this.enabledIndex(i)) {
          this.focus(i);
          return;
        }
      }
      return;
    }
    const row = this.items[this.index] ? this.items[this.index].row : 0;
    const rows = [...new Set(this.items.map((it) => it.row))].sort((a, b) => a - b);
    let r = rows.indexOf(row);
    for (let k = 0; k < rows.length; k++) {
      r = (r + dy + rows.length) % rows.length;
      const candidates = this.items.map((it, i) => (it.row === rows[r] && this.enabledIndex(i) ? i : -1)).filter((i) => i >= 0);
      if (candidates.length) {
        this.focus(candidates[0]);
        return;
      }
    }
  }

  press() {
    const it = this.items[this.index];
    if (it && this.enabledIndex(this.index)) it.press();
  }

  page(delta) {
    return this.pageFn ? this.pageFn(delta) === true : false;
  }
}
