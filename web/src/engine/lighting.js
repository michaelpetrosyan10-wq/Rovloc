// Lighting: everything that changes the light at run time (LightingController + Film + the RenderBudget's light
// budget), on top of the baked vertex light.
//
//   * Flicker. Fixtures sharing a flicker group flicker together: smooth value noise, sharp dropouts and seeded
//     blackouts with a stuttering recovery, scheduled in fixed time slots; a pure function of (RunSeed, group, time).
//     The factor of every group is written into the shared 256-texel flicker texture each frame, which scales each
//     vertex's baked share of that group (and the Neon glow of its tubes).
//   * Overrides. setOverride(lightId, brightness|null) pins a light (Timeline tracks, the pool floodlights, the
//     classroom glow): a baked light's group factor becomes brightness / base; a dynamic light burns at that
//     brightness. burst(lightId) surges a bulb to 4x, stutters and kills it for the run.
//   * Dynamic lights. Scripted / unbaked lights and lights the game adds (addLight: the creature's eyes, a flare)
//     compete for the tier's point-light slots by distance to the camera.
//   * Film. The level film (data.film, else LightingMood's table) eases at 0.9/s toward the level the camera is on:
//     fog colour / density, exposure, contrast, saturation, lift, bloom, the resting vignette, how much shafts and
//     dust show; the area grade tint eases at 1.2/s.
//   * Lightning. lightning({intensity, stages}) flashes the sky (two-stage envelope), damped to 0.18 indoors; while the
//     camera is outdoors an ambient storm throws seeded lightning with thunder unless setStormEnabled(false).

import * as THREE from 'three';
import { MAX_POINT } from './materials.js';
import { clamp01, lerp, noise1, seededRandom, smoothstep } from './math.js';

const NOISE_PERIOD = 4096;
const RECOVERY_SECONDS = 0.45;
const RECOVERY_HZ = 14;
const BURST_PEAK = 4;
const FILM_RATE = 0.9;
const GRADE_RATE = 1.2;
const INDOOR_FLASH = 0.18;
const FLASH_SKY = 2.4;
const STORM_SLOT = 11;
const STORM_CHANCE = 0.8;
const STORM_QUIET_AFTER_SCRIPTED = 8;
const FOG_SCALE = 0.02; // Atmosphere density -> exp2 fog coefficient
const LOBBY = 'Lobby';
const EXPOSURE_BASE = 0.3; // LightingRig.Baseline.ExposureCompensation
/**
 * Web calibration of the exposure, in stops on top of the film's (the browser frame has no Future-lighting
 * auto-exposure, and players found the Roblox night "pitch black"): dark but readable, a lit corridor around 18-30
 * mean luminance (of 255) without the torch, the safe warm lobby clearly readable, the torch hotspot unclipped.
 */
export const ExposureTrim = { base: 0.25, Lobby: 0.8 };
// (The flashlight is scaled back by the same trim: see shared.torchGain.)

const rgb = (r, g, b) => [r, g, b];

