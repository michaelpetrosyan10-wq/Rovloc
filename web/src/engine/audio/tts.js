// tts.js: spoken lines on the website (docs/design/game-spec-v2.md 3.4's Words and Fallback rows, 2.3's Lines), a
// primitive the story's cutscenes and the talking monster share.
//
// Words. One SpeechSynthesisUtterance per line (at most 12 words), its pitch and rate the speaker's (2.2), its volume
// the caller's (master x voice x gain). Only voices the device speaks itself (SpeechSynthesisVoice.localService): a
// remote voice would send the line to a foreign host, which the website never does. The voices are scored per role
// (+3 local, +1 English, +2 a name hint: the young male voice for Danny, the older male for Gus); with a single voice
// the pitch and rate tell the roles apart. The caller ends a line at its slot (handle.cancel); a line still speaking
// when the next starts is cut.
// Fallback. No local voice, no speechSynthesis, or a speech error: the line's body is a murmur instead, one breathy
// syllable (the SpeechMurmur preset) per syllable of the text, spread over the slot, at the speaker's place (the
// subtitle always carries the words). The talking monster's throat layer (WP12) takes the murmur's place for its
// lines.
//
//   const speech = new Speech(audio)
//   speech.speak({text, pitch, rate, volume, seconds, role, position?, muffled?}) -> {mode: 'voice'|'fallback', cancel()}
//   speech.available()      whether a local voice can speak
//   syllables(text)         the syllables a line's body plays (vowel groups; at least one a word)

const HINTS = Object.freeze({
  // the name hints of the voices the platforms ship, per role (2.2's casting): Danny young male, Gus older male
  Young: ['alex', 'daniel', 'aaron', 'tom', 'guy', 'male'],
  Older: ['fred', 'arthur', 'albert', 'ralph', 'george', 'male'],
});
const MURMUR_GAP = 0.04;

/** The syllables of a line: vowel groups per word (y counts), at least one a word. */
export function syllables(text) {
  let total = 0;
  for (const word of String(text).toLowerCase().split(/\s+/)) {
    const letters = word.replace(/[^a-z]/g, '');
    if (!letters) continue;
    const groups = letters.match(/[aeiouy]+/g);
    total += Math.max(1, groups ? groups.length : 0);
  }
  return total;
}

/** The voice to speak a role with: the best scored local voice, or null. */
function pickVoice(voices, role) {
  const hints = role === 'Older' ? HINTS.Older : role === 'Young' ? HINTS.Young : [];
  let best = null;
  let bestScore = -Infinity;
  for (const v of voices) {
    if (!v.localService) continue;
    const name = String(v.name || '').toLowerCase();
    let score = 3;
    if (/^en\b|^en-/i.test(v.lang || '')) score += 1;
    if (hints.some((h) => name.includes(h))) score += 2;
    if (score > bestScore) {
      best = v;
      bestScore = score;
    }
  }
  return best;
}

export class Speech {
  /** @param {any} audio the engine's Audio (the fallback's murmur plays through it) */
  constructor(audio) {
    this.audio = audio;
    this.synth = typeof window !== 'undefined' && window.speechSynthesis ? window.speechSynthesis : null;
    /** @type {SpeechSynthesisVoice[]} */
    this.voices = [];
    this.current = null;
    if (this.synth) {
      this._loadVoices();
      if (typeof this.synth.addEventListener === 'function') this.synth.addEventListener('voiceschanged', () => this._loadVoices());
    }
  }

  _loadVoices() {
    try {
      this.voices = this.synth.getVoices().filter((v) => v.localService);
    } catch {
      this.voices = [];
    }
  }

  /** Whether a local voice can speak. */
  available() {
    return !!this.synth && this.voices.length > 0;
  }

  /**
   * Speaks a line (or murmurs it). Returns its handle; cancel() ends it (at its slot's end, or when the scene ends).
   * @param {{text: string, pitch: number, rate: number, volume: number, seconds: number, role?: string,
   *   position?: import('three').Vector3, muffled?: boolean}} line
   */
  speak(line) {
    if (this.current) this.current.cancel();
    const handle = this.available() ? this._voice(line) : null;
    this.current = handle || this._murmur(line);
    return this.current;
  }

  _voice(line) {
    const voice = pickVoice(this.voices, line.role);
    if (!voice) return null;
    let utterance;
    try {
      utterance = new SpeechSynthesisUtterance(line.text);
    } catch {
      return null;
    }
    utterance.voice = voice;
    utterance.lang = voice.lang;
    utterance.pitch = Math.max(0, Math.min(2, line.pitch));
    utterance.rate = Math.max(0.1, Math.min(10, line.rate));
    utterance.volume = Math.max(0, Math.min(1, line.volume * (line.muffled ? 0.7 : 1)));
    const handle = { mode: 'voice', done: false, fallback: null,
      cancel: () => {
        if (handle.done) return;
        handle.done = true;
        if (handle.fallback) handle.fallback.cancel();
        else this.synth.cancel();
      } };
    utterance.onerror = () => {
      if (handle.done || handle.fallback) return;
      // a speech error: the line's body is the murmur from here
      handle.mode = 'fallback';
      handle.fallback = this._murmur(line);
    };
    utterance.onend = () => {
      if (!handle.fallback) handle.done = true;
    };
    this.synth.speak(utterance);
    return handle;
  }

  _murmur(line) {
    const count = Math.max(1, syllables(line.text));
    const span = Math.max(0.3, line.seconds * 0.9);
    const step = Math.max(MURMUR_GAP, span / count);
    const timers = [];
    const voices = [];
    const handle = { mode: 'fallback', done: false,
      cancel: () => {
        if (handle.done) return;
        handle.done = true;
        for (const t of timers) clearTimeout(t);
        for (const v of voices) if (v && v.stop) v.stop(0.05);
      } };
    const play = () => {
      if (handle.done || !this.audio) return;
      const v = this.audio.play('SpeechMurmur', { position: line.position || undefined,
        volume: Math.max(0, line.volume) * (line.muffled ? 0.6 : 1), speed: Math.max(0.5, Math.min(2, line.pitch)) });
      if (v) voices.push(v);
    };
    for (let i = 0; i < count; i++) timers.push(setTimeout(play, i * step * 1000));
    return handle;
  }

  /** Ends whatever is speaking. */
  stop() {
    if (this.current) this.current.cancel();
    this.current = null;
  }
}
