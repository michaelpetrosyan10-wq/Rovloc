// noise.mjs: the noise colours exciters are cut from. White is Gaussian (not uniform: real turbulence and friction
// are), pink falls 3 dB/octave (Kellet's refined filter), brown 6 dB/octave (a leaky integrator), velvet is sparse
// random-sign impulses (the cheapest smooth "diffuse" excitation and a grit texture).

/**
 * Gaussian white noise, standard deviation `amp`.
 * @param {number} n samples
 * @param {import('./rng.mjs').Rng} rng
 * @param {number} [amp]
 */
export function white(n, rng, amp = 1) {
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = rng.normal() * amp;
  return out;
}

/**
 * Pink noise (-3 dB/octave), about unit standard deviation.
 * @param {number} n
 * @param {import('./rng.mjs').Rng} rng
 */
export function pink(n, rng) {
  const out = new Float32Array(n);
  let b0 = 0;
  let b1 = 0;
  let b2 = 0;
  let b3 = 0;
  let b4 = 0;
  let b5 = 0;
  let b6 = 0;
  for (let i = 0; i < n; i++) {
    const w = rng.normal();
    b0 = 0.99886 * b0 + w * 0.0555179;
    b1 = 0.99332 * b1 + w * 0.0750759;
    b2 = 0.969 * b2 + w * 0.153852;
    b3 = 0.8665 * b3 + w * 0.3104856;
    b4 = 0.55 * b4 + w * 0.5329522;
    b5 = -0.7616 * b5 - w * 0.016898;
    out[i] = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.33;
    b6 = w * 0.115926;
  }
  return out;
}

/**
 * Brown noise (-6 dB/octave above `corner` Hz), about unit standard deviation.
 * @param {number} n
 * @param {number} sr
 * @param {import('./rng.mjs').Rng} rng
 * @param {number} [corner] the leak's corner, Hz (below it the spectrum is flat: no DC wander)
 */
export function brown(n, sr, rng, corner = 20) {
  const out = new Float32Array(n);
  const leak = Math.exp((-2 * Math.PI * corner) / sr);
  const norm = Math.sqrt(1 - leak * leak);
  let y = 0;
  for (let i = 0; i < n; i++) {
    y = leak * y + rng.normal() * norm;
    out[i] = y;
  }
  return out;
}

/**
 * Velvet noise: about `density` random-sign unit impulses a second, one per grid cell at a random place in it.
 * @param {number} n
 * @param {number} sr
 * @param {number} density impulses per second
 * @param {import('./rng.mjs').Rng} rng
 */
export function velvet(n, sr, density, rng) {
  const out = new Float32Array(n);
  const cell = sr / density;
  for (let start = 0; start < n; start += cell) {
    const at = Math.floor(start + rng.next() * cell);
    if (at < n) out[at] = rng.sign();
  }
  return out;
}
