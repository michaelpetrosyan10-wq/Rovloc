// Rovloc Web bake: world-raw.json (tools/export-world.luau) -> build/world.json + build/world.bin.
//
//   node tools/bake.mjs [--quality low|high] [--raw build/cache/world-raw.json] [--out build]
//
// 1. Geometry. Every visible part is tessellated (mesh.mjs): blocks, wedges, corner wedges, cylinders, balls, with
//    studs-based UVs; faces larger than the level's cell size are subdivided so vertex light can hold a pool; face
//    cells buried inside other solid static parts are culled. Static parts merge per level x bucket (opaque /
//    transparent / emissive Neon) x material key x 80-stud cell; entity parts (doors, grates, lockers, pickups, ...)
//    stay separate per entity node in that node's space; the Creature rig is grouped per Motor6D bone.
// 2. Light. Every vertex gets baked light (light.mjs): direct light from every burning Light (and the moonlight
//    window spills) with soft BVH shadow rays, soft AO on the ambient fill, sky openness for the outdoor ambient and
//    the moon; plus its dominant flicker group and that group's share. Probes: a 4-stud irradiance grid per level.
// 3. Pack. Quantised streams (positions u16 per chunk, normals i8, uv i16, colour u8, sqrt light u8, flicker u8x2,
//    indices u16), per-level collision (coarse triangles of colliding parts), probes; metadata in world.json.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Worker } from 'node:worker_threads';
import { fileURLToPath } from 'node:url';

import { FORMAT_VERSION, LIGHT_SCALE, UV_SCALE, deltaEncode, encodeLightByte, triEncode } from '../src/engine/data.js';
import { SolidIndex, coarseTriangles, decalFace, partAabb, tessellatePart } from './bake/mesh.mjs';
import { bakeDecals } from './bake/decals.mjs';
import { buildTracer } from './bake/trace.mjs';
import { LightGrid, asArray, collectLights, directEstimate, srgbToLinear } from './bake/light.mjs';
import { buildMeta } from './bake/meta.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const webDir = path.resolve(here, '..');

const args = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};
const QUALITY = arg('quality', 'high');
const RAW = path.resolve(webDir, arg('raw', 'build/cache/world-raw.json'));
const OUT = path.resolve(webDir, arg('out', 'build'));
const THREADS = Number(arg('threads', Math.max(1, Math.min(4, os.cpus().length))));
const SKIP_DECALS = args.includes('--no-decals');

/** Bake settings per quality. */
const PRESETS = {
  low: { shadowRays: 1, aoRays: 4, skyRays: 2, aoRadius: 5, aoStrength: 0.85, skyDistance: 160, minContribution: 0.003, probeSpacing: 4 },
  high: { shadowRays: 5, aoRays: 14, skyRays: 6, aoRadius: 6, aoStrength: 0.85, skyDistance: 220, minContribution: 0.0015, probeSpacing: 4 },
};
const settings = PRESETS[QUALITY];
if (!settings) throw new Error(`unknown quality ${QUALITY}`);

// Subdivision (max edge, studs) per level key: interiors fine enough for pools, outside coarse.
const MAX_EDGE = { Exterior: 8, Skyline: 16, default: 2.4, entity: 2.5, creature: 1e9 };
// Faces that no light reaches (ceilings over downlights, dark rooms) or that it lights evenly are split coarser.
const EDGE_DARK = 8;
const EDGE_EVEN = 5;
const DARK_LEVEL = 0.1; // peak unshadowed light below this (sqrt-encoded 0..1) counts as dark
const EVEN_SPREAD = 0.035; // sqrt-encoded spread below this counts as even
const CELL = { default: 120, Exterior: 4000 }; // static chunk cells (studs, XZ)
const MAX_CHUNK_VERTS = 65535;

// Ambient fills (LightingRig.Baseline), as linear light. The scales map Roblox's ambient colours onto the same
// units as the lights: dark but readable gaps between the pools.
const AMBIENT_SCALE = 3.2;
const OUTDOOR_SCALE = 2.6;
const MOON_SCALE = 0.07; // the night "sun" at ClockTime 0.5 behind the storm deck (Lighting.Brightness 0.5)

// Roblox base materials -> PBR approximations (textured keys take roughness from their roughness map).
const MATERIAL_PBR = {
  Plastic: [0.62, 0, 0],
  SmoothPlastic: [0.32, 0, 0.02],
  Neon: [0.6, 0, 0],
  Glass: [0.06, 0, 0.35],
  Metal: [0.38, 0.85, 0.08],
  CorrodedMetal: [0.62, 0.55, 0.03],
  DiamondPlate: [0.42, 0.85, 0.06],
  Concrete: [0.92, 0, 0],
  Brick: [0.9, 0, 0],
  Wood: [0.66, 0, 0.01],
  WoodPlanks: [0.72, 0, 0.01],
  Fabric: [0.96, 0, 0],
  Carpet: [1, 0, 0],
  Slate: [0.78, 0, 0.01],
  Marble: [0.28, 0, 0.05],
  CeramicTiles: [0.3, 0, 0.06],
  Plaster: [0.86, 0, 0],
  Pebble: [0.92, 0, 0],
  Asphalt: [0.95, 0, 0],
  Ground: [1, 0, 0],
  Grass: [1, 0, 0],
  Mud: [0.7, 0, 0.02],
  Leather: [0.55, 0, 0.02],
  Rubber: [0.82, 0, 0],
  Cardboard: [0.92, 0, 0],
  Pavement: [0.9, 0, 0],
  Granite: [0.6, 0, 0.02],
  Sand: [1, 0, 0],
  Foil: [0.25, 1, 0.1],
  Ice: [0.1, 0, 0.2],
  ForceField: [0.2, 0, 0],
};

