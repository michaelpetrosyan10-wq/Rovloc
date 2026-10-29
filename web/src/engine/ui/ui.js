// The DOM HUD kit (HUD/init + UIKit + StatusBars + PromptRenderer + Captions + SettingsMenu), drawn over the canvas.
//
//   * Primitives: panel, meter (thin rounded bar), ring (SVG progress ring, clockwise from 12), keyCap (keyboard key,
//     gamepad button or touch mark for an action on the current device), roundButton.
//   * Status bars: battery (amber), stamina (moss), oxygen (cyan), bottom-left (top-left on touch). A bar shows fully
//     while it changes or matters (oxygen underwater, battery while lit), rests dim when partly spent and quiet,
//     fades away when full and idle; under 20 % it warms toward ember and pulses (faster under 10 %).
//   * Prompts: rows at their world anchor (projected each frame), a hold ring around the key glyph, the object text
//     above the action; rows fade in and out, the ring fills while holding and drains when released. On touch the
//     row is the button.
//   * Toasts (top centre, max 3, repeats refresh), the hint line and captions (centre column; captions only with
//     the Captions setting; creature sounds carry a blood tick), floor cards, fades to black, the pause / settings
//     menu (every visible SettingsSchema entry + Quality) and the loading screen.

import { InputBindings } from '../config.js';
import { Settings } from '../settings.js';
import { getString } from '../strings.js';
import { CSS, Palette } from './style.js';

const MAX_TOASTS = 3;
const TOAST_DEDUPE = 1.5;
const CAPTION_DEDUPE = 1.5;
const CAPTION_MAX = 3;
const CAPTION_HOLD = 3.2;
const LOW = 0.2;
const CRITICAL = 0.1;
const LINGER = 2.5;
const REST_ALPHA = 0.5;
const FADE_IN = 6;
const FADE_OUT = 1.6;
const FULL = 0.999;

const KEY_NAMES = {
  ShiftLeft: 'SHIFT', ControlLeft: 'CTRL', Space: 'SPACE', Tab: 'TAB', Escape: 'ESC', Mouse0: 'LMB',
  ArrowUp: '↑', ArrowDown: '↓', ArrowLeft: '←', ArrowRight: '→',
};
const PAD_NAMES = ['A', 'B', 'X', 'Y', 'LB', 'RB', 'LT', 'RT', 'SEL', 'START', 'L3', 'R3', '▲', '▼', '◀', '▶'];
const PAD_TINTS = { 0: Palette.GamepadA, 1: Palette.GamepadB, 2: Palette.GamepadX, 3: Palette.GamepadY };

function el(tag, className, parent, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text !== undefined) e.textContent = text;
  if (parent) parent.appendChild(e);
  return e;
}

/** The short label for a key code. */
export function keyLabel(code) {
  if (KEY_NAMES[code]) return KEY_NAMES[code];
  if (code.startsWith('Key')) return code.slice(3);
  if (code.startsWith('Digit')) return code.slice(5);
  return code.toUpperCase();
}