/** LightingMood BASE_FILM and the per-level patches (used when the world data carries no film). */
const BASE_FILM = Object.freeze({
  exposure: 0.08, contrast: 0.2, saturation: -0.22, lift: 0.015, bloomIntensity: 0.85, bloomSize: 34,
  bloomThreshold: 1.12, density: 0.34, offset: 0.06, haze: 1.9, glare: 0.2, hazeColor: rgb(42, 48, 52),
  decay: rgb(20, 26, 28), sunRays: 0.03, dofFar: 0.14, dofFocus: 38, dofRadius: 44, vignette: 0.32, shafts: 1,
  dust: 1, moon: 1,
});
const FILM_PATCHES = {
  Lobby: { exposure: 0.1, contrast: 0.14, saturation: -0.12, bloomIntensity: 0.8, bloomSize: 32, bloomThreshold: 1.15, density: 0.28, offset: 0.1, haze: 1.4, hazeColor: rgb(60, 52, 44), decay: rgb(30, 24, 20), dofFar: 0.1, dofRadius: 50, vignette: 0.26, shafts: 0.8, dust: 0.8, moon: 0 },
  Level0_Basement: { exposure: 0.05, saturation: -0.18, bloomIntensity: 0.95, bloomSize: 36, bloomThreshold: 1.05, density: 0.42, offset: 0.04, haze: 2.4, glare: 0.35, hazeColor: rgb(62, 50, 36), decay: rgb(34, 24, 14), sunRays: 0, dofFar: 0.16, dofFocus: 34, dofRadius: 40, vignette: 0.36, shafts: 1.25, dust: 1.4, moon: 0 },
  Level1_Hallways: { saturation: -0.24, hazeColor: rgb(42, 52, 48), decay: rgb(20, 28, 26) },
  Level2_ScienceHall: { exposure: 0.1, bloomIntensity: 0.9, bloomThreshold: 1.1, density: 0.32, haze: 1.7, hazeColor: rgb(38, 52, 54), decay: rgb(18, 28, 30), shafts: 0.95, dust: 0.9 },
  Level3_Gymnasium: { bloomIntensity: 0.9, bloomSize: 38, bloomThreshold: 1.1, density: 0.38, haze: 2.1, hazeColor: rgb(46, 52, 42), decay: rgb(24, 28, 20), dofFocus: 44, dofRadius: 52, shafts: 1.15, dust: 1.2, moon: 1.15 },
  Level4_FloodedPool: { exposure: 0.12, contrast: 0.22, saturation: -0.16, bloomIntensity: 1, bloomSize: 40, bloomThreshold: 1, density: 0.46, offset: 0.02, haze: 2.6, glare: 0.3, hazeColor: rgb(40, 54, 62), decay: rgb(18, 30, 38), dofFar: 0.16, vignette: 0.34, shafts: 1.2, dust: 0.6, moon: 1.1 },
  Level5_Roof: { exposure: 0.2, contrast: 0.16, bloomIntensity: 0.75, bloomSize: 30, bloomThreshold: 1.2, density: 0.36, offset: 0.12, haze: 2.2, glare: 0.1, hazeColor: rgb(40, 44, 54), decay: rgb(20, 24, 30), sunRays: 0.06, dofFar: 0.12, dofFocus: 48, dofRadius: 60, vignette: 0.3, shafts: 0.8, dust: 0, moon: 0 },
};
/** LightingMood.LEVELS grade tints. */
const GRADES = {
  Lobby: rgb(255, 240, 222), Level0_Basement: rgb(255, 236, 214), Level1_Hallways: rgb(236, 255, 244),
  Level2_ScienceHall: rgb(232, 252, 252), Level3_Gymnasium: rgb(244, 255, 236), Level4_FloodedPool: rgb(226, 244, 255),
  Level5_Roof: rgb(234, 240, 255),
};

const NUMERIC_FILM = ['exposure', 'trim', 'contrast', 'saturation', 'lift', 'bloomIntensity', 'bloomThreshold', 'density',
  'haze', 'vignette', 'shafts', 'dust', 'moon', 'dofFar'];

/** Seeded flicker character of one group (LightingController.flickerProfile). */
export function flickerProfile(seed, group) {
  const r = seededRandom(seed, `flicker:${group}`);
  return {
    rate: r.nextNumber(1.5, 7),
    depth: r.nextNumber(0.25, 0.75),
    dropRate: r.nextNumber(4, 11),
    dropThreshold: r.nextNumber(0.55, 0.85),
    slotLength: r.nextNumber(7, 16),
    blackoutChance: r.nextNumber(0.3, 0.65),
    minBlackout: 0.15,
    maxBlackout: r.nextNumber(0.8, 2.6),
    noiseSeed: r.nextNumber(0, 1000),
    dropSeed: r.nextNumber(0, 1000),
  };
}

export function blackoutSlot(seed, group, profile, slot) {
  const r = seededRandom(seed, `blackout:${group}:${slot}`);
  if (r.nextNumber() >= profile.blackoutChance) return { slot, startsAt: -1, endsAt: -1 };
  const duration = r.nextNumber(profile.minBlackout, profile.maxBlackout);
  const latest = Math.max(0, profile.slotLength - duration - RECOVERY_SECONDS);
  const startsAt = slot * profile.slotLength + r.nextNumber(0, latest);
  return { slot, startsAt, endsAt: startsAt + duration };
}