const t0 = Date.now();
const log = (...m) => console.log(`[bake ${((Date.now() - t0) / 1000).toFixed(1)}s]`, ...m);

// ---------------------------------------------------------------------------------------------------------------
// Load + classify
// ---------------------------------------------------------------------------------------------------------------

const raw = JSON.parse(fs.readFileSync(RAW, 'utf8'));
log(`raw: ${raw.parts.length} parts, ${raw.lights.length} lights, ${raw.entities.length} entities`);

const textureMeta = loadTextureMeta();

function loadTextureMeta() {
  const file = path.join(OUT, 'textures', 'textures.json');
  if (fs.existsSync(file)) return JSON.parse(fs.readFileSync(file, 'utf8'));
  // fallback: studsPerTile from the generator manifest
  const manifest = JSON.parse(fs.readFileSync(path.resolve(webDir, '../tools/textures/manifest.json'), 'utf8'));
  const out = { textures: {} };
  for (const m of manifest.materials) if (m.kind === 'variant') out.textures[m.id] = { studsPerTile: m.studsPerTile, maps: {} };
  return out;
}

const VISIBLE_MIN = 1e-3;

/** Render bucket of a part. */
function bucketOf(p) {
  if (p.material === 'Neon') return 'emissive';
  if (p.transparency > 0.01) return 'transparent';
  return 'opaque';
}

function materialKey(p) {
  return p.texture ? `${p.material}/${p.texture}` : p.material;
}

const materials = {};
function registerMaterial(p) {
  const key = materialKey(p);
  if (!materials[key]) {
    const pbr = MATERIAL_PBR[p.material] || [0.7, 0, 0];
    const tex = p.texture ? textureMeta.textures[p.texture] : null;
    materials[key] = {
      material: p.material,
      texture: p.texture || null,
      studsPerTile: tex ? tex.studsPerTile : 8,
      roughness: pbr[0],
      metalness: pbr[1],
      reflectance: pbr[2],
      emissive: p.material === 'Neon',
      glass: p.material === 'Glass',
    };
  }
  return key;
}

const parts = raw.parts;
const staticParts = [];
const entityParts = [];
for (const p of parts) {
  if (p.transparency >= 0.999) continue; // invisible colliders still go into the collision buffer below
  if (Math.min(p.size[0], p.size[1], p.size[2]) <= 0 && p.shape !== 'Cylinder') continue;
  if (p.entity) entityParts.push(p);
  else staticParts.push(p);
}

// Solids that can hide faces of static parts and that light samples are nudged out of.
const solids = staticParts.filter(
  (p) => (p.shape === 'Block' || p.shape === 'Wedge') && p.transparency < 0.05 && p.material !== 'Glass' && Math.min(...p.size) > 0.02,
);
const solidIndex = new SolidIndex(solids, 4);
log(`solids: ${solids.length}`);

const { lights, groups } = collectLights(raw);
log(`lights: ${lights.length} baked (${lights.filter((l) => l.kind === 'Moonlight').length} moonlight spills), ${groups.length - 1} flicker groups`);
const lightGrid = new LightGrid(lights);

// Fixture index -> flicker group (glow parts flicker with their light).
const fixtureGroup = new Map();
for (const l of lights) {
  if (l.index >= 0) {
    const fx = raw.lights[l.index].fixture;
    if (l.group && !fixtureGroup.has(fx)) fixtureGroup.set(fx, l.group);
  }
}


// Per-face subdivision from the unshadowed light over it (sampled every ~3 studs).
function edgeFor(at, du, dv, n, fine) {
  const su = Math.min(28, Math.max(2, Math.ceil(du / 3) + 1));
  const sv = Math.min(28, Math.max(2, Math.ceil(dv / 3) + 1));
  let lo = Infinity;
  let hi = 0;
  for (let j = 0; j < sv; j++) {
    for (let i = 0; i < su; i++) {
      const p = at(-du / 2 + (du * i) / (su - 1), -dv / 2 + (dv * j) / (sv - 1));
      const q = [p[0] + n[0] * 0.05, p[1] + n[1] * 0.05, p[2] + n[2] * 0.05];
      const e = Math.sqrt(Math.min(1, directEstimate(lights, lightGrid, q, n) / LIGHT_SCALE));
      if (e < lo) lo = e;
      if (e > hi) hi = e;
    }
  }
  if (hi < DARK_LEVEL) return Math.max(fine, EDGE_DARK);
  if (hi - lo < EVEN_SPREAD) return Math.max(fine, EDGE_EVEN);
  return fine;
}

// ---------------------------------------------------------------------------------------------------------------
// Tessellation into chunk builders
// ---------------------------------------------------------------------------------------------------------------

class ChunkBuilder {
  constructor(key, info) {
    this.key = key;
    this.info = info;
    this.pos = [];
    this.nrm = [];
    this.uv = [];
    this.col = [];
    this.sample = []; // nudged light sample positions (world)
    this.wnrm = []; // world normals for the bake
    this.fx = []; // fixture index per vertex (glow parts) or 0
    this.idx = [];
    this.count = 0;
  }
}

