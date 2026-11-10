// Graphics tiers (the web GraphicsController + RenderBudgetController): Max (the default, everything on, for a strong
// PC) down to Potato (school Chromebooks), the same five tiers and names as the Roblox game's GraphicsConfig.
//
//   * A tier only strips visual overhead from this page's own view: render scale, shadows, post, particles, texture
//     resolution, render distance and decorative Detail chunks. It never changes physics, the map, collision,
//     hitboxes, navigation, the Creature, its decisions or any mechanic (tools/tier-parity.mjs asserts identical
//     gameplay at Max and at Potato, tick for tick).
//   * The tier is the player's Graphics setting (saved in the settings blob). Changing it applies live: render targets
//     resize, materials recompile, the tier's texture set streams in the background (TextureStreamer) and swaps in
//     when it has arrived.
//   * No automatic switching. While playing, the frame rate is watched; when a non-Potato tier stays under HINT_FPS (30)
//     for HINT_AFTER seconds, `hint` becomes 'Potato' and `hinted` fires once (the menu and a toast suggest Potato;
//     the tier stays what the player chose).
//   * Dynamic resolution inside a tier (all but Max): every WINDOW the internal render scale steps down when the frame
//     rate is under the tier's target (60 fps) and up when there is headroom, between the tier's minScale and
//     maxScale, of at most `maxHeight` internal pixels (Potato: 50-70 % of 720p). Max renders at 100 %, or at 150 %
//     with the Max+ setting (supersampling).

import { Signal } from './signal.js';

/** Best first, the order the Graphics menu shows them in (GraphicsConfig.Order). */
export const Tiers = Object.freeze(['Max', 'High', 'Medium', 'Low', 'Potato']);
export const DefaultTier = 'Max';

/** @typedef {'Max'|'High'|'Medium'|'Low'|'Potato'} Tier */

/**
 * What each tier draws. Every field is visual only.
 *
 *   maxScale / minScale    the dynamic resolution range (fraction of the canvas, after the maxHeight cap)
 *   maxHeight              internal pixel rows at most (Potato: 720, so 50-70 % of 720p)
 *   dynamic                whether the render scale adapts to the frame rate
 *   shadowMapSize          the torch's shadow map (0: no torch shadow)
 *   shadowTaps             torch shadow filter taps (16 Poisson soft PCF .. 4 bilinear corners)
 *   shadowSoftness         the torch filter's radius in shadow-map texels
 *   fixtureShadows         the nearest fixtures that cast real-time shadows of moving things (the Creature)
 *   fixtureShadowSize      their shadow maps' size
 *   pointLights            dynamic point-light slots compiled into the world shader
 *   normalMaps             normal and roughness maps on textured surfaces
 *   textureSize            the texture set the tier streams (2048 / 1024 / 512 / 256 px colour maps)
 *   anisotropy             texture filtering
 *   bloom                  bloom chain levels (0: none)
 *   ssao                   screen-space ambient occlusion: 'Full' (full resolution) / 'Half' / null
 *   volumetricSteps        ray-marched torch cone with its shadow (light shafts cut by the Creature); 0: none
 *   flashlightHaze         the torch's cheap haze ribbons (where the cone is not ray-marched)
 *   shafts / dust          fixture haze cones and dust-mote clouds in them
 *   particles / particleScale  GPU particles (steam vents, drips, ceiling grit, torch motes) and their rate
 *   dof                    the panic depth of field
 *   aa                     'FXAA' or null
 *   grain / chroma         film grain amount, chromatic aberration strength
 *   detailLimit            decorative Detail chunks drawn up to this level (chunks[].detail; 0: none)
 *   wear                   the walls' grime / soot multiply decals
 *   viewDistance           studs at which the haze closes, darkened (Infinity: the level's own haze only)
 *   remoteTorches          teammates' torch beams drawn (nearest first)
 *   look                   the Creature's look tier (look.js LookTiers)
 */
