// Rovloc Web world data: the JSDoc types of the baked world (web/tools/bake.mjs writes it, everything else reads it)
// and the browser decoder for its binary buffers. See web/DATA.md for the format.
//
// The bake writes two files: `world.json` (metadata: levels, materials, lights, flicker groups, chunk table,
// entities, anchors, triggers, rooms, graphs, creature, film) and `world.bin` (every vertex / index / probe stream,
// quantised). build.mjs gzips + base64-inlines both; at boot the engine inflates world.bin (DecompressionStream) and
// calls decodeWorld(meta, bin), which returns ready-to-upload typed arrays:
//
//   chunk.attributes.position   Float32Array  xyz        world studs (entity / creature chunks: their node's space)
//   chunk.attributes.normal     Int8Array     xyz        normalized (value / 127)
//   chunk.attributes.uv         Float32Array  uv         studs along the face (texture repeat = uv / studsPerTile)
//   chunk.attributes.color      Uint8Array    rgb        normalized sRGB part colour (albedo tint)
//   chunk.attributes.bakedLight Uint16Array   rgb        normalized: linear baked light / LIGHT_SCALE (x4 in GLSL)
//   chunk.attributes.flicker    Uint8Array    (g, s)     NOT normalized: flicker group id (0 = steady), share 0..255
//   chunk.attributes.alpha      Uint8Array    a          transparent chunks only: 1 - Transparency (normalized)
//   chunk.index                 Uint16Array              triangle list
//
// Each attribute is { array, itemSize, normalized }, so `new THREE.BufferAttribute(a.array, a.itemSize,
// a.normalized)` builds it. Baked light on disk is sqrt-encoded bytes (dark tones keep their precision); the decoder
// expands it to 16-bit linear so shaders read `bakedLight * 4.0`.

/** Format version written by bake.mjs and checked by decodeWorld. */
export const FORMAT_VERSION = 2;

/** Baked light range: stored value 1.0 means LIGHT_SCALE Roblox light units. */
export const LIGHT_SCALE = 4;

/** UV quantisation: stored Int16 = round(uv * UV_SCALE) (1/64 stud). */
export const UV_SCALE = 64;

/** Stream element types. */
export const STREAM_TYPES = {
  pos: 'u16', // quantised positions (chunk.quant: origin + q * scale), delta-coded per chunk and component
  nrm: 'i8',
  uv: 'i16', // delta-coded per chunk and component (as u16 wrap-around)
  col: 'u8',
  lit: 'u8', // sqrt-encoded baked light: byte = 255 * sqrt(L / LIGHT_SCALE), delta-coded per chunk (u8 wrap)
  flk: 'u8', // (group, share) pairs
  idx: 'u16', // triangle-delta coded per chunk: (a - previous a, b - a, c - a), u16 wrap-around
  cpos: 'u16', // collision positions (per level quant), delta-coded
  cidx: 'u32', // triangle-delta coded per level (u32 wrap-around)
  probe: 'u8', // sqrt-encoded probe irradiance
  bone: 'u8', // creature chunks: Motor6D bone index per vertex (meta.creature.bones order)
  alpha: 'u8', // transparent chunks: 1 - Transparency per vertex (normalized)
};

// ---------------------------------------------------------------------------------------------------------------
// Delta coding (gzip then finds the regular face grids): exact, wrap-around arithmetic in the element width.
// ---------------------------------------------------------------------------------------------------------------

/**
 * In place: values -> deltas from the previous element of the same component (`stride` interleaved components).
 * @param {Uint8Array|Uint16Array|Int16Array|Uint32Array} a @param {number} stride @param {number} mask element mask
 */
export function deltaEncode(a, stride, mask) {
  for (let i = a.length - 1; i >= stride; i--) a[i] = (a[i] - a[i - stride]) & mask;
  return a;
}

/** In place: inverse of deltaEncode. */
export function deltaDecode(a, stride, mask) {
  for (let i = stride; i < a.length; i++) a[i] = (a[i] + a[i - stride]) & mask;
  return a;
}

