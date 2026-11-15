// sheet.mjs: the audit's contact sheets (web/build/audio/audit/<family>-<n>.png): eight sounds a sheet, each a
// log-frequency spectrogram (20 Hz - 20 kHz, 70 dB range; below 500 Hz from a long window for its resolution in
// frequency, above from a short one for its resolution in time) over the waveform, with the name and the key numbers.
// docs/SOUND.md 3 says what each class should look like.

import { Canvas } from './png.mjs';
import { framePower, hann } from '../kit/fft.mjs';

const TILE_W = 600;
const SPEC_H = 210;
const WAVE_H = 56;
const LABEL_H = 40;
const TILE_H = LABEL_H + SPEC_H + WAVE_H + 14;
const COLS = 2;
const PAD = 10;
const F_LO = 20;
const F_HI = 20000;
const RANGE = 70;

/** dark blue -> purple -> red -> orange -> pale yellow */
const STOPS = [[0, [4, 4, 16]], [0.25, [60, 12, 100]], [0.5, [170, 30, 90]], [0.75, [245, 120, 30]], [1, [252, 245, 170]]];
function colour(v) {
  const t = Math.max(0, Math.min(1, v));
  for (let k = 1; k < STOPS.length; k++) {
    const [t1, c1] = STOPS[k];
    const [t0, c0] = STOPS[k - 1];
    if (t <= t1) {
      const u = (t - t0) / (t1 - t0);
      return /** @type {[number, number, number]} */ (c0.map((c, i) => Math.round(c + (c1[i] - c) * u)));
    }
  }
  return /** @type {[number, number, number]} */ (STOPS[STOPS.length - 1][1]);
}

/** Power columns (one per pixel) of an STFT of window `size`, centred on each column's time. */
function columns(x, width, size) {
  const w = hann(size);
  const scratch = { re: new Float64Array(size), im: new Float64Array(size) };
  const cols = [];
  for (let c = 0; c < width; c++) {
    const centre = Math.round(((c + 0.5) / width) * x.length);
    cols.push(framePower(x, centre - size / 2, size, w, scratch));
  }
  return cols;
}

/**
 * Draws one sound's tile at (x0, y0).
 * @param {Canvas} cv
 * @param {number} x0
 * @param {number} y0
 * @param {Float32Array} x mono samples
 * @param {number} sr
 * @param {{name: string, lines: string[], ok: boolean}} label
 */
function tile(cv, x0, y0, x, sr, label) {
  cv.text(x0, y0 + 2, label.name, label.ok ? [235, 235, 235] : [255, 90, 90], 2);
  label.lines.forEach((line, k) => cv.text(x0, y0 + 20 + k * 10, line, [170, 170, 180], 1));
  const sy = y0 + LABEL_H;
  const long = columns(x, TILE_W, 8192);
  const short = columns(x, TILE_W, 1024);
  // the loudest cell over both sets, for the 70 dB range
  let max = 0;
  for (const set of [long, short]) for (const col of set) for (const v of col) max = Math.max(max, v * (set === short ? 8 : 1));
  const ref = 10 * Math.log10(max + 1e-30);
  for (let row = 0; row < SPEC_H; row++) {
    const f0 = F_LO * (F_HI / F_LO) ** (1 - (row + 1) / SPEC_H);
    const f1 = F_LO * (F_HI / F_LO) ** (1 - row / SPEC_H);
    const useLong = f1 < 500;
    const size = useLong ? 8192 : 1024;
    const scale = useLong ? 1 : 8; // the short window's power scaled to the long one's (8x the samples: noise)
    const k0 = Math.max(1, Math.floor((f0 * size) / sr));
    const k1 = Math.max(k0, Math.ceil((f1 * size) / sr));
    for (let c = 0; c < TILE_W; c++) {
      const col = (useLong ? long : short)[c];
      let p = 0;
      for (let k = k0; k <= Math.min(k1, col.length - 1); k++) p = Math.max(p, col[k]);
      const level = 10 * Math.log10(p * scale + 1e-30) - ref;
      cv.set(x0 + c, sy + row, colour(1 + level / RANGE));
    }
  }
  // frequency grid: 100 Hz, 1 kHz, 10 kHz
  for (const [f, text] of [[100, '100'], [1000, '1K'], [10000, '10K']]) {
    const row = Math.round((1 - Math.log(f / F_LO) / Math.log(F_HI / F_LO)) * SPEC_H);
    for (let c = 0; c < TILE_W; c += 4) cv.set(x0 + c, sy + row, [90, 90, 110]);
    cv.text(x0 + 2, sy + row - 8, text, [200, 200, 220], 1);
  }
  // the waveform (min / max per column)
  const wy = sy + SPEC_H + 4;
  cv.fill(x0, wy, TILE_W, WAVE_H, [14, 14, 22]);
  cv.hline(x0, x0 + TILE_W - 1, wy + WAVE_H / 2, [50, 50, 70]);
  let peak = 0;
  for (const v of x) peak = Math.max(peak, Math.abs(v));
  for (let c = 0; c < TILE_W; c++) {
    const a = Math.floor((c / TILE_W) * x.length);
    const b = Math.max(a + 1, Math.floor(((c + 1) / TILE_W) * x.length));
    let lo = 0;
    let hi = 0;
    for (let i = a; i < b && i < x.length; i++) {
      lo = Math.min(lo, x[i]);
      hi = Math.max(hi, x[i]);
    }
    const mid = wy + WAVE_H / 2;
    cv.vline(x0 + c, Math.round(mid - (hi / (peak || 1)) * (WAVE_H / 2 - 1)), Math.round(mid - (lo / (peak || 1)) * (WAVE_H / 2 - 1)), [120, 200, 160]);
  }
}

/**
 * One contact sheet of up to eight sounds.
 * @param {Array<{x: Float32Array, name: string, lines: string[], ok: boolean}>} items
 * @param {number} sr
 * @param {string} heading
 * @returns {Buffer} the PNG
 */
export function contactSheet(items, sr, heading) {
  const rows = Math.ceil(items.length / COLS);
  const cv = new Canvas(COLS * TILE_W + (COLS + 1) * PAD, rows * (TILE_H + PAD) + PAD + 24, [8, 8, 12]);
  cv.text(PAD, 8, heading, [255, 220, 150], 2);
  items.forEach((it, k) => {
    const col = k % COLS;
    const row = Math.floor(k / COLS);
    tile(cv, PAD + col * (TILE_W + PAD), 24 + PAD + row * (TILE_H + PAD), it.x, sr, it);
  });
  return cv.png();
}
