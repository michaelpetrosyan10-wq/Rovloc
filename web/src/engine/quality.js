// Quality tiers (the web RenderBudgetController): what the device may render, as Low / Medium / High, plus dynamic
// resolution inside the tier.
//
//   * Tiers carry the Roblox budget's fields (lights, shadows, shafts, dust, flashlight haze) and the web's own
//     (internal resolution range, shadow map size, bloom, normal maps, anisotropy).
//   * Auto tier. A frame-time probe (probe()) renders the real scene for a moment at Medium and picks the tier the
//     frame time allows; the pick is remembered in the save. While playing, the RenderBudgetController rule adapts it:
//     a tier drops after DROP_AFTER seconds under LOW_FPS at its lowest resolution, and rises after RAISE_AFTER
//     seconds over HIGH_FPS at full resolution (doubling the wait after a raise that had to drop again, up to
//     MAX_RAISE_AFTER), never above the ceiling (the Quality setting when not Auto).
//   * Dynamic resolution. Every WINDOW the internal render scale steps down when the frame rate is under the target
//     (30 fps, the Chromebook goal) and up when there is headroom, between the tier's minScale and maxScale, capped
//     at the tier's maxHeight internal pixels.

import { Signal } from './signal.js';

export const Tiers = /** @type {const} */ (['Low', 'Medium', 'High']);

/** @typedef {'Low'|'Medium'|'High'} Tier */

export const Budgets = Object.freeze({
  Low: Object.freeze({
    tier: 'Low', lights: 16, shadows: false, shadowLights: 0, windowLights: 4, shafts: 0, dust: 0,
    flashlightHaze: false, dof: false, particleScale: 0.4, pointLights: 2,
    minScale: 0.5, maxScale: 0.8, maxHeight: 576, flashlightShadow: false, shadowMapSize: 0, bloom: false,
    normalMaps: false, anisotropy: 1, grain: true,
  }),
  Medium: Object.freeze({
    tier: 'Medium', lights: 30, shadows: true, shadowLights: 20, windowLights: 6, shafts: 6, dust: 3,
    flashlightHaze: true, dof: false, particleScale: 0.7, pointLights: 4,
    minScale: 0.55, maxScale: 1, maxHeight: 720, flashlightShadow: true, shadowMapSize: 512, bloom: false,
    normalMaps: true, anisotropy: 2, grain: true,
  }),
  High: Object.freeze({
    tier: 'High', lights: 48, shadows: true, shadowLights: 40, windowLights: 10, shafts: 14, dust: 8,
    flashlightHaze: true, dof: true, particleScale: 1, pointLights: 4,
    minScale: 0.7, maxScale: 1, maxHeight: 1080, flashlightShadow: true, shadowMapSize: 1024, bloom: true,
    normalMaps: true, anisotropy: 4, grain: true,
  }),
});

const TARGET_FPS = 30;
const RAISE_SCALE_FPS = 42;
const LOW_FPS = 26;
const HIGH_FPS = 55;
const DROP_AFTER = 5;
const RAISE_AFTER = 20;
const MAX_RAISE_AFTER = 160;
const FLAP_WINDOW = 30;
const WINDOW = 1;
const SCALE_STEP = 0.05;
const PROBE_SECONDS = 1.6;

export class Quality {
  /** @param {import('./settings.js').Settings} settings @param {import('./save.js').Save} save */
  constructor(settings, save) {
    this.settings = settings;
    this.save = save;
    const remembered = save.get('autoTier', null);
    /** @type {Tier} */
    this.autoTier = Tiers.includes(remembered) ? remembered : 'Medium';
    this.ceiling = this._ceiling();
    /** @type {Tier} */
    this.tier = this.settings.get('Quality') === 'Auto' ? this.autoTier : this.ceiling;
    this.budget = Budgets[this.tier];
    this.scale = this.budget.maxScale;
    /** @type {Signal<[any]>} fires with the new budget */
    this.changed = new Signal();
    /** @type {Signal<[number]>} fires with the new render scale */
    this.scaleChanged = new Signal();
    this.lowFor = 0;
    this.highFor = 0;
    this.sinceChange = 0;
    this.lastChange = 'None';
    this.raiseAfter = RAISE_AFTER;
    this.frames = 0;
    this.elapsed = 0;
    this.fps = 60;
    this.frameMs = 16;
    this.probing = null;
    this.adapt = true;
    settings.changed.connect((key) => {
      if (key !== 'Quality') return;
      this.ceiling = this._ceiling();
      this.setTier(this.settings.get('Quality') === 'Auto' ? this.autoTier : this.ceiling);
    });
  }

