// Round-trip test of the world data format: `node web/tools/data-test.mjs [buildDir]` (default web/build).
//
// 1. The codec on synthetic data: delta / triangle-delta coding at every element width, the sqrt light encoding.
// 2. The baked world: decodeWorld(world.json, world.bin) against the bake's own pre-encoding samples
//    (build/cache/codec-golden.json): positions within half a quantisation step, UVs within half a UV step, colours, light
//    bytes, flicker pairs and indices exact. Then structural checks over everything: indices in range, positions inside
//    their chunk's bounds, unit normals, flicker groups that exist, entity ranges that tile their chunks, every vent
//    grate in both looks (each drawn, pivoting and colliding alike), creature bone indices, collision and probe tables,
//    every texture and material the chunks name. The floor objectives' guard traps: every guarded item (the basement's
//    fuses) has its guard on the careless walk in (each walk ends where the item's prompt first answers with a foot on
//    the pan on the way; the one the baked world leaves open is on the floor with the body clear; and the shortest walk
//    the baked world allows from the same start, found here, crosses the pan too), and its standing spot beside it,
//    clear of every trap spot, the item's prompt reaching it, and a walk to it from a doorway that never sets a foot on
//    a pan, all held to the baked collision and the entities' colliders. Every item entity is the prop any run builds
//    on its anchor (a floor of kinds gives its Slot as its candidate's kind, no Slot without kinds), and what the web
//    draws again away from the world matches the export: each chemical flask is its anchor's variant and looks as
//    flaskFx.js draws that variant (ChemicalFlaskBuilder.lookOf on the world's Rng: liquid tiers, crack, colour).
//    Removals (docs/design/game-spec-v2.md 6): the four-level school only, and nothing of the cut floors, the old roof's
//    objective or the pool anywhere in the baked data (levels, layouts, entities, anchors, rooms, doors, volumes, routes).
// 3. Flicker groups: world-wide 16-bit ids within the namespace and the engine's flicker texture, every light's group
//    resolving (its FlickerGroup, its level), and each tunnel floor's power circuits (Mains: / Circuit:) pooling as
//    one family: the bake's pooling rule, the family in world.json, one probe grid per family.
// 4. The run plan, the same on both platforms: the web's Rng (src/game/util.js) against the golden values of
//    tests/Specs/Rng.spec.luau (an independent C reference of xoshiro128** seeded by SplitMix32), then worldData's port
//    of RunDirector against RunDirector itself: for every seed and difficulty of the export's build/cache/run-plans.json,
//    the same objective picks and guard traps, the same bear trap, flask and battery anchors, every prop's variant
//    (variantOf), the same locked grates and the same exit stairwells.
// 5. The shared rules: every config the export lists (meta.exportedConfigs: each Shared/Config and Shared/Rules module
//    with an exportMeta) is in meta under its name, the ones the website needs among them; build/cache/golden.json
//    parses and gives every rule module rows ({ name, fn, args, expect }, names unique, at least 12 per function); the
//    run plan's spec v2 picks (meta.plan.batteries, meta.plan.flasks and every replayed plan's) are anchors of the right
//    kind on their level, as many as the rules allow; the CreatureBlocks (meta.creatureBlocks) are boxes on a level.
// Exits non-zero on the first category with failures (all failures are listed).

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import * as THREE from 'three';
import { MeshBVH } from 'three-mesh-bvh';

import {
  FLICKER_GROUP_LIMIT,
  FORMAT_VERSION,
  LIGHT_SCALE,
  UV_SCALE,
  decodeLightByte,
  decodeWorld,
  deltaDecode,
  deltaEncode,
  encodeLightByte,
  nodeIndexAttribute,
  poseEntityRange,
  sampleProbe,
  triDecode,
  triEncode,
} from '../src/engine/data.js';
import { createSharedUniforms } from '../src/engine/materials.js';
import { crackFrame, flaskLook, liquidColor, liquidTiers } from '../src/game/mechanics/flaskFx.js';
import { Rng, cfMatrix, cfPos, hash as fnv, shuffle } from '../src/game/util.js';
import { LevelOrder as WebLevelOrder } from '../src/game/config.js';
import { WorldData, variantOf } from '../src/game/worldData.js';
import { POWER_CIRCUIT, dominantGroup } from './bake/light.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const buildDir = path.resolve(process.argv[2] || path.join(here, '..', 'build'));

let failures = 0;
let checks = 0;
const fail = (msg) => {
  failures++;
  if (failures <= 40) console.log(`  FAIL ${msg}`);
};
const check = (cond, msg) => {
  checks++;
  if (!cond) fail(msg);
};

// deterministic PRNG
let seed = 12345;
const rnd = () => {
  seed = (Math.imul(seed, 1103515245) + 12345) >>> 0;
  return seed / 4294967296;
};

// ------------------------------------------------------------------------------------------------------------
console.log('== codec');
for (const [Type, mask] of [
  [Uint8Array, 0xff],
  [Uint16Array, 0xffff],
  [Uint32Array, 0xffffffff],
]) {
  for (const stride of [1, 2, 3]) {
    const a = new Type(999);
    for (let i = 0; i < a.length; i++) a[i] = Math.floor(rnd() * (mask + 1));
    const copy = a.slice();
    deltaDecode(deltaEncode(a, stride, mask), stride, mask);
    check(a.every((v, i) => v === copy[i]), `delta ${Type.name} stride ${stride}`);
  }
  const idx = new Type(300);
  for (let i = 0; i < idx.length; i++) idx[i] = Math.floor(rnd() * Math.min(mask + 1, 70000));
  const copy = idx.slice();
  triDecode(triEncode(idx, mask), mask);
  check(idx.every((v, i) => v === copy[i]), `triangle delta ${Type.name}`);
}
let worst = 0;
for (let i = 0; i <= 1000; i++) {
  const v = (i / 1000) * LIGHT_SCALE;
  const back = decodeLightByte(encodeLightByte(v));
  // sqrt coding: the error grows with the value, about 1/255 of sqrt-space
  const tol = 2 * Math.sqrt(v * LIGHT_SCALE) / 255 + 1e-6;
  worst = Math.max(worst, Math.abs(back - v) / tol);
  check(Math.abs(back - v) <= tol, `light ${v.toFixed(4)} -> ${back.toFixed(4)}`);
}
check(encodeLightByte(-1) === 0 && encodeLightByte(99) === 255, 'light clamps');
for (let b = 1; b < 256; b++) check(decodeLightByte(b) > decodeLightByte(b - 1), `light byte ${b} monotonic`);
console.log(`  ok   codec (${checks} checks, light error ${(worst * 100).toFixed(0)}% of tolerance)`);

// ------------------------------------------------------------------------------------------------------------
console.log(`== world (${buildDir})`);
const meta = JSON.parse(fs.readFileSync(path.join(buildDir, 'world.json'), 'utf8'));
const binBuf = fs.readFileSync(path.join(buildDir, 'world.bin'));
const bin = binBuf.buffer.slice(binBuf.byteOffset, binBuf.byteOffset + binBuf.byteLength);
check(meta.format === FORMAT_VERSION, `format ${meta.format} == ${FORMAT_VERSION}`);
const t0 = performance.now();
const world = decodeWorld(meta, bin);
const decodeMs = performance.now() - t0;
console.log(`  decoded ${world.chunks.length} chunks in ${decodeMs.toFixed(0)} ms`);

// golden samples
const goldenFile = path.join(buildDir, 'cache', 'codec-golden.json');
let goldenCount = 0;
if (fs.existsSync(goldenFile)) {
  const golden = JSON.parse(fs.readFileSync(goldenFile, 'utf8'));
  for (const g of golden.samples) {
    const c = world.chunks[g.chunk];
    const pos = c.attributes.position.array;
    const [, , , sx, sy, sz] = c.quant;
    const tol = [sx, sy, sz].map((s) => s * 0.5 + 1e-4);
    for (let i = 0; i < g.position.length; i++) {
      check(Math.abs(pos[i] - g.position[i]) <= tol[i % 3], `chunk ${g.chunk} position[${i}] ${pos[i]} vs ${g.position[i]}`);
    }
    const uv = c.attributes.uv.array;
    const uvTol = 0.5 / (c.uvScale || UV_SCALE) + 1e-6;
    for (let i = 0; i < g.uv.length; i++) {
      // UVs outside the int16 range are clamped by the encoder; none are expected
      check(Math.abs(uv[i] - g.uv[i]) <= uvTol, `chunk ${g.chunk} uv[${i}] ${uv[i]} vs ${g.uv[i]}`);
    }
    const col = c.attributes.color.array;
    for (let i = 0; i < g.color.length; i++) check(col[i] === g.color[i], `chunk ${g.chunk} color[${i}]`);
    const lit = c.attributes.bakedLight.array;
    for (let i = 0; i < g.light.length; i++) {
      const expect = Math.round(65535 * (g.light[i] / 255) ** 2);
      check(lit[i] === expect, `chunk ${g.chunk} light[${i}] ${lit[i]} vs ${expect}`);
    }
    const flk = c.attributes.flicker.array;
    for (let i = 0; i < g.flicker.length; i++) check(flk[i] === g.flicker[i], `chunk ${g.chunk} flicker[${i}]`);
    for (let i = 0; i < g.index.length; i++) check(c.index[i] === g.index[i], `chunk ${g.chunk} index[${i}] ${c.index[i]} vs ${g.index[i]}`);
    goldenCount++;
  }
  console.log(`  ok   ${goldenCount} golden chunk samples match the bake's pre-encoding values`);
} else {
  fail(`no golden samples at ${goldenFile} (run the bake)`);
}