export class UI {
  /**
   * @param {HTMLElement} root the #rv-root container
   * @param {{input: import('../input.js').Input, settings: import('../settings.js').Settings, quality: any}} deps
   */
  constructor(root, deps) {
    this.root = root;
    this.input = deps.input;
    this.settings = deps.settings;
    this.quality = deps.quality;
    if (!document.getElementById('rv-style')) {
      const style = el('style');
      style.id = 'rv-style';
      style.textContent = CSS;
      document.head.appendChild(style);
    }
    this.hud = el('div', 'rv-layer rv-hud', root);
    this.promptLayer = el('div', 'rv-layer', this.hud);
    this.dot = el('div', 'rv-dot', this.hud);
    this.dot.style.display = 'none'; // the Roblox game hides the cursor in first person (CursorController)
    this.status = el('div', 'rv-status', this.hud);
    this.centre = el('div', 'rv-centre', this.hud);
    this.hintEl = el('div', 'rv-hint rv-outline', this.centre);
    this.captionsEl = el('div', 'rv-captions', this.centre);
    this.toastsEl = el('div', 'rv-toasts', root);
    this.touch = el('div', 'rv-touch', root);
    this.cardLayer = el('div', 'rv-layer', root);
    this.fadeEl = el('div', 'rv-fade', root);
    this.menuEl = el('div', 'rv-menu', root);
    this.statsEl = el('div', 'rv-stats', root);
    this.statsEl.style.display = 'none';
    this.hudAlpha = 1;
    this.hudTarget = 1;
    this.hudRate = 1;
    this.toasts = [];
    this.captions = [];
    this.meterRows = new Map();
    this.promptRows = new Map();
    this.menuButtons = [];
    this.menuOpen = false;
    this.fadeState = { from: 0, to: 0, t: 0, dur: 0, resolve: null };
    this.fadeValue = 0;
    this.input.mountTouch(this.touch);
    this.input.deviceChanged.connect(() => {
      this.status.classList.toggle('touch', this.input.device === 'Touch');
      this._refreshGlyphs();
    });
    this.status.classList.toggle('touch', this.input.device === 'Touch');
    this.settings.changed.connect((key) => {
      if (key === 'Captions' && !this.settings.get('Captions')) this.clearCaptions();
    });
  }

  // ------------------------------------------------------------------ primitives

  /** A dark grimy panel. */
  panel(parent = this.hud, className = '') {
    return el('div', `rv-panel ${className}`, parent);
  }

  /**
   * A thin meter bar.
   * @returns {{root: HTMLElement, setFraction(f: number): void, setColor(c: string): void, setAlpha(a: number): void}}
   */
  meter(parent, color) {
    const root = el('div', 'rv-meter', parent);
    const fill = el('div', 'rv-meter-fill', root);
    fill.style.background = color;
    let last = -1;
    return {
      root,
      setFraction(f) {
        const v = Math.min(1, Math.max(0, f));
        if (Math.abs(v - last) > 1e-3) {
          last = v;
          fill.style.width = `${v * 100}%`;
        }
      },
      setColor(c) {
        fill.style.backgroundColor = c;
      },
      setAlpha(a) {
        root.style.opacity = String(a);
      },
    };
  }

  /**
   * A clockwise SVG progress ring with a faint track.
   * @returns {{root: SVGSVGElement, setProgress(p: number): void, setColor(c: string): void, setAlpha(a: number): void}}
   */
  ring(parent, diameter = 46, thickness = 2, color = Palette.Bone) {
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('width', diameter);
    svg.setAttribute('height', diameter);
    svg.setAttribute('viewBox', `0 0 ${diameter} ${diameter}`);
    const r = (diameter - thickness) / 2;
    const c = 2 * Math.PI * r;
    const track = document.createElementNS(ns, 'circle');
    const arc = document.createElementNS(ns, 'circle');
    for (const [k, v] of Object.entries({ cx: diameter / 2, cy: diameter / 2, r, fill: 'none', 'stroke-width': thickness })) {
      track.setAttribute(k, v);
      arc.setAttribute(k, v);
    }
    track.setAttribute('stroke', Palette.Bone);
    track.setAttribute('stroke-opacity', '0.18');
    arc.setAttribute('stroke', color);
    arc.setAttribute('stroke-dasharray', `${c} ${c}`);
    arc.setAttribute('stroke-dashoffset', `${c}`);
    arc.setAttribute('transform', `rotate(-90 ${diameter / 2} ${diameter / 2})`);
    arc.setAttribute('stroke-linecap', 'butt');
    svg.appendChild(track);
    svg.appendChild(arc);
    parent.appendChild(svg);
    let last = -1;
    return {
      root: svg,
      setProgress(p) {
        const v = Math.min(1, Math.max(0, p));
        if (Math.abs(v - last) < 1e-3) return;
        last = v;
        arc.setAttribute('stroke-dashoffset', `${c * (1 - v)}`);
      },
      setColor(col) {
        arc.setAttribute('stroke', col);
      },
      setAlpha(a) {
        svg.style.opacity = String(a);
      },
    };
  }

