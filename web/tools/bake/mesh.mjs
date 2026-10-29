// Part tessellation for the bake: Roblox parts (Block, Wedge, CornerWedge, Cylinder, Ball) to triangle faces in
// world space, with studs-based UVs, flat or smooth normals, large faces subdivided into a grid so vertex lighting can
// hold a pool of light, and cells hidden inside other solid parts culled.
//
// Conventions (Roblox): a CFrame is [x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22]; world = p + R * local.
// A WedgePart's slope runs from its top back edge (y = +h/2, z = +d/2) down to its bottom front edge (y = -h/2,
// z = -d/2); a Cylinder's axis is local X with diameter min(Y, Z); a Ball's diameter is min(X, Y, Z).

/** @typedef {{ p: number[], n: number[], uv: number[] }} Vert */

/**
 * @param {number[]} c CFrame components
 * @param {number} x @param {number} y @param {number} z local point
 * @returns {number[]}
 */
export function cfPoint(c, x, y, z) {
  return [
    c[0] + c[3] * x + c[4] * y + c[5] * z,
    c[1] + c[6] * x + c[7] * y + c[8] * z,
    c[2] + c[9] * x + c[10] * y + c[11] * z,
  ];
}

/** Rotates a local direction. */
export function cfVector(c, x, y, z) {
  return [c[3] * x + c[4] * y + c[5] * z, c[6] * x + c[7] * y + c[8] * z, c[9] * x + c[10] * y + c[11] * z];
}

/** World point -> local (rotation is orthonormal: local = R^T (p - t)). */
export function cfToLocal(c, px, py, pz) {
  const dx = px - c[0];
  const dy = py - c[1];
  const dz = pz - c[2];
  return [
    c[3] * dx + c[6] * dy + c[9] * dz,
    c[4] * dx + c[7] * dy + c[10] * dz,
    c[5] * dx + c[8] * dy + c[11] * dz,
  ];
}

/** a * b for CFrames. */
export function cfMul(a, b) {
  const p = cfPoint(a, b[0], b[1], b[2]);
  const r = [];
  for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      r.push(a[3 + i * 3] * b[3 + j] + a[3 + i * 3 + 1] * b[6 + j] + a[3 + i * 3 + 2] * b[9 + j]);
    }
  }
  return [p[0], p[1], p[2], ...r];
}

/** Inverse of a rigid CFrame. */
export function cfInverse(c) {
  // R^T and -R^T t
  const r = [c[3], c[6], c[9], c[4], c[7], c[10], c[5], c[8], c[11]];
  const t = [
    -(r[0] * c[0] + r[1] * c[1] + r[2] * c[2]),
    -(r[3] * c[0] + r[4] * c[1] + r[5] * c[2]),
    -(r[6] * c[0] + r[7] * c[1] + r[8] * c[2]),
  ];
  return [t[0], t[1], t[2], ...r];
}

const norm = (v) => {
  const l = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / l, v[1] / l, v[2] / l];
};

/**
 * Flat faces of a box-like part in local space. Each face: { kind: 'quad'|'tri', origin, u, v, du, dv, n } for a
 * quad centred on `origin` spanning du along u and dv along v; triangles carry three corners `t` plus the u / v axes
 * for the UV projection.
 */
function blockFaces(sx, sy, sz) {
  const hx = sx / 2;
  const hy = sy / 2;
  const hz = sz / 2;
  return [
    { kind: 'quad', origin: [hx, 0, 0], n: [1, 0, 0], u: [0, 0, -1], v: [0, 1, 0], du: sz, dv: sy, face: 'Right' },
    { kind: 'quad', origin: [-hx, 0, 0], n: [-1, 0, 0], u: [0, 0, 1], v: [0, 1, 0], du: sz, dv: sy, face: 'Left' },
    { kind: 'quad', origin: [0, hy, 0], n: [0, 1, 0], u: [1, 0, 0], v: [0, 0, -1], du: sx, dv: sz, face: 'Top' },
    { kind: 'quad', origin: [0, -hy, 0], n: [0, -1, 0], u: [1, 0, 0], v: [0, 0, 1], du: sx, dv: sz, face: 'Bottom' },
    { kind: 'quad', origin: [0, 0, hz], n: [0, 0, 1], u: [1, 0, 0], v: [0, 1, 0], du: sx, dv: sy, face: 'Back' },
    { kind: 'quad', origin: [0, 0, -hz], n: [0, 0, -1], u: [-1, 0, 0], v: [0, 1, 0], du: sx, dv: sy, face: 'Front' },
  ];
}