const builders = new Map();
const builderList = [];

function builderFor(key, info) {
  let list = builders.get(key);
  if (!list) builders.set(key, (list = []));
  let b = list[list.length - 1];
  if (!b || b.count > MAX_CHUNK_VERTS - 4096) {
    b = new ChunkBuilder(key, info);
    list.push(b);
    builderList.push(b);
  }
  return b;
}

// Light sample point for a vertex: lifted off the surface; when that lands inside another solid (a floor vertex at
// the foot of a wall), slid sideways until it is clear.
function samplePoint(p, n, self) {
  const lift = 0.05;
  const q = [p[0] + n[0] * lift, p[1] + n[1] * lift, p[2] + n[2] * lift];
  if (!solidIndex.inside(q, self)) return q;
  const t1 = Math.abs(n[1]) < 0.9 ? norm3(cross3(n, [0, 1, 0])) : norm3(cross3(n, [1, 0, 0]));
  const t2 = cross3(n, t1);
  for (const r of [0.12, 0.3, 0.6]) {
    for (let k = 0; k < 8; k++) {
      const a = (k / 8) * Math.PI * 2;
      const c = Math.cos(a) * r;
      const s = Math.sin(a) * r;
      const cand = [q[0] + t1[0] * c + t2[0] * s, q[1] + t1[1] * c + t2[1] * s, q[2] + t1[2] * c + t2[2] * s];
      if (!solidIndex.inside(cand, self)) return cand;
    }
  }
  return q;
}

const cross3 = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const norm3 = (v) => {
  const l = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / l, v[1] / l, v[2] / l];
};

/**
 * Adds one part's triangles. `toLocal` maps world -> chunk space (entities / creature), `keyOf(centroid)` picks the
 * builder key per triangle.
 */
function addPart(p, opts) {
  const color = opts.color || p.color;
  const maxEdge = opts.maxEdge;
  const cull = opts.cull ? (q) => solidIndex.inside(q, p) : null;
  const generate = opts.generate || ((sink) => tessellatePart(p, { maxEdge, cull, edgeFor: opts.adaptive ? edgeFor : null }, sink));
  generate((verts, tris) => {
    // group triangles by builder key
    const groups = new Map();
    for (const t of tris) {
      const a = verts[t[0]].p;
      const b = verts[t[1]].p;
      const c = verts[t[2]].p;
      const cx = (a[0] + b[0] + c[0]) / 3;
      const cz = (a[2] + b[2] + c[2]) / 3;
      const key = opts.keyOf(cx, cz);
      let g = groups.get(key);
      if (!g) groups.set(key, (g = []));
      g.push(t);
    }
    for (const [key, list] of groups) {
      const b = builderFor(key, opts.info);
      const startCount = b.count;
      const remap = new Map();
      for (const t of list) {
        const out = [];
        for (const vi of t) {
          let ni = remap.get(vi);
          if (ni === undefined) {
            const v = verts[vi];
            ni = b.count++;
            remap.set(vi, ni);
            const lp = opts.toLocal ? opts.toLocal(v.p) : v.p;
            const ln = opts.toLocalDir ? opts.toLocalDir(v.n) : v.n;
            b.pos.push(lp[0], lp[1], lp[2]);
            b.nrm.push(ln[0], ln[1], ln[2]);
            const uv = opts.uvMap ? opts.uvMap(v.uv) : v.uv;
            b.uv.push(uv[0], uv[1]);
            b.col.push(color[0], color[1], color[2]);
            const sp = opts.bake ? samplePoint(v.p, v.n, p) : v.p;
            b.sample.push(sp[0], sp[1], sp[2]);
            b.wnrm.push(v.n[0], v.n[1], v.n[2]);
            b.fx.push(opts.glowFixture !== undefined ? opts.glowFixture : p.glow && p.fixture ? p.fixture : 0);
          }
          out.push(ni);
        }
        b.idx.push(out[0], out[1], out[2]);
      }
      if (opts.onAppend) opts.onAppend(b, startCount, b.count);
    }
  });
}

const levelBounds = {};
function growBounds(level, p) {
  const [lo, hi] = partAabb(p);
  const b = (levelBounds[level] ||= [Infinity, Infinity, Infinity, -Infinity, -Infinity, -Infinity]);
  for (let i = 0; i < 3; i++) {
    b[i] = Math.min(b[i], lo[i]);
    b[i + 3] = Math.max(b[i + 3], hi[i]);
  }
}

// Static parts
let culledParts = 0;
for (const p of staticParts) {
  const bucket = bucketOf(p);
  const material = registerMaterial(p);
  const level = p.level;
  const opacity = bucket === 'transparent' ? Math.round((1 - p.transparency) * 20) / 20 : 1;
  const group = p.source === 'Skyline' ? 'Skyline' : level;
  const maxEdge = bucket === 'emissive' ? 1e9 : MAX_EDGE[group] || MAX_EDGE.default;
  growBounds(level, p);
  const before = builderList.length;
  const cell = CELL[level] || CELL.default;
  addPart(p, {
    maxEdge,
    adaptive: bucket !== 'emissive',
    cull: bucket === 'opaque',
    bake: bucket !== 'emissive',
    info: { kind: 'static', level, bucket, material, opacity },
    keyOf: (x, z) => `S|${level}|${bucket}|${material}|${opacity}|${Math.floor(x / cell)},${Math.floor(z / cell)}`,
  });
  if (builderList.length === before && false) culledParts++;
}
log(`static tessellated: ${builderList.length} builders`);

