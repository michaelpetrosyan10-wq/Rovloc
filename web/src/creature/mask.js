// The Tall Man's mask on the website: the sculpt and everything painted on it, built from the numbers the rig carries
// (CreatureRigBuilder: the Mask part's attributes and the detail parts' CrackFrom / StreakFrom ends). Roblox draws the
// same mask from Parts; the website hides those (look.js) and draws this instead:
//   * maskSpec(meta): the numbers: eye holes, pupils, the half-smiling slit, the outline knots (MaskOutline), the
//     centreline's depth (MaskProfile), the relief (MaskRelief), the chip (ChipCentre / ChipRadius / ChipAngle).
//   * buildMaskSculpt(spec, faceToModel, bones): a dense mesh of that surface in two pieces split at the slit (the upper
//     mask on the Head bone, the chin on the Jaw bone, so the hinge splits it): an elongated oval shell whose rim
//     recedes on an ellipse into the skull, the relief pushed out of it (real geometry: brow ridges over deep sockets, a
//     thin nose, cheekbones over sunken cheeks, lips round the slit, a pointed chin), a rolled edge with thickness, and
//     per vertex the cavity (ambient occlusion), the distance to the rim and the relief height for the shader.
//   * crackSegments / streakSegments: the painted cracks and weeping streaks, plus the cracks that race across the mask
//     in the jumpscare (grown from the rig's cracks by a seeded rule: Roblox's controller can grow the same ones).
//   * detailTexture(): the glaze's detail normal map (crazing and pitting) for the Max tier.
//   * maskFx(elapsed): the jumpscare's timeline on the mask (cracks racing, the maw tearing, the strands stretching,
//     one pupil dilating), seconds after the Lunge starts.
// Face frame: the FaceFrontAttachment (x right, y up, z back, origin between the pupils), in studs.

import * as THREE from 'three';

const num = (v, d) => (Number.isFinite(v) ? v : d);

/** Parses "a:b:c;d:e:f" rows (the rig's MaskOutline / MaskProfile); bad rows are dropped. */
export function parseRows(text, width) {
  const out = [];
  for (const row of String(text || '').split(';')) {
    const cells = row.split(':').map(Number);
    if (cells.length === width && cells.every(Number.isFinite)) out.push(cells);
  }
  return out;
}

/** Parses "Name:x:y:rx:ry:height:tilt;..." (MaskRelief). */
export function parseRelief(text) {
  const out = [];
  for (const row of String(text || '').split(';')) {
    const cells = row.split(':');
    if (cells.length !== 7) continue;
    const v = cells.slice(1).map(Number);
    if (!v.every(Number.isFinite)) continue;
    const tilt = (v[5] * Math.PI) / 180;
    out.push({ name: cells[0], cx: v[0], cy: v[1], rx: Math.max(v[2], 1e-3), ry: Math.max(v[3], 1e-3), height: v[4], cos: Math.cos(tilt), sin: Math.sin(tilt) });
  }
  return out;
}

// The rig's numbers, for a meta without them (an old bake): the same mask, so the website always has one.
const FALLBACK_OUTLINE = '0.53:0:0;0.5:0.14:0.15;0.44:0.235:0.245;0.36:0.3:0.31;0.24:0.345:0.352;0.1:0.368:0.372;-0.04:0.37:0.366;-0.16:0.352:0.346;-0.28:0.318:0.312;-0.4:0.272:0.262;-0.52:0.212:0.2;-0.62:0.148:0.134;-0.7:0.088:0.074;-0.76:0.036:0.028;-0.79:0:0';
const FALLBACK_PROFILE = '0.53:0.24;0.48:0.14;0.4:0.06;0.3:0.02;0.15:0;0:0;-0.2:0;-0.34:0.01;-0.5:0.03;-0.65:0.06;-0.79:0.13';
const FALLBACK_RELIEF = 'BrowLeft:-0.155:0.125:0.115:0.034:0.055:-9;BrowRight:0.16:0.135:0.118:0.034:0.05:7;SocketLeft:-0.15:-0.005:0.105:0.085:-0.085:0;SocketRight:0.152:0:0.11:0.09:-0.09:0;Nose:0:-0.075:0.022:0.12:0.04:0;NoseTip:0:-0.2:0.042:0.032:0.03:0';