export function flickerFactor(profile, blackout, t) {
  if (blackout.startsAt >= 0) {
    if (t >= blackout.startsAt && t < blackout.endsAt) return 0;
    if (t >= blackout.endsAt && t < blackout.endsAt + RECOVERY_SECONDS) {
      return Math.floor((t - blackout.endsAt) * RECOVERY_HZ) % 2 === 0 ? 0.12 : 0.85;
    }
  }
  const sample = t % NOISE_PERIOD;
  const wave = noise1(sample * profile.rate, profile.noiseSeed);
  let factor = 1 - profile.depth * smoothstep(-0.2, 0.8, wave);
  if (noise1(sample * profile.dropRate, profile.dropSeed) > profile.dropThreshold) factor *= 0.12;
  return clamp01(factor);
}

/** Lightning envelope 0..1 at t seconds into a flash; null once over (two-stage or single). */
export function lightningEnvelope(t, stages) {
  if (t < 0) return 0;
  if (stages >= 2) {
    if (t < 0.05) return (0.65 * t) / 0.05;
    if (t < 0.11) return 0.65;
    if (t < 0.3) return lerp(0.65, 0.06, (t - 0.11) / 0.19);
    if (t < 0.42) return 0.04;
    if (t < 0.47) return lerp(0.04, 1, (t - 0.42) / 0.05);
    if (t < 0.6) return 1;
    if (t < 1.7) return Math.exp(-4 * (t - 0.6));
    return null;
  }
  if (t < 0.05) return t / 0.05;
  if (t < 0.12) return 1;
  if (t < 1.1) return Math.exp(-4.5 * (t - 0.12));
  return null;
}

export function burstMultiplier(t) {
  if (t < 0.05) return lerp(1, BURST_PEAK, Math.max(0, t) / 0.05);
  if (t < 0.14) return BURST_PEAK * (0.92 + 0.08 * Math.sin(t * 190));
  if (t < 0.42) return Math.floor(t * 30) % 2 === 0 ? 2.5 * (1 - (t - 0.14) / 0.28) : 0;
  return null;
}

export class Lighting {
  /** @param {import('./index.js').Engine} engine */
  constructor(engine) {
    this.engine = engine;
    this.world = engine.world;
    this.shared = engine.shared;
    const meta = engine.world.meta;
    this.seed = meta.seed || 1;
    /** @type {Map<number, {id: number, name: string, kind: string, initial: number, profile: any, blackout: any, override: number|null, burstAt: number|null, dead: boolean}>} */
    this.groups = new Map();
    for (const g of meta.flickerGroups || []) {
      if (g.id === 0) continue;
      this.groups.set(g.id, {
        id: g.id,
        name: g.name || `G${g.id}`,
        kind: g.kind,
        initial: g.initial ?? 1,
        profile: g.kind === 'flicker' ? flickerProfile(this.seed, g.name || `G${g.id}`) : null,
        blackout: { slot: -Infinity, startsAt: -1, endsAt: -1 },
        override: null,
        burstAt: null,
        dead: false,
      });
    }
    /** @type {Map<string, any>} light id -> world.json light */
    this.lightsById = new Map();
    for (const l of meta.lights || []) this.lightsById.set(l.id, l);
    /** @type {Array<any>} dynamic point lights (added by the game / creature, or forced on by an override) */
    this.dynamic = [];
    this.film = { ...normalizeFilm(BASE_FILM), trim: 0 };
    this.filmTarget = { ...BASE_FILM, trim: 0 };
    this.filmLevel = undefined;
    this.grade = new THREE.Color(1, 1, 1);
    this.gradeTarget = new THREE.Color(1, 1, 1);
    this.flashes = [];
    this.flash = 0;
    this.skyFlash = 0;
    this.stormEnabled = true;
    this.stormSlot = -1;
    this.stormAt = null;
    this.lastScripted = -Infinity;
    this.outdoors = false;
    this._fogColor = new THREE.Color();
  }

  _addDynamic(props) {
    const d = {
      id: props.id,
      position: new THREE.Vector3().copy(props.position),
      color: new THREE.Color(),
      brightness: props.brightness ?? 1,
      base: props.brightness ?? 1,
      range: props.range ?? 12,
      level: props.level,
      group: props.group || 0,
      enabled: true,
      override: null,
      burstAt: null,
      dead: false,
    };
    setLinear(d.color, props.color);
    this.dynamic.push(d);
    return d;
  }

