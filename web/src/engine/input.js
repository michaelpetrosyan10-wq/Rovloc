// Input: every gameplay action on keyboard + mouse (pointer lock), gamepad and touch, through one context stack
// (InputController.luau + CursorController + MobileControls).
//
//   * Contexts. Systems push an InputContext under a token and pop it by the same token; the active context is the
//     highest-priority pushed one (Menu > Cutscene > Struggle > Locker > Trapped > Downed > Vent > Swim > Parachute
//     > OnFoot > Spectator), the "OnFoot" baseline when nothing is pushed. Only the actions InputBindings marks live
//     in the active context fire.
//   * Phases. Hold actions fire "Begin" when the first of their inputs goes down and "End" when the last comes up.
//     Tap, Toggle and Mash actions fire "Begin" on every press (the consumer toggles / counts). A context change
//     ends held actions that are no longer live.
//   * Move / look. WASD + arrows / the left stick / the touch thumbstick give the move vector; the mouse (only while
//     the pointer is locked), the right stick (radial deadzone + curve live in the camera rig) and a look drag on
//     the right of a touch screen give look deltas that the camera consumes once per frame.
//   * Cursor. The pointer is locked during play; a click on the game locks it again after Escape freed it. Systems
//     that need a free cursor (menus) hold setCursorFree(token, true). Losing the lock while playing fires "Menu"
//     (Escape opens the pause menu, as M does).
//   * Device. The last input type decides the device (KeyboardMouse / Gamepad / Touch); glyphs and touch buttons
//     follow it (deviceChanged).

import { InputBindings, InputContexts } from './config.js';
import { Signal } from './signal.js';

const CONTEXT_RANK = Object.fromEntries(InputContexts.map((c, i) => [c, InputContexts.length - i]));
const BASELINE = 'OnFoot';
const MOVE_KEYS = {
  KeyW: [0, 1], ArrowUp: [0, 1], KeyS: [0, -1], ArrowDown: [0, -1],
  KeyA: [-1, 0], ArrowLeft: [-1, 0], KeyD: [1, 0], ArrowRight: [1, 0],
};
const STICK_DEADZONE = 0.14;
const TOUCH_LOOK_MIN_X = 0.4; // CameraRig.TouchLookMinX
const TOUCH_LOOK_TOP = 0.3; // CameraRig.TouchLookTop
const THUMB_RADIUS = 60;
const TOUCH_MOUSE_GRACE = 900; // ms after a touch in which mouse events are the browser's emulation of it
const PREVENT = new Set(['Tab', 'Space', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'ShiftLeft', 'KeyF']);
// the contexts the body moves in: only there does the touch layer draw its thumbstick (in a locker it sat under the
// LEAVE button, in a trap or a struggle it did nothing)
const STICK_CONTEXTS = new Set(['OnFoot', 'Vent', 'Swim', 'Downed', 'Parachute']);

/** @typedef {'Begin'|'End'} Phase */
/** @typedef {'KeyboardMouse'|'Gamepad'|'Touch'} Device */

export class Input {
  /** @param {HTMLElement} surface the element that captures the pointer (the game canvas's container) */
  constructor(surface) {
    this.surface = surface;
    /** @type {{token: string, context: string}[]} */
    this.stack = [];
    this.context = BASELINE;
    /** @type {Device} */
    this.device = matchMedia('(pointer: coarse)').matches ? 'Touch' : 'KeyboardMouse';
    /** @type {Signal<[Device]>} */
    this.deviceChanged = new Signal();
    /** @type {Signal<[string, string]>} (new, old) */
    this.contextChanged = new Signal();
    /** @type {Signal<[number]>} a gamepad button went down (standard mapping index; menus navigate with it) */
    this.padPressed = new Signal();
    /** @type {Map<string, Signal<[Phase]>>} */
    this.signals = new Map();
    /** @type {Map<string, Set<string>>} action -> held input ids */
    this.held = new Map();
    this.keys = new Set();
    this.mouse = { x: 0, y: 0 };
    this.touchLook = { x: 0, y: 0 };
    this.stick = { x: 0, y: 0 };
    this.leftStick = { x: 0, y: 0 };
    this.thumb = { x: 0, y: 0 };
    this.pointerLocked = false;
    this.wantPointerLock = false;
    this.lastTouchAt = -Infinity;
    /** @type {Map<string, boolean>} */
    this.cursorFreeTokens = new Map();
    this.gamepadButtons = [];
    this.enabled = true;
    /** Text entry (a focused input element) suspends everything. */
    this.typing = false;
    this._bind();
  }