/** In place: triangle list -> (a - previous a, b - a, c - a), wrapped to `mask`. */
export function triEncode(idx, mask) {
  let prev = 0;
  for (let t = 0; t < idx.length; t += 3) {
    const a = idx[t];
    const b = idx[t + 1];
    const c = idx[t + 2];
    idx[t] = (a - prev) & mask;
    idx[t + 1] = (b - a) & mask;
    idx[t + 2] = (c - a) & mask;
    prev = a;
  }
  return idx;
}

/** In place: inverse of triEncode. */
export function triDecode(idx, mask) {
  let prev = 0;
  for (let t = 0; t < idx.length; t += 3) {
    const a = (prev + idx[t]) & mask;
    idx[t] = a;
    idx[t + 1] = (a + idx[t + 1]) & mask;
    idx[t + 2] = (a + idx[t + 2]) & mask;
    prev = a;
  }
  return idx;
}


const ARRAY_TYPES = {
  u8: Uint8Array,
  i8: Int8Array,
  u16: Uint16Array,
  i16: Int16Array,
  u32: Uint32Array,
  f32: Float32Array,
};

/**
 * @typedef {[number, number, number, number, number, number, number, number, number, number, number, number]} CFrameArray
 * A Roblox CFrame as its GetComponents(): x, y, z, R00, R01, R02, R10, R11, R12, R20, R21, R22 (world = p + R * local).
 */

/**
 * @typedef {object} StreamRef
 * @property {number} offset byte offset into world.bin
 * @property {number} length element count
 * @property {string} type   'u8' | 'i8' | 'u16' | 'i16' | 'u32' | 'f32'
 */

/**
 * @typedef {object} ChunkMeta
 * @property {number} id
 * @property {string} level        level key (LevelId, "Lobby", "Stairwells", "Exterior")
 * @property {'opaque'|'transparent'|'emissive'|'decal'} bucket  decal: alpha-blended SurfaceGui quads (atlas UVs)
 * @property {number} [uvScale]    UV quantisation of this chunk (decals: 8192, atlas UVs in 0..1; default UV_SCALE)
 * @property {string} material     key into meta.materials
 * @property {'static'|'entity'|'creature'} kind
 * @property {EntityRange[]} [ranges] entity chunks: the contiguous vertex range of every (entity, node) in the chunk
 * @property {number} [boneOffset] creature chunks: element offset of the per-vertex bone index in the `bone` stream
 * @property {number} [alphaOffset] transparent chunks: element offset of their per-vertex alpha in the `alpha` stream
 * @property {number} vertexOffset vertex index into the streams
 * @property {number} vertexCount
 * @property {number} indexOffset  index element offset into the idx stream
 * @property {number} indexCount
 * @property {[number, number, number, number, number, number]} quant origin xyz + scale xyz for positions
 * @property {[number, number, number, number, number, number]} aabb min xyz, max xyz (world for static chunks)
 */

/**
 * @typedef {object} EntityRange
 * @property {number} entity index into meta.entities
 * @property {string} node   entity node path ("" = parts that move with the entity pivot)
 * @property {number} start  first vertex (within the chunk)
 * @property {number} count
 */

/**
 * @typedef {object} Attribute
 * @property {Float32Array|Int8Array|Uint8Array|Uint16Array} array
 * @property {number} itemSize
 * @property {boolean} normalized
 */

/**
 * @typedef {ChunkMeta & { attributes: Record<string, Attribute>, index: Uint16Array }} Chunk
 */

/**
 * @typedef {object} LevelInfo
 * @property {[number, number, number]} origin  level origin (world studs)
 * @property {number} elevation  floor Y
 * @property {number|null} height default ceiling height
 * @property {[number, number, number, number, number, number]} aabb  min xyz, max xyz of its static geometry
 * @property {string} film       key into meta.film.levels
 */

/**
 * @typedef {object} MaterialInfo
 * @property {string} material   Roblox material name (Concrete, Neon, ...)
 * @property {string|null} texture generated texture id (meta.textures key) or null
 * @property {number} studsPerTile texture repeat in studs
 * @property {number} roughness
 * @property {number} metalness
 * @property {number} reflectance
 * @property {boolean} emissive  Neon: self-lit in its part colour
 * @property {boolean} glass     Glass (windows, water, bulbs)
 */