  /**
   * A key glyph for an action on the current device (keyboard key, gamepad button, touch mark).
   * @param {HTMLElement} parent
   * @param {string} action an InputBindings action
   * @param {number} [size]
   */
  keyCap(parent, action, size = 34) {
    const cap = el('div', 'rv-key', parent);
    cap.dataset.action = action;
    cap.dataset.size = String(size);
    this._paintKey(cap);
    return cap;
  }

  _paintKey(cap) {
    const b = InputBindings[cap.dataset.action];
    const size = Number(cap.dataset.size) || 34;
    const device = this.input.device;
    cap.className = `rv-key ${device === 'Gamepad' ? 'gamepad' : device === 'Touch' ? 'touch' : 'keyboard'}`;
    cap.style.width = cap.style.height = `${device === 'KeyboardMouse' ? size * 0.86 : size}px`;
    cap.style.color = Palette.Bone;
    if (!b || device === 'Touch') {
      cap.textContent = '';
      return;
    }
    const text = device === 'Gamepad' ? PAD_NAMES[b.gamepad[0]] || '?' : keyLabel(b.keyboard[0]);
    cap.textContent = text;
    cap.style.fontSize = `${Math.floor(size * (text.length > 2 ? 0.26 : 0.42))}px`;
    if (device === 'Gamepad') cap.style.color = PAD_TINTS[b.gamepad[0]] || Palette.Bone;
  }

  _refreshGlyphs() {
    for (const cap of this.root.querySelectorAll('.rv-key')) this._paintKey(cap);
  }

  /** An inline key glyph (for hints written in HTML): returns an element to append. */
  inlineKey(action, size = 22) {
    const wrap = el('span', 'rv-key-inline');
    wrap.style.width = wrap.style.height = `${size}px`;
    this.keyCap(wrap, action, size);
    return wrap;
  }

  // ------------------------------------------------------------------ HUD visibility

  /** Fades the whole HUD (cutscenes). */
  setVisible(visible, seconds = 2.5) {
    this.hudTarget = visible ? 1 : 0;
    this.hudRate = seconds > 0 ? 1 / seconds : 1000;
  }

  /** Shows / hides the centre dot. */
  setCrosshair(on) {
    this.dot.style.display = on ? '' : 'none';
  }

  // ------------------------------------------------------------------ toasts, hint, captions, cards

  /**
   * A top-centre message. kind: 'info' | 'danger' | 'good'.
   * @param {string} text
   * @param {{seconds?: number, kind?: string}} [opts]
   */
  toast(text, opts = {}) {
    const now = performance.now() / 1000;
    const existing = this.toasts.find((t) => t.text === text && now - t.born < TOAST_DEDUPE + (t.seconds || 4));
    if (existing) {
      existing.born = now;
      existing.el.style.opacity = '1';
      return;
    }
    const e = el('div', `rv-toast rv-outline ${opts.kind || ''}`, this.toastsEl, text);
    e.style.opacity = '0';
    requestAnimationFrame(() => (e.style.opacity = '1'));
    this.toasts.push({ text, el: e, born: now, seconds: opts.seconds ?? 4 });
    while (this.toasts.length > MAX_TOASTS) this.toasts.shift().el.remove();
  }

  /** One centred narrative line; seconds <= 0 keeps it until clearHint(). Accepts text or a DOM node. */
  hint(content, seconds = 6) {
    this.hintEl.textContent = '';
    if (typeof content === 'string') this.hintEl.textContent = content;
    else this.hintEl.appendChild(content);
    this.hintEl.classList.add('on');
    clearTimeout(this.hintTimer);
    if (seconds > 0) this.hintTimer = setTimeout(() => this.clearHint(), seconds * 1000);
  }

  clearHint() {
    this.hintEl.classList.remove('on');
  }