  // ------------------------------------------------------------------ contexts

  /** Pushes `context` under `token` (replacing that token's previous context). */
  pushContext(token, context) {
    if (!(context in CONTEXT_RANK)) throw new Error(`unknown input context ${context}`);
    this.stack = this.stack.filter((e) => e.token !== token);
    this.stack.push({ token, context });
    this._refreshContext();
  }

  popContext(token) {
    const before = this.stack.length;
    this.stack = this.stack.filter((e) => e.token !== token);
    if (this.stack.length !== before) this._refreshContext();
  }

  getContext() {
    return this.context;
  }

  /** Whether `action` is live in the active context. */
  isLive(action) {
    const b = InputBindings[action];
    return !!b && b.contexts.includes(this.context);
  }

  _refreshContext() {
    let best = BASELINE;
    let rank = CONTEXT_RANK[BASELINE];
    for (const e of this.stack) {
      const r = CONTEXT_RANK[e.context];
      if (r > rank) {
        rank = r;
        best = e.context;
      }
    }
    if (best === this.context) return;
    const old = this.context;
    this.context = best;
    for (const [action, set] of this.held) {
      if (set.size > 0 && !this.isLive(action)) {
        set.clear();
        if (InputBindings[action].kind === 'Hold') this._emit(action, 'End');
      }
    }
    this.contextChanged.fire(best, old);
    this._renderTouch();
  }

  // ------------------------------------------------------------------ actions

  /** The phase signal of an action. @returns {Signal<[Phase]>} */
  action(name) {
    let s = this.signals.get(name);
    if (!s) {
      s = new Signal();
      this.signals.set(name, s);
    }
    return s;
  }

  /** Shorthand: subscribe to an action's phases. Returns the disconnect function. */
  on(name, fn) {
    return this.action(name).connect(fn);
  }

  /** Whether any input of a Hold action is down (and the action live). */
  isHeld(name) {
    const set = this.held.get(name);
    return !!set && set.size > 0 && this.isLive(name);
  }

  /** Feeds a press / release from any source (`id` distinguishes simultaneous inputs). */
  inject(action, id, down) {
    const b = InputBindings[action];
    if (!b) return;
    let set = this.held.get(action);
    if (!set) {
      set = new Set();
      this.held.set(action, set);
    }
    if (down) {
      if (!this.isLive(action) || !this.enabled) return;
      const was = set.size;
      if (set.has(id)) return;
      set.add(id);
      if (b.kind === 'Hold') {
        if (was === 0) this._emit(action, 'Begin');
      } else {
        this._emit(action, 'Begin');
      }
    } else {
      if (!set.delete(id)) return;
      if (b.kind === 'Hold' && set.size === 0) this._emit(action, 'End');
    }
  }

  _emit(action, phase) {
    const s = this.signals.get(action);
    if (s) s.fire(phase);
  }

  _releaseAll() {
    for (const [action, set] of this.held) {
      if (set.size > 0) {
        set.clear();
        if (InputBindings[action].kind === 'Hold') this._emit(action, 'End');
      }
    }
    this.keys.clear();
  }

  // ------------------------------------------------------------------ move / look

