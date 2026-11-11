// strings/index.js: every player-facing string, by key. UI code calls S(key, ...args) and never embeds text.
//
// The lines come in files of their own: base.js (the school's lines, Shared/Strings.luau value for value, and the web's
// overrides of a few) and one file per package that adds lines (run.js: the run's stages, the stand-in and lives). A
// package's file calls defineStrings(table) once and is imported by the package's own modules, so a new package adds
// its lines without editing a shared file; a key defined twice is an error at load.

import { STRINGS, WEB_OVERRIDES } from './base.js';

/** @type {Map<string, string>} the packages' lines (defineStrings) */
const DEFINED = new Map();

/**
 * Adds a package's lines. Throws on a key that base.js or another package already defines.
 * @param {Record<string, string>} table
 */
export function defineStrings(table) {
  for (const [key, value] of Object.entries(table)) {
    if (key in STRINGS || key in WEB_OVERRIDES || DEFINED.has(key)) throw new Error(`string ${key} is defined twice`);
    if (typeof value !== 'string') throw new Error(`string ${key} is not text`);
    DEFINED.set(key, value);
  }
}

function template(key) {
  return WEB_OVERRIDES[key] ?? DEFINED.get(key) ?? STRINGS[key];
}

/**
 * Formats a string by key (Strings.get): %d, %s, %.Nf, %02d and %% like Lua's string.format. Unknown keys return the
 * key itself so a missing string is visible but harmless.
 * @param {string} key
 * @param {...any} args
 * @returns {string}
 */
export function S(key, ...args) {
  const text = template(key);
  if (text === undefined) return key;
  if (args.length === 0) return text.replace(/%%/g, '%');
  let i = 0;
  return text.replace(/%(%|0?\d*d|s|\.\d+f|d)/g, (m) => {
    if (m === '%%') return '%';
    const v = args[i++];
    if (m === '%s') return String(v);
    if (m.endsWith('f')) return Number(v).toFixed(Number(m.slice(2, -1)));
    const n = Math.trunc(Number(v) || 0);
    const pad = m.match(/^%0(\d+)d$/);
    return pad ? String(n).padStart(Number(pad[1]), '0') : String(n);
  });
}

/** Whether a key exists. */
export function hasString(key) {
  return template(key) !== undefined;
}