  /** A caption line (only while the Captions setting is on); danger lines carry a blood tick. */
  caption(text, opts = {}) {
    if (!this.settings.get('Captions')) return;
    const now = performance.now() / 1000;
    const existing = this.captions.find((c) => c.text === text && now - c.at < CAPTION_DEDUPE + CAPTION_HOLD);
    if (existing) {
      existing.at = now;
      existing.el.style.opacity = '1';
      return;
    }
    const e = el('div', `rv-caption ${opts.danger ? 'danger' : ''}`, this.captionsEl, text);
    this.captions.push({ text, el: e, at: now });
    while (this.captions.length > CAPTION_MAX) this.captions.shift().el.remove();
  }

  clearCaptions() {
    for (const c of this.captions) c.el.remove();
    this.captions.length = 0;
  }

  /** A floor / title card (typewriter title, condensed subtitle). Resolves when it is gone. */
  card(title, subtitle = '', seconds = 4) {
    const box = el('div', 'rv-card', this.cardLayer);
    el('div', 'rv-card-title rv-outline', box, title);
    el('div', 'rv-card-rule', box);
    if (subtitle) el('div', 'rv-card-sub rv-outline', box, subtitle);
    box.style.opacity = '0';
    requestAnimationFrame(() => (box.style.opacity = '1'));
    return new Promise((resolve) => {
      setTimeout(() => {
        box.style.opacity = '0';
        setTimeout(() => {
          box.remove();
          resolve();
        }, 1200);
      }, seconds * 1000);
    });
  }

  /** Fades the screen toward `alpha` (0 clear .. 1 black) over `seconds`. Resolves when done. */
  fade(alpha, seconds = 1, color = '#000') {
    this.fadeEl.style.background = color;
    const f = this.fadeState;
    if (f.resolve) f.resolve();
    f.from = this.fadeValue;
    f.to = Math.min(1, Math.max(0, alpha));
    f.t = 0;
    f.dur = Math.max(0, seconds);
    return new Promise((resolve) => {
      f.resolve = resolve;
      if (f.dur === 0) this._stepFade(0);
    });
  }

  /** Cut to / from black. */
  black(on, seconds = 0) {
    return this.fade(on ? 1 : 0, seconds);
  }

  _stepFade(dt) {
    const f = this.fadeState;
    if (!f.resolve) return;
    f.t += dt;
    const k = f.dur > 0 ? Math.min(1, f.t / f.dur) : 1;
    this.fadeValue = f.from + (f.to - f.from) * k;
    this.fadeEl.style.opacity = String(this.fadeValue);
    if (k >= 1) {
      const r = f.resolve;
      f.resolve = null;
      r();
    }
  }

  // ------------------------------------------------------------------ status bars

  /**
   * Draws the meters (battery / stamina / oxygen) each frame.
   * @param {number} dt
   * @param {Array<{id: string, label: string, fraction: number, color: string, active: boolean}>} meters
   * @param {number} [syringes] charges left (pips)
   */
  updateStatus(dt, meters, syringes = 0) {
    for (const m of meters) {
      let row = this.meterRows.get(m.id);
      if (!row) {
        const frame = el('div', 'rv-meter-row', this.status);
        el('div', 'rv-caps', frame, m.label);
        row = { frame, bar: this.meter(frame, m.color), alpha: 0, last: m.fraction, lastActive: -Infinity, t: 0 };
        this.meterRows.set(m.id, row);
      }
      row.t += dt;
      const changing = Math.abs(m.fraction - row.last) > 1e-4;
      row.last = m.fraction;
      if (changing || m.active) row.lastActive = row.t;
      let want = 0;
      if (row.t - row.lastActive < LINGER) want = 1;
      else if (m.fraction < FULL) want = REST_ALPHA;
      const rate = want > row.alpha ? FADE_IN : FADE_OUT;
      row.alpha += Math.sign(want - row.alpha) * Math.min(Math.abs(want - row.alpha), rate * dt);
      let color = m.color;
      let pulse = 1;
      if (m.fraction < LOW) {
        color = Palette.Ember;
        const hz = m.fraction < CRITICAL ? 3 : 1.4;
        pulse = 0.6 + 0.4 * (0.5 + 0.5 * Math.sin(row.t * Math.PI * 2 * hz));
      }
      row.bar.setColor(color);
      row.bar.setFraction(m.fraction);
      row.frame.style.opacity = String(row.alpha * pulse);
      row.frame.classList.toggle('collapsed', row.alpha < 0.01);
    }
    if (!this.pipsEl) this.pipsEl = el('div', 'rv-pips', this.status);
    if (this.pipsEl.childElementCount !== Math.min(4, syringes)) {
      this.pipsEl.textContent = '';
      for (let i = 0; i < Math.min(4, syringes); i++) el('div', 'rv-pip', this.pipsEl);
    }
  }