function wedgeFaces(sx, sy, sz) {
  const hx = sx / 2;
  const hy = sy / 2;
  const hz = sz / 2;
  const slopeLen = Math.hypot(sy, sz);
  const along = [0, sy / slopeLen, sz / slopeLen];
  const n = norm([0, sz, -sy]);
  return [
    { kind: 'quad', origin: [0, -hy, 0], n: [0, -1, 0], u: [1, 0, 0], v: [0, 0, 1], du: sx, dv: sz, face: 'Bottom' },
    { kind: 'quad', origin: [0, 0, hz], n: [0, 0, 1], u: [1, 0, 0], v: [0, 1, 0], du: sx, dv: sy, face: 'Back' },
    { kind: 'quad', origin: [0, 0, 0], n, u: [-1, 0, 0], v: along, du: sx, dv: slopeLen, face: 'Slope' },
    {
      kind: 'tri',
      t: [
        [hx, -hy, -hz],
        [hx, -hy, hz],
        [hx, hy, hz],
      ],
      n: [1, 0, 0],
      u: [0, 0, -1],
      v: [0, 1, 0],
      face: 'Right',
    },
    {
      kind: 'tri',
      t: [
        [-hx, -hy, hz],
        [-hx, -hy, -hz],
        [-hx, hy, hz],
      ],
      n: [-1, 0, 0],
      u: [0, 0, 1],
      v: [0, 1, 0],
      face: 'Left',
    },
  ];
}

function cornerWedgeFaces(sx, sy, sz) {
  // Apex over the (+x, -z) corner; base is the full bottom.
  const hx = sx / 2;
  const hy = sy / 2;
  const hz = sz / 2;
  const a = [-hx, -hy, -hz];
  const b = [hx, -hy, -hz];
  const c = [hx, -hy, hz];
  const d = [-hx, -hy, hz];
  const top = [hx, hy, -hz];
  const tri = (p, q, r) => {
    const e1 = [q[0] - p[0], q[1] - p[1], q[2] - p[2]];
    const e2 = [r[0] - p[0], r[1] - p[1], r[2] - p[2]];
    const n = norm([e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]]);
    const u = norm(e1);
    const v = norm([n[1] * u[2] - n[2] * u[1], n[2] * u[0] - n[0] * u[2], n[0] * u[1] - n[1] * u[0]]);
    return { kind: 'tri', t: [p, q, r], n, u, v, face: 'Tri' };
  };
  return [
    { kind: 'quad', origin: [0, -hy, 0], n: [0, -1, 0], u: [1, 0, 0], v: [0, 0, 1], du: sx, dv: sz, face: 'Bottom' },
    tri(a, top, b),
    tri(b, top, c),
    tri(c, top, d),
    tri(d, top, a),
  ];
}

/**
 * Emits the triangles of one part. `sink` receives (verts, tris, faceTag) per face grid where verts is a flat list
 * of { p, n, uv } in world space and tris an array of vertex index triples into it.
 *
 * @param {any} part raw part (cf, size, shape)
 * @param {{ maxEdge: number, cull?: (p: number[], n: number[]) => boolean }} opt
 * @param {(verts: Vert[], tris: number[][]) => void} sink
 */
export function tessellatePart(part, opt, sink) {
  const [sx, sy, sz] = part.size;
  const c = part.cf;
  const shape = part.shape;
  if (shape === 'Cylinder') {
    return cylinder(c, sx, Math.min(sy, sz) / 2, opt, sink);
  }
  if (shape === 'Ball') {
    return ball(c, Math.min(sx, sy, sz) / 2, opt, sink);
  }
  const faces = shape === 'Wedge' ? wedgeFaces(sx, sy, sz) : shape === 'CornerWedge' ? cornerWedgeFaces(sx, sy, sz) : blockFaces(sx, sy, sz);
  for (const f of faces) {
    if (f.kind === 'quad') quadFace(c, f, opt, sink);
    else triFace(c, f, opt, sink);
  }
}

