// raw.mjs: the finished, unencoded samples of every render (web/build/audio/raw/<family>/<name>-<n>.f32, channels one
// after the other, plus a .json beside it with the rate, the channel count and the render's numbers). The audit
// measures these, not the MP3s; format-check.mjs compares the two.

import fs from 'node:fs';

/**
 * @param {string} file the .f32 path
 * @param {Float32Array[]} channels
 * @param {number} sr
 * @param {object} info
 */
export function writeRaw(file, channels, sr, info) {
  const n = channels[0].length;
  const all = new Float32Array(n * channels.length);
  channels.forEach((c, k) => all.set(c, k * n));
  fs.writeFileSync(file, Buffer.from(all.buffer));
  fs.writeFileSync(file.replace(/\.f32$/, '.json'), JSON.stringify({ sr, channels: channels.length, length: n, ...info }));
}

/**
 * @param {string} file the .f32 path
 * @returns {{channels: Float32Array[], info: any}}
 */
export function readRaw(file) {
  const info = JSON.parse(fs.readFileSync(file.replace(/\.f32$/, '.json'), 'utf8'));
  const buf = fs.readFileSync(file);
  const all = new Float32Array(buf.buffer, buf.byteOffset, buf.byteLength / 4);
  const channels = [];
  for (let k = 0; k < info.channels; k++) channels.push(Float32Array.from(all.subarray(k * info.length, (k + 1) * info.length)));
  return { channels, info };
}

/** The raw record's numbers alone (null when there is none). */
export function readInfo(file) {
  const json = file.replace(/\.f32$/, '.json');
  if (!fs.existsSync(json) || !fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(json, 'utf8'));
}