// Entities: batched per level x bucket x material in WORLD space at their rest pose; every (entity, node) owns one
// contiguous vertex range per chunk (chunk.ranges), so the engine can move a door leaf by rewriting its range or by a
// per-vertex node index (data.js nodeIndexAttribute). Parts are added sorted by entity and node to keep ranges whole.
const entities = raw.entities;
const entityPivot = (e) => e.pivot || [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1];
const nodeFrame = (e, nodePath) => {
  if (nodePath) {
    const node = asArray(e.nodes).find((n) => n.path === nodePath);
    if (node && node.pivot) return node.pivot;
  }
  return entityPivot(e);
};
entityParts.sort((x, y) => x.entity - y.entity || (x.node || '').localeCompare(y.node || ''));
for (const p of entityParts) {
  const e = entities[p.entity - 1];
  const bucket = bucketOf(p);
  const material = registerMaterial(p);
  const opacity = bucket === 'transparent' ? Math.round((1 - p.transparency) * 20) / 20 : 1;
  const node = p.node || '';
  const entity = p.entity - 1;
  addPart(p, {
    maxEdge: bucket === 'emissive' ? 1e9 : MAX_EDGE.entity,
    adaptive: bucket !== 'emissive',
    cull: false,
    bake: bucket !== 'emissive',
    info: { kind: 'entity', level: e.level, bucket, material, opacity },
    keyOf: () => `E|${e.level}|${bucket}|${material}|${opacity}`,
    onAppend: (b, start, end) => {
      if (end <= start) return;
      b.ranges ||= [];
      const last = b.ranges[b.ranges.length - 1];
      if (last && last.entity === entity && last.node === node && last.start + last.count === start) last.count += end - start;
      else b.ranges.push({ entity, node, start, count: end - start });
    },
  });
}
log(`entities tessellated: ${builderList.length} builders`);

// Creature: one chunk per bucket x material in the rig's model space (built at the origin, rest pose), each vertex
// tagged with the Motor6D bone it follows (welded parts follow their bone): ready for a THREE.SkinnedMesh with
// skinIndex = bone, skinWeight = 1 (data.js adds both attributes).
const creature = raw.creature;
const creatureBones = buildCreatureBones(creature);
const boneIndexOf = new Map(creatureBones.bones.map((name, i) => [name, i]));
for (const cp of creature ? creature.parts : []) {
  if (cp.transparency >= 0.999 || cp.name === 'HumanoidRootPart' || cp.name === 'CreatureHitbox') continue;
  const bone = creatureBones.boneOf.get(cp.name) || creatureBones.root;
  const p = { ...cp };
  const bucket = bucketOf(p);
  const material = registerMaterial(p);
  const opacity = bucket === 'transparent' ? Math.round((1 - p.transparency) * 20) / 20 : 1;
  const boneIndex = boneIndexOf.get(bone) ?? 0;
  addPart(p, {
    maxEdge: MAX_EDGE.creature,
    cull: false,
    bake: false,
    info: { kind: 'creature', level: 'Creature', bucket, material, opacity },
    keyOf: () => `C|${bucket}|${material}|${opacity}`,
    onAppend: (b, start, end) => {
      b.bones ||= [];
      for (let v = start; v < end; v++) b.bones[v] = boneIndex;
    },
  });
}

// SurfaceGui decals (decals.mjs): signs, plates, chalkboards, notices, posters, hazard stripes, numbers, labels and
// the exit signs' letters, as alpha-blended quads on their faces (bucket "decal"). Lit decals take baked light like
// any surface; a gui with LightInfluence < 1 mixes in its own Brightness (material lightInfluence / brightness), and a
// self-lit one on a light fixture (exit letters) flickers with its fixture.
const DECAL_UV_SCALE = 8192;
const decalResult = SKIP_DECALS ? { pages: [], decals: [], skipped: 0, cells: 0 } : await bakeDecals(raw, path.join(OUT, 'textures'));
for (const pg of decalResult.pages) {
  textureMeta.textures[`Decals${pg.index}`] = {
    studsPerTile: 1,
    atlas: true,
    width: pg.width,
    height: pg.height,
    maps: { color: `textures/${pg.file}` },
    bytes: pg.bytes,
  };
}
const decalMaterial = (d) => {
  const li = Math.round(d.lightInfluence * 100) / 100;
  const br = Math.round(d.brightness * 100) / 100;
  const key = li >= 0.999 ? `Decal/${d.page}` : `Decal/${d.page}/li${li}/b${br}`;
  if (!materials[key]) {
    materials[key] = {
      material: 'Decal',
      texture: `Decals${d.page}`,
      studsPerTile: 1,
      roughness: 0.7,
      metalness: 0,
      reflectance: 0,
      emissive: li < 0.001,
      glass: false,
      decal: true,
      lightInfluence: li,
      brightness: br,
    };
  }
  return key;
};
let decalQuads = 0;
for (const d of decalResult.decals) {
  const p = raw.parts[d.part];
  if (!p || p.creature) continue;
  const material = decalMaterial(d);
  const rect = d.rect;
  const uvMap = (uv) => [rect[0] + (rect[2] - rect[0]) * uv[0], rect[1] + (rect[3] - rect[1]) * uv[1]];
  const generate = (sink) => decalFace(p, d.face, MAX_EDGE.default, 0.015, sink);
  const glowFixture = d.lightInfluence < 0.001 && p.fixture ? p.fixture : 0;
  const white = [1, 1, 1];
  if (p.entity) {
    const e = entities[p.entity - 1];
    const entity = p.entity - 1;
    const node = p.node || '';
    addPart(p, {
      generate,
      uvMap,
      color: white,
      bake: true,
      glowFixture,
      info: { kind: 'entity', level: e.level, bucket: 'decal', material, opacity: 1, uvScale: DECAL_UV_SCALE },
      keyOf: () => `ED|${e.level}|${material}`,
      onAppend: (b, start, end) => {
        if (end <= start) return;
        b.ranges ||= [];
        const last = b.ranges[b.ranges.length - 1];
        if (last && last.entity === entity && last.node === node && last.start + last.count === start) last.count += end - start;
        else b.ranges.push({ entity, node, start, count: end - start });
      },
    });
  } else {
    const level = p.level;
    const cell = CELL[level] || CELL.default;
    addPart(p, {
      generate,
      uvMap,
      color: white,
      bake: true,
      glowFixture,
      info: { kind: 'static', level, bucket: 'decal', material, opacity: 1, uvScale: DECAL_UV_SCALE },
      keyOf: (x, z) => `SD|${level}|${material}|${Math.floor(x / cell)},${Math.floor(z / cell)}`,
    });
  }
  decalQuads++;
}
log(`decals: ${decalQuads} placed from ${decalResult.cells} atlas cells on ${decalResult.pages.length} page(s), ${decalResult.skipped} wear/finish guis skipped`);