function quadFace(c, f, opt, sink) {
  if (f.du < 1e-4 || f.dv < 1e-4) return;
  const nW = norm(cfVector(c, f.n[0], f.n[1], f.n[2]));
  let maxEdge = opt.maxEdge;
  if (opt.edgeFor && (f.du > maxEdge || f.dv > maxEdge)) {
    const at = (a, b) => {
      const l = [
        f.origin[0] + f.u[0] * a + f.v[0] * b,
        f.origin[1] + f.u[1] * a + f.v[1] * b,
        f.origin[2] + f.u[2] * a + f.v[2] * b,
      ];
      return cfPoint(c, l[0], l[1], l[2]);
    };
    maxEdge = opt.edgeFor(at, f.du, f.dv, nW, maxEdge);
  }
  const nu = Math.max(1, Math.ceil(f.du / maxEdge - 1e-6));
  const nv = Math.max(1, Math.ceil(f.dv / maxEdge - 1e-6));
  const verts = [];
  const local = (a, b) => [
    f.origin[0] + f.u[0] * a + f.v[0] * b,
    f.origin[1] + f.u[1] * a + f.v[1] * b,
    f.origin[2] + f.u[2] * a + f.v[2] * b,
  ];
  for (let j = 0; j <= nv; j++) {
    const b = -f.dv / 2 + (f.dv * j) / nv;
    for (let i = 0; i <= nu; i++) {
      const a = -f.du / 2 + (f.du * i) / nu;
      const l = local(a, b);
      // UV: studs along the face axes, measured from the part centre's projection (so a part's faces tile alike)
      const uvU = l[0] * f.u[0] + l[1] * f.u[1] + l[2] * f.u[2];
      const uvV = l[0] * f.v[0] + l[1] * f.v[1] + l[2] * f.v[2];
      verts.push({ p: cfPoint(c, l[0], l[1], l[2]), n: nW, uv: [uvU, uvV] });
    }
  }
  const tris = [];
  const row = nu + 1;
  for (let j = 0; j < nv; j++) {
    for (let i = 0; i < nu; i++) {
      const a = j * row + i;
      const b = a + 1;
      const cc = a + row + 1;
      const d = a + row;
      if (opt.cull && cellHidden(opt.cull, [verts[a].p, verts[b].p, verts[cc].p, verts[d].p], nW)) continue;
      tris.push([a, b, cc], [a, cc, d]);
    }
  }
  if (tris.length) sink(verts, tris, f.face);
}

function triFace(c, f, opt, sink) {
  const [A, B, C] = f.t;
  const edge = Math.max(dist(A, B), dist(B, C), dist(C, A));
  if (edge < 1e-4) return;
  const n = Math.max(1, Math.ceil(edge / opt.maxEdge - 1e-6));
  const nW = norm(cfVector(c, f.n[0], f.n[1], f.n[2]));
  const verts = [];
  const index = [];
  for (let i = 0; i <= n; i++) {
    index.push([]);
    for (let j = 0; j <= n - i; j++) {
      const wa = i / n;
      const wb = j / n;
      const wc = 1 - wa - wb;
      const l = [
        A[0] * wc + B[0] * wa + C[0] * wb,
        A[1] * wc + B[1] * wa + C[1] * wb,
        A[2] * wc + B[2] * wa + C[2] * wb,
      ];
      index[i].push(verts.length);
      const uvU = l[0] * f.u[0] + l[1] * f.u[1] + l[2] * f.u[2];
      const uvV = l[0] * f.v[0] + l[1] * f.v[1] + l[2] * f.v[2];
      verts.push({ p: cfPoint(c, l[0], l[1], l[2]), n: nW, uv: [uvU, uvV] });
    }
  }
  const tris = [];
  for (let i = 0; i < n; i++) {
    for (let j = 0; j < n - i; j++) {
      const a = index[i][j];
      const b = index[i + 1][j];
      const cc = index[i][j + 1];
      tris.push([a, b, cc]);
      if (j < n - i - 1) {
        const d = index[i + 1][j + 1];
        tris.push([b, d, cc]);
      }
    }
  }
  // winding: make the first triangle agree with the face normal
  if (tris.length) {
    const t = tris[0];
    const p0 = verts[t[0]].p;
    const p1 = verts[t[1]].p;
    const p2 = verts[t[2]].p;
    const cr = cross(sub(p1, p0), sub(p2, p0));
    if (cr[0] * nW[0] + cr[1] * nW[1] + cr[2] * nW[2] < 0) {
      for (const tt of tris) {
        const s = tt[1];
        tt[1] = tt[2];
        tt[2] = s;
      }
    }
  }
  const kept = opt.cull ? tris.filter((t) => !cellHidden(opt.cull, [verts[t[0]].p, verts[t[1]].p, verts[t[2]].p], nW)) : tris;
  if (kept.length) sink(verts, kept, f.face);
}

