// The light model of the bake: every Light the builders create (after LightingMood.resolve), the client's moonlight
// window spills (LightingController/Volumetrics), the ambient fills (LightingRig) and the night sky, evaluated at a
// point with soft shadows (BVH rays towards jittered points of the light's emitter) and soft ambient occlusion.
//
// Units: "Roblox light units" in linear RGB, the same units the web engine's dynamic lights use: a white light of
// Brightness 1 lighting a surface head-on next to it gives 1.0. The falloff is the engine's (src/engine/materials.js
// `falloff`): a range window (1 - (d/R)^2)^2 over a soft inverse-square body 1 / (1 + 0.012 d^2), so baked pools and
// the dynamic flicker lights that stand in for them match.

import { cfPoint, cfVector } from './mesh.mjs';
import { hash01 } from './trace.mjs';

export const FALLOFF_K = 0.004;

/** sRGB [0, 1] -> linear. */
export const srgbToLinear = (c) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));

const FACE_NORMALS = {
  Right: [1, 0, 0],
  Left: [-1, 0, 0],
  Top: [0, 1, 0],
  Bottom: [0, -1, 0],
  Back: [0, 0, 1],
  Front: [0, 0, -1],
};

// The two in-plane axes of each face (for sampling a SurfaceLight's emitting rectangle).
const FACE_AXES = {
  Right: [[0, 0, 1], [0, 1, 0], 2, 1],
  Left: [[0, 0, 1], [0, 1, 0], 2, 1],
  Top: [[1, 0, 0], [0, 0, 1], 0, 2],
  Bottom: [[1, 0, 0], [0, 0, 1], 0, 2],
  Back: [[1, 0, 0], [0, 1, 0], 0, 1],
  Front: [[1, 0, 0], [0, 1, 0], 0, 1],
};

/** Roblox-ish range falloff shared with the engine. */
export function falloff(d, range) {
  const x = Math.min(1, d / range);
  const w = 1 - x * x;
  return (w * w) / (1 + FALLOFF_K * d * d);
}

/**
 * Bakeable light descriptors from the raw export.
 * @param {any} raw world-raw.json
 * @returns {{ lights: any[], groups: any[] }}
 */
