// encode.mjs: the shipped format (docs/SOUND.md 8): MP3 (LAME VBR) at 48 kHz, which Chromium, Firefox and Safari all
// decode with decodeAudioData. The encoder's priming delay is recorded in the LAME/Xing header, which those decoders
// and ffmpeg use to trim it (format-check.mjs measures that in headless Chromium). Loops ship with 100 ms of their own
// signal on either side of the loop points (pipeline.mjs), so a decoder that kept the priming would still loop
// seamlessly. Every flag below that can make the bytes depend on the machine is pinned (bitexact, no metadata, no ID3),
// so the same render always gives the same file.

import { spawnSync } from 'node:child_process';

export const FFMPEG = '/usr/bin/ffmpeg';
/** LAME's VBR quality per channel count (0 best .. 9 smallest): 4 is transparent for these sounds at 48 kHz. */
export const QUALITY = Object.freeze({ 1: 4, 2: 4 });

/**
 * Interleaves channels into little-endian float32 bytes.
 * @param {Float32Array[]} channels
 */
export function interleave(channels) {
  const n = channels[0].length;
  const c = channels.length;
  const out = new Float32Array(n * c);
  for (let i = 0; i < n; i++) for (let k = 0; k < c; k++) out[i * c + k] = channels[k][i];
  return Buffer.from(out.buffer, out.byteOffset, out.byteLength);
}

/**
 * Encodes channels to an MP3 file.
 * @param {Float32Array[]} channels
 * @param {number} sr
 * @param {string} file
 */
export function encodeMp3(channels, sr, file) {
  const args = [
    '-hide_banner', '-loglevel', 'error', '-y', '-threads', '1',
    '-f', 'f32le', '-ar', String(sr), '-ac', String(channels.length), '-i', 'pipe:0',
    '-c:a', 'libmp3lame', '-q:a', String(QUALITY[channels.length]), '-ar', String(sr),
    '-map_metadata', '-1', '-fflags', '+bitexact', '-flags:a', '+bitexact', '-id3v2_version', '0', '-write_id3v1', '0',
    '-f', 'mp3', file,
  ];
  const r = spawnSync(FFMPEG, args, { input: interleave(channels), maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error(`ffmpeg failed on ${file}: ${r.stderr?.toString() ?? r.error}`);
}

/**
 * Decodes any audio file with ffmpeg to float32 channels at `sr` (ffmpeg honours the LAME header's delay and padding).
 * @param {string} file
 * @param {number} sr
 * @param {number} channels
 * @returns {Float32Array[]}
 */
export function decode(file, sr, channels) {
  const r = spawnSync(FFMPEG, ['-hide_banner', '-loglevel', 'error', '-threads', '1', '-i', file, '-f', 'f32le', '-ar', String(sr), '-ac', String(channels), 'pipe:1'], { maxBuffer: 1 << 28 });
  if (r.status !== 0) throw new Error(`ffmpeg could not decode ${file}: ${r.stderr?.toString() ?? r.error}`);
  const all = new Float32Array(r.stdout.buffer, r.stdout.byteOffset, r.stdout.byteLength / 4);
  const n = all.length / channels;
  const out = [];
  for (let k = 0; k < channels; k++) {
    const ch = new Float32Array(n);
    for (let i = 0; i < n; i++) ch[i] = all[i * channels + k];
    out.push(ch);
  }
  return out;
}