function cylinder(c, length, r, opt, sink) {
  if (r < 1e-4 || length < 1e-4) return;
  const circ = 2 * Math.PI * r;
  const segs = Math.max(6, Math.min(24, Math.round(circ / 0.9)));
  const nl = Math.max(1, Math.ceil(length / opt.maxEdge - 1e-6));
  // side
  const verts = [];
  for (let j = 0; j <= nl; j++) {
    const x = -length / 2 + (length * j) / nl;
    for (let i = 0; i <= segs; i++) {
      const a = (i / segs) * Math.PI * 2;
      const cy = Math.cos(a);
      const cz = Math.sin(a);
      verts.push({ p: cfPoint(c, x, cy * r, cz * r), n: norm(cfVector(c, 0, cy, cz)), uv: [a * r, x] });
    }
  }
  const tris = [];
  const row = segs + 1;
  for (let j = 0; j < nl; j++) {
    for (let i = 0; i < segs; i++) {
      const a = j * row + i;
      const b = a + 1;
      const cc = a + row + 1;
      const d = a + row;
      // outward winding: (a, d, cc), (a, cc, b) for this parametrisation
      tris.push([a, cc, d], [a, b, cc]);
    }
  }
  fixWinding(verts, tris);
  sink(verts, tris, 'Side');
  // caps
  for (const side of [1, -1]) {
    const rings = Math.max(1, Math.ceil(r / opt.maxEdge - 1e-6));
    const capVerts = [];
    const n = norm(cfVector(c, side, 0, 0));
    capVerts.push({ p: cfPoint(c, (side * length) / 2, 0, 0), n, uv: [0, 0] });
    for (let k = 1; k <= rings; k++) {
      const rr = (r * k) / rings;
      for (let i = 0; i < segs; i++) {
        const a = (i / segs) * Math.PI * 2;
        capVerts.push({ p: cfPoint(c, (side * length) / 2, Math.cos(a) * rr, Math.sin(a) * rr), n, uv: [Math.cos(a) * rr, Math.sin(a) * rr] });
      }
    }
    const capTris = [];
    for (let i = 0; i < segs; i++) capTris.push([0, 1 + i, 1 + ((i + 1) % segs)]);
    for (let k = 1; k < rings; k++) {
      const inner = 1 + (k - 1) * segs;
      const outer = 1 + k * segs;
      for (let i = 0; i < segs; i++) {
        const i2 = (i + 1) % segs;
        capTris.push([inner + i, outer + i, outer + i2], [inner + i, outer + i2, inner + i2]);
      }
    }
    fixWindingFlat(capVerts, capTris, n);
    const kept = opt.cull ? capTris.filter((t) => !cellHidden(opt.cull, [capVerts[t[0]].p, capVerts[t[1]].p, capVerts[t[2]].p], n)) : capTris;
    if (kept.length) sink(capVerts, kept, side > 0 ? 'Right' : 'Left');
  }
}

function ball(c, r, opt, sink) {
  if (r < 1e-4) return;
  const circ = 2 * Math.PI * r;
  const lon = Math.max(8, Math.min(20, Math.round(circ / 0.9)));
  const lat = Math.max(4, Math.round(lon / 2));
  const verts = [];
  for (let j = 0; j <= lat; j++) {
    const th = (j / lat) * Math.PI;
    for (let i = 0; i <= lon; i++) {
      const ph = (i / lon) * Math.PI * 2;
      const x = Math.sin(th) * Math.cos(ph);
      const y = Math.cos(th);
      const z = Math.sin(th) * Math.sin(ph);
      verts.push({ p: cfPoint(c, x * r, y * r, z * r), n: norm(cfVector(c, x, y, z)), uv: [ph * r, th * r] });
    }
  }
  const tris = [];
  const row = lon + 1;
  for (let j = 0; j < lat; j++) {
    for (let i = 0; i < lon; i++) {
      const a = j * row + i;
      const b = a + 1;
      const cc = a + row + 1;
      const d = a + row;
      if (j > 0) tris.push([a, b, cc]);
      if (j < lat - 1) tris.push([a, cc, d]);
    }
  }
  fixWinding(verts, tris);
  sink(verts, tris, 'Ball');
}