export function collectLights(raw) {
  const fixtures = raw.fixtures;
  const layoutLights = new Map();
  for (const id of Object.keys(raw.layouts)) {
    const layout = raw.layouts[id];
    for (const room of asArray(layout.rooms)) {
      for (const light of asArray(room.lights)) layoutLights.set(light.id, { ...light, room: room.id });
    }
  }
  const groups = [{ id: 0, name: null, kind: 'steady', initial: 1, lights: [] }];
  const groupIndex = new Map();
  const groupOf = (name, kind, level, initial) => {
    if (!name) return 0;
    let g = groupIndex.get(name);
    if (g === undefined) {
      g = groups.length;
      if (g > 255) throw new Error('more than 255 flicker groups');
      groups.push({ id: g, name, kind, level, initial, lights: [] });
      groupIndex.set(name, g);
    }
    return g;
  };

  const lights = [];
  raw.lights.forEach((l, index) => {
    const fixture = fixtures[l.fixture - 1];
    const fa = fixture.attributes || {};
    const kind = fa.LightKind || null;
    const level = fa.LevelId || null;
    let brightness = l.enabled ? l.brightness : 0;
    let groupName = fa.FlickerGroup || null;
    let groupKind = 'flicker';
    let initial = 1;
    // Scripted owners: the pool's emergency floodlights stay off until the switch (lit at the layout brightness),
    // the Floor 1 classroom glow and its spill die in the scare's light burst.
    if (kind === 'Floodlight' && level === 'Level4_FloodedPool') {
      const spec = layoutLights.get(fixture.name);
      const base = spec ? spec.brightness : 2;
      brightness = l.name === 'Light' ? base : base * 0.35;
      groupName = 'Scripted:Floodlights';
      groupKind = 'scripted';
      initial = 0;
    } else if (kind === 'ClassroomGlow') {
      groupName = `Scripted:${fixture.name}`;
      groupKind = 'scripted';
    }
    if (!(brightness > 0) || !(l.range > 0)) return;
    const g = groupOf(groupName, groupKind, level, initial);
    const desc = buildDescriptor(l, brightness);
    desc.index = index;
    desc.fixture = fixture.name;
    desc.kind = kind;
    desc.level = level;
    desc.group = g;
    desc.entity = l.entity || null;
    lights.push(desc);
    groups[g].lights.push(index);
  });

  // Moonlight spills through the windows (client-local SpotLights in Roblox; shadowed, so the planks stripe them).
  const moon = raw.lighting.moonlight;
  for (const layoutId of Object.keys(raw.windows)) {
    const film = raw.lighting.films[layoutId] || raw.lighting.baseFilm;
    const strength = moon.brightness * (film.moon ?? 1);
    if (!(strength > 0)) continue;
    for (const w of asArray(raw.windows[layoutId])) {
      const at = [w.center[0] - w.inward[0] * 1.7, w.center[1] - w.inward[1] * 1.7, w.center[2] - w.inward[2] * 1.7];
      const color = moon.color.map(srgbToLinear);
      const half = (moon.angle * Math.PI) / 360;
      lights.push({
        index: -1,
        fixture: `Moon_${w.id}`,
        kind: 'Moonlight',
        level: layoutId,
        group: 0,
        cls: 'spot',
        pos: at,
        dir: w.direction,
        color,
        brightness: strength,
        range: moon.range,
        cosOuter: Math.cos(half),
        cosInner: Math.cos(half * 0.75),
        shadows: true,
        // the emitter: the window opening itself (rays leave from across it, so plank gaps let light through)
        area: { center: w.center, u: w.tangent, v: [0, 1, 0], hu: w.width / 2, hv: w.height / 2 },
        radius: 0,
        twoSided: false,
      });
    }
  }
  return { lights, groups };
}

function buildDescriptor(l, brightness) {
  const c = l.partCFrame;
  const size = l.partSize;
  const color = l.color.map(srgbToLinear);
  const desc = {
    color,
    brightness,
    range: Math.min(60, l.range),
    shadows: l.shadows !== false,
    radius: 0,
  };
  if (l.class === 'PointLight') {
    desc.cls = 'point';
    desc.pos = l.attached ? [c[0], c[1], c[2]] : [c[0], c[1], c[2]];
    desc.radius = l.attached ? 0.1 : Math.min(0.35, Math.min(size[0], size[1], size[2]) / 2);
    return desc;
  }
  const faceN = FACE_NORMALS[l.face] || FACE_NORMALS.Front;
  const dir = cfVector(c, faceN[0], faceN[1], faceN[2]);
  const half = ((l.angle ?? 90) * Math.PI) / 360;
  desc.dir = dir;
  desc.cosOuter = Math.cos(Math.min(half, Math.PI / 2 - 1e-3));
  desc.cosInner = Math.cos(Math.min(half, Math.PI / 2) * 0.7);
  if (l.attached) {
    desc.cls = 'spot';
    desc.pos = [c[0], c[1], c[2]];
    return desc;
  }
  // on a part face: the emitter rectangle is that face
  const off = [(faceN[0] * size[0]) / 2, (faceN[1] * size[1]) / 2, (faceN[2] * size[2]) / 2];
  const center = cfPoint(c, off[0] + faceN[0] * 0.02, off[1] + faceN[1] * 0.02, off[2] + faceN[2] * 0.02);
  const axes = FACE_AXES[l.face] || FACE_AXES.Front;
  desc.pos = center;
  if (l.class === 'SurfaceLight') {
    desc.cls = 'surface';
    desc.area = {
      center,
      u: cfVector(c, ...axes[0]),
      v: cfVector(c, ...axes[1]),
      hu: size[axes[2]] / 2,
      hv: size[axes[3]] / 2,
    };
  } else {
    desc.cls = 'spot';
    desc.radius = Math.min(0.4, Math.min(size[axes[2]], size[axes[3]]) / 2);
  }
  return desc;
}

