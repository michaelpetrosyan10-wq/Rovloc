// format-check.mjs (npm run sounds:format): proves the shipped format (docs/SOUND.md 8). Every shipped MP3 is decoded
// by headless Chromium's decodeAudioData (an OfflineAudioContext at 48 kHz: what the game will do) and compared with
// the raw render it came from:
//
//   offset    the lag (samples) that best aligns the decode with the render over the whole file (0: the encoder's
//             priming was trimmed)
//   length    decoded samples minus rendered samples (0: the padding was trimmed too)
//   snr       render energy over the residual's after alignment (dB): how much the codec changed the waveform (for
//             bright noise, like crunching glass, a perceptual codec keeps the spectrum, not the waveform: low here
//             is expected, so it is reported, not judged)
//   bands     the largest third-octave level difference (dB) over the bands within 20 dB of the loudest (and,
//             separately, those 20-30 dB down), under 15 kHz (LAME's low-pass): the spectrum the ear hears is kept
//   envelope  the correlation of the 1 ms envelopes: the transients land where they were, as sharp
//   onset     the residual over the first 10 ms against the render's (dB)
//   seam      loops only: the decoded loop window [start, end) wrapped onto itself, by the audit's seam measure
//
// It fails when an offset is not 0, the decoded length is off by more than one MP3 frame (1,152 samples: the LAME
// header's padding is not always trimmed to the sample; loops play by their loop points, so only one-shots' silent
// ends are affected), a strong band moves more than 1.5 dB (a weak one, 20-30 dB down, more than 3 dB), the envelopes
// correlate under 0.98, or a decoded loop's seam is rough.

import fs from 'node:fs';
import path from 'node:path';
import { ROOT, SR } from './lib/voices.mjs';
import { readRaw } from './lib/raw.mjs';
import { loopSeam, rmsEnvelope, segmentPower } from './lib/measure.mjs';
import { welch, nextPow2 } from './kit/fft.mjs';
import { loadPlaywright } from './lib/browser.mjs';
import { MARGIN } from './lib/pipeline.mjs';

const BUILD = path.resolve(ROOT, '..', 'build', 'audio');
const manifest = JSON.parse(fs.readFileSync(path.join(BUILD, 'manifest.json'), 'utf8'));

/** The samples a shipped file holds, rebuilt from the raw render (a loop: the period with its margins). */
function expected(raw, loop) {
  if (!loop) return raw;
  const M = Math.round(MARGIN * SR);
  return raw.map((c) => {
    const L = c.length;
    const s = new Float32Array(L + 2 * M);
    s.set(c.subarray(L - M), 0);
    s.set(c, M);
    s.set(c.subarray(0, M), M + L);
    return s;
  });
}

/**
 * The lag (samples) that best aligns `b` with `a`. A coarse search over the first half second finds it within `range`;
 * the whole file then settles it within a few samples, because over half a second a sound that is nearly all low
 * rumble has a correlation peak too broad to place to the sample (the codec's slight phase change under 200 Hz moves
 * it), while a real offset shifts every part of the file alike and stays where the coarse search put it.
 */
function bestLag(a, b, range) {
  const search = (from, to, n) => {
    let best = -Infinity;
    let lag = 0;
    for (let d = from; d <= to; d++) {
      let s = 0;
      for (let i = Math.max(0, -d); i < n && i + d < b.length; i++) s += a[i] * b[i + d];
      if (s > best) {
        best = s;
        lag = d;
      }
    }
    return lag;
  };
  const coarse = search(-range, range, Math.min(a.length, b.length, 24000));
  return search(coarse - 8, coarse + 8, Math.min(a.length, b.length));
}

/** Third-octave band levels (dB) from 40 Hz to 15 kHz of a mono buffer. */
function thirds(x) {
  const size = 8192;
  const p = x.length >= 2 * size ? welch(x, size) : segmentPower(x, 0, x.length, nextPow2(Math.max(x.length, 4096)));
  const n = (p.length - 1) * 2;
  const out = [];
  for (let f = 40; f <= 15000; f *= 2 ** (1 / 3)) {
    const lo = Math.floor(((f / 2 ** (1 / 6)) * n) / SR);
    const hi = Math.max(lo + 1, Math.ceil(((f * 2 ** (1 / 6)) * n) / SR));
    let e = 0;
    for (let k = lo; k < hi && k < p.length; k++) e += p[k];
    out.push(10 * Math.log10(e + 1e-30));
  }
  return out;
}