export const Budgets = Object.freeze({
  Max: Object.freeze({
    tier: 'Max', index: 0, maxScale: 1, minScale: 1, maxHeight: 2160, dynamic: false,
    shadowMapSize: 2048, shadowTaps: 16, shadowSoftness: 2.6, flashlightShadow: true,
    fixtureShadows: 4, fixtureShadowSize: 1024, pointLights: 4, normalMaps: true, textureSize: 2048, anisotropy: 16,
    bloom: 3, ssao: 'Full', volumetricSteps: 28, flashlightHaze: false, shafts: 20, dust: 12, particles: true,
    particleScale: 1, dof: true, aa: 'FXAA', grain: 0.035, chroma: 1, detailLimit: 3, wear: true,
    viewDistance: Infinity, remoteTorches: 3, look: 'Max',
  }),
  High: Object.freeze({
    tier: 'High', index: 1, maxScale: 1, minScale: 0.85, maxHeight: 1440, dynamic: true,
    shadowMapSize: 1024, shadowTaps: 8, shadowSoftness: 2, flashlightShadow: true,
    fixtureShadows: 3, fixtureShadowSize: 1024, pointLights: 4, normalMaps: true, textureSize: 1024, anisotropy: 8,
    bloom: 2, ssao: 'Half', volumetricSteps: 14, flashlightHaze: false, shafts: 14, dust: 8, particles: true,
    particleScale: 1, dof: true, aa: 'FXAA', grain: 0.035, chroma: 0.6, detailLimit: 3, wear: true,
    viewDistance: 300, remoteTorches: 3, look: 'Max',
  }),
  Medium: Object.freeze({
    tier: 'Medium', index: 2, maxScale: 1, minScale: 0.7, maxHeight: 1080, dynamic: true,
    shadowMapSize: 1024, shadowTaps: 9, shadowSoftness: 1, flashlightShadow: true,
    fixtureShadows: 2, fixtureShadowSize: 512, pointLights: 4, normalMaps: true, textureSize: 1024, anisotropy: 4,
    bloom: 1, ssao: null, volumetricSteps: 0, flashlightHaze: true, shafts: 6, dust: 3, particles: true,
    particleScale: 0.7, dof: false, aa: 'FXAA', grain: 0.035, chroma: 0, detailLimit: 2, wear: true,
    viewDistance: 220, remoteTorches: 2, look: 'Max',
  }),
  Low: Object.freeze({
    tier: 'Low', index: 3, maxScale: 0.85, minScale: 0.6, maxHeight: 720, dynamic: true,
    shadowMapSize: 512, shadowTaps: 4, shadowSoftness: 1, flashlightShadow: true,
    fixtureShadows: 0, fixtureShadowSize: 0, pointLights: 2, normalMaps: false, textureSize: 512, anisotropy: 2,
    bloom: 0, ssao: null, volumetricSteps: 0, flashlightHaze: false, shafts: 0, dust: 0, particles: true,
    particleScale: 0.4, dof: false, aa: null, grain: 0.03, chroma: 0, detailLimit: 1, wear: false,
    viewDistance: 160, remoteTorches: 1, look: 'Potato',
  }),
  Potato: Object.freeze({
    tier: 'Potato', index: 4, maxScale: 0.7, minScale: 0.5, maxHeight: 720, dynamic: true,
    shadowMapSize: 0, shadowTaps: 0, shadowSoftness: 0, flashlightShadow: false,
    fixtureShadows: 0, fixtureShadowSize: 0, pointLights: 2, normalMaps: false, textureSize: 256, anisotropy: 1,
    bloom: 0, ssao: null, volumetricSteps: 0, flashlightHaze: false, shafts: 0, dust: 0, particles: false,
    particleScale: 0, dof: false, aa: null, grain: 0, chroma: 0, detailLimit: 0, wear: false,
    viewDistance: 120, remoteTorches: 1, look: 'Potato',
  }),
});

/** Max+ (the Supersample setting): Max renders at this scale (capped at SUPERSAMPLE_MAX_HEIGHT rows). */
export const SUPERSAMPLE = 1.5;
const SUPERSAMPLE_MAX_HEIGHT = 3240;

const TARGET_FPS = 60;
const DROP_BELOW_FPS = 54; // under the target with a margin: a 60 Hz display never reports more than 60
const RAISE_ABOVE_FPS = 58.5; // pinned at the display rate: there is headroom
const RAISE_AFTER = 3; // seconds at the display rate before the scale steps up again
const WINDOW = 1;
const SCALE_STEP = 0.05;
export const HINT_FPS = 30;
export const HINT_AFTER = 12;

/** The old Quality setting (Auto / Low / Medium / High) as a Graphics tier, for saves from before the five tiers. */
export function migrateQuality(quality, autoTier) {
  if (quality === 'Low' || quality === 'Medium' || quality === 'High') return quality;
  if (quality === 'Auto' && (autoTier === 'Low' || autoTier === 'Medium')) return autoTier;
  return null;
}