// structure
const groups = meta.flickerGroups.length;
let verts = 0;
let tris = 0;
for (const c of world.chunks) {
  const n = c.vertexCount;
  verts += n;
  tris += c.indexCount / 3;
  check(c.index.length === c.indexCount && c.indexCount % 3 === 0, `chunk ${c.id} index count`);
  let maxIndex = 0;
  for (let i = 0; i < c.index.length; i++) if (c.index[i] > maxIndex) maxIndex = c.index[i];
  check(maxIndex < n, `chunk ${c.id} index ${maxIndex} < ${n}`);
  const pos = c.attributes.position.array;
  const bb = c.aabb;
  let inside = true;
  for (let i = 0; i < n * 3; i++) {
    const k = i % 3;
    if (!(pos[i] >= bb[k] - 0.01 && pos[i] <= bb[k + 3] + 0.01)) inside = false;
  }
  check(inside, `chunk ${c.id} positions inside aabb`);
  const nrm = c.attributes.normal.array;
  let unit = true;
  for (let i = 0; i < n; i++) {
    const l = Math.hypot(nrm[i * 3], nrm[i * 3 + 1], nrm[i * 3 + 2]) / 127;
    if (Math.abs(l - 1) > 0.03) unit = false;
  }
  check(unit, `chunk ${c.id} unit normals`);
  const flk = c.attributes.flicker.array;
  let groupsOk = true;
  for (let i = 0; i < n; i++) if (flk[i * 2] >= groups || (flk[i * 2] === 0 && flk[i * 2 + 1] !== 0)) groupsOk = false;
  check(groupsOk, `chunk ${c.id} flicker groups valid`);
  const uv = c.attributes.uv.array;
  check(uv.every(Number.isFinite), `chunk ${c.id} uv finite`);
  check(!!meta.materials[c.material], `chunk ${c.id} material ${c.material}`);
  const mat = meta.materials[c.material];
  if (mat && mat.texture) {
    const tex = meta.textures[mat.texture];
    check(!!tex, `material ${c.material} texture ${mat.texture} listed`);
    if (tex) for (const file of Object.values(tex.maps || {})) check(fs.existsSync(path.join(buildDir, file)), `texture file ${file}`);
  }
  if (c.bucket === 'transparent') check(c.attributes.alpha && c.attributes.alpha.array.length === n && c.attributes.alpha.array.every((a) => a > 0), `chunk ${c.id} alpha`);
  if (c.kind === 'entity') {
    // ranges tile the chunk exactly
    const covered = new Uint8Array(n);
    for (const r of c.ranges) {
      check(r.start >= 0 && r.start + r.count <= n, `chunk ${c.id} range in bounds`);
      check(r.entity >= 0 && r.entity < meta.entities.length, `chunk ${c.id} range entity`);
      for (let v = r.start; v < r.start + r.count; v++) covered[v]++;
    }
    check(covered.every((x) => x === 1), `chunk ${c.id} entity ranges tile the vertices`);
  }
  if (c.kind === 'creature') {
    const si = c.attributes.skinIndex.array;
    let ok = true;
    for (let i = 0; i < n; i++) if (si[i * 4] >= meta.creature.bones.length) ok = false;
    check(ok, `chunk ${c.id} bone indices`);
  }
}
console.log(`  ok   ${world.chunks.length} chunks, ${verts} vertices, ${tris} triangles checked`);

// entity helpers: re-posing a range by the identity leaves it unchanged; hiding collapses it
const ec = world.chunks.find((c) => c.kind === 'entity' && c.ranges.length > 0);
if (ec) {
  const before = ec.attributes.position.array.slice();
  const rest = {};
  const r = ec.ranges[0];
  poseEntityRange(ec, r, [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], rest);
  let same = true;
  for (let i = r.start * 3; i < (r.start + r.count) * 3; i++) if (Math.abs(ec.attributes.position.array[i] - before[i]) > 1e-4) same = false;
  check(same, 'poseEntityRange identity');
  poseEntityRange(ec, r, [5, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], rest);
  check(Math.abs(ec.attributes.position.array[r.start * 3] - before[r.start * 3] - 5) < 1e-4, 'poseEntityRange translate');
  poseEntityRange(ec, r, [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1], rest);
  const { attribute, nodes } = nodeIndexAttribute(ec);
  check(attribute.array.length === ec.vertexCount && nodes.length > 0, 'nodeIndexAttribute');
}
for (const e of meta.entities) {
  check(Array.isArray(e.ranges) && e.ranges.length > 0, `entity ${e.id} has geometry`);
  for (const r of e.ranges) check(world.chunks[r.chunk] && world.chunks[r.chunk].kind === 'entity', `entity ${e.id} range chunk`);
}

// vent grates in both looks over the same boxes (VentGrateBuilder): the galvanized one in the grate's own nodes ('',
// Panel, Screw1-4), the rusted-shut one in each node's Rusted sub-node, pivoting where that node rests. A run shows the
// look its plan picks (vents.js), so the export ships both shown: each drawn, the two colliding alike
{
  const before = failures;
  const LOOK_NODES = ['', 'Panel', 'Screw1', 'Screw2', 'Screw3', 'Screw4'];
  const rustedNode = (node) => (node ? `${node}/Rusted` : 'Rusted');
  const boxKey = (c) => `${c.shape}|${c.group}|${c.size.map((v) => v.toFixed(3))}|${c.cf.map((v) => v.toFixed(3))}`;
  const grates = meta.entities.filter((e) => e.type === 'VentGrate');
  check(grates.length >= 2, `${grates.length} vent grates`);
  for (const e of grates) {
    const nodes = new Map(e.nodes.map((n) => [n.path, n]));
    const drawn = new Set(e.ranges.filter((r) => r.count > 0).map((r) => r.node || ''));
    for (const node of LOOK_NODES) {
      const twin = rustedNode(node);
      const name = node || 'frame';
      check(nodes.has(twin) && (!node || nodes.has(node)), `${e.id} ${name}: nodes ${node || "''"} and ${twin}`);
      check(drawn.has(node) && drawn.has(twin), `${e.id} ${name}: drawn in both looks`);
      const pivot = node ? nodes.get(node) && nodes.get(node).pivot : e.pivot;
      const twinPivot = nodes.get(twin) && nodes.get(twin).pivot;
      check(!!pivot && !!twinPivot && pivot.every((v, i) => Math.abs(v - twinPivot[i]) < 1e-4), `${e.id} ${twin} pivots where ${name} rests`);
      const mine = e.colliders.filter((c) => (c.node || '') === node).map(boxKey).sort();
      const theirs = e.colliders.filter((c) => c.node === twin).map(boxKey).sort();
      check(mine.join(';') === theirs.join(';'), `${e.id} ${name}: the looks collide alike (${mine.length} / ${theirs.length} boxes)`);
      if (node === '' || node === 'Panel') check(mine.length >= 4, `${e.id} ${name}: colliding boxes`);
    }
  }
  if (failures === before) console.log(`  ok   ${grates.length} vent grates in both looks, drawn and colliding alike`);
}

// floor objectives: every candidate, station and lock is an entity with its prompts, leaves and attachments
{
  const ids = new Set(meta.entities.map((e) => e.id));
  check(new Set(meta.entities.map((e) => `${e.level}/${e.id}`)).size === meta.entities.length, 'entity ids unique per level');
  const byType = (type) => meta.entities.filter((e) => e.type === type);
  // the fewest candidates each floor may offer (a rebuilt floor offers at least as many as the one it replaced); every
  // candidate anchor of the item's kind becomes one entity
  const ITEMS = { Fuse: 14, MasterKeys: 10 };
  const anchorKind = new Map(meta.anchors.map((a) => [a.id, a.kind]));
  for (const [type, least] of Object.entries(ITEMS)) {
    const list = byType(type);
    const kinds = new Set(list.map((e) => e.attributes.Candidate).filter(Boolean));
    const offered = kinds.size ? meta.anchors.filter((a) => kinds.has(a.kind)).length : least;
    check(list.length >= least && list.length === offered && kinds.size <= 1,
      `${type}: ${list.length} entities (want ${offered}, at least ${least})`);
    for (const e of list) {
      if (e.attributes.Candidate) check(anchorKind.get(e.attributes.AnchorId) === e.attributes.Candidate, `${e.id} stands on its candidate anchor`);
      check(e.tags.includes('ObjectiveItem'), `${e.id} tag`);
      check(typeof e.attributes.Floor === 'number' && typeof e.attributes.Step === 'string', `${e.id} Floor / Step`);
      check(typeof e.attributes.Planned === 'boolean', `${e.id} Planned`);
      check(e.attachments && e.attachments.Grip && e.attachments.PromptPoint, `${e.id} Grip + PromptPoint`);
      check(e.prompts.length === 1 && e.prompts[0].name === 'Pickup', `${e.id} Pickup prompt`);
    }
  }
  const STATIONS = {
    BreakerPanel: ['Door', 'FuseSlot1', 'FuseSlot2', 'FuseSlot3', 'Lever'],
  };
  for (const [type, leaves] of Object.entries(STATIONS)) {
    const list = byType(type);
    check(list.length === 1, `${type}: one entity`);
    for (const e of list) {
      const paths = new Set(e.nodes.map((n) => n.path));
      for (const leaf of leaves) {
        check(paths.has(leaf), `${type} node ${leaf}`);
        check(e.attachments[`${leaf}Rest`], `${type} ${leaf}Rest`);
      }
      check(e.prompts.length >= 1 && e.prompts.every((p) => typeof p.attributes.Step === 'string'), `${type} prompts carry Step`);
    }
  }
  // an ExitLock on every exit candidate of a floor whose objective has a lock step (floors 0-1; the Auditorium's
  // interim crossing has none)
  const lockLevels = new Set(((meta.objectives && meta.objectives.floors) || []).filter((f) => f.lockStep).map((f) => f.levelId));
  check(lockLevels.size === 2 && lockLevels.has('Level0_Basement') && lockLevels.has('Level1_Hallways'), `floors with a lock step: ${[...lockLevels].join(', ')}`);
  const locks = byType('ExitLock');
  check(locks.length === 3 * lockLevels.size, `ExitLock: ${locks.length} entities (want ${3 * lockLevels.size}: one per exit candidate on floors 0-1)`);
  for (const e of locks) {
    check(lockLevels.has(e.level), `${e.id} on a floor with a lock step (${e.level})`);
    check(['Padlock', 'Chain', 'Keypad'].includes(e.attributes.LockVariant) && e.attributes.Locked === true, `${e.id} variant`);
    check(e.prompts.some((p) => p.name === 'Locked'), `${e.id} Locked prompt`);
    check(ids.has(e.attributes.DoorId), `${e.id} names its door entity`);
  }
  check(meta.objectives && Object.keys(meta.objectives.levels || {}).length === 3 && (meta.objectives.floors || []).length === 3,
    'meta.objectives for the three floors below the roof');
}