/** The Mask part's numbers (CreatureRigBuilder.MaskAttributes and MaskShape), with defaults. */
export function maskSpec(meta) {
  const creature = meta && meta.creature;
  const part = creature && (creature.parts || []).find((p) => p.name === 'Mask');
  const a = (part && part.attributes) || {};
  const outline = parseRows(a.MaskOutline || FALLBACK_OUTLINE, 3).sort((p, q) => q[0] - p[0]);
  const profile = parseRows(a.MaskProfile || FALLBACK_PROFILE, 2).sort((p, q) => q[0] - p[0]);
  const chipCentre = Array.isArray(a.ChipCentre) ? a.ChipCentre : [0.315, 0.31];
  const chipRadius = Array.isArray(a.ChipRadius) ? a.ChipRadius : [0.075, 0.05];
  return {
    eyeX: num(a.EyeX, 0.15),
    holeW: num(a.EyeHoleWidth, 0.098),
    holeH: num(a.EyeHoleHeight, 0.07),
    holeDepth: num(a.EyeHoleDepth, 0.3),
    pupilR: num(a.PupilGlowRadius, 0.011),
    pupilScaleRight: num(a.PupilScaleRight, 1.45),
    slitY: num(a.SlitY, -0.34),
    slitHalf: num(a.SlitHalfWidth, 0.16),
    slitUpturn: num(a.SlitUpturn, 0.05),
    top: num(a.MaskTop, outline.length ? outline[0][0] : 0.53),
    chinY: num(a.ChinY, outline.length ? outline[outline.length - 1][0] : -0.79),
    depth: num(a.MaskDepth, 0.24),
    outline,
    profile,
    relief: parseRelief(a.MaskRelief || FALLBACK_RELIEF),
    chip: { x: num(chipCentre[0], 0.315), y: num(chipCentre[1], 0.31), rx: num(chipRadius[0], 0.075), ry: num(chipRadius[1], 0.05), angle: (num(a.ChipAngle, 35) * Math.PI) / 180 },
  };
}

// ---------------------------------------------------------------------------------------------------------------
// The surface
// ---------------------------------------------------------------------------------------------------------------

/** Monotone cubic (Fritsch-Carlson) through knots sorted by descending x: knots[i] = [x, v0, v1, ...]. */
function monotone(knots, column) {
  const n = knots.length;
  const xs = knots.map((k) => -k[0]); // ascending
  const ys = knots.map((k) => k[column]);
  const d = [];
  for (let i = 0; i < n - 1; i++) d.push((ys[i + 1] - ys[i]) / Math.max(xs[i + 1] - xs[i], 1e-6));
  const m = new Array(n).fill(0);
  m[0] = d[0] || 0;
  m[n - 1] = d[n - 2] || 0;
  for (let i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
  for (let i = 0; i < n - 1; i++) {
    if (d[i] === 0) {
      m[i] = 0;
      m[i + 1] = 0;
      continue;
    }
    const a = m[i] / d[i];
    const b = m[i + 1] / d[i];
    const s = a * a + b * b;
    if (s > 9) {
      const t = 3 / Math.sqrt(s);
      m[i] = t * a * d[i];
      m[i + 1] = t * b * d[i];
    }
  }
  return (y) => {
    const x = -y;
    if (n === 0) return 0;
    if (x <= xs[0]) return ys[0];
    if (x >= xs[n - 1]) return ys[n - 1];
    let i = 0;
    while (i < n - 2 && x > xs[i + 1]) i++;
    const h = xs[i + 1] - xs[i];
    const t = (x - xs[i]) / h;
    const t2 = t * t;
    const t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1];
  };
}

const smooth = (a, b, x) => {
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
};

/** The slit's centreline at x: the seam, curling up at the right corner into the wrong half-smile. */
export function slitCurve(spec, x) {
  const corner = smooth(spec.slitHalf * 0.35, spec.slitHalf * 1.02, x);
  return spec.slitY + spec.slitUpturn * corner * corner;
}

