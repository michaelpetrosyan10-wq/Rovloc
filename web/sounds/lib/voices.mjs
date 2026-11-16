// voices.mjs: the voice format (docs/SOUND.md 7) and the loader. A family file web/sounds/voices/<family>.mjs
// exports `voices`, an array of definitions; one definition is one sound of the game, rendered in 1-6 variants.
// A voice is a recipe over recordings (lib/recipe.mjs recorded() builds `sources` and `render` from its layers).
//
//   name         the game's name for it (the existing preset or recipe name where there is one)
//   title        plain words for the sound board ("His footsteps, walking, on concrete")
//   description  one line for the sound board
//   family       the voice file it lives in (one manifest per family)
//   group        'reference' | 'world' | 'air' (cast.json's owner group)
//   class        the audit class (lib/classes.mjs) its numbers are held to
//   him          for his sounds: the signatures it carries, of 'throat' (the low wet rattle of his throat) and 'gait'
//                (the heavy step); the audit measures at least one of them in every variant (law 7, I1)
//   repeats      true for what the game plays over and over (steps, drips, creaks): 3-6 variants
//   variants     how many (from different takes, not only re-pitched)
//   channels     1 (positional, most sounds) or 2 (beds, 2D stingers and music)
//   loop         null (a one-shot) or {seconds, crossfade}: the render is seconds + crossfade long and the pipeline
//                folds the crossfade over the start (a loop is seamless by construction)
//   space        'dry' (positional: the game adds distance and the room; it still carries its own body) or 'baked'
//                (its space is in the file: always-far events, 2D sounds). How far a positional sound carries is
//                not here: every distance is in the shared config (the preset's roll-off)
//   loudness     the reference loudness, LUFS: one-shots by their loudest 400 ms block, loops integrated
//   first        true for what a stage needs at once (him, the scares, footsteps, doors): the game decodes it
//                before the first frame; everything else in the background (docs/SOUND.md 11)
//   board        the sound board heading it is listed under
//   expect       optional per-voice audit overrides that only TIGHTEN or declare (resonance: true; bright: true)
//   sources      the recordings it is made from, as ids (lib/sources.mjs): at least one, each in SOURCES.json
//   render       ({sr, rng, variant, name, seconds}) => Float32Array | [Float32Array, Float32Array]

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { CLASSES } from './classes.mjs';

/**
 * @typedef {{
 *   name: string, title: string, description: string, family: string, group: 'reference'|'world'|'air',
 *   class: string, him?: Array<'throat'|'gait'>, repeats?: boolean, variants: number, channels: 1|2, loop: null|{seconds: number, crossfade: number},
 *   space: 'dry'|'baked', loudness: number, first?: boolean, board: string, sources: string[],
 *   expect?: {resonance?: boolean, bright?: boolean, minVariantDistance?: number, maxSeconds?: number},
 *   render: (ctx: {sr: number, rng: import('../kit/rng.mjs').Rng, variant: number, name: string, seconds: number})
 *     => Float32Array|[Float32Array, Float32Array],
 * }} Voice
 */

export const SR = 48000;
export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ROOT = path.resolve(HERE, '..');
export const VOICE_DIR = path.join(ROOT, 'voices');

/** The sound board's headings, in page order. */
export const BOARD = Object.freeze(['Him', 'His footsteps', 'Your footsteps', 'Glass', 'Doors and lockers', 'Power and machines', 'The building', 'Scares', 'Story', 'Menus']);

/**
 * Checks one definition's shape; returns a list of problems (empty when it is well formed).
 * @param {Voice} v
 */
export function validate(v) {
  const p = [];
  const need = (cond, msg) => {
    if (!cond) p.push(`${v.name ?? '?'}: ${msg}`);
  };
  need(typeof v.name === 'string' && /^[A-Z][A-Za-z0-9]+$/.test(v.name), 'name must be PascalCase');
  need(typeof v.title === 'string' && v.title.length > 3, 'needs a plain-words title');
  need(typeof v.description === 'string' && v.description.length > 10, 'needs a one-line description');
  need(['reference', 'world', 'air'].includes(v.group), 'group must be reference, world or air');
  need(Object.hasOwn(CLASSES, v.class), `unknown class ${v.class}`);
  need(Number.isInteger(v.variants) && v.variants >= 1 && v.variants <= 6, 'variants must be 1-6');
  need(v.channels === 1 || v.channels === 2, 'channels must be 1 or 2');
  need(v.loop === null || (v.loop && v.loop.seconds >= 8 && v.loop.seconds <= 24 && v.loop.crossfade >= 0), 'loop must be null or {seconds 8-24, crossfade}');
  need(v.space === 'dry' || v.space === 'baked', "space must be 'dry' or 'baked'");
  need(Number.isFinite(v.loudness) && v.loudness < 0, 'needs a reference loudness (LUFS)');
  need(Array.isArray(v.sources) && v.sources.length > 0 && v.sources.every((id) => typeof id === 'string' && id.split('/').length === 3), 'needs its recordings (sources: "<lib>/<pack>/<file>" ids): no sound is bare synthesis');
  need(BOARD.includes(v.board), `board heading must be one of ${BOARD.join(', ')}`);
  need(typeof v.render === 'function', 'needs a render function');
  if (v.repeats) need(v.variants >= 3, 'a repeating sound needs 3-6 variants');
  need(v.him === undefined || (Array.isArray(v.him) && v.him.length > 0 && v.him.every((s) => ['throat', 'gait'].includes(s))), "him lists 'throat' or 'gait'");
  need(!v.him || v.group === 'reference', 'his sounds are the reference group');
  need(!!CLASSES[v.class]?.loop === false || v.loop !== null, `class ${v.class} is a loop`);
  return p;
}

/** Every family file in voices/, sorted. */
export function familyFiles() {
  if (!fs.existsSync(VOICE_DIR)) return [];
  return fs.readdirSync(VOICE_DIR).filter((f) => f.endsWith('.mjs')).sort().map((f) => path.join(VOICE_DIR, f));
}

/**
 * Loads every voice (or the families / names `only` names), validated; throws on a malformed one or a duplicate.
 * @param {string[]} [only] family or sound names
 * @returns {Promise<Voice[]>}
 */
export async function loadVoices(only) {
  /** @type {Voice[]} */
  const all = [];
  const problems = [];
  for (const file of familyFiles()) {
    const family = path.basename(file, '.mjs');
    const mod = await import(pathToFileURL(file).href);
    for (const v of mod.voices ?? []) {
      if (v.family !== family) problems.push(`${v.name}: family ${v.family} is not its file's (${family})`);
      problems.push(...validate(v));
      all.push(v);
    }
  }
  const seen = new Set();
  for (const v of all) {
    if (seen.has(v.name)) problems.push(`${v.name}: defined twice`);
    seen.add(v.name);
  }
  if (problems.length) throw new Error(`malformed voices:\n  ${problems.join('\n  ')}`);
  if (!only || !only.length) return all;
  const picked = all.filter((v) => only.includes(v.family) || only.includes(v.name));
  const unknown = only.filter((o) => !all.some((v) => v.family === o || v.name === o));
  if (unknown.length) throw new Error(`no family or sound named ${unknown.join(', ')}`);
  return picked;
}

/** The file stem of one rendered variant. */
export function stem(name, variant) {
  return `${name}-${variant}`;
}
