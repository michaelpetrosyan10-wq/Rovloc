// subtitles.js: who says what, on screen (docs/design/game-spec-v2.md 3.4's Subtitles, 2.3's Lines), the primitive the
// story's cutscenes and the talking monster share.
//
// A subtitle is a speaker's label and the line: the label in caps, struck through for the monster wearing its host's
// name (DANNY in the school, GUS in the city); the line in italics for a whisper at your ear (the Ear channel); a
// direction glyph before it when the speaker has a place (▴ ahead within 45°, ▸ right, ◂ left, ▾ behind beyond 135°).
// Each shows for its `seconds` (a cutscene's line its slot; a line in play subtitleSeconds(text)), fading at its ends,
// at `opacity` (a voice far off is fainter). The newest sits lowest; at most MAX are up, the oldest giving way. The
// subtitles sit over the letterbox's lower bar while a cutscene shows one. "Captions" (the engine's) covers sound
// effects; speech always has its subtitle. The two share the screen: each frame the subtitles tell the engine's UI how
// high their rows (or the letterbox's bar) reach, and the captions' column sits above that (ui.setCaptionFloor).
//
//   const subs = new Subtitles(game)
//   subs.show({speaker: 'DANNY', struck, text, ear, bearing (degrees, 0 ahead, + right) | null, seconds, opacity})
//   subs.clear()
//   subtitleSeconds(text)   3.4: clamp(1.5 + 0.06 x characters, 2.5, 7)

import { Fonts, Palette, el } from './style.js';

const MAX = 3;
const FADE = 0.25;

/** How long a line in play stays up (3.4). */
export function subtitleSeconds(text) {
  return Math.min(7, Math.max(2.5, 1.5 + 0.06 * String(text).length));
}

/** The direction glyph for a speaker at `bearing` degrees (0 ahead, positive to the right), or '' for none. */
export function directionGlyph(bearing) {
  if (bearing === null || bearing === undefined || !Number.isFinite(bearing)) return '';
  const b = ((bearing % 360) + 540) % 360 - 180;
  const a = Math.abs(b);
  if (a <= 45) return '▴';
  if (a > 135) return '▾';
  return b > 0 ? '▸' : '◂';
}

export class Subtitles {
  /** @param {import('../game.js').Game} game */
  constructor(game) {
    this.name = 'Subtitles';
    this.game = game;
    this.env = game.env;
    this.root = el('div', 'rg-layer', this.env.uiRoot());
    Object.assign(this.root.style, { zIndex: '41', display: 'flex', flexDirection: 'column', justifyContent: 'flex-end',
      alignItems: 'center', paddingBottom: '9vh', gap: '6px' });
    /** @type {{el: HTMLElement, shownAt: number, seconds: number, opacity: number}[]} */
    this.lines = [];
    /** the lower edge the subtitles keep above (a share of the screen's height: the letterbox's bar) */
    this.lift = 0;
  }

  /**
   * @param {{speaker: string, struck?: boolean, text: string, ear?: boolean, bearing?: number|null, seconds: number,
   *   opacity?: number}} line
   */
  show(line) {
    const row = el('div', 'rg-body rg-outline', this.root);
    Object.assign(row.style, { maxWidth: 'min(760px, 90vw)', textAlign: 'center', fontSize: 'clamp(16px, 2.2vw, 22px)',
      color: Palette.Bone, background: 'rgba(8,8,9,0.55)', padding: '4px 12px', borderRadius: '4px', opacity: '0' });
    const label = el('span', '', row, line.speaker ? `${line.speaker}` : '');
    Object.assign(label.style, { fontFamily: Fonts.Strong, letterSpacing: '0.12em', color: Palette.Amber,
      marginRight: line.speaker ? '10px' : '0', textDecoration: line.struck ? 'line-through' : 'none' });
    const glyph = directionGlyph(line.bearing);
    if (glyph) {
      const g = el('span', '', row, glyph);
      g.style.marginRight = '6px';
      g.style.color = Palette.Ash;
    }
    const text = el('span', '', row, line.text);
    if (line.ear) text.style.fontStyle = 'italic';
    this.lines.push({ el: row, shownAt: this.env.now(), seconds: Math.max(0.2, line.seconds),
      opacity: line.opacity ?? 1 });
    while (this.lines.length > MAX) this.lines.shift().el.remove();
    return row;
  }

  /** Everything off at once. */
  clear() {
    for (const l of this.lines) l.el.remove();
    this.lines.length = 0;
  }

  /** The lower bar's share of the screen the subtitles sit over (0 when none). */
  setLift(share) {
    this.lift = share;
    this.root.style.paddingBottom = share > 0 ? `${(share * 100 + 2).toFixed(1)}vh` : '9vh';
  }

  frame() {
    const now = this.env.now();
    for (let i = this.lines.length - 1; i >= 0; i--) {
      const l = this.lines[i];
      const age = now - l.shownAt;
      if (age >= l.seconds) {
        l.el.remove();
        this.lines.splice(i, 1);
        continue;
      }
      const a = Math.min(1, age / FADE, (l.seconds - age) / FADE);
      l.el.style.opacity = (Math.max(0, a) * l.opacity).toFixed(3);
    }
    this.env.setCaptionFloor(this.reach());
  }

  /** How high (px from the bottom of the screen) the rows up, or else the letterbox's bar, reach (0: nothing). */
  reach() {
    if (!this.lines.length && !(this.lift > 0)) return 0;
    const screen = this.root.getBoundingClientRect();
    if (this.lines.length) return screen.bottom - this.lines[0].el.getBoundingClientRect().top;
    return this.lift * screen.height;
  }

  endRun() {
    this.clear();
  }
}