/** The worst band differences: [over the bands within 20 dB of the loudest, over those 20-30 dB down]. */
function bandDiff(a, b) {
  const A = thirds(a);
  const B = thirds(b);
  const top = Math.max(...A);
  let strong = 0;
  let weak = 0;
  A.forEach((v, k) => {
    if (v > top - 20) strong = Math.max(strong, Math.abs(v - B[k]));
    else if (v > top - 30) weak = Math.max(weak, Math.abs(v - B[k]));
  });
  return [strong, weak];
}

/** The correlation of two 1 ms RMS envelopes. */
function envelopeCorrelation(a, b) {
  const x = rmsEnvelope(a, SR);
  const y = rmsEnvelope(b, SR);
  const n = Math.min(x.length, y.length);
  let mx = 0;
  let my = 0;
  for (let i = 0; i < n; i++) {
    mx += x[i];
    my += y[i];
  }
  mx /= n;
  my /= n;
  let sxy = 0;
  let sxx = 0;
  let syy = 0;
  for (let i = 0; i < n; i++) {
    sxy += (x[i] - mx) * (y[i] - my);
    sxx += (x[i] - mx) ** 2;
    syy += (y[i] - my) ** 2;
  }
  return sxy / Math.sqrt(sxx * syy + 1e-30);
}