// floor objectives: every item candidate is fair, and the export seed's picks keep the multi-item rules
{
  const o = meta.objectives || {};
  const rules = o.rules || {};
  check(rules.entryClearance === 35 && rules.pickSpacing === 25 && rules.pickQuarters === 2, 'objective rules exported');
  const MIN = { Level0_Basement: 12, Level1_Hallways: 9 };
  const anchorIds = new Set(meta.anchors.map((a) => a.id));
  const [fw, fd] = rules.footprint || [240, 160];
  const quarterOf = (p) => 1 + (p[0] >= fw / 2 ? 1 : 0) + (p[2] >= fd / 2 ? 2 : 0);
  const flat = (a, b) => Math.hypot(a[0] - b[0], a[2] - b[2]);
  for (const floor of o.floors || []) {
    const level = (o.levels || {})[floor.levelId];
    check(!!level, `${floor.levelId} objective data`);
    if (!level) continue;
    const list = level.candidates || [];
    check(level.entry && level.entry.room && Array.isArray(level.entry.pos), `${floor.levelId} entry point`);
    if (!floor.item) {
      // a plain crossing (the Auditorium's interim floor): nothing to find, nothing planned
      // (Lune's JSON writes an empty Luau table as {})
      const none = (x) => !x || Object.keys(x).length === 0;
      check(!(floor.levelId in MIN) && none(level.candidates) && none(level.places) && (!level.picks || none(level.picks.anchors)),
        `${floor.levelId}: no item, no candidates, no places, no picks`);
      continue;
    }
    check(list.length >= MIN[floor.levelId], `${floor.levelId}: ${list.length} candidates (want >= ${MIN[floor.levelId]})`);
    for (const c of list) {
      check(c.eligible === true, `${c.anchorId} is a candidate a run may use`);
      check(c.entryDistance >= rules.entryClearance, `${c.anchorId} ${c.entryDistance} studs walked from the entry`);
      const ways = level.entries && level.entries.length ? level.entries : level.entry ? [level.entry] : [];
      if (ways.length) check(c.entryDistance + 0.1 >= Math.min(...ways.map((e) => flat(c.pos, e.pos))), `${c.anchorId} walk >= straight line`);
      check(c.hide && c.hide.distance <= o.hideReach, `${c.anchorId} hiding spot within ${o.hideReach}`);
      check(c.quarter === quarterOf(c.pos), `${c.anchorId} quarter`);
      if (floor.item.guarded) check(c.ref && anchorIds.has(c.ref), `${c.anchorId} guard trap spot ${c.ref}`);
    }
    const picked = (level.picks ? level.picks.anchors : []).map((id) => list.find((c) => c.anchorId === id));
    check(picked.length === floor.item.count && picked.every(Boolean), `${floor.levelId} export picks`);
    check(list.filter((c) => c.planned).length === floor.item.count, `${floor.levelId} planned flags`);
    for (let i = 0; i < picked.length; i++) {
      for (let j = i + 1; j < picked.length; j++) {
        const a = picked[i];
        const b = picked[j];
        if (!a || !b) continue;
        check(a.room !== b.room, `${a.anchorId} / ${b.anchorId} in different rooms`);
        check(flat(a.pos, b.pos) >= rules.pickSpacing, `${a.anchorId} / ${b.anchorId} ${flat(a.pos, b.pos).toFixed(1)} apart`);
      }
    }
    if (picked.length >= 3 && picked.every(Boolean)) check(new Set(picked.map((c) => c.quarter)).size >= rules.pickQuarters, `${floor.levelId} picks spread`);
    // every item entity is the prop any run that picks its anchor builds (RunDirector.objectiveProp): no item has kinds
    // since the reagents were cut, so none carries a Slot (on the model or its Pickup prompt), whatever the picks
    for (const e of meta.entities.filter((x) => x.type === floor.item.prop)) {
      const prompt = e.prompts.find((p) => p.name === 'Pickup');
      check(e.attributes.Slot === undefined && (prompt ? prompt.attributes.Slot : undefined) === undefined,
        `${e.id} Slot ${e.attributes.Slot} / prompt ${prompt ? prompt.attributes.Slot : '-'} (want none)`);
    }
  }
}

// the props the web draws again away from the world (flaskFx.js: the flask in a hand, in flight and a teammate's): a
// chemical flask on any anchor is its anchor's variant (RunDirector.variantOf) and looks exactly as the exported world
// prop (ChemicalFlaskBuilder.lookOf on the world's Rng: the fill line's three liquid tiers, the crack and its frame, the
// liquid colour). One flask is exported on every FlaskCandidate anchor; while the floors have none (the four-level school
// until its flask candidates are added), there is no flask to check, else there must be some.
{
  const before = failures;
  const rawFile = path.join(buildDir, 'cache', 'world-raw.json');
  check(fs.existsSync(rawFile), `the export's world (${rawFile})`);
  let flasks = 0;
  let cracked = 0;
  if (fs.existsSync(rawFile)) {
    const raw = JSON.parse(fs.readFileSync(rawFile, 'utf8'));
    const partsOf = new Map();
    for (const p of raw.parts) {
      if (p.entity === undefined) continue;
      if (!partsOf.has(p.entity)) partsOf.set(p.entity, new Map());
      partsOf.get(p.entity).set(p.name, p);
    }
    const planProps = meta.plan && Array.isArray(meta.plan.props) ? meta.plan.props : [];
    const planned = new Map(planProps.filter((p) => p.kind === 'ChemicalFlask').map((p) => [p.anchorId, p.variant]));
    const near = (a, b, tol) => Math.abs(a - b) <= tol;
    const STUD = 2e-4; // the export's 1e-4 rounding plus Lune's 1/65536 storage
    const at = new THREE.Vector3();
    for (const e of raw.entities.filter((x) => /^ChemicalFlask_/.test(x.name))) {
      flasks++;
      const anchor = e.attributes.AnchorId;
      const variant = variantOf('ChemicalFlask', e.level, anchor);
      if (planned.has(anchor)) check(planned.get(anchor) === variant, `${anchor}: variantOf ${variant} is the plan's ${planned.get(anchor)}`);
      const look = flaskLook(variant);
      const parts = partsOf.get(e.index) || new Map();
      const pivot = cfMatrix(e.pivot);
      liquidTiers(look).forEach(([y0, y1, d], i) => {
        const p = parts.get(`Liquid${i + 1}`);
        check(!!p, `${anchor} Liquid${i + 1}`);
        if (!p) return;
        at.set(0, (y0 + y1) / 2, 0).applyMatrix4(pivot);
        check(near(p.size[0], y1 - y0, STUD) && near(p.size[1], d, STUD) && near(p.size[2], d, STUD),
          `${anchor} Liquid${i + 1} ${p.size.join(' x ')} (look: ${(y1 - y0).toFixed(4)} x ${d.toFixed(4)})`);
        check(at.distanceTo(cfPos(p.cf)) <= 1e-3, `${anchor} Liquid${i + 1} sits at its tier`);
        const c = liquidColor(variant);
        check([c.r, c.g, c.b].every((v, k) => Math.round(v * 255) === Math.round(p.color[k] * 255)), `${anchor} Liquid${i + 1} colour`);
      });
      const crack = parts.get('Crack');
      check(!!crack === look.cracked, `${anchor}: ${crack ? 'a' : 'no'} crack (look: ${look.cracked ? 'cracked' : 'whole'})`);
      if (crack && look.cracked) {
        cracked++;
        const want = crackFrame(look);
        check(want.size.every((v, k) => near(crack.size[k], v, STUD)), `${anchor} crack size ${crack.size.join(' x ')}`);
        const frame = pivot.clone().multiply(want.frame);
        check(cfPos(crack.cf).distanceTo(at.setFromMatrixPosition(frame)) <= 1e-3, `${anchor} crack position`);
        // each axis within a milliradian (the stored rotations are rounded, so their columns are unit only to ~1e-5)
        const got = cfMatrix(crack.cf);
        const axis = (m, k) => new THREE.Vector3().setFromMatrixColumn(m, k).normalize();
        check([0, 1, 2].every((k) => axis(got, k).angleTo(axis(frame, k)) <= 1e-3), `${anchor} crack orientation`);
      }
    }
    const anchored = meta.anchors.filter((a) => a.kind === 'FlaskCandidate').length;
    check(flasks === meta.entities.filter((x) => x.type === 'ChemicalFlask').length && flasks === anchored,
      `${flasks} chemical flasks exported and baked, one per FlaskCandidate anchor (${anchored})`);
    if (anchored > 0) check(flasks > 0, `${flasks} chemical flasks with ${anchored} FlaskCandidate anchors`);
  }
  if (failures === before) console.log(`  ok   ${flasks} chemical flasks (${cracked} cracked) look as flaskFx draws their variant`);
}