export function asArray(v) {
  if (Array.isArray(v)) return v;
  return [];
}

/** Uniform grid over light influence spheres, for "which lights reach this point". */
export class LightGrid {
  constructor(lights, cell = 16) {
    this.cell = cell;
    this.map = new Map();
    lights.forEach((l, i) => {
      const r = l.range + (l.area ? Math.max(l.area.hu, l.area.hv) : 0);
      const lo = l.pos.map((v) => Math.floor((v - r) / cell));
      const hi = l.pos.map((v) => Math.floor((v + r) / cell));
      for (let x = lo[0]; x <= hi[0]; x++)
        for (let y = lo[1]; y <= hi[1]; y++)
          for (let z = lo[2]; z <= hi[2]; z++) {
            const key = `${x},${y},${z}`;
            let list = this.map.get(key);
            if (!list) this.map.set(key, (list = []));
            list.push(i);
          }
    });
  }

  near(p) {
    return this.map.get(`${Math.floor(p[0] / this.cell)},${Math.floor(p[1] / this.cell)},${Math.floor(p[2] / this.cell)}`) || EMPTY;
  }
}

const EMPTY = [];

/**
 * Unshadowed direct light (luminance-ish sum of r + g + b) at a surface point: the cheap estimate the tessellator
 * uses to decide how finely a face must be subdivided.
 */
export function directEstimate(lights, grid, p, n) {
  let sum = 0;
  const near = grid.near(p);
  for (let k = 0; k < near.length; k++) {
    const L = lights[near[k]];
    const lx = L.pos[0] - p[0];
    const ly = L.pos[1] - p[1];
    const lz = L.pos[2] - p[2];
    const d = Math.sqrt(lx * lx + ly * ly + lz * lz);
    if (d >= L.range) continue;
    const inv = 1 / Math.max(d, 1e-4);
    let lambert = n[0] * lx * inv + n[1] * ly * inv + n[2] * lz * inv;
    if (L.area) lambert = (lambert + 0.15) / 1.15;
    if (lambert <= 0) continue;
    let cone = 1;
    if (L.dir) {
      const cd = -(L.dir[0] * lx + L.dir[1] * ly + L.dir[2] * lz) * inv;
      cone = smoothstep(L.cosOuter, L.cosInner, cd);
      if (cone <= 0) continue;
    }
    sum += L.brightness * falloff(d, L.range) * lambert * cone * (L.color[0] + L.color[1] + L.color[2]) / 3;
  }
  return sum;
}

/**
 * Evaluates the baked light at one surface point (or, with n = null, the omnidirectional irradiance for a probe).
 *
 * @param {object} ctx { lights, grid, tracer, settings, ambient, outdoor, moonDir, moonColor }
 * @param {number[]} p surface point (already nudged off its surface)
 * @param {number[] | null} n unit normal, or null for a probe
 * @param {number} seed per-point seed for the jitter
 * @param {Float64Array} groupAcc scratch [groups] accumulators (luminance per group)
 * @param {Float64Array | null} [groupRgb] scratch [groups * 3]: RGB per group (probes split scripted groups out)
 * @returns {{ r: number, g: number, b: number }}
 */
