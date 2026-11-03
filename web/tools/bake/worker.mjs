// Bake worker: shades batches of points (surface vertices or probe points) with light.mjs over a shared tracer.
//
// init message: { tracer: { positions, index, nodes }, lights, settings, ambient, outdoor, moonDir, moonColor,
//                 groupKinds, groupFamily (family id per group: power circuits pool), probeSlots (groups per slot) }
// job message:  { id, points: Float32Array (xyz), normals: Float32Array (xyz, or empty for probes), seeds: Uint32Array }
// reply:        { id, rgb: Float32Array (3n), group: Uint16Array (n), share: Float32Array (n), ao: Float32Array (n),
//                 sky: Float32Array (n), extra: Float32Array (probes: n x probe slots x 3, taken out of rgb), rays }

import { parentPort } from 'node:worker_threads';
import { Tracer } from './trace.mjs';
import { LightGrid, dominantGroup, shadePoint } from './light.mjs';

let ctx = null;
let groupCount = 1;
const picked = [0, 0];

/** The groups of each family (index = family id). */
function membersOf(groupFamily) {
  const out = [];
  if (!groupFamily) return out;
  groupFamily.forEach((f, g) => {
    if (g === 0) return;
    (out[f] ||= []).push(g);
  });
  return out.map((m) => m || []);
}

parentPort.on('message', (msg) => {
  if (msg.type === 'init') {
    const tracer = new Tracer(msg.tracer);
    ctx = {
      lights: msg.lights,
      grid: new LightGrid(msg.lights),
      tracer,
      settings: msg.settings,
      ambient: msg.ambient,
      outdoor: msg.outdoor,
      moonDir: msg.moonDir,
      moonColor: msg.moonColor,
      groupKinds: msg.groupKinds,
      groupFamily: msg.groupFamily,
      familyMembers: membersOf(msg.groupFamily),
      // probe slots: the groups each slot pools (a scripted group alone, or a power family)
      probeSlots: msg.probeSlots,
    };
    groupCount = msg.groupKinds.length;
    parentPort.postMessage({ type: 'ready' });
    return;
  }
  if (msg.type === 'job') {
    const { id, points, normals, seeds } = msg;
    const n = points.length / 3;
    const rgb = new Float32Array(n * 3);
    const group = new Uint16Array(n);
    const share = new Float32Array(n);
    const ao = new Float32Array(n);
    const sky = new Float32Array(n);
    const acc = new Float64Array(groupCount);
    const hasNormals = normals.length === points.length;
    // probes: the slots' light is kept apart (base + level x extra at run time)
    const slots = ctx.probeSlots;
    const family = ctx.groupFamily;
    const groupRgb = hasNormals ? null : new Float64Array(groupCount * 3);
    const extra = hasNormals ? new Float32Array(0) : new Float32Array(n * slots.length * 3);
    const before = ctx.tracer.rays;
    for (let i = 0; i < n; i++) {
      acc.fill(0);
      const p = [points[i * 3], points[i * 3 + 1], points[i * 3 + 2]];
      const nn = hasNormals ? [normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]] : null;
      if (groupRgb) groupRgb.fill(0);
      const res = shadePoint(ctx, p, nn, seeds[i], acc, groupRgb);
      rgb[i * 3] = res.r;
      rgb[i * 3 + 1] = res.g;
      rgb[i * 3 + 2] = res.b;
      if (groupRgb) {
        slots.forEach((members, k) => {
          for (let c = 0; c < 3; c++) {
            let v = 0;
            for (const g of members) v += groupRgb[g * 3 + c];
            extra[(i * slots.length + k) * 3 + c] = v;
            rgb[i * 3 + c] -= v;
          }
        });
      }
      ao[i] = res.ao;
      sky[i] = res.sky;
      // the dominant non-steady group and its share (a power family's light pooled into it)
      dominantGroup(acc, res.r + res.g + res.b, ctx.groupKinds, family, ctx.familyMembers, picked);
      group[i] = picked[0];
      share[i] = picked[1];
    }
    parentPort.postMessage({ type: 'done', id, rgb, group, share, ao, sky, extra, rays: ctx.tracer.rays - before }, [
      rgb.buffer,
      group.buffer,
      share.buffer,
      ao.buffer,
      sky.buffer,
      extra.buffer,
    ]);
  }
});