// guarded items (the basement's fuses): every candidate is taken from a spot beside it, clear of every trap spot a run
// may arm (the guard of whichever fuses it picks, any other's, the seeded rest) and walked to from a doorway of its room
// with no foot on a pan: the export's ObjectivePlaces.standingSpot, held here to the baked world (the static collision,
// the entities' colliders and the item's own Pickup prompt)
{
  const o = meta.objectives || {};
  const S = o.stand || {};
  check(S.near > 0 && S.reach > S.near && S.trapClear > 0 && S.panReach > 0 && S.body > 0 && S.step > 0 && S.eye > 0 && S.bodyHeight > S.eye,
    'the standing-spot rule is exported');
  check(S.panCore > 0 && S.panCore < S.panReach && S.promptReach > S.reach && S.approachRun > 0, 'the guard rule is exported');
  const rooms = new Map(meta.rooms.map((r) => [r.id, r]));
  const bvhs = new Map();
  const bvhOf = (level) => {
    if (!bvhs.has(level)) {
      // the engine's collision BVH (World._buildCollision)
      const c = world.collision[level];
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.BufferAttribute(c.position, 3));
      geometry.setIndex(new THREE.BufferAttribute(c.index, 1));
      bvhs.set(level, new MeshBVH(geometry, { targetLeafSize: 8, strategy: 0 }));
    }
    return bvhs.get(level);
  };
  const ray = new THREE.Ray();
  const hit = (level, from, dir, dist) => {
    ray.origin.set(from[0], from[1], from[2]);
    ray.direction.set(dir[0], dir[1], dir[2]).normalize();
    const h = bvhOf(level).raycastFirst(ray, THREE.DoubleSide, 0, dist);
    return h && h.distance <= dist ? h : null;
  };
  // an entity's colliders as oriented boxes (pivot * collider frame; CFrame rows: position, then the rotation matrix)
  const compose = (a, b) => {
    const r = (m, i, j) => m[3 + i * 3 + j];
    const out = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
    for (let i = 0; i < 3; i++) {
      out[i] = a[i] + r(a, i, 0) * b[0] + r(a, i, 1) * b[1] + r(a, i, 2) * b[2];
      for (let j = 0; j < 3; j++) out[3 + i * 3 + j] = r(a, i, 0) * r(b, 0, j) + r(a, i, 1) * r(b, 1, j) + r(a, i, 2) * r(b, 2, j);
    }
    return out;
  };
  const toLocal = (box, p) => {
    const d = [p[0] - box.cf[0], p[1] - box.cf[1], p[2] - box.cf[2]];
    return [0, 1, 2].map((j) => d[0] * box.cf[3 + j] + d[1] * box.cf[6 + j] + d[2] * box.cf[9 + j]);
  };
  const boxGap = (box, p) => {
    const l = toLocal(box, p);
    return Math.hypot(...l.map((v, k) => Math.max(Math.abs(v) - box.half[k], 0)));
  };
  const segmentHitsBox = (box, a, b) => {
    const la = toLocal(box, a);
    const lb = toLocal(box, b);
    let t0 = 0;
    let t1 = 1;
    for (let k = 0; k < 3; k++) {
      const d = lb[k] - la[k];
      if (Math.abs(d) < 1e-9) {
        if (Math.abs(la[k]) > box.half[k]) return false;
        continue;
      }
      let ta = (-box.half[k] - la[k]) / d;
      let tb = (box.half[k] - la[k]) / d;
      if (ta > tb) [ta, tb] = [tb, ta];
      t0 = Math.max(t0, ta);
      t1 = Math.min(t1, tb);
      if (t0 > t1) return false;
    }
    return true;
  };
  const DIRS = [[1, 0, 0], [-1, 0, 0], [0, 0, 1], [0, 0, -1]];
  const DIAGONALS = DIRS.concat([[1, 0, 1], [1, 0, -1], [-1, 0, 1], [-1, 0, -1]]);
  let held = 0;
  let guarded = 0;
  let walked = 0;
  let sprung = 0;
  let searched = 0;
  // The shortest walk the baked world allows from `start` ([x, z]) to the first point where `answers` (<= 0) holds, on
  // a 0.25 grid at any angle (Theta*: a leg runs straight while every cell under it is free), searched inside `region`
  // ({x0, z0, x1, z1}); `free(x, z)` says whether the body may stand on a cell's centre. [x, z] points, or null.
  const anyAngleWalk = (start, region, free, answers) => {
    const CELL = 0.25;
    const nx = Math.ceil((region.x1 - region.x0) / CELL);
    const nz = Math.ceil((region.z1 - region.z0) / CELL);
    const known = new Int8Array(nx * nz).fill(-1);
    const at = (k) => [region.x0 + ((k % nx) + 0.5) * CELL, region.z0 + (Math.floor(k / nx) + 0.5) * CELL];
    const open = (i, j) => {
      if (i < 0 || j < 0 || i >= nx || j >= nz) return false;
      const k = j * nx + i;
      if (known[k] < 0) known[k] = free(...at(k)) ? 1 : 0;
      return known[k] === 1;
    };
    const cellOf = (x, z) => [Math.floor((x - region.x0) / CELL), Math.floor((z - region.z0) / CELL)];
    const sight = (a, b) => {
      const [ax, az] = at(a);
      const [bx, bz] = at(b);
      const n = Math.max(1, Math.ceil(Math.hypot(bx - ax, bz - az) / 0.05));
      for (let t = 0; t <= n; t++) {
        if (!open(...cellOf(ax + ((bx - ax) * t) / n, az + ((bz - az) * t) / n))) return false;
      }
      return true;
    };
    // the start's cell, else the free cell nearest the start (a start on the body's limit can put a centre over it)
    let [si, sj] = cellOf(start[0], start[1]);
    if (!open(si, sj)) {
      let best = null;
      for (let di = -2; di <= 2; di++) {
        for (let dj = -2; dj <= 2; dj++) {
          if (!open(si + di, sj + dj)) continue;
          const [cx, cz] = at((sj + dj) * nx + si + di);
          const d = Math.hypot(cx - start[0], cz - start[1]);
          if (!best || d < best[0]) best = [d, si + di, sj + dj];
        }
      }
      if (!best) return null;
      [, si, sj] = best;
    }
    const dist = new Float64Array(nx * nz).fill(Infinity);
    const prev = new Int32Array(nx * nz).fill(-1);
    const heap = [];
    const push = (d, k) => {
      heap.push([d, k]);
      for (let c = heap.length - 1; c > 0; ) {
        const p = (c - 1) >> 1;
        if (heap[p][0] <= heap[c][0]) break;
        [heap[p], heap[c]] = [heap[c], heap[p]];
        c = p;
      }
    };
    const pop = () => {
      const top = heap[0];
      const end = heap.pop();
      if (heap.length) {
        heap[0] = end;
        for (let c = 0; ; ) {
          const l = 2 * c + 1;
          let m = c;
          if (l < heap.length && heap[l][0] < heap[m][0]) m = l;
          if (l + 1 < heap.length && heap[l + 1][0] < heap[m][0]) m = l + 1;
          if (m === c) break;
          [heap[m], heap[c]] = [heap[c], heap[m]];
          c = m;
        }
      }
      return top;
    };
    const s0 = sj * nx + si;
    dist[s0] = 0;
    push(0, s0);
    while (heap.length) {
      const [d, k] = pop();
      if (d > dist[k]) continue;
      const [x, z] = at(k);
      if (answers(x, z) <= 0) {
        const walk = [];
        for (let c = k; c >= 0; c = prev[c]) walk.unshift(at(c));
        return walk;
      }
      const i = k % nx;
      const j = Math.floor(k / nx);
      for (const [di, dj] of DIAGONALS.map((v) => [v[0], v[2]])) {
        if (!open(i + di, j + dj) || (di && dj && !(open(i + di, j) && open(i, j + dj)))) continue;
        const n = (j + dj) * nx + i + di;
        const [ux, uz] = at(n);
        const p = prev[k];
        if (p >= 0 && sight(p, n)) {
          const [px, pz] = at(p);
          const nd = dist[p] + Math.hypot(ux - px, uz - pz);
          if (nd < dist[n] - 1e-9) {
            dist[n] = nd;
            prev[n] = p;
            push(nd, n);
          }
        } else {
          const nd = d + CELL * Math.hypot(di, dj);
          if (nd < dist[n] - 1e-9) {
            dist[n] = nd;
            prev[n] = k;
            push(nd, n);
          }
        }
      }
    }
    return null;
  };
  for (const floor of o.floors || []) {
    if (!floor.item || !floor.item.guarded) continue;
    const level = (o.levels || {})[floor.levelId];
    if (!level) continue;
    guarded += level.candidates.length;
    const id = floor.levelId;
    const origin = meta.levels[id].origin;
    const traps = meta.anchors.filter((a) => a.level === id && a.kind === 'TrapCandidate').map((a) => [a.cframe[0], a.cframe[2]]);
    const trapGap = (x, z) => Math.min(...traps.map((t) => Math.hypot(t[0] - x, t[1] - z)));
    const items = new Map(meta.entities.filter((e) => e.level === id && e.tags.includes('ObjectiveItem')).map((e) => [e.attributes.AnchorId, e]));
    const boxes = [];
    for (const e of meta.entities) {
      if (e.level !== id || e.tags.includes('ObjectiveItem')) continue;
      for (const c of e.colliders) boxes.push({ id: e.id, cf: compose(e.pivot, c.cf), half: c.size.map((v) => v / 2) });
    }
    // the body standing at (x, z) on a floor at y: clear of the static collision and of every entity's colliders
    const bodyClear = (x, y, z, dirs, radius) => {
      for (const h of [S.step + 0.2, 3, S.bodyHeight - 0.6]) {
        const p = [x, y + h, z];
        if (dirs.some((d) => hit(id, p, d, radius))) return `a wall within ${radius} at ${h} studs up`;
        const near = boxes.find((b) => boxGap(b, p) < radius);
        if (near) return `${near.id} within ${radius} at ${h} studs up`;
      }
      return null;
    };
    // the floor under (x, z): a walking surface at y
    const footing = (x, y, z) => {
      const h = hit(id, [x, y + 2, z], [0, -1, 0], 3);
      return !!h && Math.abs(h.point.y - y) < 0.15;
    };
    for (const c of level.candidates) {
      const s = c.stand;
      check(!!s, `${c.anchorId}: a spot to stand beside it clear of every trap spot, walked to round its guard`);
      if (!s) continue;
      const room = rooms.get(c.room);
      check(!!room, `${c.anchorId} room ${c.room}`);
      if (!room) continue;
      const y = room.floorY;
      const x = origin[0] + s.pos[0];
      const z = origin[2] + s.pos[2];
      const item = [origin[0] + c.pos[0], origin[1] + c.pos[1], origin[2] + c.pos[2]];
      const reach = Math.hypot(x - item[0], z - item[2]);
      check(reach >= S.near - 0.01 && reach <= S.reach + 0.01, `${c.anchorId}: the spot ${reach.toFixed(2)} studs off it`);
      check(trapGap(x, z) >= S.trapClear - 0.01, `${c.anchorId}: the spot ${trapGap(x, z).toFixed(2)} studs from the nearest trap spot`);
      // the item's own Pickup prompt answers the standing root, in sight of the eye
      const e = items.get(c.anchorId);
      const prompt = e && e.prompts.find((p) => p.name === 'Pickup');
      const point = e && e.attachments.PromptPoint;
      check(!!prompt && !!point, `${c.anchorId}: its item and Pickup prompt`);
      if (prompt && point) {
        const root = [x, y + S.eye - 1.5, z];
        const d = Math.hypot(point[0] - root[0], point[1] - root[1], point[2] - root[2]);
        check(d <= prompt.maxDistance, `${c.anchorId}: its prompt reaches the spot (${d.toFixed(2)} of ${prompt.maxDistance})`);
        const eye = [x, y + S.eye, z];
        const to = [point[0] - eye[0], point[1] - eye[1], point[2] - eye[2]];
        const len = Math.hypot(...to);
        check(!hit(id, eye, to, len - 0.05), `${c.anchorId}: the item in sight of the spot (the static world)`);
        const blocker = boxes.find((b) => segmentHitsBox(b, eye, point));
        check(!blocker, `${c.anchorId}: the item in sight of the spot (${blocker && blocker.id} in the way)`);
      }
      // the careless walk in (a walk per way the arrival doorway's leaf may hang): each ends where the item's prompt first
      // answers with its foot on the guard's pan on the way; the one the baked world leaves open (the leaf hangs where it
      // does) is walked on the floor with the body clear all the way
      const cw = c.careless;
      const guardAt = (meta.anchors.find((a) => a.id === c.ref) || {}).cframe;
      check(!!cw && Array.isArray(cw.walks) && cw.walks.length >= 1 && !!guardAt, `${c.anchorId}: its careless walk in and its guard`);
      if (cw && guardAt && prompt && point) {
        let open = 0;
        cw.walks.forEach((w, v) => {
          const pts = w.map((p) => [origin[0] + p[0], origin[2] + p[1]]);
          const label = `${c.anchorId} careless walk ${v + 1}`;
          const answers = (px, pz) => Math.hypot(point[0] - px, point[1] - (y + S.eye - 1.5), point[2] - pz) - prompt.maxDistance;
          let near = Infinity;
          let clear = true;
          for (let i = 0; i + 1 < pts.length; i++) {
            const [ax, az] = pts[i];
            const [bx, bz] = pts[i + 1];
            const steps = Math.max(1, Math.ceil(Math.hypot(bx - ax, bz - az) / 0.25));
            for (let k = 0; k <= steps; k++) {
              const px = ax + ((bx - ax) * k) / steps;
              const pz = az + ((bz - az) * k) / steps;
              near = Math.min(near, Math.hypot(px - guardAt[0], pz - guardAt[2]));
              if (i + 2 < pts.length || k < steps) check(answers(px, pz) > -0.05, `${label} at (${px.toFixed(2)}, ${pz.toFixed(2)}): the prompt waits for its end`);
              if (clear && (!footing(px, y, pz) || bodyClear(px, y, pz, DIRS, S.body - 0.1))) clear = false;
            }
          }
          const [ex, ez] = pts[pts.length - 1];
          check(pts.length >= 2 && answers(ex, ez) <= 0.05, `${label} ends where the prompt answers`);
          check(near <= S.panCore + 0.01, `${label} passes ${near.toFixed(2)} studs from ${c.ref}: its foot on the pan`);
          if (clear) open++;
        });
        check(open >= 1, `${c.anchorId}: a careless walk the baked world leaves open`);
        sprung++;
        // and found here, not taken from the export: the shortest walk the baked world allows from the same start to
        // where the prompt first answers (the body clear of the static collision and every entity's colliders, the floor
        // under it) sets its foot on the guard's pan too
        const start = [origin[0] + cw.walks[0][0][0], origin[2] + cw.walks[0][0][1]];
        const span = cw.walks.flat().map((p) => [origin[0] + p[0], origin[2] + p[1]]);
        const r = room.rect;
        const region = {
          x0: Math.min(origin[0] + r.x, ...span.map((p) => p[0])) - 4,
          z0: Math.min(origin[2] + r.z, ...span.map((p) => p[1])) - 4,
          x1: Math.max(origin[0] + r.x + r.w, ...span.map((p) => p[0])) + 4,
          z1: Math.max(origin[2] + r.z + r.d, ...span.map((p) => p[1])) + 4,
        };
        const nearBoxes = boxes.filter((b) => b.cf[0] > region.x0 - 8 && b.cf[0] < region.x1 + 8 && b.cf[2] > region.z0 - 8 && b.cf[2] < region.z1 + 8);
        const free = (px, pz) => {
          if (!footing(px, y, pz)) return false;
          for (const h of [S.step + 0.2, 3, S.bodyHeight - 0.6]) {
            const q = [px, y + h, pz];
            if (DIAGONALS.some((d) => hit(id, q, d, S.body - 0.1))) return false;
            if (nearBoxes.some((b) => boxGap(b, q) < S.body - 0.1)) return false;
          }
          return true;
        };
        const answers = (px, pz) => Math.hypot(point[0] - px, point[1] - (y + S.eye - 1.5), point[2] - pz) - prompt.maxDistance;
        const found = anyAngleWalk(start, region, free, answers);
        check(!!found, `${c.anchorId}: the baked world lets a body walk in from the careless walk's start to the item's prompt`);
        if (found) {
          let near = Infinity;
          for (let i = 0; i < found.length; i++) {
            const [ax, az] = found[i];
            const [bx, bz] = found[Math.min(i + 1, found.length - 1)];
            const ab = [bx - ax, bz - az];
            const l2 = ab[0] * ab[0] + ab[1] * ab[1];
            const t = l2 > 1e-12 ? Math.max(0, Math.min(1, ((guardAt[0] - ax) * ab[0] + (guardAt[2] - az) * ab[1]) / l2)) : 0;
            near = Math.min(near, Math.hypot(ax + ab[0] * t - guardAt[0], az + ab[1] * t - guardAt[2]));
          }
          check(near <= S.panCore, `${c.anchorId}: the shortest walk the baked world allows passes ${near.toFixed(2)} studs from ${c.ref}: its foot on the pan`);
          searched++;
        }
      }
      check(footing(x, y, z), `${c.anchorId}: the spot stands on the floor`);
      check(!hit(id, [x, y + 0.3, z], [0, 1, 0], S.bodyHeight - 0.3), `${c.anchorId}: head room at the spot`);
      const blocked = bodyClear(x, y, z, DIAGONALS, S.body - 0.05);
      check(!blocked, `${c.anchorId}: the body clear at the spot (${blocked})`);
      // the walk: from a doorway of the room (the way out through it is open) along straight legs, the foot off every
      // pan, the body clear and the floor under it all the way
      const path = (s.path || []).map((p) => [origin[0] + p[0], origin[2] + p[1]]);
      const last = path[path.length - 1];
      check(path.length >= 1 && Math.hypot(last[0] - x, last[1] - z) < 0.01, `${c.anchorId}: the walk ends on the spot`);
      if (!path.length) continue;
      const r = room.rect;
      const [fx, fz] = path[0];
      const edges = [[fx - r.x, [-1, 0, 0]], [r.x + r.w - fx, [1, 0, 0]], [fz - r.z, [0, 0, -1]], [r.z + r.d - fz, [0, 0, 1]]];
      const [toEdge, out] = edges.reduce((a, b) => (b[0] < a[0] ? b : a));
      check(toEdge <= S.body + 1.01, `${c.anchorId}: the walk starts by a wall of its room (${toEdge.toFixed(2)} in)`);
      check(!hit(id, [fx, y + 3, fz], out, toEdge + 2), `${c.anchorId}: the walk starts in a doorway (the way out is open)`);
      for (let i = 0; i + 1 < path.length; i++) {
        const [ax, az] = path[i];
        const [bx, bz] = path[i + 1];
        const steps = Math.max(1, Math.ceil(Math.hypot(bx - ax, bz - az) / 0.25));
        for (let k = 0; k <= steps; k++) {
          const px = ax + ((bx - ax) * k) / steps;
          const pz = az + ((bz - az) * k) / steps;
          walked++;
          const where = `${c.anchorId}: the walk at (${px.toFixed(2)}, ${pz.toFixed(2)})`;
          check(trapGap(px, pz) > S.panReach - 1e-6, `${where} keeps the foot off every pan`);
          check(footing(px, y, pz), `${where} is on the floor`);
          const b = bodyClear(px, y, pz, DIRS, S.body - 0.1);
          check(!b, `${where}: the body clear (${b})`);
        }
      }
      held++;
    }
  }
  check(guarded > 0 && held === guarded, `${held} of ${guarded} guarded items held to the standing-spot rule`);
  check(sprung === guarded, `${sprung} of ${guarded} guarded items' guards on their careless walks`);
  check(searched === guarded, `${searched} of ${guarded} guarded items' guards on the shortest walk the baked world allows`);
  console.log(`  ok   guarded items: ${sprung} guards on the careless walk in (${searched} on the shortest walk the baked world allows), ${held} standing spots and their walks (${walked} steps) clear of every trap spot`);
}
// removals (docs/design/game-spec-v2.md 6): the baked world is the four-level school; no level, layout, route,
// stairwell, entity, anchor, room, door, volume or name in it comes from the cut floors (the Science Hall, the Gym, the
// pool), the old roof's objective and landing field, or the stairwells above the old Level 3; no pool water data
{
  const before = failures;
  const SCHOOL = ['Level0_Basement', 'Level1_Hallways', 'Level2_Auditorium', 'Level3_Roof'];
  check(Object.keys(meta.levels).filter((id) => id.startsWith('Level')).sort().join() === SCHOOL.join(), `levels: ${Object.keys(meta.levels).join(', ')}`);
  check(Object.keys(meta.layouts || {}).filter((id) => id !== 'Lobby').sort().join() === SCHOOL.join(), `layouts: ${Object.keys(meta.layouts || {}).join(', ')}`);
  check(!('pools' in meta) && !('basins' in meta), 'no pool water or basins');
  const CUT = ['Level2_ScienceHall', 'Level3_Gymnasium', 'Level4_FloodedPool', 'Level5_Roof', 'Stairwell_3_4', 'Stairwell_4_5',
    'ScienceHall', 'Gymnasium', 'FloodedPool', 'PoolWater', 'Basin', 'FumeHood', 'AcidFlask', 'Reagent', 'Generator',
    'CoachKey', 'StoreLock', 'EquipmentStoreDoor', 'ValveWheel', 'HatchValve', 'FloodlightSwitch', 'BoltCutter',
    'CrateChain', 'CutCrate', 'LandingField', 'flasksScienceHall', 'flasksPool'];
  const text = JSON.stringify(meta);
  for (const cut of CUT) check(!text.includes(cut), `the baked data names ${cut} (cut)`);
  const oldFloor = /"L[45]_/g;
  const hits = text.match(oldFloor) || [];
  check(hits.length === 0, `${hits.length} ids of the old floors 4 and 5 (L4_ / L5_) in the baked data`);
  if (failures === before) console.log(`  ok   removals: the four-level school, ${CUT.length} cut names and the L4_ / L5_ ids absent from ${(text.length / 1e6).toFixed(1)} MB of meta`);
}
// routes: three candidate stairwells per floor pair, each complete (exit fire doors, entry doors, Checkpoint volume,
// arrival spawns, an ExitLock on every exit candidate of a floor with a lock step and none elsewhere, the Creature's
// spot in every roof housing), its doors carrying the jam data, every
// candidate reachable and fair from at least one way in, and the export seed's pick among them
{
  const routes = meta.routes || {};
  const pairs = meta.routePairs || [];
  const rule = meta.routeRule || {};
  const entityById = new Map(meta.entities.map((e) => [e.id, e]));
  const anchorById = new Map(meta.anchors.map((a) => [a.id, a]));
  const triggerIds = new Set(meta.triggers.map((t) => t.id));
  const roomIds = new Set(meta.rooms.map((r) => r.id));
  const stairIds = new Set((meta.stairwells || []).map((s) => s.id));
  const order = (meta.worldConfig && meta.worldConfig.LevelOrder) || [];
  const roof = order[order.length - 1];
  const lockLevels = new Set(((meta.objectives && meta.objectives.floors) || []).filter((f) => f.lockStep).map((f) => f.levelId));
  check(order.join() === 'Level0_Basement,Level1_Hallways,Level2_Auditorium,Level3_Roof', `the school's levels: ${order.join(', ')}`);
  check(pairs.length === 3 && pairs.every((p, i) => p.from === order[i]), `3 floor pairs (${pairs.map((p) => p.from).join(', ')})`);
  check(stairIds.size === 9, `9 stairwells in meta.stairwells (${stairIds.size})`);
  check(rule.stream === 'Route|<from>' && rule.attempts > 0 && rule.fairShare > 0, 'route rule');
  for (const p of pairs) {
    const list = routes[p.from] || [];
    check(list.length === 3, `${p.from}: 3 exit candidates`);
    check(list.map((c) => c.slot).join() === 'North,Middle,South', `${p.from}: slot order`);
    check(p.candidates.includes(p.picked), `${p.from}: export pick ${p.picked}`);
    for (const c of list) {
      const tag = `${c.stairwellId}`;
      check(stairIds.has(c.stairwellId) && c.id === c.stairwellId, `${tag} is a stairwell`);
      check(roomIds.has(c.fromRoom) && roomIds.has(c.toRoom), `${tag} vestibules ${c.fromRoom} / ${c.toRoom}`);
      check(c.exitDoorIds.length === 1, `${tag} exit fire door`);
      check(c.entryDoorIds.length === 1, `${tag} entry door`);
      for (const id of [...c.exitDoorIds, ...c.entryDoorIds]) {
        const e = entityById.get(id);
        check(!!e, `${tag} door ${id} entity`);
        if (!e) continue;
        check(e.attributes.StairwellId === c.stairwellId && e.attributes.RouteSlot === c.slot, `${id} StairwellId / RouteSlot`);
        check(e.attributes.Jammed === (c.stairwellId !== p.picked), `${id} Jammed matches the export pick`);
        check(e.nodes.some((n) => n.path === 'Jam'), `${id} has the Jam leaf`);
        check(e.prompts.some((pr) => pr.name === 'Locked' && pr.holdDuration === 0), `${id} Jammed prompt`);
      }
      check(triggerIds.has(c.checkpoint), `${tag} Checkpoint ${c.checkpoint}`);
      check(c.spawns.length >= 4 && c.spawns.every((id) => anchorById.has(id) && anchorById.get(id).room === c.toRoom), `${tag} 4+ arrival spawns`);
      if (lockLevels.has(c.from)) check(!!c.exitLock && entityById.has(c.exitLock) && c.exitDoorIds.includes(entityById.get(c.exitLock).attributes.DoorId), `${tag} ExitLock on its fire door`);
      else check(!c.exitLock, `${tag}: no ExitLock (${c.from} has no lock step)`);
      if (c.to === roof) check(!!c.creatureSpawn && anchorById.has(c.creatureSpawn), `${tag} housing has the Creature's spot`);
      const verdicts = Object.values((rule.checks || {})[p.from] || {}).map((list2) => list2.find((v) => v.stairwellId === c.stairwellId));
      check(verdicts.length >= 1 && verdicts.every((v) => v && v.distance > 0), `${tag} reachable from every way in`);
      check(verdicts.some((v) => v && v.fair), `${tag} fair from some way in`);
    }
  }
  // Nightmare's trap count is served by trap entities
  const traps = meta.entities.filter((e) => e.type === 'BearTrap');
  check(traps.length >= 16, `${traps.length} bear trap entities (want >= 16)`);
  console.log(`  ok   routes ${pairs.length} pairs, ${Object.values(routes).flat().length} candidates, ${traps.length} traps`);
}
// tunnel floors, decor (Detail) and the potentially visible sets
{
  const rooms = new Map(meta.rooms.map((r) => [r.id, r]));
  // visibility: every zone of every layout level lists itself, its neighbours through openings, ids of its own level,
  // symmetric
  const vis = meta.visibility || {};
  const layoutLevels = Object.keys(meta.layouts || {});
  let listed = 0;
  for (const level of layoutLevels) {
    const sets = vis[level];
    check(!!sets && typeof sets === 'object', `visibility for ${level}`);
    if (!sets) continue;
    for (const z of meta.rooms.filter((r) => r.level === level)) {
      const list = sets[z.id];
      check(Array.isArray(list) && list.includes(z.id), `visibility ${z.id} lists itself`);
      if (!Array.isArray(list)) continue;
      listed += list.length;
      for (const id of list) {
        const other = rooms.get(id);
        check(!!other && other.level === level, `visibility ${z.id} -> ${id} on its own level`);
        check(Array.isArray(sets[id]) && sets[id].includes(z.id), `visibility ${z.id} <-> ${id} both ways`);
      }
    }
    for (const d of meta.layoutDoors.filter((d) => d.level === level && d.kind !== 'Boarded')) {
      const [a, b] = d.rooms;
      if (sets[a] && sets[b]) check(sets[a].includes(b), `visibility: ${a} sees ${b} through ${d.id}`);
    }
  }
  check(meta.visibilityInfo && meta.visibilityInfo.maxDistance > 0, 'visibilityInfo');
  // Detail: decorative static / decal chunks only, levels 1..3, each level present on every tunnel floor; no collider is
  // decor
  const tunnelLevels = Object.keys(meta.regions || {});
  check(tunnelLevels.includes('Level0_Basement'), `tunnel floors: ${tunnelLevels.join(', ')}`);
  const detailChunks = meta.chunks.filter((c) => c.detail !== undefined);
  for (const c of detailChunks) check(c.kind === 'static' && [1, 2, 3].includes(c.detail), `chunk ${c.id} detail ${c.detail}`);
  for (const level of tunnelLevels) for (const lv of [1, 2, 3]) {
    check(detailChunks.some((c) => c.detail === lv && c.level === level), `${level} has Detail ${lv} chunks`);
  }
  for (const e of meta.entities) for (const col of e.colliders) check(!(col.attributes && col.attributes.Detail), `${e.id} collider is no decor`);
  // every tunnel floor's data: teleport points in its tunnels, junction plates, landmarks, 4-6 named regions
  let points = [];
  let plates = [];
  let regions = [];
  for (const level of tunnelLevels) {
    const own = (meta.teleportPoints || {})[level] || [];
    check(own.length >= 100, `${own.length} teleport points on ${level}`);
    for (const p of own) {
      const r = rooms.get(p.zone);
      check(!!r && r.level === level && (r.kind === 'Tunnel' || r.kind === 'Gallery'), `teleport point in a tunnel (${p.zone})`);
      if (r) {
        const inside = p.pos[0] >= r.rect.x - 0.01 && p.pos[0] <= r.rect.x + r.rect.w + 0.01 && p.pos[2] >= r.rect.z - 0.01 && p.pos[2] <= r.rect.z + r.rect.d + 0.01;
        check(inside, `teleport point inside ${p.zone}`);
      }
    }
    const marks = (meta.landmarks || {})[level] || [];
    // a plate on every junction of the planner's graph (TunnelRules), at least 20 on a full-size floor (a crossing rule
    // of 1100 studs or more; the Auditorium's interim crossing is a short one)
    const own2 = marks.filter((m) => m.kind === 'JunctionPlate');
    const tunnels = (meta.layouts[level] && meta.layouts[level].tunnels) || {};
    const junctions = (tunnels.nodes || []).filter((n) => n.kind === 'Junction');
    const full = !!(tunnels.rules && tunnels.rules.crossing && tunnels.rules.crossing[0] >= 1100);
    check(junctions.length > 0 && own2.length === junctions.length && new Set(own2.map((m) => m.text)).size === own2.length,
      `${level}: ${own2.length} junction plates for ${junctions.length} junctions`);
    check(own2.length >= (full ? 20 : 1) && own2.every((m) => /^J-\d\d$/.test(m.text)), `${level}: ${own2.length} junction plates J-NN${full ? ' (a full-size floor: 20 or more)' : ''}`);
    check(marks.every((m) => rooms.has(m.room) && rooms.get(m.room).level === level && m.text), `${level}: landmarks name their room and text`);
    const named = (meta.regions || {})[level] || [];
    check(named.length >= 4 && named.length <= 6 && new Set(named.map((r) => r.name)).size === named.length, `${level}: ${named.length} named regions`);
    points = points.concat(own);
    plates = plates.concat(own2);
    regions = regions.concat(named);
  }
  // doors: head room and crawl-only flags, the zone graph's too
  for (const d of meta.layoutDoors) check(typeof d.clearance === 'number' && d.clearance > 0 && typeof d.crawlOnly === 'boolean', `door ${d.id} clearance / crawlOnly`);
  const crawlDoors = meta.layoutDoors.filter((d) => d.crawlOnly);
  check(crawlDoors.length >= 6 && crawlDoors.every((d) => d.clearance < 9), `${crawlDoors.length} crawl-only mouths, all under 9`);
  const crawlEdges = ((meta.zoneGraph && meta.zoneGraph.edges) || []).filter((e) => e.crawlOnly);
  check(crawlEdges.length === crawlDoors.length, `zone graph: ${crawlEdges.length} crawl-only edges (${crawlDoors.length} mouths)`);
  // hiding spots: barrels and cabinets (most standing free with a side exit), lockers with HideKind
  const hides = meta.entities.filter((e) => e.type === 'Barrel' || e.type === 'Cabinet');
  check(hides.length >= 40, `${hides.length} barrels and cabinets`);
  let side = 0;
  for (const e of hides) {
    check(e.tags.includes('Hideable') && e.attributes.HideKind === e.type, `${e.id} Hideable / HideKind`);
    for (const name of ['EntryAnchor', 'ExitAnchor', 'HideAnchor', 'PeekAnchor']) check(!!e.attachments[name], `${e.id} ${name}`);
    check(e.prompts.some((p) => p.name === 'Hide'), `${e.id} Hide prompt`);
    const exit = e.attachments.ExitAnchor;
    if (exit) {
      const pv = e.pivot;
      const d = [exit[0] - pv[0], exit[2] - pv[2]];
      const right = [pv[3], pv[9]];
      const look = [-pv[5], -pv[11]];
      if (Math.abs(d[0] * right[0] + d[1] * right[1]) > Math.abs(d[0] * look[0] + d[1] * look[1])) side++;
    }
  }
  check(side >= 0.6 * hides.length, `${side} of ${hides.length} hiding spots step out to a side`);
  const lockers = meta.entities.filter((e) => e.type === 'Locker');
  check(lockers.length > 0 && lockers.every((e) => e.attributes.HideKind === 'Locker'), 'lockers carry HideKind Locker');
  console.log(`  ok   tunnels (${tunnelLevels.length} floors): ${points.length} teleport points, ${plates.length} plates, ${regions.length} regions, ${hides.length} barrels / cabinets (${side} side exits); ${detailChunks.length} Detail chunks; visibility ${listed} entries`);
}
// collision
for (const [level, c] of Object.entries(world.collision)) {
  let max = 0;
  for (let i = 0; i < c.index.length; i++) if (c.index[i] > max) max = c.index[i];
  check(max < c.position.length / 3, `collision ${level} indices in range`);
  check(c.index.length % 3 === 0 && c.position.every(Number.isFinite), `collision ${level} well formed`);
}
// probes
for (const [level, g] of Object.entries(world.probes)) {
  check(g.data.length === g.dims[0] * g.dims[1] * g.dims[2] * 3, `probes ${level} size`);
  const s = sampleProbe(g, g.origin[0] + g.spacing * 1.5, g.origin[1] + g.spacing * 0.5, g.origin[2] + g.spacing * 1.5);
  check(s.every((v) => Number.isFinite(v) && v >= 0), `probes ${level} sample`);
  for (const gr of g.groups) {
    check(gr.data.length === g.data.length, `probes ${level} group ${gr.group} size`);
    check(meta.flickerGroups[gr.group] && meta.flickerGroups[gr.group].kind === 'scripted', `probes ${level} group ${gr.group} is scripted`);
  }
}
console.log(`  ok   entities ${meta.entities.length}, collision ${Object.keys(world.collision).length}, probes ${Object.keys(world.probes).length}, groups ${groups}`);