  /** The move vector this frame: x right, y forward, length <= 1. */
  moveVector() {
    if (!this.enabled) return { x: 0, y: 0 };
    let x = 0;
    let y = 0;
    for (const code of this.keys) {
      const m = MOVE_KEYS[code];
      if (m) {
        x += m[0];
        y += m[1];
      }
    }
    x += this.leftStick.x + this.thumb.x;
    y += this.leftStick.y + this.thumb.y;
    const len = Math.hypot(x, y);
    if (len > 1) {
      x /= len;
      y /= len;
    }
    return { x, y };
  }

  /** Accumulated look input since the last call: mouse px, touch px and the right stick (-1..1). */
  consumeLook() {
    const out = { mouse: { ...this.mouse }, touch: { ...this.touchLook }, stick: { ...this.stick } };
    this.mouse.x = this.mouse.y = 0;
    this.touchLook.x = this.touchLook.y = 0;
    return out;
  }

  // ------------------------------------------------------------------ cursor

  /** Ref-counted free-cursor request (menus). */
  setCursorFree(token, free) {
    if (free) this.cursorFreeTokens.set(token, true);
    else this.cursorFreeTokens.delete(token);
    if (this.isCursorFree()) {
      if (document.pointerLockElement) document.exitPointerLock();
    }
  }

  isCursorFree() {
    return this.cursorFreeTokens.size > 0;
  }

  /** Whether play wants the pointer locked (the engine sets this while a player is in control). */
  setPointerLockWanted(want) {
    this.wantPointerLock = want;
  }

  requestPointerLock() {
    if (this.device === 'Touch' || this.isCursorFree() || document.pointerLockElement) return;
    try {
      const p = this.surface.requestPointerLock({ unadjustedMovement: true });
      if (p && p.catch) p.catch(() => {
        try {
          const q = this.surface.requestPointerLock();
          if (q && q.catch) q.catch(() => {});
        } catch { /* not allowed (no user gesture) */ }
      });
    } catch { /* not allowed (no user gesture) */ }
  }

  _setDevice(device) {
    if (device === this.device) return;
    this.device = device;
    this.deviceChanged.fire(device);
    this._renderTouch();
  }

  // ------------------------------------------------------------------ DOM

  _bind() {
    const keyActions = new Map();
    for (const [action, b] of Object.entries(InputBindings)) {
      for (const k of b.keyboard) {
        if (!keyActions.has(k)) keyActions.set(k, []);
        keyActions.get(k).push(action);
      }
    }
    this.keyActions = keyActions;

    const isTyping = (e) => {
      const t = e.target;
      return t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.isContentEditable);
    };

    window.addEventListener('keydown', (e) => {
      if (isTyping(e)) return;
      this._setDevice('KeyboardMouse');
      if (PREVENT.has(e.code)) e.preventDefault();
      if (e.repeat) return;
      this.keys.add(e.code);
      this._pressKey(e.code, true);
    });
    window.addEventListener('keyup', (e) => {
      this.keys.delete(e.code);
      this._pressKey(e.code, false);
    });
    window.addEventListener('blur', () => this._releaseAll());

    // a tap is followed by compatibility mouse events (mousedown, click): they must not turn the device to
    // KeyboardMouse, which hid the touch controls after the first tap on PLAY or a prompt
    const fromTouch = (e) => (e.sourceCapabilities && e.sourceCapabilities.firesTouchEvents) ||
      performance.now() - this.lastTouchAt < TOUCH_MOUSE_GRACE;
    window.addEventListener('touchstart', () => {
      this.lastTouchAt = performance.now();
    }, { passive: true, capture: true });
    this.surface.addEventListener('mousedown', (e) => {
      if (e.button !== 0 || fromTouch(e)) return;
      this._setDevice('KeyboardMouse');
      if (this.wantPointerLock && !document.pointerLockElement && !this.isCursorFree()) {
        this.requestPointerLock();
        return;
      }
      if (document.pointerLockElement) this._pressKey('Mouse0', true);
    });
    window.addEventListener('mouseup', (e) => {
      if (e.button === 0 && !fromTouch(e)) this._pressKey('Mouse0', false);
    });
    window.addEventListener('mousemove', (e) => {
      if (document.pointerLockElement === this.surface) {
        // Chrome occasionally reports a huge spurious jump right after locking; drop those.
        if (Math.abs(e.movementX) < 400 && Math.abs(e.movementY) < 400) {
          this.mouse.x += e.movementX;
          this.mouse.y += e.movementY;
        }
      }
    });
    document.addEventListener('pointerlockchange', () => {
      const locked = document.pointerLockElement === this.surface;
      const lost = this.pointerLocked && !locked;
      this.pointerLocked = locked;
      if (lost && this.wantPointerLock && !this.isCursorFree()) {
        this._releaseAll();
        this.inject('Menu', 'pointerlock', true);
        this.inject('Menu', 'pointerlock', false);
      }
    });
    this.surface.addEventListener('contextmenu', (e) => e.preventDefault());