async function main() {
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto('about:blank');
  const rows = [];
  const failures = [];
  for (const sound of Object.values(manifest.sounds)) {
    for (const v of sound.variants) {
      const bytes = fs.readFileSync(path.join(BUILD, v.file)).toString('base64');
      const decoded = await page.evaluate(async ({ b64, sr }) => {
        const bin = atob(b64);
        const buf = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
        const ctx = new OfflineAudioContext(1, 1, sr);
        const audio = await ctx.decodeAudioData(buf.buffer);
        const out = [];
        for (let k = 0; k < audio.numberOfChannels; k++) {
          const ch = audio.getChannelData(k);
          const u8 = new Uint8Array(ch.buffer, ch.byteOffset, ch.byteLength);
          let s = '';
          for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000));
          out.push(btoa(s));
        }
        return { channels: out, rate: audio.sampleRate };
      }, { b64: bytes, sr: SR });
      const dec = decoded.channels.map((s) => {
        const b = Buffer.from(s, 'base64');
        return new Float32Array(b.buffer, b.byteOffset, b.byteLength / 4);
      });
      const raw = readRaw(path.join(BUILD, 'raw', v.file.replace(/\.mp3$/, '.f32'))).channels;
      const ref = expected(raw, v.loop);
      const lag = bestLag(ref[0], dec[0], 2400);
      const lengthDiff = dec[0].length - ref[0].length;
      let e = 0;
      let r = 0;
      let eOn = 0;
      let rOn = 0;
      const on = Math.round(0.01 * SR);
      for (let k = 0; k < ref.length; k++) {
        for (let i = 0; i < ref[k].length; i++) {
          const j = i + lag;
          const d = j >= 0 && j < dec[k].length ? dec[k][j] : 0;
          e += (d - ref[k][i]) ** 2;
          r += ref[k][i] ** 2;
          if (i < on) {
            eOn += (d - ref[k][i]) ** 2;
            rOn += ref[k][i] ** 2;
          }
        }
      }
      const snr = 10 * Math.log10(r / Math.max(e, 1e-20));
      const onset = 10 * Math.log10(Math.max(eOn, 1e-20) / Math.max(rOn, 1e-20));
      let seam = null;
      if (v.loop) {
        const a = Math.round(v.loop.start * SR);
        const b = Math.round(v.loop.end * SR);
        seam = loopSeam(dec.map((c) => c.subarray(a, b)), SR);
      }
      const aligned = dec[0].subarray(Math.max(0, lag), Math.max(0, lag) + ref[0].length);
      const [bands, weakBands] = bandDiff(ref[0], aligned);
      const envelope = envelopeCorrelation(ref[0], aligned);
      const row = { file: v.file, rate: decoded.rate, lag, lengthDiff, snr, bands, weakBands, envelope, onset, seam };
      rows.push(row);
      if (decoded.rate !== SR) failures.push(`${v.file}: decoded at ${decoded.rate} Hz`);
      if (lag !== 0) failures.push(`${v.file}: decoded ${lag} samples off`);
      if (Math.abs(lengthDiff) > 1152) failures.push(`${v.file}: decoded length differs by ${lengthDiff} samples`);
      if (!(bands <= 1.5)) failures.push(`${v.file}: a strong third-octave band moved ${bands.toFixed(2)} dB`);
      if (!(weakBands <= 3)) failures.push(`${v.file}: a weak third-octave band moved ${weakBands.toFixed(2)} dB`);
      if (!(envelope >= 0.98)) failures.push(`${v.file}: envelope correlation ${envelope.toFixed(3)}`);
      if (seam && (seam.ratio > 1.5 || seam.level > 1.5)) failures.push(`${v.file}: decoded loop seam ratio ${seam.ratio.toFixed(2)}, level ${seam.level.toFixed(2)} dB`);
    }
  }
  await browser.close();
  const pct = (list, q) => list.slice().sort((a, b) => a - b)[Math.floor((list.length - 1) * q)];
  const snrs = rows.map((x) => x.snr);
  const onsets = rows.map((x) => x.onset);
  const loops = rows.filter((x) => x.seam);
  console.log(`decoded ${rows.length} files in headless Chromium (decodeAudioData, OfflineAudioContext ${SR} Hz)`);
  console.log(`  offset: ${rows.filter((x) => x.lag === 0).length}/${rows.length} at 0 samples; length: ${rows.filter((x) => x.lengthDiff === 0).length}/${rows.length} exact`);
  console.log(`  SNR (render / codec residual): min ${Math.min(...snrs).toFixed(1)} dB, median ${pct(snrs, 0.5).toFixed(1)} dB (reported, not judged)`);
  console.log(`  third-octave bands within 20 dB of the loudest: worst ${Math.max(...rows.map((x) => x.bands)).toFixed(2)} dB, median ${pct(rows.map((x) => x.bands), 0.5).toFixed(2)} dB; 20-30 dB down: worst ${Math.max(...rows.map((x) => x.weakBands)).toFixed(2)} dB`);
  console.log(`  envelope correlation (1 ms): worst ${Math.min(...rows.map((x) => x.envelope)).toFixed(4)}, median ${pct(rows.map((x) => x.envelope), 0.5).toFixed(4)}`);
  console.log(`  length: ${rows.filter((x) => x.lengthDiff !== 0).map((x) => `${x.file} ${x.lengthDiff > 0 ? '+' : ''}${x.lengthDiff}`).join(', ') || 'all exact'}`);
  console.log(`  first 10 ms residual: median ${pct(onsets, 0.5).toFixed(1)} dB under the render`);
  if (loops.length) console.log(`  loops: ${loops.length}, worst decoded seam ratio ${Math.max(...loops.map((x) => x.seam.ratio)).toFixed(2)}, level ${Math.max(...loops.map((x) => x.seam.level)).toFixed(2)} dB`);
  const worst = rows.slice().sort((a, b) => a.snr - b.snr).slice(0, 5);
  console.log(`  lowest SNR: ${worst.map((x) => `${x.file} ${x.snr.toFixed(1)}`).join(', ')}`);
  fs.mkdirSync(path.join(BUILD, 'audit'), { recursive: true });
  fs.writeFileSync(path.join(BUILD, 'audit', 'format.json'), JSON.stringify(rows, null, 1));
  if (failures.length) {
    console.log(`FAIL: ${failures.length}\n  ${failures.slice(0, 40).join('\n  ')}`);
    process.exit(1);
  }
  console.log('format: pass');
}

await main();
