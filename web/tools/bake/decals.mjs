// SurfaceGui decals: the signage, chalkboards, notices, posters, hazard stripes, room plates, locker numbers, flask
// labels and exit-sign letters the builders paint with SurfaceGuis (SurfaceArt, SignageBuilder, LobbySignage, ...),
// rasterised into WebP atlas pages by Playwright's Chromium (a 2D canvas: frames, rotation, UICorner, UIGradient,
// UIStroke, text), and placed back as textured quads on their part faces by bake.mjs.
//
// Skipped: "Wear" (grime, soot, cracks over every wall: thousands of guis of soft noise) and "Finish" (ceiling grids
// and floor checkers, which the generated textures already carry).
//
// Fonts: the Roblox families map onto fonts present at bake time (the result is pixels, so the player needs none):
// GothamSSm -> Inter, Oswald -> Inter narrowed, SpecialElite -> Courier 10 Pitch, PatrickHand -> DejaVu Sans with a
// hand-written jitter, Michroma -> Inter widened, RobotoMono -> JetBrains Mono.

import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { faceStuds } from './mesh.mjs';

const require = createRequire(import.meta.url);

const SKIP = new Set(['Wear', 'Finish']);
const PAD = 4; // texels of transparent padding around every decal (mipmaps)
const MIN_SIDE = 16;
const MAX_SIDE = 512;
const MAX_PPS = 40;

/**
 * @param {any} raw world-raw.json
 * @param {string} outDir build/textures
 * @param {{ pageSize?: number, quality?: number }} [opts]
 * @returns {Promise<{ pages: any[], decals: any[], skipped: number }>}
 */
export async function bakeDecals(raw, outDir, opts = {}) {
  const pageSize = opts.pageSize || 2048;
  const quality = opts.quality ?? 0.9;
  const jobs = [];
  const byKey = new Map();
  const decals = [];
  let skipped = 0;
  raw.guis.forEach((g, index) => {
    if (SKIP.has(g.name) || g.enabled === false || !g.children || g.children.length === 0) {
      skipped++;
      return;
    }
    const part = raw.parts[g.part - 1];
    const [sw, sh] = faceStuds(part.size, g.face);
    if (sw < 1e-3 || sh < 1e-3) return;
    let pps = Math.min(g.pixelsPerStud || 20, MAX_PPS);
    if (Math.min(sw, sh) * pps < MIN_SIDE) pps = MIN_SIDE / Math.min(sw, sh);
    if (Math.max(sw, sh) * pps > MAX_SIDE) pps = MAX_SIDE / Math.max(sw, sh);
    const w = Math.max(1, Math.round(sw * pps));
    const h = Math.max(1, Math.round(sh * pps));
    // identical paint at identical size shares one atlas cell (wet-floor signs, hazard bands, stair signs, ...)
    const key = `${w}x${h}|${g.pixelsPerStud}|${JSON.stringify(g.children)}`;
    let job = byKey.get(key);
    if (!job) {
      job = { id: jobs.length, w, h, scale: pps / (g.pixelsPerStud || 20), children: g.children };
      jobs.push(job);
      byKey.set(key, job);
    }
    decals.push({
      gui: index,
      name: g.name,
      part: g.part - 1,
      face: g.face,
      job: job.id,
      lightInfluence: g.lightInfluence ?? 1,
      brightness: g.brightness ?? 1,
    });
  });

  const pages = pack(jobs, pageSize);

  const { chromium } = require('playwright');
  const browser = await chromium.launch();
  try {
    const tab = await browser.newPage();
    await tab.setContent('<!doctype html><html><body></body></html>');
    await tab.addScriptTag({ content: RENDERER });
    fs.mkdirSync(outDir, { recursive: true });
    for (const p of pages) {
      const dataUrl = await tab.evaluate(([pg, q]) => window.renderPage(pg, q), [{ width: p.width, height: p.height, jobs: p.jobs }, quality]);
      const file = `decals_${p.index}.webp`;
      fs.writeFileSync(path.join(outDir, file), Buffer.from(dataUrl.split(',')[1], 'base64'));
      p.file = file;
      p.bytes = fs.statSync(path.join(outDir, file)).size;
      delete p.jobs;
    }
  } finally {
    await browser.close();
  }

  for (const d of decals) {
    const job = jobs[d.job];
    const p = pages[job.page];
    d.page = job.page;
    // UVs in the GL / three.js convention (images uploaded with flipY = true: v = 0 is the image's bottom row), so a
    // decal reads [u0, vTop, u1, vBottom] with the canvas's top edge at vTop
    d.rect = [job.x / p.width, 1 - job.y / p.height, (job.x + job.w) / p.width, 1 - (job.y + job.h) / p.height];
  }
  return { pages, decals, skipped, cells: jobs.length };
}


