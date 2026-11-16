// worker.mjs: renders one variant in a worker thread (render.mjs runs at most two): the voice's render, the pipeline,
// the raw finished samples (for the audit) and the shipped MP3, and a few numbers for the manifest.

import fs from 'node:fs';
import path from 'node:path';
import { parentPort } from 'node:worker_threads';
import { pathToFileURL } from 'node:url';
import { renderVariant } from './pipeline.mjs';
import { encodeMp3 } from './encode.mjs';
import { writeRaw } from './raw.mjs';
import { SR } from './voices.mjs';
import { truePeak, momentaryMax, integrated } from '../kit/loudness.mjs';
import { rmsEnvelope, mono, spectrumOf } from './measure.mjs';

/** A sound is dark when at most this share of its energy lies over DARK_ABOVE Hz: the game decodes it at 24 kHz. */
const DARK_SHARE = 2e-4;
const DARK_ABOVE = 9000;

/** Whether nothing of a sound is lost at a 24 kHz sample rate (docs/SOUND.md 11: half the decoded memory). */
function isDark(channels) {
  const { power, size } = spectrumOf(mono(channels), SR);
  let high = 0;
  let total = 0;
  for (let k = 1; k < power.length; k++) {
    total += power[k];
    if ((k * SR) / size >= DARK_ABOVE) high += power[k];
  }
  return total > 0 && high / total <= DARK_SHARE;
}

/** Seconds from the loudest 10 ms to where the sound stays 60 dB under it. */
function tailSeconds(channels) {
  const env = rmsEnvelope(mono(channels), SR, 0.01);
  let max = 0;
  let at = 0;
  for (let i = 0; i < env.length; i++) if (env[i] > max) {
    max = env[i];
    at = i;
  }
  let end = env.length - 1;
  while (end > at && env[end] < max * 1e-3) end--;
  return (end - at) / SR;
}

parentPort?.on('message', async (job) => {
  try {
    const mod = await import(pathToFileURL(job.file).href);
    const voice = mod.voices.find((v) => v.name === job.name);
    if (!voice) throw new Error(`${job.name} is not in ${job.file}`);
    const started = performance.now();
    const r = renderVariant(voice, job.variant);
    fs.mkdirSync(path.dirname(job.raw), { recursive: true });
    fs.mkdirSync(path.dirname(job.mp3), { recursive: true });
    const stats = {
      key: job.key,
      seconds: r.render[0].length / SR,
      fileSeconds: r.channels[0].length / SR,
      truePeak: truePeak(r.render),
      loudness: voice.loop ? integrated(r.render, SR) : momentaryMax(r.render, SR),
      tail: voice.loop ? 0 : tailSeconds(r.render),
      loop: r.loop,
      dark: isDark(r.render),
      renderMs: Math.round(performance.now() - started),
    };
    writeRaw(job.raw, r.render, SR, stats);
    encodeMp3(r.channels, SR, job.mp3);
    parentPort.postMessage({ ok: true, stats: { ...stats, bytes: fs.statSync(job.mp3).size } });
  } catch (err) {
    parentPort.postMessage({ ok: false, error: err instanceof Error ? err.stack : String(err) });
  }
});