/** The sculpt as functions of the face frame: outline half-widths, centreline depth, relief height. */
export function sculptFunctions(spec) {
  const left = monotone(spec.outline, 1);
  const right = monotone(spec.outline, 2);
  const centre = monotone(spec.profile, 1);
  const relief = (x, y) => {
    let h = 0;
    for (const f of spec.relief) {
      const dx = x - f.cx;
      const dy = y - f.cy;
      const u = (dx * f.cos + dy * f.sin) / f.rx;
      const v = (-dx * f.sin + dy * f.cos) / f.ry;
      const e = u * u + v * v;
      if (e < 12) h += f.height * Math.exp(-e);
    }
    // the slit is carved: a fine groove along it, the lips rising either side (the relief's LipUpper / LipLower)
    const taper = 1 - smooth(spec.slitHalf * 0.85, spec.slitHalf * 1.08, Math.abs(x));
    const g = (y - slitCurve(spec, x)) / 0.0075;
    h -= 0.014 * Math.exp(-g * g) * taper;
    return h;
  };
  return { left: (y) => Math.max(0, left(y)), right: (y) => Math.max(0, right(y)), centre, relief };
}

const ROLL = [0.35, 0.75]; // the rolled edge: two rings past the rim, curling in and back (the porcelain's thickness)

/**
 * The dense sculpt in two pieces (upper: rows from the slit to the top; lower: from the chin to the slit), each a grid
 * of `rows` x (`cols` + the rolled edge on both sides). Returns face-frame positions, normals and per-vertex
 * [cavity, rim, relief] for each piece.
 */
export function sculptGrid(spec, opts = {}) {
  const f = sculptFunctions(spec);
  const cols = opts.cols || 64;
  const pieces = [
    { name: 'upper', y0: spec.slitY, y1: spec.top, rows: opts.upperRows || 78 },
    { name: 'lower', y0: spec.chinY, y1: spec.slitY, rows: opts.lowerRows || 46 },
  ];
  const ring = [];
  for (let k = ROLL.length - 1; k >= 0; k--) ring.push(-1 - ROLL[k]);
  for (let j = 0; j < cols; j++) ring.push(-1 + (2 * j) / (cols - 1));
  for (let k = 0; k < ROLL.length; k++) ring.push(1 + ROLL[k]);
  const width = ring.length;
  const out = [];
  for (const piece of pieces) {
    const rows = piece.rows;
    const P = new Float32Array(rows * width * 3);
    const H = new Float32Array(rows * width);
    const Q = new Float32Array(rows * width);
    for (let i = 0; i < rows; i++) {
      const y = piece.y0 + ((piece.y1 - piece.y0) * i) / (rows - 1);
      const wl = f.left(y);
      const wr = f.right(y);
      const zc = f.centre(y);
      const reach = Math.max(wl, wr);
      // the rim recedes on an ellipse into the skull; narrow rows (the top, the chin) close up instead
      const depth = spec.depth * smooth(0, 0.24, reach);
      for (let j = 0; j < width; j++) {
        const s = ring[j];
        const c = Math.max(-1, Math.min(1, s));
        const theta = (c * Math.PI) / 2;
        const w = c < 0 ? wl : wr;
        let x = Math.sin(theta) * w;
        let z = zc + depth * (1 - Math.cos(theta));
        const q = Math.abs(Math.sin(theta));
        let h = 0;
        if (Math.abs(s) <= 1) {
          h = f.relief(x, y) * (1 - smooth(0.68, 0.98, q)) * smooth(0, 0.08, reach);
          z -= h;
        } else {
          // the rolled edge: the porcelain's thickness turning in behind the rim
          const roll = Math.abs(s) - 1;
          x *= 1 - 0.09 * roll;
          z += 0.05 * roll;
        }
        const v = i * width + j;
        P[v * 3] = x;
        P[v * 3 + 1] = y;
        P[v * 3 + 2] = z;
        H[v] = h;
        Q[v] = Math.min(1.2, Math.abs(s));
      }
    }
    // normals from the grid (toward the viewer: -Z at the front)
    const N = new Float32Array(rows * width * 3);
    const at = (i, j, o) => P[(i * width + j) * 3 + o];
    for (let i = 0; i < rows; i++) {
      for (let j = 0; j < width; j++) {
        const i0 = Math.max(0, i - 1);
        const i1 = Math.min(rows - 1, i + 1);
        const j0 = Math.max(0, j - 1);
        const j1 = Math.min(width - 1, j + 1);
        const ux = at(i, j1, 0) - at(i, j0, 0);
        const uy = at(i, j1, 1) - at(i, j0, 1);
        const uz = at(i, j1, 2) - at(i, j0, 2);
        const vx = at(i1, j, 0) - at(i0, j, 0);
        const vy = at(i1, j, 1) - at(i0, j, 1);
        const vz = at(i1, j, 2) - at(i0, j, 2);
        // up the face x across it (left to right) is the outward normal in this z-back frame
        let nx = vy * uz - vz * uy;
        let ny = vz * ux - vx * uz;
        let nz = vx * uy - vy * ux;
        let len = Math.hypot(nx, ny, nz);
        if (len < 1e-9) {
          // a collapsed row (the very top or the chin's point): the shell's own direction there
          nx = 0;
          ny = i === rows - 1 && piece.name === 'upper' ? 0.6 : i === 0 && piece.name === 'lower' ? -0.6 : 0;
          nz = -0.8;
          len = Math.hypot(nx, ny, nz);
        }
        const v = i * width + j;
        N[v * 3] = nx / len;
        N[v * 3 + 1] = ny / len;
        N[v * 3 + 2] = nz / len;
      }
    }
    // cavity: how far the surface sits under its neighbourhood (sockets, the creases by the nose and the slit)
    const C = new Float32Array(rows * width);
    const R = 4;
    for (let i = 0; i < rows; i++) {
      for (let j = 0; j < width; j++) {
        let sum = 0;
        let count = 0;
        for (let di = -R; di <= R; di += 2) {
          for (let dj = -R; dj <= R; dj += 2) {
            const ii = i + di;
            const jj = j + dj;
            if (ii < 0 || jj < 0 || ii >= rows || jj >= width) continue;
            sum += H[ii * width + jj];
            count++;
          }
        }
        const v = i * width + j;
        C[v] = Math.max(0, sum / count - H[v]) + Math.max(0, -H[v]) * 0.35;
      }
    }
    out.push({ name: piece.name, rows, width, P, N, H, Q, C });
  }
  return out;
}