/**
 * @typedef {object} LightInfo
 * @property {string} id        fixture name (e.g. L1_Light_ClassroomGlow) or Moon_<window>
 * @property {string|null} kind LightKind (Fluorescent, Bulb, EmergencyRed, ExitSign, BoilerGlow, ClassroomGlow,
 *                              Floodlight, Moonlight, ...)
 * @property {'point'|'spot'|'surface'} cls
 * @property {[number, number, number]} pos     emitter centre
 * @property {[number, number, number]|null} dir emitting direction (spot / surface)
 * @property {number|null} angle                full cone angle in degrees (spot / surface)
 * @property {[number, number, number]} color   sRGB 0..1
 * @property {number} brightness  Roblox Brightness as baked (0 = dark at start)
 * @property {number} range
 * @property {boolean} shadows
 * @property {boolean} broken     dark at the start of a run
 * @property {boolean} baked      included in the vertex light
 * @property {number} group       flicker group id (0 = steady)
 * @property {string|null} level  LevelId / Lobby
 * @property {string|null} room   ZoneId
 * @property {number|null} entity entity index when the light belongs to an entity
 */

/**
 * @typedef {object} FlickerGroup
 * @property {number} id
 * @property {string|null} name   the Roblox FlickerGroup (flicker is a pure function of (seed, name, time)), or
 *                                "Scripted:<owner>" for lights a scene drives (Floodlights, ClassroomGlow)
 * @property {'steady'|'flicker'|'scripted'} kind
 * @property {number} initial     level at the start of a run (0: the pool floodlights before the switch)
 * @property {number[]} lights    indices into meta.lights
 */

/**
 * @typedef {object} ProbeGrid
 * @property {[number, number, number]} origin  world position of probe (0, 0, 0)
 * @property {[number, number, number]} dims    nx, ny, nz
 * @property {number} spacing studs between probes
 * @property {Float32Array} data linear RGB irradiance; probe (x, y, z) is at element ((y * nz + z) * nx + x) * 3
 *                         (without the scripted groups' light)
 * @property {{ group: number, data: Float32Array }[]} groups extra irradiance of each scripted flicker group that
 *                         reaches the level (the pool floodlights, the classroom glow): add level[group] x data
 */

/**
 * @typedef {object} WorldData
 * @property {any} meta        world.json as parsed
 * @property {Chunk[]} chunks  every render chunk (static, entity and creature)
 * @property {Record<string, { position: Float32Array, index: Uint32Array }>} collision per level key
 * @property {Record<string, ProbeGrid>} probes per level key
 */

/**
 * Typed view of one stream.
 * @param {ArrayBuffer} bin
 * @param {StreamRef} ref
 */
export function streamView(bin, ref) {
  const Type = ARRAY_TYPES[ref.type];
  return new Type(bin, ref.offset, ref.length);
}

/** Inverse of the sqrt light encoding: byte -> linear Roblox light units. */
export function decodeLightByte(b) {
  const x = b / 255;
  return x * x * LIGHT_SCALE;
}

/** Linear light -> sqrt-encoded byte (the bake's encoder; exported so tests use the same rule). */
export function encodeLightByte(value) {
  const x = Math.sqrt(Math.max(0, Math.min(1, value / LIGHT_SCALE)));
  return Math.round(x * 255);
}

// byte -> Uint16 normalized linear (65535 * (b / 255)^2)
const LIGHT_LUT = (() => {
  const lut = new Uint16Array(256);
  for (let b = 0; b < 256; b++) lut[b] = Math.round(65535 * (b / 255) * (b / 255));
  return lut;
})();

/**
 * Decodes one chunk's streams into GPU-ready typed arrays.
 * @param {ChunkMeta} c
 * @param {Record<string, any>} s stream views
 * @returns {Chunk}
 */
