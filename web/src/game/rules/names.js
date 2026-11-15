// names.js: the port of Shared/Rules/NameSanitizer.luau (docs/design/game-spec-v2.md 3.4, 2.3), function for function.
// Pure, ASCII only; the rules' lists are the world's own (world.json meta.storyConfig.Names). nameRules(meta) binds the
// functions to them; tools/story-test.mjs replays every NameSanitizer row of build/cache/golden.json (I11).
//
//   tokens(raw)          the input split at spaces, underscores, digits and CamelCase boundaries
//   normalise(raw)       lower case, leetspeak read as letters, every other character but a-z dropped
//   blocked(raw)         normalise(raw) or the first token on the blocklist, or holding one of its stems
//   sanitize(raw)        the first token when it is letters, ' and - only (starting with a letter), Min..Max long and
//                        not blocked, capitalised; '' otherwise (the nameless twin)
//   slots(text)          the name slots a line uses, in order
//   fill(text, names)    the line with every slot filled; '' when a name is missing or empty
//   compose(line, names, sayNames)  the filled text, or the twin when names are off or one is missing

const isUpper = (b) => b >= 65 && b <= 90;
const isLower = (b) => b >= 97 && b <= 122;
const isLetter = (b) => isUpper(b) || isLower(b);
/** space, tab, newline, carriage return, underscore, a digit */
const isSeparator = (b) => b === 32 || b === 9 || b === 10 || b === 13 || b === 95 || (b >= 48 && b <= 57);
/** Luau's string.lower / upper: ASCII letters only. */
const lowerAscii = (s) => s.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 32));
const upperAscii = (s) => s.replace(/[a-z]/g, (c) => String.fromCharCode(c.charCodeAt(0) - 32));

/** The UTF-8 bytes of a string, as Luau sees it. */
function bytesOf(text) {
  return Array.from(new TextEncoder().encode(String(text)));
}

/**
 * The name rules bound to a world's story config.
 * @param {{storyConfig: {Names: {Min: number, Max: number, Leet: Record<string, string>, Blocked: string[],
 *   Stems: string[]}}}} meta
 */
export function nameRules(meta) {
  const names = meta && meta.storyConfig && meta.storyConfig.Names;
  if (!names) throw new Error('the world carries no storyConfig.Names');
  const leet = names.Leet || {};
  const blockedList = Array.isArray(names.Blocked) ? names.Blocked : [];
  const stems = Array.isArray(names.Stems) ? names.Stems : [];
  const decoder = new TextDecoder();

  function tokens(raw) {
    const bytes = bytesOf(raw);
    const out = [];
    let current = [];
    const flush = () => {
      if (current.length > 0) {
        out.push(decoder.decode(new Uint8Array(current)));
        current = [];
      }
    };
    for (let i = 0; i < bytes.length; i++) {
      const b = bytes[i];
      if (isSeparator(b)) {
        flush();
        continue;
      }
      if (isUpper(b) && current.length > 0) {
        const prev = bytes[i - 1];
        const next = i + 1 < bytes.length ? bytes[i + 1] : 0;
        if (isLower(prev) || (isUpper(prev) && isLower(next))) flush();
      }
      current.push(b);
    }
    flush();
    return out;
  }

  function normalise(raw) {
    let out = '';
    for (const b of bytesOf(lowerAscii(String(raw)))) {
      const c = String.fromCharCode(b);
      const mapped = leet[c] ?? c;
      if (isLower(mapped.charCodeAt(0))) out += mapped;
    }
    return out;
  }

  const holdsStem = (text) => stems.some((stem) => text.includes(stem));
  const onList = (word) => blockedList.includes(word);

  function blocked(raw) {
    const whole = normalise(raw);
    if (holdsStem(whole) || onList(whole)) return true;
    const first = tokens(raw)[0];
    if (first === undefined) return false;
    const word = normalise(first);
    return holdsStem(word) || onList(word);
  }

  function sanitize(raw) {
    const first = tokens(raw)[0];
    if (first === undefined) return '';
    const bytes = bytesOf(first);
    if (bytes.length < names.Min || bytes.length > names.Max || !isLetter(bytes[0])) return '';
    for (let i = 1; i < bytes.length; i++) {
      const b = bytes[i];
      if (!(isLetter(b) || b === 39 || b === 45)) return '';
    }
    if (blocked(raw)) return '';
    return upperAscii(first.slice(0, 1)) + lowerAscii(first.slice(1));
  }

  function slots(text) {
    const out = [];
    for (const m of String(text).matchAll(/\{([A-Za-z0-9]+)\}/g)) out.push(m[1]);
    return out;
  }

  function fill(text, given) {
    const map = given || {};
    for (const slot of slots(text)) {
      const name = map[slot];
      if (typeof name !== 'string' || name === '') return '';
    }
    return String(text).replace(/\{([A-Za-z0-9]+)\}/g, (_, slot) => map[slot]);
  }

  function compose(line, given, sayNames) {
    if (slots(line.text).length === 0) return line.text;
    const filled = sayNames ? fill(line.text, given) : '';
    if (filled !== '') return filled;
    return line.twin ?? '';
  }

  return { tokens, normalise, blocked, sanitize, slots, fill, compose };
}
