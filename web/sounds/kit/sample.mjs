// sample.mjs: working with recordings (docs/SOUND.md 3). A recording is pitched the way tape is: played slower it is
// lower AND longer (`resample`), which is how every horror creature is made out of an animal or a person. Nothing here
// stretches time or shifts pitch on its own: those leave artefacts a slowed tape never has.
//
//   resample    a band-limited read of a buffer at any rate, constant or changing over the sound (a windowed sinc,
//               16 zero crossings a side; reading faster than 1 lowers its cut-off so nothing folds back)
//   region      a slice with raised-cosine fades            active     where a recording actually sounds
//   events      its separate takes (a file of five growls)

const ZERO_CROSSINGS = 16;
const PHASES = 512;

function bessel0(x) {
  let sum = 1;
  let term = 1;
  for (let k = 1; k < 40; k++) {
    term *= (x / (2 * k)) ** 2;
    sum += term;
    if (term < 1e-12 * sum) break;
  }
  return sum;
}

/** Half of the Kaiser-windowed sinc, sampled PHASES times a zero crossing (about 90 dB of stopband). */
const KERNEL = (() => {
  const n = ZERO_CROSSINGS * PHASES;
  const table = new Float64Array(n + 2);
  const beta = 9;
  const norm = bessel0(beta);
  for (let i = 0; i <= n; i++) {
    const t = i / PHASES;
    const sinc = t === 0 ? 1 : Math.sin(Math.PI * t) / (Math.PI * t);
    const r = t / ZERO_CROSSINGS;
    table[i] = sinc * (bessel0(beta * Math.sqrt(Math.max(0, 1 - r * r))) / norm);
  }
  return table;
})();

function kernelAt(t) {
  const a = Math.abs(t) * PHASES;
  const i = Math.floor(a);
  if (i >= ZERO_CROSSINGS * PHASES) return 0;
  const f = a - i;
  return KERNEL[i] + (KERNEL[i + 1] - KERNEL[i]) * f;
}

/**
 * `input` played at `rate` (0.5: an octave down and twice as long). `rate` is a number, or a function of the output
 * time in seconds for a pitch that moves (a drop, a rising shriek); the read position is its running sum.
 * @param {Float32Array} input
 * @param {number|((seconds: number) => number)} rate
 * @param {number} [sr] only read by a rate function (its time argument)
 */
export function resample(input, rate, sr = 48000) {
  const fixed = typeof rate === 'number';
  if (fixed && !(rate > 0)) throw new Error('resample: the rate must be positive');
  if (fixed && rate === 1) return Float32Array.from(input);
  const out = [];
  let pos = 0;
  let i = 0;
  const limit = input.length - 1;
  while (pos <= limit) {
    const r = fixed ? rate : Math.max(0.01, rate(i / sr));
    const scale = Math.min(1, 1 / r);
    const width = ZERO_CROSSINGS / scale;
    const lo = Math.max(0, Math.ceil(pos - width));
    const hi = Math.min(limit, Math.floor(pos + width));
    let acc = 0;
    for (let j = lo; j <= hi; j++) acc += input[j] * kernelAt((j - pos) * scale);
    out.push(acc * scale);
    pos += r;
    i++;
  }
  return Float32Array.from(out);
}

/**
 * The slice [from, to) seconds of a buffer (clamped), faded in and out.
 * @param {Float32Array} buf
 * @param {number} sr
 * @param {number} from
 * @param {number} to
 * @param {number} [fadeIn] seconds
 * @param {number} [fadeOut] seconds
 */
export function region(buf, sr, from, to, fadeIn = 0.004, fadeOut = 0.02) {
  const a = Math.max(0, Math.min(buf.length - 1, Math.round(from * sr)));
  const b = Math.max(a + 1, Math.min(buf.length, Math.round(to * sr)));
  const out = buf.slice(a, b);
  const nIn = Math.min(out.length >> 1, Math.round(fadeIn * sr));
  const nOut = Math.min(out.length >> 1, Math.round(fadeOut * sr));
  for (let i = 0; i < nIn; i++) out[i] *= 0.5 - 0.5 * Math.cos((Math.PI * i) / nIn);
  for (let i = 0; i < nOut; i++) out[out.length - 1 - i] *= 0.5 - 0.5 * Math.cos((Math.PI * i) / nOut);
  return out;
}

/** The mean-square level of `buf` in windows of `hop` samples. */
function powers(buf, hop) {
  const n = Math.max(1, Math.floor(buf.length / hop));
  const out = new Float64Array(n);
  for (let k = 0; k < n; k++) {
    let s = 0;
    for (let i = k * hop; i < Math.min(buf.length, (k + 1) * hop); i++) s += buf[i] * buf[i];
    out[k] = s / hop;
  }
  return out;
}

/**
 * Where a recording actually sounds: [from, to] seconds between its first and last 5 ms window above `floorDb` of its
 * loudest one (leading and trailing silence, room tone and encoder padding left out).
 * @param {Float32Array} buf
 * @param {number} sr
 * @param {number} [floorDb]
 * @returns {[number, number]}
 */
export function active(buf, sr, floorDb = -45) {
  const hop = Math.max(1, Math.round(0.005 * sr));
  const p = powers(buf, hop);
  let max = 0;
  for (const v of p) max = Math.max(max, v);
  const thr = max * 10 ** (floorDb / 10);
  let a = 0;
  while (a < p.length - 1 && p[a] < thr) a++;
  let b = p.length - 1;
  while (b > a && p[b] < thr) b--;
  return [(a * hop) / sr, Math.min(buf.length, (b + 1) * hop) / sr];
}

/**
 * The separate takes of a recording: [from, to] seconds of every stretch that stays above `floorDb` of the loudest
 * 20 ms, allowing gaps up to `gap` seconds inside a take and dropping takes shorter than `min`, padded by `pad`.
 * @param {Float32Array} buf
 * @param {number} sr
 * @param {{floorDb?: number, gap?: number, min?: number, pad?: number}} [spec]
 * @returns {Array<[number, number]>}
 */
export function events(buf, sr, { floorDb = -30, gap = 0.18, min = 0.12, pad = 0.03 } = {}) {
  const hop = Math.max(1, Math.round(0.02 * sr));
  const p = powers(buf, hop);
  let max = 0;
  for (const v of p) max = Math.max(max, v);
  const thr = max * 10 ** (floorDb / 10);
  const gapHops = Math.max(1, Math.round((gap * sr) / hop));
  /** @type {Array<[number, number]>} */
  const out = [];
  let start = -1;
  let quiet = 0;
  const close = (endHop) => {
    const from = Math.max(0, (start * hop) / sr - pad);
    const to = Math.min(buf.length / sr, (endHop * hop) / sr + pad);
    if (to - from >= min) out.push([from, to]);
    start = -1;
  };
  for (let k = 0; k < p.length; k++) {
    if (p[k] >= thr) {
      if (start < 0) start = k;
      quiet = 0;
    } else if (start >= 0 && ++quiet > gapHops) close(k - quiet + 1);
  }
  if (start >= 0) close(p.length - quiet);
  return out;
}
