// rolloff.js: how loud a positional sound arrives (VoicePool.attenuation): InverseTapered between the preset's
// roll-off distances. A pure function, so the sound audit (web/sounds/audit.mjs) measures with the game's own.

/**
 * 1 within rollOff.min; then min / distance, tapering linearly to 0 at rollOff.max.
 * @param {number} distance studs
 * @param {{min: number, max: number}} rollOff
 */
export function attenuation(distance, rollOff) {
  if (distance <= rollOff.min) return 1;
  if (distance >= rollOff.max) return 0;
  return (rollOff.min / distance) * (1 - (distance - rollOff.min) / Math.max(rollOff.max - rollOff.min, 1e-3));
}
