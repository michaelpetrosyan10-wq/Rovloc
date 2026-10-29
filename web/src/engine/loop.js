// The game loop: a fixed 30 Hz logic tick (`onTick(dt)`) and a per-display-frame render callback (`onFrame(dt)`).
// Ticks run from an accumulator so game logic is frame-rate independent; at most MAX_CATCH_UP ticks run per frame
// (a long stall drops time instead of spiralling). Frame dt is clamped to MAX_FRAME_DT, like the Roblox render step.
// `time` is the game clock (seconds, paused while the loop is paused); `realTime` keeps running.

import { Signal } from './signal.js';

export const TICK_HZ = 30;
const TICK_DT = 1 / TICK_HZ;
const MAX_CATCH_UP = 4;
const MAX_FRAME_DT = 0.1;

/** Ordering slots for frame callbacks: lower runs first. */
export const FramePriority = Object.freeze({ Input: 0, Logic: 100, Camera: 200, Default: 300, Render: 1000 });

export class Loop {
  constructor() {
    /** Game clock in seconds (advances only while running and not paused). */
    this.time = 0;
    /** Wall clock in seconds since start. */
    this.realTime = 0;
    this.paused = false;
    this.frameCount = 0;
    /** Interpolation share of the next tick (0..1) for smoothing render state between ticks. */
    this.alpha = 0;
    this.tickDt = TICK_DT;
    /** @type {Array<{fn: (dt: number) => void, priority: number}>} */
    this.ticks = [];
    /** @type {Array<{fn: (dt: number) => void, priority: number}>} */
    this.frames = [];
    this.accumulator = 0;
    this.last = 0;
    this.running = false;
    this.raf = 0;
    this.onError = new Signal();
    this._step = this._step.bind(this);
  }

  /**
   * Fixed 30 Hz game logic. Returns an unsubscribe function.
   * @param {(dt: number) => void} fn
   * @param {number} [priority] lower runs first
   */
  onTick(fn, priority = FramePriority.Default) {
    return add(this.ticks, fn, priority);
  }

  /**
   * Once per rendered frame (dt clamped to 0.1 s). Returns an unsubscribe function.
   * @param {(dt: number) => void} fn
   * @param {number} [priority] lower runs first
   */
  onFrame(fn, priority = FramePriority.Default) {
    return add(this.frames, fn, priority);
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.last = performance.now();
    this.raf = requestAnimationFrame(this._step);
  }

  stop() {
    this.running = false;
    cancelAnimationFrame(this.raf);
  }

  setPaused(paused) {
    this.paused = !!paused;
  }

  /** Runs one frame by hand (tests, headless capture). */
  stepManual(dt) {
    this._run(Math.min(dt, MAX_FRAME_DT), dt);
  }

  _step(now) {
    if (!this.running) return;
    this.raf = requestAnimationFrame(this._step);
    const raw = Math.max(0, (now - this.last) / 1000);
    this.last = now;
    this._run(Math.min(raw, MAX_FRAME_DT), raw);
  }

  _run(dt, raw) {
    this.realTime += raw;
    this.frameCount++;
    const gameDt = this.paused ? 0 : dt;
    if (!this.paused) {
      this.accumulator += dt;
      let n = 0;
      while (this.accumulator >= TICK_DT && n < MAX_CATCH_UP) {
        this.accumulator -= TICK_DT;
        this.time += TICK_DT;
        call(this.ticks, TICK_DT, this.onError);
        n++;
      }
      if (n === MAX_CATCH_UP) this.accumulator = Math.min(this.accumulator, TICK_DT);
    }
    this.alpha = this.accumulator / TICK_DT;
    call(this.frames, gameDt, this.onError, dt);
  }
}

function add(list, fn, priority) {
  const entry = { fn, priority };
  let i = list.length;
  while (i > 0 && list[i - 1].priority > priority) i--;
  list.splice(i, 0, entry);
  return () => {
    const at = list.indexOf(entry);
    if (at >= 0) list.splice(at, 1);
  };
}

function call(list, dt, onError, realDt) {
  const snapshot = list.slice();
  for (const entry of snapshot) {
    try {
      entry.fn(dt, realDt);
    } catch (err) {
      console.error('[loop]', err);
      onError.fire(err);
    }
  }
}