    // touch look: one finger that lands on the look side of the screen, outside any button
    /** @type {number|null} */
    let lookId = null;
    let lx = 0;
    let ly = 0;
    this.surface.addEventListener('touchstart', (e) => {
      this._setDevice('Touch');
      for (const t of e.changedTouches) {
        if (lookId !== null) break;
        const w = window.innerWidth;
        const h = window.innerHeight;
        if (t.clientX >= w * TOUCH_LOOK_MIN_X || t.clientY <= h * TOUCH_LOOK_TOP) {
          lookId = t.identifier;
          lx = t.clientX;
          ly = t.clientY;
        }
      }
    }, { passive: true });
    this.surface.addEventListener('touchmove', (e) => {
      for (const t of e.changedTouches) {
        if (t.identifier === lookId) {
          this.touchLook.x += t.clientX - lx;
          this.touchLook.y += t.clientY - ly;
          lx = t.clientX;
          ly = t.clientY;
        }
      }
    }, { passive: true });
    const endTouch = (e) => {
      for (const t of e.changedTouches) if (t.identifier === lookId) lookId = null;
    };
    this.surface.addEventListener('touchend', endTouch, { passive: true });
    this.surface.addEventListener('touchcancel', endTouch, { passive: true });

    window.addEventListener('gamepadconnected', () => this._setDevice('Gamepad'));
  }

  _pressKey(code, down) {
    const actions = this.keyActions.get(code);
    if (!actions) return;
    for (const action of actions) this.inject(action, `key:${code}`, down);
  }

  /** Polls gamepads (call once per frame). */
  pollGamepads() {
    const pads = navigator.getGamepads ? navigator.getGamepads() : [];
    let pad = null;
    for (const p of pads) if (p && p.connected) { pad = p; break; }
    if (!pad) {
      this.stick.x = this.stick.y = 0;
      this.leftStick.x = this.leftStick.y = 0;
      // unplugged (or asleep) with buttons down: let them go, or a held Sprint / Throw stays held for good
      for (let i = 0; i < this.gamepadButtons.length; i++) {
        if (!this.gamepadButtons[i]) continue;
        this.gamepadButtons[i] = false;
        for (const [action, b] of Object.entries(InputBindings)) {
          if (b.gamepad.includes(i)) this.inject(action, `pad:${i}`, false);
        }
      }
      return;
    }
    const dz = (v) => (Math.abs(v) < STICK_DEADZONE ? 0 : v);
    const lx = dz(pad.axes[0] || 0);
    const ly = dz(pad.axes[1] || 0);
    this.leftStick.x = lx;
    this.leftStick.y = -ly;
    // the camera rig applies the radial deadzone + curve to the raw right stick (Roblox Thumbstick2: up is +Y)
    this.stick.x = pad.axes[2] || 0;
    this.stick.y = -(pad.axes[3] || 0);
    let any = Math.abs(lx) > 0 || Math.abs(ly) > 0 || Math.hypot(this.stick.x, this.stick.y) > 0.3;
    for (let i = 0; i < pad.buttons.length; i++) {
      const down = pad.buttons[i].pressed || pad.buttons[i].value > 0.5;
      const was = !!this.gamepadButtons[i];
      if (down !== was) {
        this.gamepadButtons[i] = down;
        any = true;
        if (down) this.padPressed.fire(i);
        for (const [action, b] of Object.entries(InputBindings)) {
          if (b.gamepad.includes(i)) this.inject(action, `pad:${i}`, down);
        }
      }
    }
    if (any) this._setDevice('Gamepad');
  }

  // ------------------------------------------------------------------ touch controls (MobileControls)

  /**
   * Mounts the touch layer (thumbstick + the active context's buttons) into `root`. Buttons are drawn from
   * InputBindings.touch with the HUD's round-button style.
   * @param {HTMLElement} root
   */
  mountTouch(root) {
    this.touchRoot = root;
    this._renderTouch();
  }

  _renderTouch() {
    const root = this.touchRoot;
    if (!root) return;
    root.textContent = '';
    root.style.display = this.device === 'Touch' && this.enabled ? '' : 'none';
    if (this.device !== 'Touch') return;
    this._renderButtons(root);
    if (!STICK_CONTEXTS.has(this.context)) return;
    // thumbstick
    const base = document.createElement('div');
    base.className = 'rv-thumb';
    const knob = document.createElement('div');
    knob.className = 'rv-thumb-knob';
    base.appendChild(knob);
    root.appendChild(base);
    let id = null;
    let cx = 0;
    let cy = 0;
    const move = (t) => {
      let dx = t.clientX - cx;
      let dy = t.clientY - cy;
      const len = Math.hypot(dx, dy);
      if (len > THUMB_RADIUS) {
        dx = (dx / len) * THUMB_RADIUS;
        dy = (dy / len) * THUMB_RADIUS;
      }
      knob.style.transform = `translate(${dx}px, ${dy}px)`;
      this.thumb.x = dx / THUMB_RADIUS;
      this.thumb.y = -dy / THUMB_RADIUS;
    };
    base.addEventListener('touchstart', (e) => {
      e.preventDefault();
      const t = e.changedTouches[0];
      id = t.identifier;
      const r = base.getBoundingClientRect();
      cx = r.left + r.width / 2;
      cy = r.top + r.height / 2;
      move(t);
    });
    base.addEventListener('touchmove', (e) => {
      e.preventDefault();
      for (const t of e.changedTouches) if (t.identifier === id) move(t);
    });
    const end = (e) => {
      for (const t of e.changedTouches) if (t.identifier === id) {
        id = null;
        this.thumb.x = this.thumb.y = 0;
        knob.style.transform = '';
      }
    };
    base.addEventListener('touchend', end);
    base.addEventListener('touchcancel', end);
  }

  /** The active context's touch buttons (InputBindings.touch). */
  _renderButtons(root) {
    for (const [action, b] of Object.entries(InputBindings)) {
      if (!b.touch || !b.contexts.includes(this.context)) continue;
      const btn = document.createElement('button');
      btn.className = 'rv-round';
      btn.textContent = b.touch.label;
      const [sx, ox, sy, oy] = b.touch.position;
      const size = b.touch.size;
      btn.style.width = btn.style.height = `${size}px`;
      btn.style.left = `calc(${sx * 100}% + ${ox - size / 2}px)`;
      btn.style.top = `calc(${sy * 100}% + ${oy - size / 2}px)`;
      const tid = `touch:${action}`;
      btn.addEventListener('touchstart', (e) => {
        e.preventDefault();
        btn.classList.add('pressed');
        if (b.kind === 'Toggle') btn.classList.toggle('latched');
        this.inject(action, tid, true);
      });
      const up = (e) => {
        e.preventDefault();
        btn.classList.remove('pressed');
        this.inject(action, tid, false);
      };
      btn.addEventListener('touchend', up);
      btn.addEventListener('touchcancel', up);
      root.appendChild(btn);
    }
  }

  /** Enables / disables every input (cutscene fades, loading). Disabling releases what is held. */
  setEnabled(on) {
    this.enabled = !!on;
    if (!on) this._releaseAll();
    this._renderTouch();
  }
}