/**
 * Wear (grime at the foot of walls, soot under ceilings, dirt in corners, water runs, cracks, stains): every "Wear"
 * SurfaceGui rendered at low resolution over its wall's own colour, then stored as a MULTIPLY factor
 * (painted / bare, per channel, display-encoded): white = untouched. The engine draws these quads with multiplicative
 * blending (dst * src), so no lighting and no alpha are needed and the result matches Roblox's paint over the lit
 * wall. Each quad is cropped to the part of its canvas the paint actually darkens.
 *
 * @param {any} raw @param {string} outDir @param {{ pps?: number, pageSize?: number, quality?: number, textureRefs?: any }} [opts]
 */
export async function bakeWear(raw, outDir, opts = {}) {
  const pageSize = opts.pageSize || 2048;
  const quality = opts.quality ?? 0.8;
  const pps = opts.pps || 3;
  const refs = opts.textureRefs || {};
  const jobs = [];
  const wear = [];
  raw.guis.forEach((g, index) => {
    if (g.name !== 'Wear' || g.enabled === false || !g.children || !g.children.length) return;
    const part = raw.parts[g.part - 1];
    if (!part || part.entity || part.transparency > 0.01) return;
    const [sw, sh] = faceStuds(part.size, g.face);
    let k = pps;
    if (Math.max(sw, sh) * k > 256) k = 256 / Math.max(sw, sh);
    const w = Math.max(4, Math.round(sw * k));
    const h = Math.max(4, Math.round(sh * k));
    // the bare wall colour the paint is laid over (a textured part's colour was divided by its texture's reference)
    const ref = part.texture && refs[part.texture] && refs[part.texture].reference ? refs[part.texture].reference : [1, 1, 1];
    const base = part.color.map((c, i) => Math.min(1, c * ref[i]));
    const job = { id: jobs.length, w, h, scale: (w / sw) / (g.pixelsPerStud || 6), children: g.children, base };
    jobs.push(job);
    wear.push({ gui: index, part: g.part - 1, face: g.face, job: job.id });
  });
  const pages = pack(jobs, pageSize, 2);
  const { chromium } = require('playwright');
  const browser = await chromium.launch();
  try {
    const tab = await browser.newPage();
    await tab.setContent('<!doctype html><html><body></body></html>');
    await tab.addScriptTag({ content: RENDERER });
    fs.mkdirSync(outDir, { recursive: true });
    for (const p of pages) {
      const res = await tab.evaluate(([pg, q]) => window.renderWearPage(pg, q), [{ width: p.width, height: p.height, jobs: p.jobs }, quality]);
      const file = `wear_${p.index}.webp`;
      fs.writeFileSync(path.join(outDir, file), Buffer.from(res.dataUrl.split(',')[1], 'base64'));
      p.file = file;
      p.bytes = fs.statSync(path.join(outDir, file)).size;
      for (const [id, crop] of Object.entries(res.crops)) jobs[id].crop = crop;
      delete p.jobs;
    }
  } finally {
    await browser.close();
  }
  const placed = [];
  for (const d of wear) {
    const job = jobs[d.job];
    if (!job.crop) continue; // the paint darkens nothing visible
    const p = pages[job.page];
    const [c0, c1, c2, c3] = job.crop; // canvas fractions, v down
    d.page = job.page;
    d.crop = job.crop;
    d.rect = [
      (job.x + c0 * job.w) / p.width,
      1 - (job.y + c1 * job.h) / p.height,
      (job.x + c2 * job.w) / p.width,
      1 - (job.y + c3 * job.h) / p.height,
    ];
    placed.push(d);
  }
  return { pages, wear: placed, total: wear.length };
}

/** Shelf-packs jobs ({ w, h }) onto pages of `pageSize` width (heights rounded up to a power of two). */
function pack(jobs, pageSize, pad = PAD) {
  // shelf packing, tallest first
  const order = [...jobs].sort((a, b) => b.h - a.h || b.w - a.w);
  const pages = [];
  let page = null;
  let x = 0;
  let y = 0;
  let shelf = 0;
  const newPage = () => {
    page = { index: pages.length, width: pageSize, height: 0, jobs: [] };
    pages.push(page);
    x = 0;
    y = 0;
    shelf = 0;
  };
  newPage();
  for (const job of order) {
    const w = job.w + pad * 2;
    const h = job.h + pad * 2;
    if (x + w > pageSize) {
      x = 0;
      y += shelf;
      shelf = 0;
    }
    if (y + h > pageSize) newPage();
    job.page = page.index;
    job.x = x + pad;
    job.y = y + pad;
    page.jobs.push(job);
    x += w;
    shelf = Math.max(shelf, h);
    page.height = Math.max(page.height, y + shelf);
  }
  // page heights rounded up to a power of two (mipmapping on WebGL1-era GPUs is happier)
  for (const p of pages) {
    let ph = 64;
    while (ph < p.height) ph *= 2;
    p.height = ph;
  }

  return pages;
}