export function decodeChunk(c, s) {
  const n = c.vertexCount;
  const v0 = c.vertexOffset;
  const [ox, oy, oz, sx, sy, sz] = c.quant;
  const qp = deltaDecode(s.pos.slice(v0 * 3, (v0 + n) * 3), 3, 0xffff);
  const position = new Float32Array(n * 3);
  for (let i = 0; i < n; i++) {
    position[i * 3] = ox + qp[i * 3] * sx;
    position[i * 3 + 1] = oy + qp[i * 3 + 1] * sy;
    position[i * 3 + 2] = oz + qp[i * 3 + 2] * sz;
  }
  const qu = deltaDecode(new Uint16Array(s.uv.buffer, s.uv.byteOffset + v0 * 4, n * 2).slice(), 2, 0xffff);
  const uvSigned = new Int16Array(qu.buffer);
  const uv = new Float32Array(n * 2);
  const uvScale = c.uvScale || UV_SCALE;
  for (let i = 0; i < n * 2; i++) uv[i] = uvSigned[i] / uvScale;
  const ql = deltaDecode(s.lit.slice(v0 * 3, (v0 + n) * 3), 3, 0xff);
  const bakedLight = new Uint16Array(n * 3);
  for (let i = 0; i < n * 3; i++) bakedLight[i] = LIGHT_LUT[ql[i]];
  /** @type {Record<string, Attribute>} */
  const attributes = {
    position: { array: position, itemSize: 3, normalized: false },
    normal: { array: s.nrm.subarray(v0 * 3, (v0 + n) * 3), itemSize: 3, normalized: true },
    uv: { array: uv, itemSize: 2, normalized: false },
    color: { array: s.col.subarray(v0 * 3, (v0 + n) * 3), itemSize: 3, normalized: true },
    bakedLight: { array: bakedLight, itemSize: 3, normalized: true },
    flicker: { array: s.flk.subarray(v0 * 2, (v0 + n) * 2), itemSize: 2, normalized: false },
  };
  if (c.alphaOffset !== undefined && s.alpha) {
    attributes.alpha = { array: s.alpha.subarray(c.alphaOffset, c.alphaOffset + n), itemSize: 1, normalized: true };
  }
  if (c.kind === 'creature' && s.bone) {
    // THREE.SkinnedMesh attributes: one bone per vertex at full weight
    const bones = s.bone.subarray(c.boneOffset, c.boneOffset + n);
    const skinIndex = new Uint16Array(n * 4);
    const skinWeight = new Float32Array(n * 4);
    for (let i = 0; i < n; i++) {
      skinIndex[i * 4] = bones[i];
      skinWeight[i * 4] = 1;
    }
    attributes.skinIndex = { array: skinIndex, itemSize: 4, normalized: false };
    attributes.skinWeight = { array: skinWeight, itemSize: 4, normalized: false };
  }
  const index = triDecode(s.idx.slice(c.indexOffset, c.indexOffset + c.indexCount), 0xffff);
  return { ...c, attributes, index };
}

/**
 * Decodes the whole baked world.
 * @param {any} meta parsed world.json
 * @param {ArrayBuffer} bin inflated world.bin
 * @returns {WorldData}
 */
export function decodeWorld(meta, bin) {
  if (meta.format !== FORMAT_VERSION) {
    throw new Error(`world data format ${meta.format}, decoder expects ${FORMAT_VERSION}`);
  }
  const s = {};
  for (const [name, ref] of Object.entries(meta.streams)) s[name] = streamView(bin, ref);
  const chunks = meta.chunks.map((c) => decodeChunk(c, s));

  const collision = {};
  for (const [level, c] of Object.entries(meta.collision)) {
    const q = deltaDecode(s.cpos.slice(c.vertexOffset * 3, (c.vertexOffset + c.vertexCount) * 3), 3, 0xffff);
    const position = new Float32Array(c.vertexCount * 3);
    const [ox, oy, oz, sx, sy, sz] = c.quant;
    for (let i = 0; i < c.vertexCount; i++) {
      position[i * 3] = ox + q[i * 3] * sx;
      position[i * 3 + 1] = oy + q[i * 3 + 1] * sy;
      position[i * 3 + 2] = oz + q[i * 3 + 2] * sz;
    }
    const index = s.cidx.slice(c.indexOffset, c.indexOffset + c.indexCount);
    let prev = 0;
    for (let t = 0; t < index.length; t += 3) {
      const a = (prev + index[t]) >>> 0;
      index[t] = a;
      index[t + 1] = (a + index[t + 1]) >>> 0;
      index[t + 2] = (a + index[t + 2]) >>> 0;
      prev = a;
    }
    collision[level] = { position, index };
  }

  const probes = {};
  for (const [level, p] of Object.entries(meta.probes)) {
    const count = p.dims[0] * p.dims[1] * p.dims[2];
    const raw = s.probe.subarray(p.offset * 3, (p.offset + count) * 3);
    const data = new Float32Array(count * 3);
    for (let i = 0; i < count * 3; i++) data[i] = decodeLightByte(raw[i]);
    const groups = (p.groups || []).map((g) => {
      const rawG = s.probe.subarray(g.offset * 3, (g.offset + count) * 3);
      const gd = new Float32Array(count * 3);
      for (let i = 0; i < count * 3; i++) gd[i] = decodeLightByte(rawG[i]);
      return { group: g.group, data: gd };
    });
    probes[level] = { origin: p.origin, dims: p.dims, spacing: p.spacing, data, groups };
  }
  return { meta, chunks, collision, probes };
}