  // ------------------------------------------------------------------ prompts

  /**
   * Draws the shown prompts.
   * @param {Array<{id: number, x: number, y: number, visible: boolean, alpha: number, progress: number,
   *   text: string, objectText: string, action: string, onPress?: Function, onRelease?: Function}>} rows
   */
  renderPrompts(rows) {
    const seen = new Set();
    for (const r of rows) {
      seen.add(r.id);
      let view = this.promptRows.get(r.id);
      if (!view) {
        const frame = el('div', 'rv-prompt', this.promptLayer);
        const ringWrap = el('div', 'rv-prompt-ring', frame);
        const ring = this.ring(ringWrap, 46, 2, Palette.Bone);
        const cap = this.keyCap(ringWrap, r.action || 'Interact', 34);
        const text = el('div', 'rv-prompt-text', frame);
        const object = el('div', 'rv-prompt-object rv-outline', text);
        const action = el('div', 'rv-prompt-action rv-outline', text);
        frame.addEventListener('pointerdown', (e) => {
          if (this.input.device !== 'Touch' && !this.input.isCursorFree()) return;
          e.preventDefault();
          if (view.onPress) view.onPress();
        });
        const up = () => view.onRelease && view.onRelease();
        frame.addEventListener('pointerup', up);
        frame.addEventListener('pointercancel', up);
        frame.addEventListener('pointerleave', up);
        view = { frame, ring, cap, object, action, text: '', objectText: '' };
        this.promptRows.set(r.id, view);
      }
      view.onPress = r.onPress;
      view.onRelease = r.onRelease;
      if (view.text !== r.text) {
        view.text = r.text;
        view.action.textContent = r.text;
      }
      if (view.objectText !== r.objectText) {
        view.objectText = r.objectText;
        view.object.textContent = r.objectText || '';
      }
      view.frame.style.left = `${r.x}px`;
      view.frame.style.top = `${r.y}px`;
      view.frame.style.opacity = String(r.visible ? r.alpha : 0);
      view.frame.style.pointerEvents = r.visible && r.alpha > 0.5 ? 'auto' : 'none';
      view.ring.setProgress(r.progress);
    }
    for (const [id, view] of this.promptRows) {
      if (!seen.has(id)) {
        view.frame.remove();
        this.promptRows.delete(id);
      }
    }
  }

  // ------------------------------------------------------------------ menu

  /** Buttons above the settings in the pause menu (W4: Resume, Return to lobby, ...). */
  setMenuButtons(buttons) {
    this.menuButtons = buttons || [];
    if (this.menuOpen) this._buildMenu();
  }

  openMenu(title = 'PAUSED') {
    this.menuTitle = title;
    this.menuOpen = true;
    this.input.setCursorFree('menu', true);
    this.input.pushContext('menu', 'Menu');
    this._buildMenu();
    this.menuEl.classList.add('open');
  }

  closeMenu() {
    if (!this.menuOpen) return;
    this.menuOpen = false;
    this.menuEl.classList.remove('open');
    this.input.setCursorFree('menu', false);
    this.input.popContext('menu');
    this.input.requestPointerLock();
  }