  /**
   * Adds a dynamic point light (the creature's eye glow, a flare). Returns a handle {set(props), remove()}.
   * @param {{position: THREE.Vector3, color?: any, brightness?: number, range?: number}} props
   */
  addLight(props) {
    const d = this._addDynamic({ position: props.position, color: props.color || [1, 1, 1],
      brightness: props.brightness ?? 1, range: props.range ?? 12 });
    return {
      light: d,
      set: (p) => {
        if (p.position) d.position.copy(p.position);
        if (p.color) setLinear(d.color, p.color);
        if (p.brightness !== undefined) d.brightness = d.base = p.brightness;
        if (p.range !== undefined) d.range = p.range;
        if (p.enabled !== undefined) d.enabled = p.enabled;
      },
      remove: () => {
        const i = this.dynamic.indexOf(d);
        if (i >= 0) this.dynamic.splice(i, 1);
      },
    };
  }

  /**
   * Pins a light's brightness (null releases). A baked light acts through its flicker group (its group factor
   * becomes brightness / baked brightness); an unbaked light (broken at the start of the run) burns as a dynamic
   * point light at that brightness.
   */
  setOverride(lightId, brightness) {
    const l = this.lightsById.get(lightId);
    if (!l) return;
    const off = brightness === null || brightness === undefined;
    if (l.baked && l.group > 0) {
      const g = this.groups.get(l.group);
      if (g) g.override = off ? null : l.brightness > 0 ? brightness / l.brightness : 0;
      return;
    }
    let dyn = this.dynamic.find((d) => d.id === lightId);
    if (off) {
      if (dyn) this.dynamic.splice(this.dynamic.indexOf(dyn), 1);
      return;
    }
    if (!dyn) {
      dyn = this._addDynamic({ id: l.id, position: new THREE.Vector3(...l.pos), color: l.color, brightness, range: l.range, level: l.level });
    }
    dyn.override = brightness;
  }

  /** Factor override for a whole flicker group (null releases): Scripted:Floodlights 1 at the L4 switch. */
  setGroupFactor(groupId, factor) {
    const g = this.groups.get(groupId);
    if (g) g.override = factor === null || factor === undefined ? null : factor;
  }

  /** The id of a flicker group by its name ("Scripted:Floodlights"), or 0. */
  groupId(name) {
    for (const g of this.groups.values()) if (g.name === name) return g.id;
    return 0;
  }

  /** LightBurst: the bulb (its flicker group) surges to 4x, stutters and dies for the run. */
  burst(lightId) {
    const l = this.lightsById.get(lightId);
    if (!l) return;
    const now = this.engine.loop.realTime;
    const g = this.groups.get(l.group);
    if (g) g.burstAt = now;
    const dyn = this.dynamic.find((d) => d.id === lightId);
    if (dyn) dyn.burstAt = now;
  }

  /** Bursts every light of a flicker group (the classroom scare's glow + spill). */
  burstGroup(groupId) {
    const g = this.groups.get(groupId);
    if (g) g.burstAt = this.engine.loop.realTime;
  }

  /** Clears every override, burst and dead bulb (run reset). */
  resetForRun() {
    for (const g of this.groups.values()) {
      g.override = null;
      g.burstAt = null;
      g.dead = false;
    }
    for (const d of this.dynamic) {
      d.override = null;
      d.burstAt = null;
      d.dead = false;
    }
    this.flashes.length = 0;
    this.stormEnabled = true;
  }

  /** Lands the film and grade on the camera's level at once (spawns, teleports, cuts). */
  snapFilm() {
    this.snap = true;
    this.filmLevel = undefined;
  }

  /** OneShot "Lightning" (intensity 0..1+, stages 1|2). */
  lightning(opts = {}) {
    this.flashes.push({ start: this.engine.loop.realTime, strength: opts.intensity ?? 1, stages: opts.stages ?? 2 });
    if (!opts.ambient) this.lastScripted = this.engine.loop.realTime;
  }

  setStormEnabled(on) {
    this.stormEnabled = !!on;
  }

  /** The film of a layout: world.json's film (LightingMood.film per level, "Outdoor" outside every building). */
  filmFor(level) {
    const f = this._filmOf(level);
    f.trim = ExposureTrim.base + (ExposureTrim[level] || 0);
    f.exposure += f.trim;
    return f;
  }