// Smooth shapes: flip any triangle whose geometric normal disagrees with its vertex normals.
function fixWinding(verts, tris) {
  for (const t of tris) {
    const p0 = verts[t[0]].p;
    const cr = cross(sub(verts[t[1]].p, p0), sub(verts[t[2]].p, p0));
    const n = verts[t[0]].n;
    const m = verts[t[1]].n;
    const sn = [n[0] + m[0], n[1] + m[1], n[2] + m[2]];
    if (cr[0] * sn[0] + cr[1] * sn[1] + cr[2] * sn[2] < 0) {
      const s = t[1];
      t[1] = t[2];
      t[2] = s;
    }
  }
}

function fixWindingFlat(verts, tris, n) {
  for (const t of tris) {
    const p0 = verts[t[0]].p;
    const cr = cross(sub(verts[t[1]].p, p0), sub(verts[t[2]].p, p0));
    if (cr[0] * n[0] + cr[1] * n[1] + cr[2] * n[2] < 0) {
      const s = t[1];
      t[1] = t[2];
      t[2] = s;
    }
  }
}

// A face cell is hidden when its centre and every corner (pulled 5% toward the centre and lifted off the face) lie
// inside other solid parts.
function cellHidden(cull, corners, n) {
  const k = corners.length;
  const ctr = [0, 0, 0];
  for (const p of corners) {
    ctr[0] += p[0] / k;
    ctr[1] += p[1] / k;
    ctr[2] += p[2] / k;
  }
  const lift = 0.03;
  const test = (p) => cull([p[0] + n[0] * lift, p[1] + n[1] * lift, p[2] + n[2] * lift]);
  if (!test(ctr)) return false;
  for (const p of corners) {
    const q = [p[0] + (ctr[0] - p[0]) * 0.05, p[1] + (ctr[1] - p[1]) * 0.05, p[2] + (ctr[2] - p[2]) * 0.05];
    if (!test(q)) return false;
  }
  return true;
}

const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);

/**
 * Coarse triangles of a part for the collision / shadow BVH (no subdivision, no culling): flat Float32 positions.
 * @param {any} part
 * @param {number[]} out flat xyz list (appended)
 */
export function coarseTriangles(part, out) {
  tessellatePart(part, { maxEdge: 1e9 }, (verts, tris) => {
    for (const t of tris) {
      for (const i of t) out.push(verts[i].p[0], verts[i].p[1], verts[i].p[2]);
    }
  });
}

/**
 * Solid index: answers "is this world point inside a solid part" for face culling and for nudging light samples out
 * of walls. Blocks and wedges only (cylinders and balls never hide anything).
 */
export class SolidIndex {
  /** @param {any[]} solids parts @param {number} cell grid cell size */
  constructor(solids, cell = 4) {
    this.cell = cell;
    this.grid = new Map();
    this.solids = solids;
    solids.forEach((s, i) => {
      const [lo, hi] = partAabb(s);
      s._lo = lo;
      s._hi = hi;
      const x0 = Math.floor(lo[0] / cell);
      const x1 = Math.floor(hi[0] / cell);
      const y0 = Math.floor(lo[1] / cell);
      const y1 = Math.floor(hi[1] / cell);
      const z0 = Math.floor(lo[2] / cell);
      const z1 = Math.floor(hi[2] / cell);
      for (let x = x0; x <= x1; x++)
        for (let y = y0; y <= y1; y++)
          for (let z = z0; z <= z1; z++) {
            const key = `${x},${y},${z}`;
            let list = this.grid.get(key);
            if (!list) this.grid.set(key, (list = []));
            list.push(i);
          }
    });
  }

  /** @param {number[]} p @param {any} [except] part to ignore @returns {boolean} */
  inside(p, except) {
    const key = `${Math.floor(p[0] / this.cell)},${Math.floor(p[1] / this.cell)},${Math.floor(p[2] / this.cell)}`;
    const list = this.grid.get(key);
    if (!list) return false;
    for (const i of list) {
      const s = this.solids[i];
      if (s === except) continue;
      if (p[0] < s._lo[0] || p[1] < s._lo[1] || p[2] < s._lo[2] || p[0] > s._hi[0] || p[1] > s._hi[1] || p[2] > s._hi[2]) continue;
      if (pointInPart(s, p)) return true;
    }
    return false;
  }
}

