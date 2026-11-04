// Round-trip test of the world data format: `node web/tools/data-test.mjs [buildDir]` (default web/build).
//
// 1. The codec on synthetic data: delta / triangle-delta coding at every element width, the sqrt light encoding.
// 2. The baked world: decodeWorld(world.json, world.bin) against the bake's own pre-encoding samples
//    (build/cache/golden.json): positions within half a quantisation step, UVs within half a UV step, colours, light
//    bytes, flicker pairs and indices exact. Then structural checks over everything: indices in range, positions
//    inside their chunk's bounds, unit normals, flicker groups that exist, entity ranges that tile their chunks,
//    creature bone indices, collision and probe tables, every texture and material the chunks name.
// 3. Flicker groups: world-wide 16-bit ids within the namespace and the engine's flicker texture, every light's group
//    resolving (its FlickerGroup, its level), and each tunnel floor's power circuits (Mains: / Circuit:) pooling as
//    one family: the bake's pooling rule, the family in world.json, one probe grid per family.
// Exits non-zero on the first category with failures (all failures are listed).

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

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
const goldenFile = path.join(buildDir, 'cache', 'golden.json');
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

// floor objectives: every candidate, station and lock is an entity with its prompts, leaves and attachments
{
  const ids = new Set(meta.entities.map((e) => e.id));
  check(new Set(meta.entities.map((e) => `${e.level}/${e.id}`)).size === meta.entities.length, 'entity ids unique per level');
  const byType = (type) => meta.entities.filter((e) => e.type === type);
  // the fewest candidates each floor may offer (a rebuilt floor offers at least as many as the one it replaced); every
  // candidate anchor of the item's kind becomes one entity
  const ITEMS = { Fuse: 14, MasterKeys: 10, ReagentJar: 12, CoachKey: 32, ValveWheel: 8, BoltCutters: 9, AcidFlask: 1 };
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
  check(byType('ValveWheel').every((e) => e.attachments.Hub), 'valve wheels have a Hub');
  const STATIONS = {
    BreakerPanel: ['Door', 'FuseSlot1', 'FuseSlot2', 'FuseSlot3', 'Lever'],
    FumeHood: ['Sash'],
    Generator: ['PullCord'],
    HatchValve: ['Hatch', 'Stem'],
    CrateChain: ['Chain', 'Padlock'],
    StoreLock: ['Padlock'],
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
  const locks = byType('ExitLock');
  check(locks.length === 15, `ExitLock: ${locks.length} entities (want 15: one per exit candidate on floors 0-4)`);
  for (const e of locks) {
    check(['Padlock', 'Chain', 'Keypad'].includes(e.attributes.LockVariant) && e.attributes.Locked === true, `${e.id} variant`);
    check(e.prompts.some((p) => p.name === 'Locked'), `${e.id} Locked prompt`);
    check(ids.has(e.attributes.DoorId), `${e.id} names its door entity`);
  }
  check(byType('StoreDoor').length === 1, 'the equipment store door');
  check(meta.objectives && Object.keys(meta.objectives.levels || {}).length === 6, 'meta.objectives for six floors');
}

// floor objectives: every item candidate is fair, and the export seed's picks keep the multi-item rules
{
  const o = meta.objectives || {};
  const rules = o.rules || {};
  check(rules.entryClearance === 35 && rules.pickSpacing === 25 && rules.pickQuarters === 2, 'objective rules exported');
  const MIN = { Level0_Basement: 12, Level1_Hallways: 9, Level2_ScienceHall: 12, Level3_Gymnasium: 12, Level4_FloodedPool: 6, Level5_Roof: 8 };
  const anchorIds = new Set(meta.anchors.map((a) => a.id));
  const lockerIds = new Set(meta.entities.filter((e) => e.type === 'Locker').map((e) => e.id));
  const [fw, fd] = rules.footprint || [240, 160];
  const quarterOf = (p) => 1 + (p[0] >= fw / 2 ? 1 : 0) + (p[2] >= fd / 2 ? 2 : 0);
  const flat = (a, b) => Math.hypot(a[0] - b[0], a[2] - b[2]);
  for (const floor of o.floors || []) {
    const level = (o.levels || {})[floor.levelId];
    check(!!level, `${floor.levelId} objective data`);
    if (!level) continue;
    const list = level.candidates || [];
    check(list.length >= MIN[floor.levelId], `${floor.levelId}: ${list.length} candidates (want >= ${MIN[floor.levelId]})`);
    check(level.entry && level.entry.room && Array.isArray(level.entry.pos), `${floor.levelId} entry point`);
    for (const c of list) {
      check(c.eligible === true, `${c.anchorId} is a candidate a run may use`);
      check(c.entryDistance >= rules.entryClearance, `${c.anchorId} ${c.entryDistance} studs walked from the entry`);
      const ways = level.entries && level.entries.length ? level.entries : level.entry ? [level.entry] : [];
      if (ways.length) check(c.entryDistance + 0.1 >= Math.min(...ways.map((e) => flat(c.pos, e.pos))), `${c.anchorId} walk >= straight line`);
      check(c.hide && c.hide.distance <= o.hideReach, `${c.anchorId} hiding spot within ${o.hideReach}`);
      check(c.quarter === quarterOf(c.pos), `${c.anchorId} quarter`);
      if (floor.item.guarded) check(c.ref && anchorIds.has(c.ref), `${c.anchorId} guard trap spot ${c.ref}`);
      if (floor.item.candidate === 'CoachKeyCandidate') check(lockerIds.has(c.ref), `${c.anchorId} hangs in locker ${c.ref}`);
    }
    if (floor.item.slots) {
      for (let k = 1; k <= floor.item.slots; k++) check(list.filter((c) => c.slot === k).length >= 4, `${floor.levelId} kind ${k} has 4+ spots`);
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
    if (floor.item.slots) picked.forEach((c, i) => c && check(c.slot === i + 1, `${c.anchorId} is kind ${i + 1}`));
  }
}
// routes: three candidate stairwells per floor pair, each complete (exit fire doors, entry doors, Checkpoint volume,
// arrival spawns, an ExitLock on every exit candidate below the roof), its doors carrying the jam data, every
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
  check(pairs.length === 5, `5 floor pairs (${pairs.length})`);
  check(stairIds.size === 15, `15 stairwells in meta.stairwells (${stairIds.size})`);
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
      if (c.from !== 'Level5_Roof') check(!!c.exitLock && entityById.has(c.exitLock) && c.exitDoorIds.includes(entityById.get(c.exitLock).attributes.DoorId), `${tag} ExitLock on its fire door`);
      if (c.to === 'Level5_Roof') check(!!c.creatureSpawn && anchorById.has(c.creatureSpawn), `${tag} housing has the Creature's spot`);
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
    const own2 = marks.filter((m) => m.kind === 'JunctionPlate');
    check(own2.length >= 20 && own2.every((m) => /^J-\d\d$/.test(m.text)), `${level}: ${own2.length} junction plates J-NN`);
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

console.log(failures ? `FAILED: ${failures} of ${checks} checks` : `PASSED: ${checks} checks`);
process.exit(failures ? 1 : 0);
