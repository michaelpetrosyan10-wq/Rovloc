// Bake worker: shades batches of points (surface vertices or probe points) with light.mjs over a shared tracer.
//
// init message: { tracer: { positions, index, nodes }, lights, settings, ambient, outdoor, moonDir, moonColor, groups }
// job message:  { id, points: Float32Array (xyz), normals: Float32Array (xyz, or empty for probes), seeds: Uint32Array }
// reply:        { id, rgb: Float32Array (3n), group: Uint8Array (n), share: Float32Array (n), ao: Float32Array (n),
//                 sky: Float32Array (n), extra: Float32Array (probes: n x scripted groups x 3, taken out of rgb), rays }

import { parentPort } from 'node:worker_threads';
import { Tracer } from './trace.mjs';
import { LightGrid, shadePoint } from './light.mjs';

let ctx = null;
let groupCount = 1;

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
      scriptedGroups: msg.groupKinds.map((k, g) => (k === 'scripted' ? g : -1)).filter((g) => g > 0),
    };
    groupCount = msg.groupKinds.length;
    parentPort.postMessage({ type: 'ready' });
    return;
  }
  if (msg.type === 'job') {
    const { id, points, normals, seeds } = msg;
    const n = points.length / 3;
    const rgb = new Float32Array(n * 3);
    const group = new Uint8Array(n);
    const share = new Float32Array(n);
    const ao = new Float32Array(n);
    const sky = new Float32Array(n);
    const acc = new Float64Array(groupCount);
    const hasNormals = normals.length === points.length;
    // probes: the scripted groups' light is kept apart (base + level x extra at run time)
    const scripted = ctx.scriptedGroups;
    const groupRgb = hasNormals ? null : new Float64Array(groupCount * 3);
    const extra = hasNormals ? new Float32Array(0) : new Float32Array(n * scripted.length * 3);
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
        scripted.forEach((g, k) => {
          for (let c = 0; c < 3; c++) {
            const v = groupRgb[g * 3 + c];
            extra[(i * scripted.length + k) * 3 + c] = v;
            rgb[i * 3 + c] -= v;
          }
        });
      }
      ao[i] = res.ao;
      sky[i] = res.sky;
      // dominant non-steady group (scripted groups win ties: their light switches fully on or off)
      const total = res.r + res.g + res.b;
      let best = 0;
      let bestW = 0;
      for (let g = 1; g < groupCount; g++) {
        const w = acc[g] * (ctx.groupKinds[g] === 'scripted' ? 1.5 : 1);
        if (w > bestW) {
          bestW = w;
          best = g;
        }
      }
      if (best && total > 1e-6) {
        group[i] = best;
        share[i] = Math.min(1, acc[best] / total);
      }
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