const IN_EPS = 0.005;

/** Point-in-part test for blocks and wedges. */
export function pointInPart(s, p) {
  const l = cfToLocal(s.cf, p[0], p[1], p[2]);
  const hx = s.size[0] / 2 + IN_EPS;
  const hy = s.size[1] / 2 + IN_EPS;
  const hz = s.size[2] / 2 + IN_EPS;
  if (Math.abs(l[0]) > hx || Math.abs(l[1]) > hy || Math.abs(l[2]) > hz) return false;
  if (s.shape === 'Wedge') {
    // below the slope plane through the centre with normal (0, sz, -sy)
    const d = l[1] * s.size[2] - l[2] * s.size[1];
    return d <= IN_EPS * Math.hypot(s.size[1], s.size[2]);
  }
  return true;
}

/** World AABB of a part. */
export function partAabb(part) {
  const c = part.cf;
  const [sx, sy, sz] = part.size;
  const ex = (Math.abs(c[3]) * sx + Math.abs(c[4]) * sy + Math.abs(c[5]) * sz) / 2;
  const ey = (Math.abs(c[6]) * sx + Math.abs(c[7]) * sy + Math.abs(c[8]) * sz) / 2;
  const ez = (Math.abs(c[9]) * sx + Math.abs(c[10]) * sy + Math.abs(c[11]) * sz) / 2;
  return [
    [c[0] - ex, c[1] - ey, c[2] - ez],
    [c[0] + ex, c[1] + ey, c[2] + ez],
  ];
}

/**
 * A decal quad on one face of a part (a SurfaceGui's canvas): `lift` studs off the face, subdivided like a face so
 * vertex light can vary across it. UVs are canvas coordinates in [0, 1], u to the right and v down as Roblox draws
 * a SurfaceGui (Front: right = -X; Back: +X; Right: -Z; Left: +Z; Top: +X with down = +Z; Bottom: +X, down = -Z).
 *
 * @param {any} part @param {string} faceName NormalId name @param {number} maxEdge @param {number} lift
 * @param {(verts: Vert[], tris: number[][]) => void} sink
 */
export function decalFace(part, faceName, maxEdge, lift, sink) {
  const f = blockFaces(part.size[0], part.size[1], part.size[2]).find((x) => x.face === faceName);
  if (!f || f.du < 1e-4 || f.dv < 1e-4) return;
  const c = part.cf;
  const nW = norm(cfVector(c, f.n[0], f.n[1], f.n[2]));
  const nu = Math.max(1, Math.ceil(f.du / maxEdge - 1e-6));
  const nv = Math.max(1, Math.ceil(f.dv / maxEdge - 1e-6));
  const verts = [];
  for (let j = 0; j <= nv; j++) {
    const b = -f.dv / 2 + (f.dv * j) / nv;
    for (let i = 0; i <= nu; i++) {
      const a = -f.du / 2 + (f.du * i) / nu;
      const l = [
        f.origin[0] + f.u[0] * a + f.v[0] * b + f.n[0] * lift,
        f.origin[1] + f.u[1] * a + f.v[1] * b + f.n[1] * lift,
        f.origin[2] + f.u[2] * a + f.v[2] * b + f.n[2] * lift,
      ];
      verts.push({ p: cfPoint(c, l[0], l[1], l[2]), n: nW, uv: [(a + f.du / 2) / f.du, (f.dv / 2 - b) / f.dv] });
    }
  }
  const tris = [];
  const row = nu + 1;
  for (let j = 0; j < nv; j++) {
    for (let i = 0; i < nu; i++) {
      const a = j * row + i;
      tris.push([a, a + 1, a + row + 1], [a, a + row + 1, a + row]);
    }
  }
  sink(verts, tris, faceName);
}

/** Size in studs of a part face (canvas width, height), as SurfaceArt.faceStuds. */
export function faceStuds(size, faceName) {
  if (faceName === 'Front' || faceName === 'Back') return [size[0], size[1]];
  if (faceName === 'Left' || faceName === 'Right') return [size[2], size[1]];
  return [size[0], size[2]];
}