/**
 * The sculpt as one indexed BufferGeometry in model space at rest (both pieces), with the world material's attributes
 * (bakedLight and flicker zero: it is lit by the probe like every node mesh), `node` the bone of each vertex (Head or
 * Jaw) and `sculpt` = (cavity, rim, relief). `faceToModel` maps the face frame into model space.
 * @param {ReturnType<typeof maskSpec>} spec @param {THREE.Matrix4} faceToModel
 * @param {{head: number, jaw: number}} bones @param {[number, number, number]} color sRGB 0..1
 */
export function buildMaskSculpt(spec, faceToModel, bones, color, opts = {}) {
  const grid = sculptGrid(spec, opts);
  let count = 0;
  for (const g of grid) count += g.rows * g.width;
  const position = new Float32Array(count * 3);
  const normal = new Float32Array(count * 3);
  const uv = new Float32Array(count * 2);
  const colors = new Float32Array(count * 3);
  const sculpt = new Float32Array(count * 3);
  const node = new Float32Array(count);
  const index = [];
  const normalMatrix = new THREE.Matrix3().getNormalMatrix(faceToModel);
  const p = new THREE.Vector3();
  const n = new THREE.Vector3();
  let base = 0;
  for (const g of grid) {
    const bone = g.name === 'upper' ? bones.head : bones.jaw;
    for (let v = 0; v < g.rows * g.width; v++) {
      const o = base + v;
      p.set(g.P[v * 3], g.P[v * 3 + 1], g.P[v * 3 + 2]).applyMatrix4(faceToModel);
      n.set(g.N[v * 3], g.N[v * 3 + 1], g.N[v * 3 + 2]).applyMatrix3(normalMatrix).normalize();
      position[o * 3] = p.x;
      position[o * 3 + 1] = p.y;
      position[o * 3 + 2] = p.z;
      normal[o * 3] = n.x;
      normal[o * 3 + 1] = n.y;
      normal[o * 3 + 2] = n.z;
      uv[o * 2] = g.P[v * 3];
      uv[o * 2 + 1] = g.P[v * 3 + 1];
      colors[o * 3] = color[0];
      colors[o * 3 + 1] = color[1];
      colors[o * 3 + 2] = color[2];
      sculpt[o * 3] = g.C[v];
      sculpt[o * 3 + 1] = g.Q[v];
      sculpt[o * 3 + 2] = g.H[v];
      node[o] = bone;
    }
    // counter-clockwise seen from the front (-Z of the face frame, toward the viewer)
    for (let i = 0; i < g.rows - 1; i++) {
      for (let j = 0; j < g.width - 1; j++) {
        const a = base + i * g.width + j;
        const b = a + 1;
        const c = a + g.width + 1;
        const d = a + g.width;
        index.push(a, c, b, a, d, c);
      }
    }
    base += g.rows * g.width;
  }
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute('position', new THREE.BufferAttribute(position, 3));
  geometry.setAttribute('normal', new THREE.BufferAttribute(normal, 3));
  geometry.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
  geometry.setAttribute('color', new THREE.BufferAttribute(colors, 3));
  geometry.setAttribute('bakedLight', new THREE.BufferAttribute(new Float32Array(count * 3), 3));
  geometry.setAttribute('flicker', new THREE.BufferAttribute(new Float32Array(count * 2), 2));
  geometry.setAttribute('node', new THREE.BufferAttribute(node, 1));
  geometry.setAttribute('sculpt', new THREE.BufferAttribute(sculpt, 3));
  geometry.setIndex(index);
  geometry.boundingSphere = new THREE.Sphere(new THREE.Vector3(), 1e6);
  return geometry;
}