  _buildMenu() {
    const m = this.menuEl;
    m.textContent = '';
    const panel = this.panel(m, 'rv-menu-panel');
    el('h2', '', panel, this.menuTitle || 'PAUSED');
    for (const b of this.menuButtons) {
      const btn = el('button', 'rv-btn', panel, b.label);
      btn.addEventListener('click', () => b.onClick());
    }
    el('div', 'rv-caps', panel, getString('Settings.Title')).style.margin = '16px 0 6px';
    for (const s of Settings.visible()) {
      const row = el('label', 'rv-setting', panel);
      el('span', '', row, s.key === 'Quality' ? 'Graphics quality' : getString(s.label));
      if (s.kind === 'Number') {
        const range = el('input', '', row);
        range.type = 'range';
        range.min = s.min;
        range.max = s.max;
        range.step = s.step;
        range.value = this.settings.get(s.key);
        const val = el('span', 'val', row, fmt(this.settings.get(s.key)));
        range.addEventListener('input', () => {
          this.settings.set(s.key, Number(range.value));
          val.textContent = fmt(this.settings.get(s.key));
        });
      } else if (s.kind === 'Bool') {
        const t = el('div', `rv-toggle ${this.settings.get(s.key) ? 'on' : ''}`, row);
        el('span', '', row);
        t.addEventListener('click', (e) => {
          e.preventDefault();
          this.settings.set(s.key, !this.settings.get(s.key));
          t.classList.toggle('on', !!this.settings.get(s.key));
        });
      } else if (s.kind === 'Choice') {
        const sel = el('select', '', row);
        for (const o of s.options) {
          const opt = el('option', '', sel, o === 'Auto' ? `Auto (${this.quality.tier})` : o);
          opt.value = o;
        }
        sel.value = this.settings.get(s.key);
        sel.addEventListener('change', () => this.settings.set(s.key, sel.value));
        el('span', '', row);
      }
    }
  }

  // ------------------------------------------------------------------ loading

  showLoading(text = 'THE SCHOOL IS WAKING UP') {
    if (!this.loadingEl) {
      this.loadingEl = el('div', 'rv-loading', this.root);
      el('div', 'rv-title', this.loadingEl, text);
      const bar = el('div', 'rv-loading-bar', this.loadingEl);
      this.loadingFill = el('div', '', bar);
      this.loadingSub = el('div', 'rv-loading-sub', this.loadingEl, '');
    }
    this.loadingEl.style.opacity = '1';
    this.loadingEl.style.display = '';
  }

  setLoading(fraction, sub = '') {
    if (!this.loadingEl) this.showLoading();
    this.loadingFill.style.width = `${Math.round(Math.min(1, Math.max(0, fraction)) * 100)}%`;
    this.loadingSub.textContent = sub;
  }

  hideLoading(seconds = 0.8) {
    if (!this.loadingEl) return Promise.resolve();
    this.loadingEl.style.opacity = '0';
    return new Promise((r) => setTimeout(() => {
      if (this.loadingEl) this.loadingEl.style.display = 'none';
      r();
    }, seconds * 1000));
  }

  /** Shows a small stats line (dev). */
  setStats(text) {
    this.statsEl.style.display = text ? '' : 'none';
    this.statsEl.textContent = text || '';
  }

  // ------------------------------------------------------------------ frame

  update(dt) {
    const step = this.hudRate * dt;
    this.hudAlpha += Math.sign(this.hudTarget - this.hudAlpha) * Math.min(Math.abs(this.hudTarget - this.hudAlpha), step);
    this.hud.style.opacity = String(this.hudAlpha);
    this._stepFade(dt);
    const now = performance.now() / 1000;
    for (let i = this.toasts.length - 1; i >= 0; i--) {
      const t = this.toasts[i];
      const age = now - t.born;
      if (age > t.seconds) t.el.style.opacity = '0';
      if (age > t.seconds + 0.7) {
        t.el.remove();
        this.toasts.splice(i, 1);
      }
    }
    for (let i = this.captions.length - 1; i >= 0; i--) {
      const c = this.captions[i];
      const age = now - c.at;
      if (age > CAPTION_HOLD) c.el.style.opacity = '0';
      if (age > CAPTION_HOLD + 0.8) {
        c.el.remove();
        this.captions.splice(i, 1);
      }
    }
  }
}

function fmt(v) {
  return typeof v === 'number' ? (Math.abs(v) >= 10 ? String(Math.round(v)) : v.toFixed(2)) : String(v);
}