function buildCreatureBones(rig) {
  const boneOf = new Map();
  if (!rig) return { boneOf, root: null, bones: [] };
  const motors = rig.joints.filter((j) => j.class === 'Motor6D');
  const boneNames = new Set();
  for (const m of motors) {
    if (m.part0) boneNames.add(m.part0);
    if (m.part1) boneNames.add(m.part1);
  }
  const root = rig.primaryPart || 'HumanoidRootPart';
  boneNames.add(root);
  // weld graph
  const adj = new Map();
  const link = (a, b) => {
    if (!a || !b) return;
    if (!adj.has(a)) adj.set(a, []);
    if (!adj.has(b)) adj.set(b, []);
    adj.get(a).push(b);
    adj.get(b).push(a);
  };
  for (const j of rig.joints) if (j.class !== 'Motor6D') link(j.part0, j.part1);
  for (const name of boneNames) boneOf.set(name, name);
  // BFS from each bone through welds (never across another bone)
  for (const bone of boneNames) {
    const queue = [bone];
    while (queue.length) {
      const cur = queue.shift();
      for (const nb of adj.get(cur) || []) {
        if (boneOf.has(nb)) continue;
        boneOf.set(nb, bone);
        queue.push(nb);
      }
    }
  }
  // parts parented under a bone part with no weld: follow their parent
  for (const p of rig.parts) {
    if (!boneOf.has(p.name) && p.parent && boneOf.has(p.parent)) boneOf.set(p.name, boneOf.get(p.parent));
  }
  return { boneOf, root, bones: [...boneNames] };
}

// ---------------------------------------------------------------------------------------------------------------
// Lighting
// ---------------------------------------------------------------------------------------------------------------


// Shadow casters: everything that casts a shadow in Roblox (CastShadow, mostly opaque, not glass).
const casterTris = [];
for (const p of parts) {
  if (!p.castShadow || p.transparency > 0.3 || p.material === 'Glass') continue;
  coarseTriangles(p, casterTris);
}
const tracerData = buildTracer(new Float32Array(casterTris));
log(`tracer: ${casterTris.length / 9} triangles`);

const baseline = raw.lighting.baseline;
const lin = (c) => c.map(srgbToLinear);
const ambient = lin(baseline.Ambient).map((v) => v * AMBIENT_SCALE);
const outdoor = lin(baseline.OutdoorAmbient).map((v, i) => v * OUTDOOR_SCALE + lin(raw.lighting.moonlight.color)[i] * baseline.EnvironmentDiffuseScale * 0.02);
const moon = raw.lighting.moonlight;
const moonDir = norm3([-0.28, Math.tan(moon.pitch), 1]); // towards the moon: high and to one side (Volumetrics skew)
const moonColor = lin(moon.color).map((v) => v * MOON_SCALE * (baseline.Brightness / 0.5));

async function runWorkers(jobs) {
  const workers = [];
  for (let i = 0; i < THREADS; i++) {
    const w = new Worker(path.join(here, 'bake', 'worker.mjs'));
    workers.push(w);
  }
  await Promise.all(
    workers.map(
      (w) =>
        new Promise((resolve) => {
          w.once('message', resolve);
          w.postMessage({
            type: 'init',
            tracer: tracerData,
            lights,
            settings,
            ambient,
            outdoor,
            moonDir,
            moonColor,
            groupKinds: groups.map((g) => g.kind),
          });
        }),
    ),
  );
  const results = new Array(jobs.length);
  let next = 0;
  let done = 0;
  let rays = 0;
  let lastLog = Date.now();
  await new Promise((resolve) => {
    const feed = (w) => {
      if (next >= jobs.length) return;
      const id = next++;
      const j = jobs[id];
      w.postMessage({ type: 'job', id, points: j.points, normals: j.normals, seeds: j.seeds });
    };
    for (const w of workers) {
      w.on('message', (msg) => {
        if (msg.type !== 'done') return;
        results[msg.id] = msg;
        rays += msg.rays;
        done++;
        if (Date.now() - lastLog > 10000) {
          lastLog = Date.now();
          log(`  ${done}/${jobs.length} batches, ${(rays / 1e6).toFixed(1)}M rays`);
        }
        if (done === jobs.length) resolve();
        else feed(w);
      });
      feed(w);
    }
  });
  await Promise.all(workers.map((w) => w.terminate()));
  return { results, rays };
}