export class Quality {
  /** @param {import('./settings.js').Settings} settings @param {import('./save.js').Save} save */
  constructor(settings, save) {
    this.settings = settings;
    this.save = save;
    /** @type {Tier} */
    this.tier = Tiers.includes(settings.get('Graphics')) ? settings.get('Graphics') : DefaultTier;
    this.budget = Budgets[this.tier];
    this.supersample = !!settings.get('Supersample');
    this.scale = this._topScale();
    /** @type {Signal<[any]>} fires with the new budget */
    this.changed = new Signal();
    /** @type {Signal<[number]>} fires with the new render scale */
    this.scaleChanged = new Signal();
    /** @type {Signal<[string]>} fires once when the frame rate stays low: the suggested tier ('Potato') */
    this.hinted = new Signal();
    /** The tier the frame rate suggests (null: none), shown by the Graphics menu; never applied by itself. */
    this.hint = null;
    this.frames = 0;
    this.elapsed = 0;
    this.fps = 60;
    this.frameMs = 16;
    this.highFor = 0;
    this.lowFor = 0;
    /** false: the render scale stays where it is (tests, screenshots) */
    this.adapt = true;
    /** true while the frame rate means nothing for the hint (menus, loading, cutscenes the game flags) */
    this.watchPaused = false;
    settings.changed.connect((key) => {
      if (key === 'Graphics') this.setTier(this.settings.get('Graphics'));
      if (key === 'Supersample') {
        this.supersample = !!this.settings.get('Supersample');
        this.scale = this._topScale();
        this.scaleChanged.fire(this.scale);
      }
    });
  }

  /** The tier's full render scale (Max+: supersampled). */
  _topScale() {
    return this.tier === 'Max' && this.supersample ? SUPERSAMPLE : this.budget.maxScale;
  }

  /** The internal render height cap for the current tier. */
  maxHeight() {
    return this.tier === 'Max' && this.supersample ? SUPERSAMPLE_MAX_HEIGHT : this.budget.maxHeight;
  }

  /**
   * The internal render size for a canvas of `width` x `height` device pixels: the tier's cap, then the scale (Potato
   * on a 1080p screen: 720 x 0.5..0.7 rows).
   */
  internalSize(width, height) {
    const h = Math.min(Math.min(height, this.budget.maxHeight) * this.scale, this.maxHeight());
    const w = h * (width / Math.max(1, height));
    return [Math.max(64, Math.round(w)), Math.max(36, Math.round(h))];
  }

  /**
   * Applies a tier now (the Graphics setting calls this; tests and screenshots may too). Visual only.
   * @param {Tier} tier
   */
  setTier(tier) {
    if (!Tiers.includes(tier) || tier === this.tier) return;
    this.tier = tier;
    this.budget = Budgets[tier];
    this.scale = this._topScale();
    this.lowFor = 0;
    this.highFor = 0;
    if (this.hint && Tiers.indexOf(tier) >= Tiers.indexOf(this.hint)) this.hint = null;
    this.changed.fire(this.budget);
    this.scaleChanged.fire(this.scale);
  }

  /** Feeds one frame's real duration (seconds). Call once per rendered frame. */
  frame(dt) {
    if (!(dt > 0) || dt > 0.5) return;
    this.frames++;
    this.elapsed += dt;
    if (this.elapsed < WINDOW) return;
    this.fps = this.frames / this.elapsed;
    this.frameMs = (this.elapsed / this.frames) * 1000;
    const seconds = this.elapsed;
    this.frames = 0;
    this.elapsed = 0;
    if (!this.adapt) return;
    this._stepScale(this.fps, seconds);
    this._watch(this.fps, seconds);
  }

  _stepScale(fps, seconds) {
    const b = this.budget;
    if (!b.dynamic) return;
    let s = this.scale;
    if (fps < DROP_BELOW_FPS) {
      this.highFor = 0;
      s = Math.max(b.minScale, s - SCALE_STEP * (fps < TARGET_FPS * 0.7 ? 2 : 1));
    } else if (fps > RAISE_ABOVE_FPS) {
      this.highFor += seconds;
      if (this.highFor >= RAISE_AFTER) {
        this.highFor = 0;
        s = Math.min(b.maxScale, s + SCALE_STEP);
      }
    } else this.highFor = 0;
    if (Math.abs(s - this.scale) > 1e-3) {
      this.scale = s;
      this.scaleChanged.fire(s);
    }
  }

  /** The Auto hint: a low frame rate that lasts suggests Potato, once; it never switches by itself. */
  _watch(fps, seconds) {
    if (this.tier === 'Potato' || this.watchPaused || this.hint) {
      this.lowFor = 0;
      return;
    }
    if (fps < HINT_FPS - 0.5) this.lowFor += seconds;
    else this.lowFor = Math.max(0, this.lowFor - seconds * 2);
    if (this.lowFor >= HINT_AFTER) {
      this.lowFor = 0;
      this.hint = 'Potato';
      this.hinted.fire(this.hint);
    }
  }
}