/**
 * Trilinear probe lookup (linear RGB written into `out`). `groupLevels[groupId]` (e.g. the flicker texture's data)
 * adds the scripted groups' light at their current level; without it only the base light is returned.
 * @param {ProbeGrid} grid
 * @param {number} x @param {number} y @param {number} z
 * @param {number[]} [out]
 * @param {ArrayLike<number> | null} [groupLevels]
 */
export function sampleProbe(grid, x, y, z, out = [0, 0, 0], groupLevels = null) {
  const [nx, ny, nz] = grid.dims;
  const fx = Math.min(nx - 1, Math.max(0, (x - grid.origin[0]) / grid.spacing));
  const fy = Math.min(ny - 1, Math.max(0, (y - grid.origin[1]) / grid.spacing));
  const fz = Math.min(nz - 1, Math.max(0, (z - grid.origin[2]) / grid.spacing));
  const x0 = Math.min(nx - 2, Math.floor(fx));
  const y0 = Math.min(ny - 2, Math.floor(fy));
  const z0 = Math.min(nz - 2, Math.floor(fz));
  const tx = nx > 1 ? fx - Math.max(0, x0) : 0;
  const ty = ny > 1 ? fy - Math.max(0, y0) : 0;
  const tz = nz > 1 ? fz - Math.max(0, z0) : 0;
  out[0] = out[1] = out[2] = 0;
  for (let k = 0; k < 8; k++) {
    const dx = k & 1;
    const dy = (k >> 1) & 1;
    const dz = (k >> 2) & 1;
    const ix = Math.min(nx - 1, Math.max(0, x0 + dx));
    const iy = Math.min(ny - 1, Math.max(0, y0 + dy));
    const iz = Math.min(nz - 1, Math.max(0, z0 + dz));
    const w = (dx ? tx : 1 - tx) * (dy ? ty : 1 - ty) * (dz ? tz : 1 - tz);
    const i = ((iy * nz + iz) * nx + ix) * 3;
    out[0] += grid.data[i] * w;
    out[1] += grid.data[i + 1] * w;
    out[2] += grid.data[i + 2] * w;
    if (groupLevels && grid.groups) {
      for (const g of grid.groups) {
        const lv = groupLevels[g.group] ?? 1;
        if (!lv) continue;
        out[0] += g.data[i] * w * lv;
        out[1] += g.data[i + 1] * w * lv;
        out[2] += g.data[i + 2] * w * lv;
      }
    }
  }
  return out;
}

/**
 * Rest-space frame of an entity node: the node's WorldPivot, or the entity pivot for root parts ("").
 * @param {any} entity meta.entities[i]
 * @param {string} node
 * @returns {CFrameArray}
 */
export function entityNodeRest(entity, node) {
  if (node) {
    const n = entity.nodes.find((x) => x.path === node);
    if (n && n.pivot) return n.pivot;
  }
  return entity.pivot;
}

/**
 * Per-vertex node index for an entity chunk (GPU path: the shader fetches node i's matrix
 * `current pivot x inverse(rest pivot)` from a texture or uniform array). Returns the attribute and the node table
 * (index -> { entity, node }).
 * @param {Chunk} chunk
 */