// ------------------------------------------------------------------------------------------------------------
console.log('== flicker groups');
{
  const fg = meta.flickerGroups;
  const before = failures;
  // the namespace: ids are world-wide (every level draws on the same 16-bit range), dense, named once
  check(fg.length > 0 && fg[0].id === 0 && fg[0].kind === 'steady' && !fg[0].name && !fg[0].family, 'group 0 is the steady one');
  check(fg.every((g, i) => g.id === i), 'group ids are their index');
  check(fg.length - 1 <= FLICKER_GROUP_LIMIT, `${fg.length - 1} groups within the ${FLICKER_GROUP_LIMIT} ids a vertex holds`);
  const shared = createSharedUniforms(fg.length);
  const img = shared.uFlickerTex.value.image;
  check(shared.uFlickerData.length >= fg.length && img.width * img.height === shared.uFlickerData.length,
    `the flicker texture (${img.width} x ${img.height}) holds every group`);
  const names = new Set();
  for (const g of fg.slice(1)) {
    check(!!g.name && !names.has(g.name), `group ${g.id} named once (${g.name})`);
    names.add(g.name);
  }
  const perLevel = {};
  for (const g of fg.slice(1)) perLevel[g.level || '-'] = (perLevel[g.level || '-'] || 0) + 1;

  // every light's group resolves: the group lists it, sits on its level and is its FlickerGroup (or the scripted
  // owner that takes it over); a baked light with a FlickerGroup never loses it
  let resolved = 0;
  meta.lights.forEach((l, li) => {
    if (l.group > 0) {
      const g = fg[l.group];
      check(!!g && g.lights.includes(li), `light ${l.id}: group ${l.group} exists and lists it`);
      if (!g) return;
      check(!l.level || g.level === l.level, `light ${l.id} (${l.level}): group ${g.name} on its level (${g.level})`);
      check(!l.flickerGroup || g.name === l.flickerGroup || g.name.startsWith('Scripted:'),
        `light ${l.id}: group ${g.name} is its FlickerGroup ${l.flickerGroup}`);
      resolved++;
    } else {
      check(l.group === 0, `light ${l.id}: group ${l.group}`);
      check(!(l.baked && l.flickerGroup), `light ${l.id}: baked without its FlickerGroup ${l.flickerGroup}`);
    }
  });
  for (const g of fg) for (const li of g.lights) check(meta.lights[li] && meta.lights[li].group === g.id, `group ${g.id} light ${li} points back`);

  // power families: the pooling rule the bake's workers run (bake/light.mjs dominantGroup) on a synthetic point.
  // Groups 1, 2: one floor's Mains / Circuit (family 1); 3: another floor's Mains (family 2); 4: a lone flicker group.
  {
    const kinds = ['steady', 'scripted', 'flicker', 'scripted', 'flicker'];
    const family = [0, 1, 1, 2, 3];
    const members = [[], [1, 2], [3], [4]];
    const out = [0, 0];
    const is = (acc, total, group, share, what) => {
      dominantGroup(acc, total, kinds, family, members, out);
      check(out[0] === group && Math.abs(out[1] - share) < 1e-9, `pooling: ${what} (got group ${out[0]} share ${out[1]})`);
    };
    is([0, 0.4, 0.4, 0, 0], 1, 1, 0.8, "a point between two circuits of a floor carries both circuits' light");
    is([0, 0.2, 0.5, 0, 0], 1, 2, 0.7, 'the brighter circuit leads and pools the steady one');
    is([0, 0.5, 0, 0.3, 0], 1, 1, 0.5, "another floor's circuits stay out of the pool");
    is([0, 0, 0.2, 0, 0.6], 1, 4, 0.6, 'a group outside the families keeps its own share');
    is([0, 0.7, 0.6, 0, 0], 1, 1, 1, 'a pooled share is at most 1');
    is([0, 0, 0, 0, 0], 0, 0, 0, 'an unlit point carries no group');
  }
  // ... the family each group belongs to in world.json, the lights on the family's floor, one probe grid per family
  const families = new Map();
  for (const g of fg.slice(1)) {
    const want = POWER_CIRCUIT.test(g.name || '') ? g.level : null;
    check((g.family ?? null) === want, `group ${g.name}: family ${g.family} (expected ${want})`);
    if (g.family) (families.get(g.family) || families.set(g.family, []).get(g.family)).push(g.id);
  }
  for (const [level, members] of families) {
    for (const id of members) for (const li of fg[id].lights) check(meta.lights[li].level === level, `power group ${fg[id].name}: light ${meta.lights[li].id} on ${level}`);
    const rep = members.find((id) => fg[id].kind === 'scripted') ?? members[0];
    for (const [plevel, p] of Object.entries(meta.probes)) {
      const grids = p.groups.filter((gr) => fg[gr.group] && fg[gr.group].family === level);
      check(grids.length <= 1 && grids.every((gr) => gr.group === rep), `probes ${plevel}: the ${level} power family in one grid (group ${rep})`);
      if (plevel === level) check(grids.length === 1, `probes ${level}: its power family's grid`);
    }
  }
  if (failures === before) {
    const counts = Object.entries(perLevel).map(([k, v]) => `${k} ${v}`).join(', ');
    const fams = [...families].map(([k, v]) => `${k} ${v.length}`).join(', ');
    console.log(`  ok   ${fg.length - 1} groups (${counts}); ${resolved} lights resolve; power families: ${fams || 'none'}`);
  }
}

