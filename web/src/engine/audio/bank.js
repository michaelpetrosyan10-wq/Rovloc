// bank.js: the recorded sounds (docs/SOUND.md 11). web/sounds renders every sound of the game from recordings into
// MP3s; the build (tools/assets.mjs) packs them and names them in the page's manifest:
//
//   audio.packs    { first: ref, rest: ref }: the files end to end (a site asset, or inline base64 in a single file)
//   audio.sounds   name -> { p: pack, f: 1 when the sound is needed at once, r: the rate it is decoded at (24000 for a
//                  dark sound: half the memory), c: channels, l: [loopStart, loopEnd] seconds of a loop,
//                  v: its variants as [offset, bytes, seconds] in the pack }
//
// A name in the bank plays its file (audio.js); a name that is not keeps its old recipe, so nothing ever goes silent.
//
// Decoding. boot() fetches the first pack and decodes what every stage needs at once (him, the scares and warnings,
// footsteps, the menus) before the first frame; then the rest pack arrives and is decoded in the background, a sound
// at a time, in the build's order. A sound asked for before its turn is decoded at once. Decoded samples are held under PCM_BUDGET:
// past it the sounds played longest ago are dropped (never one that is playing, nor a first-set one) and decoded again
// when next needed. decodeAudioData runs off the main thread: nothing here costs a frame.

export const PCM_BUDGET = 60 * 1048576;
/** The background pass stops this far under the budget (what is left is decoded when it is first played). */
const BACKGROUND_FILL = 0.9;
const DARK_RATE = 24000;
/** The background pass rests this long between two sounds (ms): it is spread thin so no frame of a slow machine pays for it. */
const BACKGROUND_GAP = 40;

/** @typedef {{p: string, f?: number, r: number, c: number, l?: [number, number], v: Array<[number, number, number]>}} SoundEntry */

export class SoundBank {
  /**
   * @param {{packs: Record<string, string>, sounds: Record<string, SoundEntry>}|null|undefined} manifest
   * @param {(ref: string) => Promise<Uint8Array>} fetchBytes the page's asset reader (a URL or an inline reference)
   * @param {BaseAudioContext|null} ctx the context the sounds play in
   */
  constructor(manifest, fetchBytes, ctx) {
    this.sounds = (manifest && manifest.sounds) || {};
    this.packRefs = (manifest && manifest.packs) || {};
    this.fetchBytes = fetchBytes;
    this.ctx = ctx;
    /** @type {Map<string, Promise<Uint8Array|null>>} */
    this.packs = new Map();
    /** @type {Map<string, {buffers: AudioBuffer[], bytes: number, used: number, playing: number, last: number}>} */
    this.decoded = new Map();
    /** @type {Map<string, Promise<AudioBuffer[]|null>>} */
    this.pending = new Map();
    this.decodedBytes = 0;
    /** the most ever held at once (the audio test reads it) */
    this.peakBytes = 0;
    this.clock = 0;
    this.booted = false;
    /** every name whose decode failed (it plays its old recipe) */
    this.failed = new Set();
    this.dark = null;
  }

  /** Whether `name` has a file. */
  has(name) {
    return Object.hasOwn(this.sounds, name) && !this.failed.has(name);
  }

  /** @returns {SoundEntry|null} */
  entry(name) {
    return this.has(name) ? this.sounds[name] : null;
  }

  /** Every name with a file. */
  names() {
    return Object.keys(this.sounds);
  }

  _pack(id) {
    let p = this.packs.get(id);
    if (!p) {
      const ref = this.packRefs[id];
      p = ref ? this.fetchBytes(ref).catch((err) => {
        console.warn('[audio] sound pack', id, err);
        return null;
      }) : Promise.resolve(null);
      this.packs.set(id, p);
    }
    return p;
  }

  /** The context a sound is decoded in: the playing one, or a 24 kHz one for a dark sound (half the samples). */
  _decoder(entry) {
    if (entry.r !== DARK_RATE || this.ctx.sampleRate <= DARK_RATE) return this.ctx;
    if (!this.dark) this.dark = new OfflineAudioContext(1, 1, DARK_RATE);
    return this.dark;
  }