export function shadePoint(ctx, p, n, seed, groupAcc, groupRgb = null) {
  const { lights, grid, tracer, settings } = ctx;
  let r = 0;
  let g = 0;
  let b = 0;
  const near = grid.near(p);
  for (let k = 0; k < near.length; k++) {
    const li = near[k];
    const L = lights[li];
    const lx = L.pos[0] - p[0];
    const ly = L.pos[1] - p[1];
    const lz = L.pos[2] - p[2];
    const d = Math.sqrt(lx * lx + ly * ly + lz * lz);
    if (d >= L.range + (L.area ? Math.max(L.area.hu, L.area.hv) : 0)) continue;
    const inv = 1 / Math.max(d, 1e-4);
    const dx = lx * inv;
    const dy = ly * inv;
    const dz = lz * inv;
    let lambert = n ? n[0] * dx + n[1] * dy + n[2] * dz : 1;
    if (n && L.area) {
      // an area emitter still lights a surface that sees any part of it: soften the cosine near the horizon
      lambert = (lambert + 0.15) / 1.15;
    }
    if (lambert <= 0) continue;
    let cone = 1;
    if (L.dir) {
      const cd = -(L.dir[0] * dx + L.dir[1] * dy + L.dir[2] * dz);
      if (L.area && L.cls === 'surface') {
        // a surface light emits from its whole face: points beside the face but in front of its plane still see it
        if (cd <= -0.05) continue;
      }
      cone = smoothstep(L.cosOuter, L.cosInner, cd);
      if (cone <= 0) continue;
    }
    const atten = falloff(d, L.range);
    const base = L.brightness * atten * lambert * cone;
    if (base < settings.minContribution) continue;
    let vis = 1;
    if (L.shadows && settings.shadowRays > 0) {
      vis = visibility(tracer, L, p, settings.shadowRays, seed + li * 7919);
      if (vis <= 0) continue;
    }
    const w = base * vis;
    r += L.color[0] * w;
    g += L.color[1] * w;
    b += L.color[2] * w;
    if (L.group && groupAcc) groupAcc[L.group] += w * (L.color[0] + L.color[1] + L.color[2]);
    if (L.group && groupRgb) {
      groupRgb[L.group * 3] += L.color[0] * w;
      groupRgb[L.group * 3 + 1] += L.color[1] * w;
      groupRgb[L.group * 3 + 2] += L.color[2] * w;
    }
  }
  // ambient fills: indoor ambient everywhere (occluded by AO), outdoor ambient + moon where the sky is open
  const occ = occlusion(ctx, p, n, seed);
  const ao = occ.ao;
  const sky = occ.sky;
  r += ctx.ambient[0] * ao + ctx.outdoor[0] * sky;
  g += ctx.ambient[1] * ao + ctx.outdoor[1] * sky;
  b += ctx.ambient[2] * ao + ctx.outdoor[2] * sky;
  if (ctx.moonColor && sky > 0) {
    const md = ctx.moonDir; // towards the moon
    const lam = n ? Math.max(0, n[0] * md[0] + n[1] * md[1] + n[2] * md[2]) : 0.6;
    if (lam > 0 && !tracer.occluded(p[0], p[1], p[2], md[0], md[1], md[2], 400)) {
      r += ctx.moonColor[0] * lam;
      g += ctx.moonColor[1] * lam;
      b += ctx.moonColor[2] * lam;
    }
  }
  return { r, g, b, ao, sky };
}

function smoothstep(e0, e1, x) {
  if (e1 === e0) return x >= e1 ? 1 : 0;
  const t = Math.min(1, Math.max(0, (x - e0) / (e1 - e0)));
  return t * t * (3 - 2 * t);
}

// Fraction of the light's emitter visible from p.
function visibility(tracer, L, p, rays, seed) {
  let seen = 0;
  for (let s = 0; s < rays; s++) {
    let tx = L.pos[0];
    let ty = L.pos[1];
    let tz = L.pos[2];
    if (rays > 1 || L.area) {
      const a = hash01(seed, s, 1) * 2 - 1;
      const bb = hash01(seed, s, 2) * 2 - 1;
      if (L.area) {
        const A = L.area;
        // stratified over the rectangle when several rays are cast
        const su = rays > 1 ? (((s % 2) + (a + 1) / 2) / 2) * 2 - 1 : a * 0.5;
        const sv = rays > 1 ? ((Math.floor(s / 2) % 2) + (bb + 1) / 2) / 2 * 2 - 1 : bb * 0.5;
        tx = A.center[0] + A.u[0] * su * A.hu + A.v[0] * sv * A.hv;
        ty = A.center[1] + A.u[1] * su * A.hu + A.v[1] * sv * A.hv;
        tz = A.center[2] + A.u[2] * su * A.hu + A.v[2] * sv * A.hv;
      } else if (L.radius > 0) {
        const c = hash01(seed, s, 3) * 2 - 1;
        tx += a * L.radius;
        ty += bb * L.radius;
        tz += c * L.radius;
      }
    }
    const dx = tx - p[0];
    const dy = ty - p[1];
    const dz = tz - p[2];
    const d = Math.sqrt(dx * dx + dy * dy + dz * dz);
    if (d < 1e-3) {
      seen++;
      continue;
    }
    if (!tracer.occluded(p[0], p[1], p[2], dx / d, dy / d, dz / d, d - 0.05)) seen++;
  }
  return seen / rays;
}