// ------------------------------------------------------------------------------------------------------------
console.log('== run plan (the web replays RunDirector)');
{
  const before = failures;
  // the generator: golden values (tests/Specs/Rng.spec.luau has the same ones)
  const raw = (rng, n) => Array.from({ length: n }, () => rng.integer(0, 4294967295));
  const same = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);
  const golden = [
    ['new(0)', raw(new Rng(0), 8), [3809008728, 1133695204, 53579671, 2891528803, 139681546, 2203266335, 104831812, 1587294886]],
    ['new(1)', raw(new Rng(1), 8), [2442144158, 3238099751, 3819917871, 2104621829, 2021136066, 4223536128, 1515984730, 2298887649]],
    ['new(2^32 - 1)', raw(new Rng(4294967295), 8), [835879718, 1921286648, 2356205009, 1885780724, 980451116, 1053911718, 3677392737, 2464361898]],
    ['seeded(20251029, Objective|Level0_Basement)', raw(Rng.seeded(20251029, 'Objective|Level0_Basement'), 8),
      [2975473077, 76520769, 278978910, 4012111892, 1972213258, 2943740582, 3088457692, 2273335167]],
    ['new(-1) is new(2^32 - 1)', raw(new Rng(-1), 4), raw(new Rng(4294967295), 4)],
  ];
  for (const [label, got, want] of golden) check(same(got, want), `Rng ${label}: ${got.join(' ')}`);
  check(fnv('Objective|Level0_Basement') === 21198310, 'MathUtil.hash (FNV-1a)');
  check(fnv('é') === Math.imul(Math.imul(0x811c9dc5 ^ 0xc3, 0x01000193) ^ 0xa9, 0x01000193) >>> 0, 'hash takes UTF-8 bytes, as Luau');
  let r = new Rng(12345);
  check(same(Array.from({ length: 6 }, () => r.number()), [0.12076167785562575, 0.10254896758124232, 0.98554719984531403,
    0.87494440888985991, 0.91712428559549153, 0.31075522652827203]), 'Rng number(): one draw / 2^32, exactly');
  r = new Rng(12345);
  check(same(Array.from({ length: 4 }, () => r.number(-3, 5)), [-2.033906577154994, -2.1796082593500614, 4.8843775987625122,
    3.9995552711188793]), 'Rng number(-3, 5)');
  r = new Rng(42);
  check(same(Array.from({ length: 12 }, () => r.integer(1, 6)), [1, 2, 3, 1, 1, 1, 5, 5, 1, 3, 4, 5]), 'Rng integer(1, 6)');
  r = new Rng(42);
  check(same(Array.from({ length: 12 }, () => r.integer(0, 3221225471)), [2837322924, 544945897, 479756282, 339756180,
    113173290, 65323186, 1112262688, 1395801302, 787581093, 2038421698, 2132581468, 3088945547]), 'Rng integer: redraws past the last whole range');
  r = new Rng(99);
  check(same(Array.from({ length: 10 }, () => r.integer(-5, 5)), [2, 0, 3, -5, 5, -2, 0, -2, -1, -4]), 'Rng integer(-5, 5)');
  r = new Rng(2026);
  check(same(Array.from({ length: 4 }, () => r.integer(1, 2000000000)), [1436751615, 742089594, 1736781945, 1312845264]), 'Rng integer(1, 2e9)');
  check(same(shuffle([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], new Rng(7)), [4, 10, 7, 6, 5, 8, 3, 2, 9, 1]), 'shuffle (Rng.shuffle)');
  let refused = 0;
  for (const bad of [() => r.integer(1, 2.5), () => r.integer(3, 2), () => r.integer(0, 4294967296), () => new Rng(NaN)]) {
    try {
      bad();
    } catch {
      refused++;
    }
  }
  check(refused === 4, 'Rng refuses bad bounds and seeds');

  // the plans: worldData's port against RunDirector's own, seed for seed
  const plansFile = path.join(buildDir, 'cache', 'run-plans.json');
  check(fs.existsSync(plansFile), `RunDirector's plans exported (${plansFile})`);
  let replayed = 0;
  const school = (meta.worldConfig && meta.worldConfig.LevelOrder) || [];
  const unported = school.filter((level) => !WebLevelOrder.includes(level));
  const ported = (level) => !unported.includes(level);
  if (fs.existsSync(plansFile)) {
    const plans = JSON.parse(fs.readFileSync(plansFile, 'utf8'));
    // RunDirector plans picks only on a floor with an item; the web's port (worldData.pickObjective) still expects an
    // item on every floor it is given, so it replays the floors that have one (the itemless Auditorium crossing has no
    // picks to replay; WP02 teaches the port such floors)
    const floors = (meta.objectives && meta.objectives.floors) || [];
    const itemless = new Set(floors.filter((f) => !f.item).map((f) => f.levelId));
    const wd = new WorldData({ ...meta, objectives: { ...meta.objectives, floors: floors.filter((f) => f.item) } });
    // the port walks the web's own level list (src/game/config.js LevelOrder) for batteries, grates and routes: a school
    // level the web does not list yet is not replayed (reported below), and every other level is replayed in full, so
    // the check is whole again the moment the web lists the four-level school (WP02)
    const sorted = (a) => [...a].sort();
    // (Lune's JSON writes an empty Luau table as {})
    const arr = (x) => (Array.isArray(x) ? x : []);
    for (const want of plans) {
      const tag = `seed ${want.seed} ${want.difficulty}`;
      const got = wd.plan(want.difficulty, want.seed);
      const planned = Object.keys(want.objectives || {});
      check(planned.length === floors.length - itemless.size && planned.every((level) => !itemless.has(level)),
        `${tag}: RunDirector picks on the floors with an item (${planned.join(', ')})`);
      for (const [level, picks] of Object.entries(want.objectives || {})) {
        const mine = got.objectives[level];
        const anchors = arr(picks.anchors);
        const guards = arr(picks.guards);
        check(!!mine && same(mine.anchors, anchors), `${tag} ${level} objective picks ${mine ? mine.anchors.join(',') : '-'} (RunDirector: ${anchors.join(',')})`);
        check(!!mine && same(mine.guards, guards), `${tag} ${level} guard traps ${mine ? mine.guards.join(',') : '-'} (RunDirector: ${guards.join(',')})`);
      }
      const props = sorted(arr(want.props).filter((p) => ['BearTrap', 'ChemicalFlask', 'Battery'].includes(p.kind) && ported(p.levelId)).map((p) => p.anchorId));
      check(same(sorted(got.props), props), `${tag} trap / flask / battery anchors (${got.props.size} vs ${props.length})`);
      // every prop as RunDirector plans it: its anchor's own variant, and no objective item with a slot (no floor has
      // kinds), so the entity the export built on that anchor is the run's prop
      for (const p of arr(want.props)) {
        check(variantOf(p.kind, p.levelId, p.anchorId) === p.variant, `${tag} ${p.anchorId}: variantOf ${variantOf(p.kind, p.levelId, p.anchorId)} (RunDirector: ${p.variant})`);
        const picks = got.objectives[p.levelId];
        if (picks && picks.anchors.includes(p.anchorId)) check(picks.slots[p.anchorId] === undefined, `${tag} ${p.anchorId} has no slot`);
      }
      check(got.placements.size === 0, `${tag} every chosen anchor has its own entity`);
      const locked = sorted(arr(want.lockedGrates));
      check(same(sorted(got.lockedGrates), locked), `${tag} locked grates ${sorted(got.lockedGrates).join(',')} (RunDirector: ${locked.join(',')})`);
      const routes = wd.routes(want.seed);
      for (const [from, id] of Object.entries(want.route || {})) {
        if (!ported(from)) continue;
        check(routes[from] && routes[from].stairwellId === id, `${tag} ${from} leaves by ${routes[from] ? routes[from].stairwellId : '-'} (RunDirector: ${id})`);
      }
      replayed++;
    }
  }
  if (failures === before) console.log(`  ok   Rng golden values; ${replayed} RunDirector plans replayed pick for pick`);
  if (unported.length) console.log(`  skip props and routes of ${unported.join(', ')}: not in the web's LevelOrder yet (src/game/config.js, WP02)`);
}