  _ceiling() {
    const q = this.settings.get('Quality');
    return q === 'Auto' ? 'High' : q;
  }

  /** @param {Tier} tier */
  setTier(tier) {
    if (!Tiers.includes(tier) || tier === this.tier) return;
    this.tier = tier;
    this.budget = Budgets[tier];
    this.scale = Math.min(Math.max(this.scale, this.budget.minScale), this.budget.maxScale);
    this.sinceChange = 0;
    this.changed.fire(this.budget);
    this.scaleChanged.fire(this.scale);
  }

  /**
   * Starts the frame-time probe: for PROBE_SECONDS the tier is Medium at full scale, then the auto tier is picked
   * from the measured frame time. `done(tier)` is called with the pick.
   */
  probe(done) {
    if (this.settings.get('Quality') !== 'Auto') {
      if (done) done(this.tier);
      return;
    }
    const before = this.tier;
    if (before !== 'Medium') this.setTier('Medium');
    this.scale = this.budget.maxScale;
    this.scaleChanged.fire(this.scale);
    this.probing = { t: 0, frames: 0, skip: 10, done };
  }

  /** Feeds one frame's real duration (seconds). Call once per rendered frame. */
  frame(dt) {
    if (!(dt > 0) || dt > 0.5) return;
    const p = this.probing;
    if (p) {
      if (p.skip > 0) {
        p.skip--;
        return;
      }
      p.t += dt;
      p.frames++;
      if (p.t >= PROBE_SECONDS) {
        this.probing = null;
        const ms = (p.t / p.frames) * 1000;
        const tier = ms < 13 ? 'High' : ms < 24 ? 'Medium' : 'Low';
        this.autoTier = tier;
        this.save.set('autoTier', tier);
        this.setTier(tier);
        if (p.done) p.done(tier);
      }
      return;
    }
    this.frames++;
    this.elapsed += dt;
    if (this.elapsed < WINDOW) return;
    this.fps = this.frames / this.elapsed;
    this.frameMs = (this.elapsed / this.frames) * 1000;
    const seconds = this.elapsed;
    this.frames = 0;
    this.elapsed = 0;
    if (!this.adapt) return;
    this._stepScale(this.fps);
    if (this.settings.get('Quality') === 'Auto') this._stepTier(this.fps, seconds);
  }

  _stepScale(fps) {
    const b = this.budget;
    let s = this.scale;
    if (fps < TARGET_FPS) s = Math.max(b.minScale, s - SCALE_STEP * (fps < TARGET_FPS * 0.75 ? 2 : 1));
    else if (fps > RAISE_SCALE_FPS) s = Math.min(b.maxScale, s + SCALE_STEP);
    if (Math.abs(s - this.scale) > 1e-3) {
      this.scale = s;
      this.scaleChanged.fire(s);
    }
  }

  _stepTier(fps, seconds) {
    this.sinceChange += seconds;
    const index = Tiers.indexOf(this.tier);
    const b = this.budget;
    if (fps < LOW_FPS && this.scale <= b.minScale + 1e-3) {
      this.highFor = 0;
      this.lowFor += seconds;
      if (this.lowFor >= DROP_AFTER && index > 0) {
        if (this.lastChange === 'Raised' && this.sinceChange <= FLAP_WINDOW) {
          this.raiseAfter = Math.min(this.raiseAfter * 2, MAX_RAISE_AFTER);
        }
        this.lowFor = 0;
        this.lastChange = 'Dropped';
        this.autoTier = Tiers[index - 1];
        this.setTier(this.autoTier);
      }
    } else if (fps > HIGH_FPS && this.scale >= b.maxScale - 1e-3) {
      this.lowFor = 0;
      this.highFor += seconds;
      if (this.highFor >= this.raiseAfter && index < Tiers.indexOf(this.ceiling)) {
        this.highFor = 0;
        this.lastChange = 'Raised';
        this.autoTier = Tiers[index + 1];
        this.setTier(this.autoTier);
      }
    } else {
      this.lowFor = 0;
      this.highFor = 0;
    }
    if (this.sinceChange >= MAX_RAISE_AFTER) this.raiseAfter = RAISE_AFTER;
  }
}
