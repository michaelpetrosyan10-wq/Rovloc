// Potentially visible sets (meta.visibility): per layout level, for every zone (a layout room; a tunnel floor's Solid
// fill is no zone) the zones a player standing in it may see. Computed offline: rays between sample points of two
// zones against the static structure (colliding, opaque, non-glass, non-decorative static parts: walls, floors,
// ceilings, solid furniture). Doors and every other entity count as open, glass as clear, so the set is conservative.
//
// Samples per zone: points across each of its openings (both heights a player's eye can pass them: crouched and
// standing), stepped just inside the zone, plus a grid over its floor at eye height. A zone sees another when any
// ray between their samples is clear, and always sees itself and every zone it shares an opening with. Pairs whose
// rects lie more than MAX_DISTANCE apart are never tested (left out).

import { Tracer, buildTracer } from './trace.mjs';
import { coarseTriangles } from './mesh.mjs';

export const MAX_DISTANCE = 300; // studs between two zones' rects past which nothing is tested
const GRID = 6; // interior samples every this many studs
const OPENING_STEP = 0.75;
const INSET = 0.35; // opening samples stand this far into their zone from the wall line
const MAX_SAMPLES = 40; // per zone (evenly thinned past it)
const EYE = 4.6;
const LOW = 1.4;
const EPS = 1e-3;

const arr = (v) => (Array.isArray(v) ? v : []);

/** The shared edge of two rects: { axis: 'X' (a line of constant x) | 'Z', coord, lo, hi } or null. */
function sharedEdge(a, b) {
  const zLo = Math.max(a.z, b.z);
  const zHi = Math.min(a.z + a.d, b.z + b.d);
  const xLo = Math.max(a.x, b.x);
  const xHi = Math.min(a.x + a.w, b.x + b.w);
  if (zHi - zLo > EPS) {
    if (Math.abs(a.x + a.w - b.x) < EPS) return { axis: 'X', coord: b.x, lo: zLo, hi: zHi };
    if (Math.abs(b.x + b.w - a.x) < EPS) return { axis: 'X', coord: a.x, lo: zLo, hi: zHi };
  }
  if (xHi - xLo > EPS) {
    if (Math.abs(a.z + a.d - b.z) < EPS) return { axis: 'Z', coord: b.z, lo: xLo, hi: xHi };
    if (Math.abs(b.z + b.d - a.z) < EPS) return { axis: 'Z', coord: a.z, lo: xLo, hi: xHi };
  }
  return null;
}

function rectGap(a, b) {
  const dx = Math.max(0, Math.max(a.x, b.x) - Math.min(a.x + a.w, b.x + b.w));
  const dz = Math.max(0, Math.max(a.z, b.z) - Math.min(a.z + a.d, b.z + b.d));
  return Math.hypot(dx, dz);
}

function thin(points, max) {
  if (points.length / 3 <= max) return points;
  const n = points.length / 3;
  const out = [];
  for (let k = 0; k < max; k++) {
    const i = Math.floor((k * n) / max);
    out.push(points[i * 3], points[i * 3 + 1], points[i * 3 + 2]);
  }
  return out;
}

/**
 * @param {any} raw world-raw.json
 * @param {any[]} parts the exported parts (raw.parts)
 * @param {{ doorWidth?: number, airlockDoorWidth?: number, doorHeight?: number, log?: (s: string) => void }} [options]
 * @returns {{ visibility: Record<string, Record<string, string[]>>, stats: Record<string, any> }}
 */
