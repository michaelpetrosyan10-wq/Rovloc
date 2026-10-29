// Monster collision: the Creature's collision group (Monster) collides with Default parts only. Desks, lab benches,
// lockers, door trims and the other MonsterPassthrough parts let it through, as in Roblox (CollisionGroups).
//
// world.bin's collision buffer holds every colliding static part of a level without its group, so
// tools/creature-collision.mjs (from the export, build/cache/world-raw.json) lists the collision vertices that only
// MonsterPassthrough parts use, as runs (passthroughData.js). A triangle whose three vertices are all such vertices
// belongs to a MonsterPassthrough part; every other triangle is kept. That test does not depend on triangle order,
// so it still holds after a BVH build has reordered the index buffer in place. A Default triangle is never dropped:
// its own vertices are used by a Default part. The table is checked against the decoded level (vertex and index
// counts and a fingerprint of the positions); when it does not match a rebuilt world, monsterIndex returns null and
// the Creature collides with the level's whole collision instead.

import { PASSTHROUGH } from './passthroughData.js';

/**
 * Order-sensitive hash of a level's decoded collision positions (FNV-1a over 1/16-stud rounded coordinates).
 * @param {Float32Array} position
 * @returns {number}
 */
export function fingerprint(position) {
  let h = 2166136261;
  for (let i = 0; i < position.length; i++) {
    h ^= Math.round(position[i] * 16) | 0;
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

/**
 * Vertex flags (1: used by MonsterPassthrough parts only) from runs [gap, length, gap, length, ...].
 * @param {number[]} runs
 * @param {number} vertexCount
 * @returns {Uint8Array}
 */
export function vertexFlags(runs, vertexCount) {
  const flags = new Uint8Array(vertexCount);
  let at = 0;
  for (let i = 0; i + 1 < runs.length; i += 2) {
    at += runs[i];
    const end = Math.min(vertexCount, at + runs[i + 1]);
    if (at < end) flags.fill(1, at, end);
    at += runs[i + 1];
  }
  return flags;
}

/**
 * The index buffer of a level's Monster-group triangles, or null when the passthrough table does not describe this
 * decoded collision (the Creature then collides with all of it).
 * @param {string} level collision level key
 * @param {{vertexCount: number, indexCount: number}|undefined} table world.json collision[level]
 * @param {{position: Float32Array, index: Uint32Array}|undefined} decoded the decoded collision of the level
 * @param {{levels: Record<string, {vertexCount: number, indexCount: number, fingerprint: number, runs: number[]}>}} [data]
 * @returns {Uint32Array|null}
 */
export function monsterIndex(level, table, decoded, data = PASSTHROUGH) {
  const entry = data && data.levels ? data.levels[level] : undefined;
  if (!entry || !table || !decoded || !decoded.position || !decoded.index) return null;
  if (entry.vertexCount !== table.vertexCount || entry.indexCount !== table.indexCount) return null;
  if (decoded.position.length !== entry.vertexCount * 3 || decoded.index.length !== entry.indexCount) return null;
  if (fingerprint(decoded.position) !== entry.fingerprint) return null;
  const flags = vertexFlags(entry.runs, entry.vertexCount);
  const index = decoded.index;
  const out = new Uint32Array(index.length);
  let n = 0;
  for (let t = 0; t + 2 < index.length; t += 3) {
    const a = index[t];
    const b = index[t + 1];
    const c = index[t + 2];
    if (flags[a] === 1 && flags[b] === 1 && flags[c] === 1) continue;
    out[n++] = a;
    out[n++] = b;
    out[n++] = c;
  }
  return out.slice(0, n);
}