// the shared rules: the configs in meta, the golden rows, the run plan's spec v2 picks, the CreatureBlocks
console.log('== shared rules (configs, goldens, picks)');
{
  const before = failures;
  const listed = Array.isArray(meta.exportedConfigs) ? meta.exportedConfigs : [];
  const NEEDED = ['stageConfig', 'worldConfig', 'objectiveConfig', 'difficultyConfig', 'gameConfig', 'noiseConfig',
    'inputConfig', 'settingsSchema', 'tutorialConfig', 'livesConfig', 'radarConfig', 'parkourConfig'];
  for (const key of NEEDED) check(listed.includes(key), `meta.exportedConfigs lists ${key}`);
  for (const key of listed) {
    check(meta[key] && typeof meta[key] === 'object', `meta.${key} is the exported config`);
  }
  const stages = (meta.stageConfig && meta.stageConfig.order) || [];
  check(stages.length === 9 && stages[0].id === 'BackLot' && stages[8].id === 'Bahamas', `meta.stageConfig: ${stages.length} stages`);
  for (const d of ['Standard', 'Nightmare']) {
    check(meta.livesConfig && meta.livesConfig[d] && meta.radarConfig && meta.radarConfig[d], `lives and radar numbers for ${d}`);
  }
  check(meta.parkourConfig && meta.parkourConfig.Leap && meta.parkourConfig.Leap.Gap === 12, 'meta.parkourConfig: the leap gap is 12');

  // the golden rows (written by the export; the website's ports of LivesRules, RadarRules and ParkourRules replay them)
  const goldenRules = path.join(buildDir, 'cache', 'golden.json');
  let modules = {};
  try {
    modules = JSON.parse(fs.readFileSync(goldenRules, 'utf8'));
  } catch (err) {
    fail(`golden rows at ${goldenRules}: ${err.message}`);
  }
  const names = Object.keys(modules).sort();
  for (const module of ['LivesRules', 'RadarRules', 'ParkourRules']) check(names.includes(module), `golden.json has ${module}`);
  let rows = 0;
  for (const module of names) {
    const list = modules[module];
    check(Array.isArray(list) && list.length > 0, `${module} has golden rows`);
    if (!Array.isArray(list)) continue;
    const seen = new Set();
    const perFn = new Map();
    for (const row of list) {
      rows++;
      check(typeof row.name === 'string' && !seen.has(row.name), `${module}: row ${row.name} is named once`);
      seen.add(row.name);
      check(typeof row.fn === 'string' && Array.isArray(row.args) && row.expect !== undefined, `${module} / ${row.name}: fn, args, expect`);
      perFn.set(row.fn, (perFn.get(row.fn) || 0) + 1);
    }
    for (const [fn, n] of perFn) check(n >= 12, `${module}.${fn}: ${n} golden rows (at least 12)`);
  }

  // the run plan's spec v2 picks: radar batteries per sneaking stage, stun flasks per stage
  const anchorsByLevel = new Map();
  for (const a of meta.anchors || []) {
    if (!anchorsByLevel.has(a.level)) anchorsByLevel.set(a.level, new Map());
    anchorsByLevel.get(a.level).set(a.id, a);
  }
  const radar = meta.radarConfig || {};
  const flaskCounts = (meta.difficultyConfig || {});
  const sneaking = new Set((meta.stageConfig && meta.stageConfig.sneaking) || []);
  const levels = (meta.worldConfig && meta.worldConfig.LevelOrder) || [];
  const plansFile = path.join(buildDir, 'cache', 'run-plans.json');
  const plans = fs.existsSync(plansFile) ? JSON.parse(fs.readFileSync(plansFile, 'utf8')) : [];
  // an empty Luau table travels as {} (JSON cannot tell it from an empty list)
  const list = (v) => (Array.isArray(v) ? v : v && typeof v === 'object' && Object.keys(v).length === 0 ? [] : null);
  const checkPicks = (tag, difficulty, batteries, flasks) => {
    for (const level of levels) {
      const of = (kind) => [...(anchorsByLevel.get(level) || new Map()).values()].filter((a) => a.kind === kind).length;
      if (sneaking.has(level)) {
        const picks = batteries && batteries[level];
        const anchors = picks ? list(picks.anchors) : null;
        const want = Math.min((radar[difficulty] || {}).BatteriesMax, of('BatteryCandidate'));
        check(anchors && anchors.length === want, `${tag} ${level}: ${anchors ? anchors.length : 0} batteries picked (want ${want})`);
        for (const id of anchors || []) {
          const a = (anchorsByLevel.get(level) || new Map()).get(id);
          check(a && a.kind === 'BatteryCandidate', `${tag} ${level}: battery ${id} is a BatteryCandidate`);
        }
      } else {
        check(!(batteries && batteries[level]), `${tag} ${level}: no radar batteries (not a sneaking stage)`);
      }
      const count = ((flaskCounts[difficulty] || {}).flasksPerStage || {})[level] || 0;
      const got = list((flasks && flasks[level]) || []);
      check(got !== null, `${tag} ${level}: the flasks are a list`);
      if (got === null) continue;
      check(got.length === Math.min(count, of('FlaskCandidate')), `${tag} ${level}: ${got.length} flasks picked of ${count}`);
      for (const id of got) {
        const a = (anchorsByLevel.get(level) || new Map()).get(id);
        check(a && a.kind === 'FlaskCandidate', `${tag} ${level}: flask ${id} is a FlaskCandidate`);
      }
    }
  };
  checkPicks('export plan', meta.plan && meta.plan.difficulty, meta.plan && meta.plan.batteries, meta.plan && meta.plan.flasks);
  for (const plan of plans) checkPicks(`seed ${plan.seed} ${plan.difficulty}`, plan.difficulty, plan.batteries, plan.flasks);

  // the CreatureBlocks: boxes on a level (none until a floor has a Gap)
  const blocks = list(meta.creatureBlocks);
  check(blocks !== null, 'meta.creatureBlocks is a list');
  for (const b of blocks || []) {
    check(typeof b.level === 'string' && Array.isArray(b.cframe) && b.cframe.length === 12 && Array.isArray(b.size), `CreatureBlock ${b.door}: a box on ${b.level}`);
  }
  if (failures === before) {
    console.log(`  ok   ${listed.length} configs in meta (${listed.join(', ')}); ${rows} golden rows of ${names.length} modules; plan picks of ${plans.length + 1} plans; ${(blocks || []).length} CreatureBlocks`);
  }
}

console.log(failures ? `FAILED: ${failures} of ${checks} checks` : `PASSED: ${checks} checks`);
process.exit(failures ? 1 : 0);