// Vertex jobs: every baked vertex of every builder (emissive and creature chunks carry no baked light).
const BATCH = 4096;
const vertexJobs = [];
const jobOwners = [];
let bakedVerts = 0;
for (const b of builderList) {
  if (b.info.bucket === 'emissive' || b.info.kind === 'creature') continue;
  for (let start = 0; start < b.count; start += BATCH) {
    const n = Math.min(BATCH, b.count - start);
    const points = new Float32Array(b.sample.slice(start * 3, (start + n) * 3));
    const normals = new Float32Array(b.wnrm.slice(start * 3, (start + n) * 3));
    const seeds = new Uint32Array(n);
    for (let i = 0; i < n; i++) seeds[i] = (bakedVerts + i) * 2654435761;
    vertexJobs.push({ points, normals, seeds });
    jobOwners.push({ b, start, n });
    bakedVerts += n;
  }
}

// Probe grids per level key (within its static bounds, `probeSpacing` apart, a little above floors).
const probeLevels = Object.keys(levelBounds).filter((k) => k !== 'Exterior');
const probeGrids = {};
const probeJobs = [];
const probeOwners = [];
for (const level of probeLevels) {
  const b = levelBounds[level];
  const sp = settings.probeSpacing;
  const origin = [Math.floor(b[0] / sp) * sp, Math.floor(b[1] / sp) * sp + 1, Math.floor(b[2] / sp) * sp];
  const dims = [
    Math.max(2, Math.ceil((b[3] - origin[0]) / sp) + 1),
    Math.max(2, Math.ceil((b[4] - origin[1]) / sp) + 1),
    Math.max(2, Math.ceil((b[5] - origin[2]) / sp) + 1),
  ];
  const count = dims[0] * dims[1] * dims[2];
  const valid = new Uint8Array(count);
  const pts = [];
  const where = [];
  for (let y = 0; y < dims[1]; y++)
    for (let z = 0; z < dims[2]; z++)
      for (let x = 0; x < dims[0]; x++) {
        const p = [origin[0] + x * sp, origin[1] + y * sp, origin[2] + z * sp];
        const i = (y * dims[2] + z) * dims[0] + x;
        if (solidIndex.inside(p)) continue;
        valid[i] = 1;
        pts.push(p[0], p[1], p[2]);
        where.push(i);
      }
  probeGrids[level] = { origin, dims, spacing: sp, valid, rgb: new Float32Array(count * 3) };
  for (let s = 0; s < where.length; s += BATCH) {
    const n = Math.min(BATCH, where.length - s);
    const seeds = new Uint32Array(n);
    for (let i = 0; i < n; i++) seeds[i] = (where[s + i] + 7) * 40503;
    probeJobs.push({ points: new Float32Array(pts.slice(s * 3, (s + n) * 3)), normals: new Float32Array(0), seeds });
    probeOwners.push({ level, where: where.slice(s, s + n) });
  }
}

log(`baking ${bakedVerts} vertices + ${probeOwners.reduce((a, o) => a + o.where.length, 0)} probes, quality ${QUALITY}, ${THREADS} threads`);
const bakeStart = Date.now();
const { results, rays } = await runWorkers([...vertexJobs, ...probeJobs]);
const bakeSeconds = (Date.now() - bakeStart) / 1000;
log(`bake done in ${bakeSeconds.toFixed(1)}s, ${(rays / 1e6).toFixed(1)}M rays`);

for (const b of builderList) {
  b.lit = new Uint8Array(b.count * 3);
  b.flk = new Uint8Array(b.count * 2);
}
vertexJobs.forEach((_, j) => {
  const { b, start, n } = jobOwners[j];
  const r = results[j];
  for (let i = 0; i < n; i++) {
    const v = start + i;
    b.lit[v * 3] = encodeLightByte(r.rgb[i * 3]);
    b.lit[v * 3 + 1] = encodeLightByte(r.rgb[i * 3 + 1]);
    b.lit[v * 3 + 2] = encodeLightByte(r.rgb[i * 3 + 2]);
    b.flk[v * 2] = r.group[i];
    b.flk[v * 2 + 1] = Math.round(r.share[i] * 255);
  }
});
// glow parts: their fixture's group at full share
for (const b of builderList) {
  for (let v = 0; v < b.count; v++) {
    const fx = b.fx[v];
    if (fx && fixtureGroup.has(fx)) {
      b.flk[v * 2] = fixtureGroup.get(fx);
      b.flk[v * 2 + 1] = 255;
    }
  }
}
probeJobs.forEach((_, j) => {
  const owner = probeOwners[j - 0];
  const r = results[vertexJobs.length + j];
  const grid = probeGrids[owner.level];
  owner.where.forEach((cell, i) => {
    grid.rgb[cell * 3] = r.rgb[i * 3];
    grid.rgb[cell * 3 + 1] = r.rgb[i * 3 + 1];
    grid.rgb[cell * 3 + 2] = r.rgb[i * 3 + 2];
  });
});
// probes inside solids take the mean of their valid neighbours (repeated), so trilinear lookups near walls stay lit
for (const grid of Object.values(probeGrids)) dilateProbes(grid);