export function computeVisibility(raw, parts, options = {}) {
  const log = options.log || (() => {});
  const doorWidth = options.doorWidth ?? 6;
  const airlockDoorWidth = options.airlockDoorWidth ?? 8;
  const doorHeight = options.doorHeight ?? 10;
  // the occluders
  const tris = [];
  for (const p of parts) {
    if (p.entity || p.creature || !p.canCollide) continue;
    if (p.transparency > 0.3 || p.material === 'Glass') continue;
    if (p.attributes && p.attributes.Detail) continue;
    coarseTriangles(p, tris);
  }
  const tracer = new Tracer(buildTracer(new Float32Array(tris)));
  const visibility = {};
  const stats = {};
  for (const levelId of arr(raw.layoutIds)) {
    const layout = raw.layouts[levelId];
    const level = raw.levels[levelId];
    if (!layout || !level) continue;
    const origin = level.origin;
    const zones = [];
    const byId = new Map();
    for (const room of arr(layout.rooms)) {
      if (room.kind === 'Solid') continue;
      const r = room.rect;
      const zone = {
        id: room.id,
        rect: { x: origin[0] + r.x, z: origin[2] + r.z, w: r.w, d: r.d },
        floor: origin[1] + (room.floorY || 0),
        height: room.height ?? layout.height ?? 12,
        points: [],
        sees: new Set([room.id]),
      };
      zones.push(zone);
      byId.set(room.id, zone);
    }
    // samples across every opening, a step inside each side; neighbours through an opening see each other
    for (const door of arr(layout.doors)) {
      const [a, b] = arr(door.rooms).map((id) => byId.get(id));
      if (!a || !b) continue;
      const edge = sharedEdge(a.rect, b.rect);
      if (!edge) continue;
      if (door.kind !== 'Boarded') {
        a.sees.add(b.id);
        b.sees.add(a.id);
      }
      const width = door.width ?? (door.kind === 'Airlock' ? airlockDoorWidth : doorWidth);
      const centre = (edge.axis === 'X' ? origin[2] : origin[0]) + door.at;
      const lo = Math.max(edge.lo, centre - width / 2 + 0.3);
      const hi = Math.min(edge.hi, centre + width / 2 - 0.3);
      if (hi < lo) continue;
      const top = Math.min(door.height ?? doorHeight, a.height - 0.5, b.height - 0.5);
      const floor = Math.max(a.floor, b.floor);
      const heights = [Math.min(LOW, top * 0.5), Math.min(EYE, top - 0.4)];
      const count = Math.max(2, Math.ceil((hi - lo) / OPENING_STEP) + 1);
      for (const zone of [a, b]) {
        const r = zone.rect;
        const into = edge.axis === 'X' ? (r.x + r.w / 2 > edge.coord ? 1 : -1) : r.z + r.d / 2 > edge.coord ? 1 : -1;
        for (let k = 0; k < count; k++) {
          const u = lo + ((hi - lo) * k) / (count - 1);
          for (const h of heights) {
            if (edge.axis === 'X') zone.points.push(edge.coord + into * INSET, floor + h, u);
            else zone.points.push(u, floor + h, edge.coord + into * INSET);
          }
        }
      }
    }
    // a grid over each floor at eye height (crawlways: a crawler's)
    for (const zone of zones) {
      const r = zone.rect;
      const eye = Math.min(EYE, Math.max(0.8, zone.height - 0.6));
      const nx = Math.max(1, Math.round((r.w - 2) / GRID));
      const nz = Math.max(1, Math.round((r.d - 2) / GRID));
      for (let i = 0; i < nx; i++) {
        for (let j = 0; j < nz; j++) {
          const x = r.x + 1 + ((r.w - 2) * (i + 0.5)) / nx;
          const z = r.z + 1 + ((r.d - 2) * (j + 0.5)) / nz;
          zone.points.push(x, zone.floor + eye, z);
        }
      }
      zone.points = Float64Array.from(thin(zone.points, MAX_SAMPLES));
    }
    // rays between the rest
    let rays = 0;
    let pairs = 0;
    const before = tracer.rays;
    for (let i = 0; i < zones.length; i++) {
      const a = zones[i];
      for (let j = i + 1; j < zones.length; j++) {
        const b = zones[j];
        if (a.sees.has(b.id) || rectGap(a.rect, b.rect) > MAX_DISTANCE) continue;
        pairs++;
        const pa = a.points;
        const pb = b.points;
        let clear = false;
        for (let s = 0; s < pa.length && !clear; s += 3) {
          for (let t = 0; t < pb.length; t += 3) {
            const dx = pb[t] - pa[s];
            const dy = pb[t + 1] - pa[s + 1];
            const dz = pb[t + 2] - pa[s + 2];
            if (!tracer.occluded(pa[s], pa[s + 1], pa[s + 2], dx, dy, dz, 1)) {
              clear = true;
              break;
            }
          }
        }
        if (clear) {
          a.sees.add(b.id);
          b.sees.add(a.id);
        }
      }
    }
    rays = tracer.rays - before;
    const out = {};
    let total = 0;
    for (const zone of zones) {
      out[zone.id] = [...zone.sees].sort();
      total += zone.sees.size;
    }
    visibility[levelId] = out;
    stats[levelId] = { zones: zones.length, pairsTested: pairs, rays, meanVisible: zones.length ? total / zones.length : 0 };
    log(`pvs ${levelId}: ${zones.length} zones, ${pairs} pairs tested, ${(rays / 1e6).toFixed(2)}M rays, ${(total / Math.max(1, zones.length)).toFixed(1)} visible per zone`);
  }
  return { visibility, stats };
}
