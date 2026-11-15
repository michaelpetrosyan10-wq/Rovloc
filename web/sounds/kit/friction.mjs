// friction.mjs: stick-slip. Two surfaces pressed together and pushed: the contact sticks, stress builds with the
// motion, and when it passes static friction (mu_s * force) it slips, dropping to kinetic friction (mu_d * force) and
// throwing one impulse into whatever it touches. Slow and heavy gives a creak (tens of slips a second into a wooden
// body); fast and light a scrape (hundreds, rough); a surface's roughness under the moving contact gives grit. The
// slip rate is stiffness * velocity / ((mu_s - mu_d) * force).
//
// bowed() couples the pulse train to the body it drives: the body's own motion at the contact feeds back into the
// relative velocity, so the slips lock onto its modes the way a bow locks onto a string: a squeal, a shriek of steel.

import { decayFactor, smoothRandom } from './env.mjs';

/** @typedef {number|Float32Array} Signal */

const at = (v, i) => (typeof v === 'number' ? v : v[Math.min(i, v.length - 1)]);

/**
 * A stick-slip impulse train (signed impulses, one per slip).
 * @param {number} n samples
 * @param {number} sr
 * @param {{velocity: Signal, force: Signal, stiffness?: number, muS?: number, muD?: number, irregularity?: number,
 *   roughness?: number, grain?: number, rng: import('./rng.mjs').Rng}} spec velocity and force 0..1-ish per sample;
 *   irregularity scatters each slip's threshold; roughness modulates it by a surface profile under the moving
 *   contact (grain: profile features per unit of travel)
 */
export function stickSlip(n, sr, { velocity, force, stiffness = 40, muS = 1, muD = 0.6, irregularity = 0.2, roughness = 0, grain = 60, rng }) {
  const out = new Float32Array(n);
  const profile = roughness > 0 ? smoothRandom(4096, 4096, 1, rng.fork('profile')) : null;
  let stress = 0;
  let travel = 0;
  let scatter = 1 + irregularity * rng.range(-0.5, 0.5);
  for (let i = 0; i < n; i++) {
    const v = Math.max(0, at(velocity, i));
    const f = Math.max(1e-4, at(force, i));
    stress += (stiffness * v) / sr;
    travel += v / sr;
    let thr = muS * f * scatter;
    if (profile) thr *= 1 + roughness * profile[Math.floor(travel * grain) % profile.length];
    if (stress >= thr && v > 0) {
      const rest = muD * f;
      out[i] = stress - rest;
      stress = rest * (1 + 0.1 * irregularity * rng.range(-1, 1));
      scatter = 1 + irregularity * rng.range(-0.5, 0.5);
    }
  }
  return out;
}

/**
 * A bowed body: friction at one contact driving a bank of modes, the modes' velocity at the contact fed back.
 * Returns the body's sound.
 * @param {number} n samples
 * @param {number} sr
 * @param {{modes: import('./modal.mjs').Mode[], velocity: Signal, force: Signal, coupling?: number, stiffness?: number,
 *   muS?: number, muD?: number, irregularity?: number, rng: import('./rng.mjs').Rng}} spec
 */
export function bowed(n, sr, { modes, velocity, force, coupling = 0.6, stiffness = 900, muS = 1, muD = 0.55, irregularity = 0.15, rng }) {
  const out = new Float32Array(n);
  const count = modes.length;
  const c = new Float64Array(count);
  const d = new Float64Array(count);
  const s = new Float64Array(count);
  const y1 = new Float64Array(count);
  const y2 = new Float64Array(count);
  for (let k = 0; k < count; k++) {
    const m = modes[k];
    const r = decayFactor(m.t60, sr);
    const w = (2 * Math.PI * Math.min(m.f, sr * 0.47)) / sr;
    c[k] = 2 * r * Math.cos(w);
    d[k] = r * r;
    s[k] = (m.gain ?? 1) * Math.sin(w);
  }
  let stress = 0;
  let prevBody = 0;
  let scatter = 1;
  for (let i = 0; i < n; i++) {
    const v = Math.max(0, at(velocity, i));
    const f = Math.max(1e-4, at(force, i));
    // the body's velocity at the contact (the derivative of its displacement) opposes the bow
    let body = 0;
    for (let k = 0; k < count; k++) body += y1[k];
    // (bounded: the body pushes back on the bow, it never runs away with it)
    const bodyVel = Math.tanh((body - prevBody) * sr * 1e-3);
    prevBody = body;
    const rel = v - coupling * bodyVel;
    stress += (stiffness * rel) / sr;
    let pulse = 0;
    const thr = muS * f * scatter;
    if (stress >= thr) {
      pulse = stress - muD * f;
      stress = muD * f;
      scatter = 1 + irregularity * rng.range(-0.5, 0.5);
    } else if (stress < -thr) {
      pulse = stress + muD * f;
      stress = -muD * f;
    }
    let sum = 0;
    for (let k = 0; k < count; k++) {
      const y = c[k] * y1[k] - d[k] * y2[k] + s[k] * pulse;
      y2[k] = y1[k];
      y1[k] = y;
      sum += y;
    }
    out[i] = sum;
  }
  return out;
}