function dilateProbes(grid) {
  const [nx, ny, nz] = grid.dims;
  for (let pass = 0; pass < 3; pass++) {
    const nextValid = grid.valid.slice();
    for (let y = 0; y < ny; y++)
      for (let z = 0; z < nz; z++)
        for (let x = 0; x < nx; x++) {
          const i = (y * nz + z) * nx + x;
          if (grid.valid[i]) continue;
          let r = 0;
          let g = 0;
          let b = 0;
          let k = 0;
          for (const [dx, dy, dz] of [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]) {
            const X = x + dx;
            const Y = y + dy;
            const Z = z + dz;
            if (X < 0 || Y < 0 || Z < 0 || X >= nx || Y >= ny || Z >= nz) continue;
            const j = (Y * nz + Z) * nx + X;
            if (!grid.valid[j]) continue;
            r += grid.rgb[j * 3];
            g += grid.rgb[j * 3 + 1];
            b += grid.rgb[j * 3 + 2];
            k++;
          }
          if (k) {
            grid.rgb[i * 3] = r / k;
            grid.rgb[i * 3 + 1] = g / k;
            grid.rgb[i * 3 + 2] = b / k;
            nextValid[i] = 1;
          }
        }
    grid.valid = nextValid;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Pack
// ---------------------------------------------------------------------------------------------------------------

class StreamWriter {
  constructor() {
    this.streams = {};
  }
  push(name, Type, values) {
    let s = this.streams[name];
    if (!s) this.streams[name] = s = { Type, parts: [], length: 0 };
    s.parts.push(values instanceof Type ? values : Type.from(values));
    const start = s.length;
    s.length += values.length;
    return start;
  }
  write(file) {
    const order = Object.keys(this.streams);
    let offset = 0;
    const refs = {};
    for (const name of order) {
      const s = this.streams[name];
      const bytes = s.Type.BYTES_PER_ELEMENT;
      offset = Math.ceil(offset / 4) * 4;
      refs[name] = { offset, length: s.length, type: typeName(s.Type) };
      offset += s.length * bytes;
    }
    const buf = new ArrayBuffer(Math.ceil(offset / 4) * 4);
    for (const name of order) {
      const s = this.streams[name];
      const view = new s.Type(buf, refs[name].offset, s.length);
      let k = 0;
      for (const part of s.parts) {
        view.set(part, k);
        k += part.length;
      }
    }
    fs.writeFileSync(file, Buffer.from(buf));
    return { refs, bytes: buf.byteLength };
  }
}

function typeName(T) {
  return { Uint8Array: 'u8', Int8Array: 'i8', Uint16Array: 'u16', Int16Array: 'i16', Uint32Array: 'u32', Float32Array: 'f32' }[T.name];
}

const writer = new StreamWriter();
const golden = [];
const chunks = [];
let vertexCursor = 0;
let indexCursor = 0;
let totalTris = 0;
for (const b of builderList) {
  if (b.count === 0 || b.idx.length === 0) continue;
  const n = b.count;
  const lo = [Infinity, Infinity, Infinity];
  const hi = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < n; i++) {
    for (let k = 0; k < 3; k++) {
      const v = b.pos[i * 3 + k];
      if (v < lo[k]) lo[k] = v;
      if (v > hi[k]) hi[k] = v;
    }
  }
  const scale = [0, 1, 2].map((k) => Math.max(hi[k] - lo[k], 1e-6) / 65535);
  const q = new Uint16Array(n * 3);
  for (let i = 0; i < n; i++) for (let k = 0; k < 3; k++) q[i * 3 + k] = Math.round((b.pos[i * 3 + k] - lo[k]) / scale[k]);
  const nr = new Int8Array(n * 3);
  for (let i = 0; i < n * 3; i++) nr[i] = Math.max(-127, Math.min(127, Math.round(b.nrm[i] * 127)));
  const uv = new Int16Array(n * 2);
  const uvScale = b.info.uvScale || UV_SCALE;
  for (let i = 0; i < n * 2; i++) uv[i] = Math.max(-32768, Math.min(32767, Math.round(b.uv[i] * uvScale)));
  const col = new Uint8Array(n * 3);
  for (let i = 0; i < n * 3; i++) col[i] = Math.round(Math.max(0, Math.min(1, b.col[i])) * 255);
  writer.push('pos', Uint16Array, deltaEncode(q, 3, 0xffff));
  writer.push('nrm', Int8Array, nr);
  writer.push('uv', Int16Array, new Int16Array(deltaEncode(new Uint16Array(uv.buffer), 2, 0xffff).buffer));
  writer.push('col', Uint8Array, col);
  writer.push('lit', Uint8Array, deltaEncode(b.lit.slice(), 3, 0xff));
  writer.push('flk', Uint8Array, b.flk);
  writer.push('idx', Uint16Array, triEncode(Uint16Array.from(b.idx), 0xffff));
  const info = b.info;
  const chunk = {
    id: chunks.length,
    kind: info.kind,
    level: info.level,
    bucket: info.bucket,
    material: info.material,
    opacity: info.opacity,
    vertexOffset: vertexCursor,
    vertexCount: n,
    indexOffset: indexCursor,
    indexCount: b.idx.length,
    quant: [lo[0], lo[1], lo[2], scale[0], scale[1], scale[2]],
    aabb: [...lo, ...hi].map((v) => Math.round(v * 1000) / 1000),
  };
  if (info.uvScale) chunk.uvScale = info.uvScale;
  if (info.kind === 'entity') chunk.ranges = b.ranges || [];
  if (info.kind === 'creature') {
    chunk.boneOffset = writer.push('bone', Uint8Array, Uint8Array.from(b.bones));
  }
  chunks.push(chunk);
  // golden samples for tools/data-test.mjs: the pre-encoding values of a few vertices / triangles of every 25th chunk
  if (chunk.id % 25 === 0 || info.kind !== 'static') {
    const k = Math.min(n, 48);
    golden.push({
      chunk: chunk.id,
      position: b.pos.slice(0, k * 3),
      uv: b.uv.slice(0, k * 2),
      color: Array.from(col.subarray(0, k * 3)),
      light: Array.from(b.lit.subarray(0, k * 3)),
      flicker: Array.from(b.flk.subarray(0, k * 2)),
      index: b.idx.slice(0, Math.min(b.idx.length, 96)),
    });
  }
  vertexCursor += n;
  indexCursor += b.idx.length;
  totalTris += b.idx.length / 3;
}
log(`chunks: ${chunks.length}, ${vertexCursor} vertices, ${totalTris} triangles`);

// Collision per level key: coarse triangles of every colliding static part (invisible colliders included).
const collision = {};
const collisionParts = {};
for (const p of parts) {
  if (!p.canCollide || p.entity) continue;
  (collisionParts[p.level] ||= []).push(p);
}
let cvCursor = 0;
let ciCursor = 0;
for (const [level, list] of Object.entries(collisionParts)) {
  const flat = [];
  for (const p of list) coarseTriangles(p, flat);
  // dedupe vertices
  const map = new Map();
  const verts = [];
  const index = [];
  for (let i = 0; i < flat.length; i += 3) {
    const key = `${flat[i].toFixed(3)},${flat[i + 1].toFixed(3)},${flat[i + 2].toFixed(3)}`;
    let vi = map.get(key);
    if (vi === undefined) {
      vi = verts.length / 3;
      map.set(key, vi);
      verts.push(flat[i], flat[i + 1], flat[i + 2]);
    }
    index.push(vi);
  }
  const lo = [Infinity, Infinity, Infinity];
  const hi = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < verts.length; i += 3)
    for (let k = 0; k < 3; k++) {
      lo[k] = Math.min(lo[k], verts[i + k]);
      hi[k] = Math.max(hi[k], verts[i + k]);
    }
  const scale = [0, 1, 2].map((k) => Math.max(hi[k] - lo[k], 1e-6) / 65535);
  const q = new Uint16Array(verts.length);
  for (let i = 0; i < verts.length; i += 3) for (let k = 0; k < 3; k++) q[i + k] = Math.round((verts[i + k] - lo[k]) / scale[k]);
  writer.push('cpos', Uint16Array, deltaEncode(q, 3, 0xffff));
  writer.push('cidx', Uint32Array, triEncode(Uint32Array.from(index), 0xffffffff));
  collision[level] = {
    vertexOffset: cvCursor,
    vertexCount: verts.length / 3,
    indexOffset: ciCursor,
    indexCount: index.length,
    quant: [lo[0], lo[1], lo[2], scale[0], scale[1], scale[2]],
    parts: list.length,
  };
  cvCursor += verts.length / 3;
  ciCursor += index.length;
}