// The in-browser renderer: draws Roblox GuiObject trees onto canvas regions, returns the page as WebP.
const RENDERER = String.raw`
(() => {
  const FONTS = {
    GothamSSm: { family: 'Inter, "DejaVu Sans", sans-serif', stretch: 1 },
    Oswald: { family: 'Inter, "DejaVu Sans", sans-serif', stretch: 0.78, weight: 600 },
    SpecialElite: { family: '"Courier 10 Pitch", "FreeMono", "DejaVu Sans Mono", monospace', stretch: 1, weight: 700 },
    PatrickHand: { family: '"DejaVu Sans", sans-serif', stretch: 0.92, hand: true },
    Michroma: { family: 'Inter, "DejaVu Sans", sans-serif', stretch: 1.18, weight: 800 },
    RobotoMono: { family: '"JetBrains Mono", "DejaVu Sans Mono", monospace', stretch: 1, weight: 600 },
  };
  const WEIGHTS = { Thin: 100, ExtraLight: 200, Light: 300, Regular: 400, Medium: 500, SemiBold: 600, Bold: 700, ExtraBold: 800, Heavy: 900 };
  const fontOf = (n) => {
    const fam = (n.font || '').replace(/^.*\//, '').replace(/\.json$/, '');
    const f = FONTS[fam] || { family: 'Inter, sans-serif', stretch: 1 };
    const wname = (n.fontWeight || '').replace(/^Enum\.FontWeight\./, '');
    return { ...f, weight: f.weight || WEIGHTS[wname] || 400, italic: /Italic/.test(n.fontStyle || '') };
  };
  const rgba = (c, a) => 'rgba(' + Math.round(c[0] * 255) + ',' + Math.round(c[1] * 255) + ',' + Math.round(c[2] * 255) + ',' + Math.max(0, Math.min(1, a)).toFixed(4) + ')';
  let seed = 1;
  const rand = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };

  function sampleSeq(seq, t, isColor) {
    if (!seq || !seq.length) return isColor ? [1, 1, 1] : 0;
    if (t <= seq[0][0]) return seq[0][1];
    for (let i = 1; i < seq.length; i++) {
      if (t <= seq[i][0]) {
        const a = seq[i - 1], b = seq[i];
        const f = (t - a[0]) / Math.max(1e-6, b[0] - a[0]);
        if (isColor) return [0, 1, 2].map((k) => a[1][k] + (b[1][k] - a[1][k]) * f);
        return a[1] + (b[1] - a[1]) * f;
      }
    }
    return seq[seq.length - 1][1];
  }

  // A canvas gradient for a UIGradient over rect r, colouring 'base' at base transparency 'bt'.
  function gradientStyle(ctx, g, r, base, bt) {
    const rad = (g.rotation || 0) * Math.PI / 180;
    const dx = Math.cos(rad), dy = Math.sin(rad);
    const cx = r.x + r.w / 2 + (g.offset ? g.offset[0] * r.w : 0);
    const cy = r.y + r.h / 2 + (g.offset ? g.offset[1] * r.h : 0);
    const half = (Math.abs(dx) * r.w + Math.abs(dy) * r.h) / 2;
    const grad = ctx.createLinearGradient(cx - dx * half, cy - dy * half, cx + dx * half, cy + dy * half);
    const times = new Set([0, 1]);
    for (const k of g.colorSeq || []) times.add(k[0]);
    for (const k of g.transparencySeq || []) times.add(k[0]);
    const list = [...times].sort((a, b) => a - b);
    for (let i = 0; i < list.length; i++) {
      const t = list[i];
      const col = sampleSeq(g.colorSeq, t, true);
      const tr = sampleSeq(g.transparencySeq, t, false);
      const a = (1 - bt) * (1 - tr);
      grad.addColorStop(Math.min(1, Math.max(0, t)), rgba([base[0] * col[0], base[1] * col[1], base[2] * col[2]], a));
    }
    return grad;
  }

  function roundRect(ctx, r, rad) {
    const k = Math.min(rad, r.w / 2, r.h / 2);
    ctx.beginPath();
    if (k <= 0.01) { ctx.rect(r.x, r.y, r.w, r.h); return; }
    ctx.moveTo(r.x + k, r.y);
    ctx.arcTo(r.x + r.w, r.y, r.x + r.w, r.y + r.h, k);
    ctx.arcTo(r.x + r.w, r.y + r.h, r.x, r.y + r.h, k);
    ctx.arcTo(r.x, r.y + r.h, r.x, r.y, k);
    ctx.arcTo(r.x, r.y, r.x + r.w, r.y, k);
    ctx.closePath();
  }

  function setFont(ctx, f, size) {
    ctx.font = (f.italic ? 'italic ' : '') + f.weight + ' ' + size.toFixed(2) + 'px ' + f.family;
  }

  function drawText(ctx, n, r, k, grad) {
    const text = n.text;
    if (!text || (n.textTransparency ?? 0) >= 1) return;
    const f = fontOf(n);
    const lines = String(text).split('\n');
    let size;
    if (n.textScaled) {
      // the largest size that fits the box (Roblox caps scaled text at 100 px)
      size = Math.min(r.h / lines.length, 100 * k);
      setFont(ctx, f, size);
      const widest = Math.max(...lines.map((l) => ctx.measureText(l).width * f.stretch));
      if (widest > r.w) size *= r.w / widest;
      size *= 0.94;
    } else {
      size = (n.textSize || 14) * k;
    }
    setFont(ctx, f, size);
    const lineH = size * 1.0;
    const total = lineH * lines.length;
    const ya = n.yAlign || 'Center';
    let y0 = ya === 'Top' ? r.y : ya === 'Bottom' ? r.y + r.h - total : r.y + (r.h - total) / 2;
    ctx.textBaseline = 'middle';
    const fill = grad || rgba(n.textColor || [0, 0, 0], 1 - (n.textTransparency || 0));
    for (const line of lines) {
      const w = ctx.measureText(line).width * f.stretch;
      const xa = n.xAlign || 'Center';
      const x0 = xa === 'Left' ? r.x : xa === 'Right' ? r.x + r.w - w : r.x + (r.w - w) / 2;
      const yc = y0 + lineH / 2;
      ctx.save();
      ctx.translate(x0, yc);
      ctx.scale(f.stretch, 1);
      ctx.fillStyle = fill;
      if (f.hand) {
        // hand-written: every glyph wobbles a little
        let cx = 0;
        for (const ch of line) {
          const cw = ctx.measureText(ch).width;
          ctx.save();
          ctx.translate(cx + cw / 2, (rand() - 0.5) * size * 0.12);
          ctx.rotate((rand() - 0.5) * 0.18);
          ctx.fillText(ch, -cw / 2, 0);
          ctx.restore();
          cx += cw * (0.96 + rand() * 0.08);
        }
      } else {
        if ((n.strokeTransparency ?? 1) < 1) {
          ctx.lineWidth = Math.max(1, size * 0.08);
          ctx.strokeStyle = rgba(n.strokeColor || [0, 0, 0], 1 - n.strokeTransparency);
          ctx.strokeText(line, 0, 0);
        }
        ctx.fillText(line, 0, 0);
      }
      ctx.restore();
      y0 += lineH;
    }
  }

  function drawNode(ctx, n, pr, k) {
    if (n.visible === false || !n.size) return;
    const w = n.size[0] * pr.w + n.size[1] * k;
    const h = n.size[2] * pr.h + n.size[3] * k;
    const anchor = n.anchor || [0, 0];
    const r = {
      x: pr.x + n.position[0] * pr.w + n.position[1] * k - anchor[0] * w,
      y: pr.y + n.position[2] * pr.h + n.position[3] * k - anchor[1] * h,
      w, h,
    };
    const kids = n.children || [];
    const grad = kids.find((c) => c.class === 'UIGradient' && c.enabled !== false);
    const corner = kids.find((c) => c.class === 'UICorner');
    const stroke = kids.find((c) => c.class === 'UIStroke');
    ctx.save();
    if (n.rotation) {
      ctx.translate(r.x + r.w / 2, r.y + r.h / 2);
      ctx.rotate(n.rotation * Math.PI / 180);
      ctx.translate(-(r.x + r.w / 2), -(r.y + r.h / 2));
    }
    const radius = corner ? corner.radius[0] * Math.min(r.w, r.h) + corner.radius[1] * k : 0;
    const bt = n.transparency ?? 0;
    if (bt < 1 && n.color) {
      ctx.fillStyle = grad ? gradientStyle(ctx, grad, r, n.color, bt) : rgba(n.color, 1 - bt);
      roundRect(ctx, r, radius);
      ctx.fill();
    }
    if (n.text !== undefined) {
      const tg = grad ? gradientStyle(ctx, grad, r, n.textColor || [1, 1, 1], n.textTransparency || 0) : null;
      // a contextual UIStroke outlines the text itself
      const t = stroke && stroke.mode !== 'Border' ? { ...n, strokeTransparency: stroke.transparency || 0, strokeColor: stroke.color } : n;
      drawText(ctx, t, r, k, tg);
    }
    if (stroke && (stroke.mode === 'Border' || n.text === undefined)) {
      ctx.lineWidth = Math.max(0.75, (stroke.thickness || 1) * k);
      ctx.strokeStyle = rgba(stroke.color || [0, 0, 0], 1 - (stroke.transparency || 0));
      const o = ctx.lineWidth / 2;
      roundRect(ctx, { x: r.x - o, y: r.y - o, w: r.w + 2 * o, h: r.h + 2 * o }, radius + o);
      ctx.stroke();
    }
    if (n.clips) {
      roundRect(ctx, r, radius);
      ctx.clip();
    }
    const ordered = kids.filter((c) => c.size).map((c, i) => [c, i]).sort((a, b) => (a[0].z || 1) - (b[0].z || 1) || a[1] - b[1]);
    for (const [c] of ordered) drawNode(ctx, c, r, k);
    ctx.restore();
  }


  // Wear pages: each job painted over its opaque base colour, then turned into a multiply factor (painted / base)
  // with white padding; returns the darkened bounding box of every job (canvas fractions) or none when untouched.
  window.renderWearPage = function (page, quality) {
    const canvas = document.createElement('canvas');
    canvas.width = page.width;
    canvas.height = page.height;
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, page.width, page.height);
    const crops = {};
    for (const job of page.jobs) {
      seed = job.id * 7919 + 1;
      ctx.save();
      ctx.beginPath();
      ctx.rect(job.x, job.y, job.w, job.h);
      ctx.clip();
      ctx.fillStyle = rgba(job.base, 1);
      ctx.fillRect(job.x, job.y, job.w, job.h);
      const root = { x: job.x, y: job.y, w: job.w, h: job.h };
      const ordered = job.children.filter((c) => c.size).map((c, i) => [c, i]).sort((a, b) => (a[0].z || 1) - (b[0].z || 1) || a[1] - b[1]);
      for (const [c] of ordered) drawNode(ctx, c, root, job.scale);
      ctx.restore();
      const img = ctx.getImageData(job.x, job.y, job.w, job.h);
      const d = img.data;
      const b = job.base.map((v) => Math.max(1, Math.round(v * 255)));
      let x0 = job.w, y0 = job.h, x1 = -1, y1 = -1;
      for (let y = 0; y < job.h; y++) {
        for (let x = 0; x < job.w; x++) {
          const i = (y * job.w + x) * 4;
          let dark = false;
          for (let k = 0; k < 3; k++) {
            const f = Math.min(255, Math.round((d[i + k] / b[k]) * 255));
            d[i + k] = f;
            if (f < 247) dark = true;
          }
          d[i + 3] = 255;
          if (dark) {
            if (x < x0) x0 = x;
            if (y < y0) y0 = y;
            if (x > x1) x1 = x;
            if (y > y1) y1 = y;
          }
        }
      }
      ctx.putImageData(img, job.x, job.y);
      if (x1 >= 0) crops[job.id] = [x0 / job.w, y0 / job.h, (x1 + 1) / job.w, (y1 + 1) / job.h];
    }
    return { dataUrl: canvas.toDataURL('image/webp', quality), crops };
  };

  window.renderPage = function (page, quality) {
    const canvas = document.createElement('canvas');
    canvas.width = page.width;
    canvas.height = page.height;
    const ctx = canvas.getContext('2d');
    ctx.clearRect(0, 0, page.width, page.height);
    for (const job of page.jobs) {
      seed = job.id * 7919 + 1;
      ctx.save();
      ctx.beginPath();
      ctx.rect(job.x, job.y, job.w, job.h);
      ctx.clip();
      const root = { x: job.x, y: job.y, w: job.w, h: job.h };
      const ordered = job.children.filter((c) => c.size).map((c, i) => [c, i]).sort((a, b) => (a[0].z || 1) - (b[0].z || 1) || a[1] - b[1]);
      for (const [c] of ordered) drawNode(ctx, c, root, job.scale);
      ctx.restore();
    }
    return canvas.toDataURL('image/webp', quality);
  };
})();
`;
