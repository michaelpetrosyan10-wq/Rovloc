// voice.mjs: a throat's flutter. flutter() is the soft palate's rattle: a 20-35 Hz train of closures and reopenings
// laid on his throat recordings (a recipe layer's `flutter`, lib/recipe.mjs), the way a slowed voice's fry is
// thickened in creature design.

/** @typedef {number|Float32Array} Signal */

const at = (v, i) => (typeof v === 'number' ? v : v[Math.min(i, v.length - 1)]);

/**
 * A soft-palate rattle: the flap of wet tissue fluttering in the airflow at `rate` Hz (20-35 for something huge),
 * as a gain track (0..1): each closure a short dip, each reopening a burst. Irregular period to period.
 * @param {number} n
 * @param {number} sr
 * @param {{rate: Signal, depth: Signal, rng: import('./rng.mjs').Rng, irregularity?: number}} spec
 */
export function flutter(n, sr, { rate, depth, rng, irregularity = 0.3 }) {
  const out = new Float32Array(n);
  let ph = 0;
  let step = 1;
  let open = 0.55;
  for (let i = 0; i < n; i++) {
    ph += (at(rate, i) * step) / sr;
    if (ph >= 1) {
      ph -= 1;
      step = 1 + irregularity * rng.range(-0.5, 0.5);
      open = 0.35 + 0.4 * rng.next();
    }
    // closed for (1 - open) of the cycle, a burst at the reopening; wet tissue closes softly (a smooth zero, not a
    // cusp: a cusp is a click every cycle, a buzz of clicks up to 10 kHz instead of a rattle)
    const g = ph < open ? Math.sin((Math.PI * ph) / open) ** 1.5 : 0;
    const d = at(depth, i);
    out[i] = 1 - d + d * g * 1.5;
  }
  return out;
}