// ---------------------------------------------------------------------------------------------------------------
// Painted detail: cracks (and the race), streaks
// ---------------------------------------------------------------------------------------------------------------

export const CRACK_COUNT = 64;
export const STREAK_COUNT = 12;

function mulberry(seed) {
  let s = seed >>> 0 || 1;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function segmentsOf(meta, prefix, from, to, widthKey, fallbackWidth) {
  const out = [];
  for (const p of (meta && meta.creature && meta.creature.parts) || []) {
    if (!p.name.startsWith(prefix)) continue;
    const a = p.attributes || {};
    if (Array.isArray(a[from]) && Array.isArray(a[to])) out.push([a[from][0], a[from][1], a[to][0], a[to][1], num(a[widthKey], fallbackWidth)]);
  }
  return out;
}

/**
 * The race: cracks that run out across the mask in the jumpscare, branching from the rig's cracks and the slit. A
 * seeded random walk from points along the existing cracks, each branch 3-5 segments heading away from the face's
 * centre; every segment carries when (0..1 of the race) it starts to grow.
 */
export function raceCracks(base, spec, seed = 8517) {
  const random = mulberry(seed);
  const out = [];
  const starts = [];
  for (const s of base) if (s[4] >= 0.008) starts.push([s[0], s[1]], [(s[0] + s[2]) / 2, (s[1] + s[3]) / 2]);
  starts.push([spec.slitHalf * 0.95, slitCurve(spec, spec.slitHalf * 0.95)], [-spec.slitHalf * 0.9, spec.slitY], [0.02, spec.slitY]);
  const f = sculptFunctions(spec);
  const branches = Math.min(starts.length, 11);
  for (let b = 0; b < branches; b++) {
    const start = starts[Math.floor((b / branches) * starts.length)];
    let [x, y] = start;
    let heading = Math.atan2(y + 0.1, x + (random() - 0.5) * 0.2) + (random() - 0.5) * 1.2;
    const t0 = 0.05 + 0.55 * (b / branches) + random() * 0.08;
    const steps = 4 + Math.floor(random() * 4);
    let t = t0;
    for (let k = 0; k < steps; k++) {
      heading += (random() - 0.5) * 1.4;
      const length = 0.025 + random() * 0.045;
      let nx = x + Math.cos(heading) * length;
      let ny = y + Math.sin(heading) * length;
      ny = Math.max(spec.chinY + 0.03, Math.min(spec.top - 0.03, ny));
      // it runs out to the rim and stops there
      const limit = (nx < 0 ? f.left(ny) : f.right(ny)) * 0.97;
      const atRim = Math.abs(nx) >= limit;
      if (atRim) nx = Math.sign(nx) * limit;
      const dt = 0.07 + random() * 0.05;
      out.push({ seg: [x, y, nx, ny, 0.0028 * (1 - k / (steps + 1)) + 0.0012], at: t, grow: dt });
      t += dt * 0.8;
      x = nx;
      y = ny;
      if (atRim) break;
    }
  }
  return out;
}

/**
 * Every painted crack: [x0, y0, x1, y1] and [width, appearsAt, growSeconds-share]: the rig's (always there: at 0) and
 * the race's, padded to CRACK_COUNT with segments far off the mask.
 */
export function crackSegments(meta, spec) {
  const base = segmentsOf(meta, 'MaskCrack', 'CrackFrom', 'CrackTo', 'CrackWidth', 0.006);
  const out = base.map((s) => ({ seg: s.slice(0, 4), width: s[4], at: 0, grow: 0 }));
  for (const r of raceCracks(base, spec || maskSpec(meta))) out.push({ seg: r.seg.slice(0, 4), width: r.seg[4], at: r.at, grow: r.grow });
  while (out.length < CRACK_COUNT) out.push({ seg: [9, 9, 9, 9], width: 0, at: 2, grow: 1 });
  return { list: out.slice(0, CRACK_COUNT), base: Math.min(base.length, CRACK_COUNT) };
}

/** The weeping streaks: [x0, y0, x1, y1, width], padded to STREAK_COUNT. */
export function streakSegments(meta) {
  const out = segmentsOf(meta, 'MaskStreak', 'StreakFrom', 'StreakTo', 'StreakWidth', 0.012);
  while (out.length < STREAK_COUNT) out.push([9, 9, 9, 9, 0]);
  return out.slice(0, STREAK_COUNT);
}

// ---------------------------------------------------------------------------------------------------------------
// The glaze's detail map (Max)
// ---------------------------------------------------------------------------------------------------------------

let detail = null;

/**
 * A tileable 256 x 256 detail map for the glaze: rg the normal's tilt (crazing: a fine network of hairline cells in
 * the glaze, sunk; pitting: tiny pocks), b the crazing lines (grime gathers in them), a a soft grime noise.
 */
export function detailTexture() {
  if (detail) return detail;
  const size = 256;
  const random = mulberry(91);
  const cells = 9;
  const pts = [];
  for (let j = 0; j < cells; j++) for (let i = 0; i < cells; i++) pts.push([(i + 0.15 + 0.7 * random()) / cells, (j + 0.15 + 0.7 * random()) / cells]);
  const height = new Float32Array(size * size);
  const lines = new Float32Array(size * size);
  const noise = new Float32Array(size * size);
  const lattice = 8;
  const grid = [];
  for (let k = 0; k < lattice * lattice; k++) grid.push(random());
  const lerp = (a, b, t) => a + (b - a) * t;
  const fade = (t) => t * t * (3 - 2 * t);
  const g = (a, b) => grid[(((b % lattice) + lattice) % lattice) * lattice + (((a % lattice) + lattice) % lattice)];
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const u = (x + 0.5) / size;
      const v = (y + 0.5) / size;
      // crazing: the distance to the nearest Voronoi edge (second nearest minus nearest), one point per cell, tiled
      const ci = Math.floor(u * cells);
      const cj = Math.floor(v * cells);
      let d1 = 9;
      let d2 = 9;
      for (let oj = -1; oj <= 1; oj++) {
        for (let oi = -1; oi <= 1; oi++) {
          const i = ci + oi;
          const j = cj + oj;
          const wi = ((i % cells) + cells) % cells;
          const wj = ((j % cells) + cells) % cells;
          const p = pts[wj * cells + wi];
          const dx = u - (p[0] + (i - wi) / cells);
          const dy = v - (p[1] + (j - wj) / cells);
          const d = dx * dx + dy * dy;
          if (d < d1) {
            d2 = d1;
            d1 = d;
          } else if (d < d2) d2 = d;
        }
      }
      const edge = Math.sqrt(d2) - Math.sqrt(d1);
      const line = Math.max(0, 1 - edge / 0.006);
      const o = y * size + x;
      lines[o] = line;
      height[o] = -0.6 * line * line;
      const gx = u * lattice;
      const gy = v * lattice;
      const ix = Math.floor(gx);
      const iy = Math.floor(gy);
      noise[o] = lerp(lerp(g(ix, iy), g(ix + 1, iy), fade(gx - ix)), lerp(g(ix, iy + 1), g(ix + 1, iy + 1), fade(gx - ix)), fade(gy - iy));
    }
  }
  // pitting: tiny pocks stamped into the glaze
  for (let k = 0; k < 260; k++) {
    const px = random() * size;
    const py = random() * size;
    const r = (0.003 + random() * 0.006) * size;
    const depth = 0.4 + random() * 0.6;
    for (let y = Math.floor(py - r); y <= Math.ceil(py + r); y++) {
      for (let x = Math.floor(px - r); x <= Math.ceil(px + r); x++) {
        const r2 = ((x + 0.5 - px) ** 2 + (y + 0.5 - py) ** 2) / (r * r);
        if (r2 >= 1) continue;
        height[(((y % size) + size) % size) * size + (((x % size) + size) % size)] -= depth * (1 - r2) * (1 - r2);
      }
    }
  }
  const data = new Uint8Array(size * size * 4);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const o = y * size + x;
      const hx = height[y * size + ((x + 1) % size)] - height[y * size + ((x + size - 1) % size)];
      const hy = height[((y + 1) % size) * size + x] - height[((y + size - 1) % size) * size + x];
      data[o * 4] = Math.round(Math.max(0, Math.min(255, 128 - hx * 140)));
      data[o * 4 + 1] = Math.round(Math.max(0, Math.min(255, 128 - hy * 140)));
      data[o * 4 + 2] = Math.round(lines[o] * 255);
      data[o * 4 + 3] = Math.round(noise[o] * 255);
    }
  }
  const tex = new THREE.DataTexture(data, size, size, THREE.RGBAFormat);
  tex.wrapS = THREE.RepeatWrapping;
  tex.wrapT = THREE.RepeatWrapping;
  tex.magFilter = THREE.LinearFilter;
  tex.minFilter = THREE.LinearMipmapLinearFilter;
  tex.generateMipmaps = true;
  tex.needsUpdate = true;
  detail = tex;
  return tex;
}