// Probes
const probes = {};
let probeCursor = 0;
for (const [level, grid] of Object.entries(probeGrids)) {
  const count = grid.dims[0] * grid.dims[1] * grid.dims[2];
  const bytes = new Uint8Array(count * 3);
  for (let i = 0; i < count * 3; i++) bytes[i] = encodeLightByte(grid.rgb[i]);
  writer.push('probe', Uint8Array, bytes);
  probes[level] = { origin: grid.origin, dims: grid.dims, spacing: grid.spacing, offset: probeCursor };
  probeCursor += count;
}

fs.mkdirSync(OUT, { recursive: true });
const { refs, bytes } = writer.write(path.join(OUT, 'world.bin'));

const meta = buildMeta(raw, {
  format: FORMAT_VERSION,
  quality: QUALITY,
  settings,
  lightScale: LIGHT_SCALE,
  uvScale: UV_SCALE,
  streams: refs,
  chunks,
  collision,
  probes,
  materials,
  textures: textureMeta.textures,
  lights,
  groups,
  levelBounds,
  creatureBones,
  ambient: { indoor: ambient, outdoor, moonDir, moonColor, ambientScale: AMBIENT_SCALE, outdoorScale: OUTDOOR_SCALE },
  stats: { vertices: vertexCursor, triangles: totalTris, bakedVertices: bakedVerts, rays, bakeSeconds, threads: THREADS },
});
fs.writeFileSync(path.join(OUT, 'world.json'), JSON.stringify(meta));
fs.mkdirSync(path.join(OUT, 'cache'), { recursive: true });
fs.writeFileSync(path.join(OUT, 'cache', 'golden.json'), JSON.stringify({ format: FORMAT_VERSION, samples: golden }));
log(`wrote world.bin (${(bytes / 1e6).toFixed(2)} MB) + world.json (${(fs.statSync(path.join(OUT, 'world.json')).size / 1e6).toFixed(2)} MB)`);