// Ambient occlusion (short cosine-weighted rays) and sky openness (long rays into the upper hemisphere).
function occlusion(ctx, p, n, seed) {
  const { tracer, settings } = ctx;
  const N = settings.aoRays;
  const S = settings.skyRays;
  const nn = n || [0, 1, 0];
  // tangent frame
  const t1 = Math.abs(nn[1]) < 0.9 ? normalize(cross(nn, [0, 1, 0])) : normalize(cross(nn, [1, 0, 0]));
  const t2 = cross(nn, t1);
  let ao = 1;
  if (N > 0) {
    let occl = 0;
    for (let s = 0; s < N; s++) {
      const u1 = (s + hash01(seed, s, 11)) / N;
      const u2 = hash01(seed, s, 12);
      const rr = Math.sqrt(u1);
      const phi = 2 * Math.PI * u2;
      const x = rr * Math.cos(phi);
      const y = rr * Math.sin(phi);
      const z = Math.sqrt(Math.max(0, 1 - u1));
      const dx = t1[0] * x + t2[0] * y + nn[0] * z;
      const dy = t1[1] * x + t2[1] * y + nn[1] * z;
      const dz = t1[2] * x + t2[2] * y + nn[2] * z;
      // two-step distance weighting: an occluder within half the radius counts fully, one further out partly
      if (tracer.occluded(p[0], p[1], p[2], dx, dy, dz, settings.aoRadius * 0.5)) occl += 1;
      else if (tracer.occluded(p[0], p[1], p[2], dx, dy, dz, settings.aoRadius)) occl += 0.4;
    }
    ao = 1 - (occl / N) * settings.aoStrength;
  }
  let sky = 0;
  if (S > 0) {
    let open = 0;
    let weight = 0;
    for (let s = 0; s < S; s++) {
      const u1 = (s + hash01(seed, s, 21)) / S;
      const u2 = hash01(seed, s, 22);
      const rr = Math.sqrt(u1);
      const phi = 2 * Math.PI * u2;
      let dx = t1[0] * rr * Math.cos(phi) + t2[0] * rr * Math.sin(phi) + nn[0] * Math.sqrt(1 - u1);
      let dy = t1[1] * rr * Math.cos(phi) + t2[1] * rr * Math.sin(phi) + nn[1] * Math.sqrt(1 - u1);
      let dz = t1[2] * rr * Math.cos(phi) + t2[2] * rr * Math.sin(phi) + nn[2] * Math.sqrt(1 - u1);
      if (dy < 0.05) {
        // the sky is above the horizon: reflect downward rays upward (the ground scatters little at night)
        dy = Math.abs(dy) + 0.05;
      }
      const l = Math.hypot(dx, dy, dz);
      dx /= l;
      dy /= l;
      dz /= l;
      weight += 1;
      if (!tracer.occluded(p[0], p[1], p[2], dx, dy, dz, settings.skyDistance)) open += 1;
    }
    sky = open / weight;
  }
  return { ao: Math.max(0, ao), sky };
}

const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const normalize = (v) => {
  const l = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / l, v[1] / l, v[2] / l];
};