// ---------------------------------------------------------------------------------------------------------------
// The jumpscare on the mask
// ---------------------------------------------------------------------------------------------------------------

/**
 * The Lunge's timeline on the mask, `elapsed` seconds after it starts (MONSTER-LOOK.md, "The jumpscare"):
 *   snap and tilt 0-0.15; the cracks race across it 0.12-0.5 (race 0..1); the slit tears open into the maw
 *   0.36-0.78 (tear 0..1, a jolt at 0.36), shards breaking off at 0.4 (`shatter`: the moment, once); thin strands
 *   stretch across the opening 0.5-1.35 (strands 0..1); the right pupil dilates 0.62-0.9 (dilate 0..1). Everything
 *   holds to the end of the hold and lets go in the release.
 * @returns {{race: number, tear: number, strands: number, dilate: number, focus: number, shatter: boolean}}
 */
export function maskFx(elapsed, total = Infinity) {
  if (!(elapsed >= 0) || elapsed > total) return { race: 0, tear: 0, strands: 0, dilate: 0, focus: 0, shatter: false };
  const release = Number.isFinite(total) ? 1 - smooth(total - 0.45, total, elapsed) : 1;
  const race = smooth(0.12, 0.5, elapsed);
  const jolt = elapsed >= 0.36 ? Math.min(1, 0.35 + 0.65 * smooth(0.36, 0.78, elapsed)) : 0;
  return {
    race: race * release,
    tear: jolt * release,
    strands: smooth(0.46, 1.35, elapsed) * release,
    dilate: smooth(0.62, 0.9, elapsed) * release,
    // the room's light falls away from the mask as it snaps in (the jumpscare's own light models it)
    focus: smooth(0, 0.12, elapsed) * release,
    shatter: elapsed >= 0.4,
  };
}