  _filmOf(level) {
    const film = this.world.meta.film;
    const levelInfo = level && this.world.meta.levels[level];
    const key = levelInfo ? levelInfo.film : level ? null : 'Outdoor';
    if (film && film.levels && key && film.levels[key]) return normalizeFilm({ ...film.base, ...film.levels[key] });
    if (film && film.base && !key) return normalizeFilm(film.base);
    const k = level === 'Exterior' || !level ? 'Level5_Roof' : level === 'Stairwells' ? null : level;
    return k && FILM_PATCHES[k] ? normalizeFilm({ ...BASE_FILM, ...FILM_PATCHES[k] }) : normalizeFilm(BASE_FILM);
  }

  /** The area grade tint of a layout (LightingMood.LEVELS grade). */
  gradeFor(level, out) {
    const moods = this.world.meta.lighting && this.world.meta.lighting.moods;
    const key = level === 'Exterior' ? 'Level5_Roof' : level;
    const g = moods && moods[key] && moods[key].grade;
    if (g) return setLinear(out, g);
    const fallback = GRADES[key];
    return fallback ? out.setRGB(fallback[0] / 255, fallback[1] / 255, fallback[2] / 255) : out.setRGB(1, 1, 1);
  }

  /**
   * Per frame.
   * @param {number} dt
   * @param {THREE.Vector3} cameraPos
   * @param {string|null} level the layout the camera is on
   */
  update(dt, cameraPos, level) {
    const t = this.engine.loop.realTime;
    const flashScale = clamp01(this.engine.settings.get('FlashScale'));
    // flicker groups
    const data = this.shared.uFlickerData;
    for (const [id, g] of this.groups) {
      let f;
      if (g.dead) f = 0;
      else {
        if (g.profile) {
          const slot = Math.floor(t / g.profile.slotLength);
          if (slot !== g.blackout.slot) g.blackout = blackoutSlot(this.seed, g.name, g.profile, slot);
          f = flickerFactor(g.profile, g.blackout, t);
          f = 1 - (1 - f) * flashScale;
        } else f = g.initial;
        if (g.override !== null) f = g.override;
        if (g.burstAt !== null) {
          const m = burstMultiplier(t - g.burstAt);
          if (m === null) {
            g.dead = true;
            g.burstAt = null;
            f = 0;
          } else f *= m;
        }
      }
      if (id < data.length) data[id] = f;
    }
    this.shared.uFlickerTex.value.needsUpdate = true;

    // film
    if (level !== this.filmLevel) {
      this.filmLevel = level;
      this.filmTarget = this.filmFor(level);
      this.gradeFor(level, this.gradeTarget);
    }
    const a = this.snap ? 1 : 1 - Math.exp(-FILM_RATE * dt);
    if (this.snap) this.grade.copy(this.gradeTarget);
    for (const k of NUMERIC_FILM) this.film[k] = lerp(this.film[k], this.filmTarget[k], a);
    this.film.hazeColor = mixRgb(this.film.hazeColor, this.filmTarget.hazeColor, a);
    this.film.bloomSize = lerp(this.film.bloomSize, this.filmTarget.bloomSize, a);
    this.grade.lerp(this.gradeTarget, 1 - Math.exp(-GRADE_RATE * dt));
    this.snap = false;

    // lightning
    this.outdoors = level === 'Level5_Roof' || level === 'Exterior' || !level;
    this._storm(t);
    let sky = 0;
    for (let i = this.flashes.length - 1; i >= 0; i--) {
      const f = this.flashes[i];
      const e = lightningEnvelope(t - f.start, f.stages);
      if (e === null) this.flashes.splice(i, 1);
      else sky = Math.max(sky, e * f.strength);
    }
    this.skyFlash = sky * flashScale;
    this.flash = this.skyFlash * (this.outdoors ? 1 : INDOOR_FLASH);

    // shared uniforms: fog, exposure, sky flash
    const film = this.film;
    this._fogColor.setRGB(film.hazeColor[0], film.hazeColor[1], film.hazeColor[2], THREE.SRGBColorSpace);
    this.shared.uFogColor.value.set(this._fogColor.r, this._fogColor.g, this._fogColor.b)
      .multiplyScalar(1 + this.flash * 6);
    this.shared.uFogDensity.value = film.density * FOG_SCALE;
    this.shared.uExposure.value = 2 ** (EXPOSURE_BASE + film.exposure + this.flash * 1.1);
    // the trim lifts the baked world only: the torch keeps the brightness it was tuned with (no clipped hotspot)
    this.shared.torchGain = 2 ** -film.trim;
    this.shared.uFlash.value.set(0.82, 0.86, 1).multiplyScalar(this.flash * FLASH_SKY);

    // dynamic point lights: nearest enabled within range, up to the tier's slots
    const slots = Math.min(MAX_POINT, this.engine.quality.budget.pointLights);
    const cands = [];
    for (const d of this.dynamic) {
      if (!d.enabled || d.dead) continue;
      let b = d.override !== null && d.override !== undefined ? d.override : d.base;
      if (d.group > 0 && (d.override === null || d.override === undefined)) b *= data[d.group] ?? 1;
      if (d.burstAt !== null) {
        const m = burstMultiplier(t - d.burstAt);
        if (m === null) {
          d.dead = true;
          continue;
        }
        b *= m;
      }
      if (b <= 0.004) continue;
      const dist = d.position.distanceTo(cameraPos);
      if (dist > d.range + 60) continue;
      cands.push({ d, b, dist });
    }
    cands.sort((x, y) => x.dist - y.dist);
    const pos = this.shared.uPlPos.value;
    const col = this.shared.uPlColor.value;
    for (let i = 0; i < MAX_POINT; i++) {
      const c = i < slots ? cands[i] : null;
      if (c) {
        pos[i].set(c.d.position.x, c.d.position.y, c.d.position.z, c.d.range);
        col[i].set(c.d.color.r, c.d.color.g, c.d.color.b).multiplyScalar(c.b);
      } else {
        pos[i].set(0, -1e5, 0, 1);
        col[i].set(0, 0, 0);
      }
    }

    // post grade from the film (panic is layered by the engine)
    return film;
  }