export function nodeIndexAttribute(chunk) {
  const array = new Uint16Array(chunk.vertexCount);
  const nodes = [];
  const ids = new Map();
  for (const r of chunk.ranges || []) {
    const key = `${r.entity}|${r.node}`;
    let id = ids.get(key);
    if (id === undefined) {
      id = nodes.length;
      ids.set(key, id);
      nodes.push({ entity: r.entity, node: r.node });
    }
    array.fill(id, r.start, r.start + r.count);
  }
  return { attribute: { array, itemSize: 1, normalized: false }, nodes };
}

/**
 * CPU path: re-poses one entity node in a decoded entity chunk. `rest` keeps the chunk's original positions and
 * normals (pass the same object every call; it is filled on first use). `matrix` is the 12-number CFrame
 * `current pivot x inverse(rest pivot)`, or null to hide the node (vertices collapse to a point). Returns the range,
 * so the caller can mark just that slice of the BufferAttributes for upload (addUpdateRange).
 * @param {Chunk} chunk @param {EntityRange} range @param {CFrameArray|null} matrix @param {{ position?: Float32Array, normal?: Int8Array }} rest
 */
export function poseEntityRange(chunk, range, matrix, rest) {
  const pos = /** @type {Float32Array} */ (chunk.attributes.position.array);
  const nrm = /** @type {Int8Array} */ (chunk.attributes.normal.array);
  if (!rest.position) rest.position = pos.slice();
  if (!rest.normal) rest.normal = nrm.slice();
  const rp = rest.position;
  const rn = rest.normal;
  for (let v = range.start; v < range.start + range.count; v++) {
    const i = v * 3;
    if (!matrix) {
      pos[i] = pos[i + 1] = pos[i + 2] = 0;
      continue;
    }
    const x = rp[i];
    const y = rp[i + 1];
    const z = rp[i + 2];
    pos[i] = matrix[0] + matrix[3] * x + matrix[4] * y + matrix[5] * z;
    pos[i + 1] = matrix[1] + matrix[6] * x + matrix[7] * y + matrix[8] * z;
    pos[i + 2] = matrix[2] + matrix[9] * x + matrix[10] * y + matrix[11] * z;
    const nx = rn[i];
    const ny = rn[i + 1];
    const nz = rn[i + 2];
    nrm[i] = Math.round(matrix[3] * nx + matrix[4] * ny + matrix[5] * nz);
    nrm[i + 1] = Math.round(matrix[6] * nx + matrix[7] * ny + matrix[8] * nz);
    nrm[i + 2] = Math.round(matrix[9] * nx + matrix[10] * ny + matrix[11] * nz);
  }
  return range;
}

/**
 * CFrame helpers on 12-number arrays (enough for entity posing without three.js).
 * @param {CFrameArray} a @param {CFrameArray} b @returns {CFrameArray}
 */
export function cframeMul(a, b) {
  const r = new Array(12);
  r[0] = a[0] + a[3] * b[0] + a[4] * b[1] + a[5] * b[2];
  r[1] = a[1] + a[6] * b[0] + a[7] * b[1] + a[8] * b[2];
  r[2] = a[2] + a[9] * b[0] + a[10] * b[1] + a[11] * b[2];
  for (let i = 0; i < 3; i++) {
    for (let j = 0; j < 3; j++) {
      r[3 + i * 3 + j] = a[3 + i * 3] * b[3 + j] + a[3 + i * 3 + 1] * b[6 + j] + a[3 + i * 3 + 2] * b[9 + j];
    }
  }
  return /** @type {CFrameArray} */ (r);
}

/** @param {CFrameArray} c @returns {CFrameArray} */
export function cframeInverse(c) {
  const r = [c[3], c[6], c[9], c[4], c[7], c[10], c[5], c[8], c[11]];
  return /** @type {CFrameArray} */ ([
    -(r[0] * c[0] + r[1] * c[1] + r[2] * c[2]),
    -(r[3] * c[0] + r[4] * c[1] + r[5] * c[2]),
    -(r[6] * c[0] + r[7] * c[1] + r[8] * c[2]),
    ...r,
  ]);
}

/**
 * A CFrame array -> column-major 4x4 matrix elements (THREE.Matrix4.fromArray order).
 * @param {CFrameArray} c
 * @returns {number[]}
 */
export function cframeToMatrixElements(c) {
  return [c[3], c[6], c[9], 0, c[4], c[7], c[10], 0, c[5], c[8], c[11], 0, c[0], c[1], c[2], 1];
}
