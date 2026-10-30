// code.js: room codes and peer ids. A room code is five characters from an alphabet without the look-alikes (no 0 / O,
// no 1 / I), so it can be read out loud and typed on a Chromebook without mistakes; typing is forgiving about case,
// spaces and dashes.

import { NetConfig } from './config.js';

/** A random value in [0, 1) from the platform CSPRNG. */
function random() {
  const word = new Uint32Array(1);
  crypto.getRandomValues(word);
  return word[0] / 4294967296;
}

/** A fresh room code ("K7QXM"). */
export function newRoomCode() {
  let code = '';
  for (let i = 0; i < NetConfig.CodeLength; i++) {
    code += NetConfig.CodeAlphabet[Math.floor(random() * NetConfig.CodeAlphabet.length)];
  }
  return code;
}

/**
 * The code a player typed (upper-cased, spaces / dashes / dots dropped), or null when it is not a room code.
 * @param {string} typed
 * @returns {string|null}
 */
export function normalizeRoomCode(typed) {
  if (typeof typed !== 'string') return null;
  const code = typed.toUpperCase().replace(/[\s\-_.]/g, '');
  if (code.length !== NetConfig.CodeLength) return null;
  for (const ch of code) if (!NetConfig.CodeAlphabet.includes(ch)) return null;
  return code;
}

/** A short random peer id (base 36, 10 characters), unique per page load. */
export function newPeerId() {
  let id = '';
  for (let i = 0; i < 10; i++) id += Math.floor(random() * 36).toString(36);
  return id;
}