  /**
   * The decoded variants of `name` (decoding them now if they are not), or null when it has no file or cannot be
   * decoded.
   * @returns {Promise<AudioBuffer[]|null>}
   */
  load(name) {
    const have = this.decoded.get(name);
    if (have) return Promise.resolve(have.buffers);
    const entry = this.entry(name);
    if (!entry || !this.ctx) return Promise.resolve(null);
    let job = this.pending.get(name);
    if (job) return job;
    job = this._pack(entry.p).then(async (pack) => {
      if (!pack) throw new Error(`pack ${entry.p} is missing`);
      const decoder = this._decoder(entry);
      const buffers = await Promise.all(entry.v.map(([offset, bytes]) => decoder.decodeAudioData(pack.buffer.slice(pack.byteOffset + offset, pack.byteOffset + offset + bytes))));
      const size = buffers.reduce((t, b) => t + b.length * b.numberOfChannels * 4, 0);
      this.decoded.set(name, { buffers, bytes: size, used: ++this.clock, playing: 0, last: -1 });
      this.decodedBytes += size;
      this._trim(name);
      this.peakBytes = Math.max(this.peakBytes, this.decodedBytes);
      return buffers;
    }).catch((err) => {
      console.warn('[audio] cannot decode', name, err);
      this.failed.add(name);
      return null;
    }).finally(() => {
      this.pending.delete(name);
    });
    this.pending.set(name, job);
    return job;
  }

  /** Drops the sounds played longest ago until the budget holds (never `keep`, a playing one or a first-set one). */
  _trim(keep) {
    if (this.decodedBytes <= PCM_BUDGET) return;
    const candidates = [...this.decoded].filter(([name, d]) => name !== keep && d.playing === 0 && !this.sounds[name].f)
      .sort((a, b) => a[1].used - b[1].used);
    for (const [name, d] of candidates) {
      if (this.decodedBytes <= PCM_BUDGET) break;
      this.decoded.delete(name);
      this.decodedBytes -= d.bytes;
    }
  }

  /** Decodes `names` now (the ones with a file). */
  prepare(names) {
    return Promise.all(names.filter((n) => this.has(n)).map((n) => this.load(n)));
  }

  /**
   * The first pack and every sound a stage needs at once, decoded (awaited before the first frame); the rest follows
   * in the background.
   * @param {(fraction: number) => void} [progress]
   */
  async boot(progress = () => {}) {
    if (this.booted || !this.ctx) return;
    this.booted = true;
    const first = this.names().filter((n) => this.sounds[n].f);
    let done = 0;
    await Promise.all(first.map((n) => this.load(n).then(() => progress(++done / first.length))));
    this._background();
  }

  /** The background pass: every sound not yet decoded, one at a time, while there is room under the budget. */
  async _background() {
    for (const name of this.names()) {
      if (this.decoded.has(name) || this.failed.has(name)) continue;
      const e = this.sounds[name];
      const estimate = e.v.reduce((t, v) => t + v[2], 0) * e.c * Math.min(e.r, this.ctx.sampleRate) * 4;
      if (this.decodedBytes + estimate > PCM_BUDGET * BACKGROUND_FILL) continue;
      await this.load(name);
      // one sound, then the page gets a turn
      await new Promise((r) => setTimeout(r, BACKGROUND_GAP));
    }
  }

  /**
   * A decoded variant of `name` to play now, or null when it is not decoded yet (load(name) first). Never the same
   * variant twice in a row; `pick` (a whole number, the same on every client) chooses one instead.
   * @returns {AudioBuffer|null}
   */
  take(name, pick = null) {
    const d = this.decoded.get(name);
    if (!d) return null;
    const n = d.buffers.length;
    let index;
    if (pick !== null) index = ((pick % n) + n) % n;
    else {
      index = Math.floor(Math.random() * n);
      if (n > 1 && index === d.last) index = (index + 1) % n;
    }
    d.last = index;
    d.used = ++this.clock;
    return d.buffers[index];
  }

  /** A voice of `name` started (+1) or ended (-1): a playing sound is never dropped. */
  hold(name, delta) {
    const d = this.decoded.get(name);
    if (d) d.playing = Math.max(0, d.playing + delta);
  }
}
