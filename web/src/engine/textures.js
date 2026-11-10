// Texture tiers and progressive loading. Each surface texture is built at four sizes (web/tools/textures.py):
// 2048 (Max: colour + normal + roughness), 1024 (High / Medium: the same maps), 512 (Low: colour) and 256 (Potato:
// colour). The page boots with the smallest set (the 256 colour maps, inline in a single-file build or the first
// fetches of the site), so a Chromebook on Potato downloads only light assets; the tier's own set then streams in the
// background (fetched, decoded off the main thread by createImageBitmap) and swaps in a few textures a frame.
//
// The asset manifest (tools/assets.mjs) names every map: `textures.sets[size].maps[id][kind]` is either a URL (the
// site's hashed assets/) or `inline:<script id>` (base64 in a single-file build). A single-file page lists only the
// sets it carries; the best set it has at or below the tier's size is used.

const SWAPS_PER_FRAME = 3;
const CONCURRENCY = 6;

/** Base64 -> bytes. */
function bytesOf(b64) {
  if (Uint8Array.fromBase64) return Uint8Array.fromBase64(b64);
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/** Decodes WebP bytes the way the world's UVs expect (flipped at decode, no colour conversion). */
export function decodeImage(blob) {
  return createImageBitmap(blob, { imageOrientation: 'flipY', colorSpaceConversion: 'none', premultiplyAlpha: 'none' });
}

export class TextureStreamer {
  /**
   * @param {import('./world.js').World} world
   * @param {any} manifest the asset manifest's `textures` block (null: the page has only what it inlined)
   * @param {number} bootSize the set the world was built with
   */
  constructor(world, manifest, bootSize) {
    this.world = world;
    this.manifest = manifest || null;
    /** @type {Map<number, Record<string, Record<string, ImageBitmap>>>} sets decoded and kept */
    this.sets = new Map();
    this.sets.set(bootSize, world.images);
    this.current = bootSize;
    this.base = bootSize;
    this.wanted = bootSize;
    /** @type {Map<number, Promise<any>>} */
    this.loading = new Map();
    /** swaps waiting for frames: [id, kind, image] */
    this.queue = [];
    this.pendingSize = null;
    this.stats = { loads: [], bytes: 0 };
  }

  /** The sizes this page can show (sorted, smallest first). */
  available() {
    const out = new Set([this.base]);
    const sets = (this.manifest && this.manifest.sets) || {};
    for (const [size, set] of Object.entries(sets)) if (set && set.maps) out.add(Number(size));
    return [...out].sort((a, b) => a - b);
  }

  /** Asks for the set of a tier (its textureSize); loads it in the background and swaps it in when ready. */
  want(size) {
    const sizes = this.available();
    let pick = sizes[0];
    for (const s of sizes) if (s <= size) pick = s;
    this.wanted = pick;
    if (pick === this.current && !this.pendingSize) return;
    const ready = this.sets.get(pick);
    if (ready) {
      this._apply(pick, ready);
      return;
    }
    this._load(pick).then((images) => {
      if (images && this.wanted === pick) this._apply(pick, images);
    }, (err) => console.warn('[textures] set', pick, err));
  }

  _load(size) {
    let p = this.loading.get(size);
    if (p) return p;
    const set = this.manifest.sets[String(size)];
    const t0 = performance.now();
    const jobs = [];
    for (const [id, maps] of Object.entries(set.maps)) {
      for (const [kind, ref] of Object.entries(maps)) jobs.push({ id, kind, ref });
    }
    const images = {};
    let bytes = 0;
    let next = 0;
    const worker = async () => {
      while (next < jobs.length) {
        const job = jobs[next++];
        let blob;
        if (job.ref.startsWith('inline:')) {
          const el = document.getElementById(job.ref.slice(7));
          if (!el) continue;
          blob = new Blob([bytesOf(el.textContent.trim())], { type: 'image/webp' });
        } else {
          const res = await fetch(job.ref);
          if (!res.ok) throw new Error(`${job.ref}: ${res.status}`);
          blob = await res.blob();
        }
        bytes += blob.size;
        const bmp = await decodeImage(blob);
        (images[job.id] || (images[job.id] = {}))[job.kind] = bmp;
      }
    };
    p = Promise.all(Array.from({ length: Math.min(CONCURRENCY, jobs.length) }, worker)).then(() => {
      // atlases (decals, wear) are shared by every set
      for (const [id, maps] of Object.entries(this.world.images)) {
        if (!images[id] && this.world.meta.textures[id] && this.world.meta.textures[id].atlas) images[id] = maps;
      }
      this.sets.set(size, images);
      this.loading.delete(size);
      this.stats.bytes += bytes;
      this.stats.loads.push({ size, maps: jobs.length, bytes, ms: Math.round(performance.now() - t0) });
      return images;
    }, (err) => {
      this.loading.delete(size);
      throw err;
    });
    this.loading.set(size, p);
    return p;
  }

  /** Queues the swap to `size` (a few textures a frame, then the shaders follow). */
  _apply(size, images) {
    this.queue.length = 0;
    this.pendingSize = size;
    // what the old set had that the new one lacks (normal maps going away) is dropped at the end
    for (const [id, maps] of Object.entries(images)) {
      for (const [kind, image] of Object.entries(maps)) this.queue.push([id, kind, image]);
    }
    this.pendingImages = images;
    if (!this.queue.length) this.frame();
  }

  /** Per frame: a few texture swaps; at the end the set becomes the world's and the materials follow. */
  frame() {
    if (this.pendingSize === null) return;
    const world = this.world;
    for (let i = 0; i < SWAPS_PER_FRAME && this.queue.length; i++) {
      const [id, kind, image] = this.queue.shift();
      world.setTextureImage(id, kind, image);
    }
    if (this.queue.length) return;
    const size = this.pendingSize;
    const images = this.pendingImages;
    this.pendingSize = null;
    this.pendingImages = null;
    const before = this.current;
    this.current = size;
    world.setTextureSet(images);
    // free a set nobody shows any more (the boot set is kept: it is the fallback)
    if (before !== size && before !== this.base) {
      const old = this.sets.get(before);
      this.sets.delete(before);
      if (old) {
        for (const [id, maps] of Object.entries(old)) {
          if (world.meta.textures[id] && world.meta.textures[id].atlas) continue;
          for (const bmp of Object.values(maps)) if (bmp && bmp.close) bmp.close();
        }
      }
    }
  }
}