  _storm(t) {
    if (!this.stormEnabled || !this.outdoors) return;
    const slot = Math.floor(t / STORM_SLOT);
    if (slot !== this.stormSlot) {
      this.stormSlot = slot;
      const r = seededRandom(this.seed, `storm:${slot}`);
      this.stormAt = r.nextNumber() < STORM_CHANCE ? slot * STORM_SLOT + r.nextNumber(0.5, STORM_SLOT - 1.5) : null;
      this.stormIntensity = r.nextNumber(0.45, 0.9);
      this.stormStages = r.nextNumber() < 0.6 ? 2 : 1;
      this.stormThunderDelay = r.nextNumber(0.4, 2.2);
    }
    if (this.stormAt !== null && t >= this.stormAt && t < this.stormAt + 0.5) {
      this.stormAt = null;
      if (t - this.lastScripted < STORM_QUIET_AFTER_SCRIPTED) return;
      this.lightning({ intensity: this.stormIntensity, stages: this.stormStages, ambient: true });
      const audio = this.engine.audio;
      if (audio) setTimeout(() => audio.play(this.stormIntensity > 0.7 ? 'Thunder' : 'DistantThunder'), this.stormThunderDelay * 1000);
    }
  }
}

function mixRgb(a, b, t) {
  return [lerp(a[0], b[0], t), lerp(a[1], b[1], t), lerp(a[2], b[2], t)];
}

/** Film colours as sRGB 0..1 (world.json writes floats; the ported fallback table writes 0..255). */
function normalizeFilm(f) {
  const out = { ...f };
  for (const k of ['hazeColor', 'decay']) {
    const c = f[k];
    if (Array.isArray(c) && (c[0] > 1 || c[1] > 1 || c[2] > 1)) out[k] = [c[0] / 255, c[1] / 255, c[2] / 255];
  }
  return out;
}

/** Sets a THREE.Color from an sRGB 0..1 triple (world.json colours). */
function setLinear(out, c) {
  if (c && c.isColor) return out.copy(c);
  return out.setRGB(c[0], c[1], c[2], THREE.SRGBColorSpace);
}

export { BASE_FILM, FILM_PATCHES, GRADES };
