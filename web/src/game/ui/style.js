// The game screens' look (UIKit.luau's palette and fonts, as the engine HUD uses them): near-black grimy panels,
// taped paper sheets for the walkthrough and the consoles, bone-white typewriter titles, condensed caps for data,
// one accent per meaning (amber light, moss ready / stamina, cyan air, blood and ember for danger). Only installed /
// generic font families: the page never downloads a font.

export const Palette = Object.freeze({
  Ink: 'rgb(8,8,9)',
  Panel: 'rgb(15,14,15)',
  Raised: 'rgb(26,24,24)',
  Track: 'rgb(40,37,35)',
  Stroke: 'rgb(84,77,68)',
  StrokeDim: 'rgb(48,45,42)',
  Bone: 'rgb(208,201,188)',
  Ash: 'rgb(134,128,118)',
  Smoke: 'rgb(92,88,82)',
  Blood: 'rgb(142,24,20)',
  Ember: 'rgb(198,58,40)',
  Amber: 'rgb(204,158,88)',
  Moss: 'rgb(150,158,132)',
  Cyan: 'rgb(110,148,160)',
  Paper: 'rgb(196,186,164)',
});

export const Fonts = Object.freeze({
  Title: '"Special Elite", "Courier Prime", "American Typewriter", Cousine, "Courier New", Courier, monospace',
  Strong: 'Oswald, "Bebas Neue", "Roboto Condensed", "Arial Narrow", "Liberation Sans Narrow", "DejaVu Sans Condensed", "Helvetica Neue", Arial, sans-serif',
  Body: '"Segoe UI", Roboto, Arimo, "Helvetica Neue", Arial, sans-serif',
});

const GRAIN = `url("data:image/svg+xml;utf8,${encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180"><filter id="n"><feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" stitchTiles="stitch"/><feColorMatrix values="0 0 0 0 1  0 0 0 0 0.93  0 0 0 0 0.84  0 0 0 0.11 0"/></filter><rect width="180" height="180" filter="url(#n)"/></svg>',
)}")`;

const STAIN = `radial-gradient(ellipse at 18% 82%, rgba(60,40,20,0.22), rgba(0,0,0,0) 46%), radial-gradient(ellipse at 88% 12%, rgba(40,30,18,0.18), rgba(0,0,0,0) 40%)`;

export const GAME_CSS = `
.rg-layer { position: absolute; inset: 0; pointer-events: none; }
.rg-screen { position: absolute; inset: 0; pointer-events: auto; display: flex; align-items: center; justify-content: center;
  transition: opacity 0.6s linear; }
.rg-hidden { display: none !important; }
.rg-panel { background-color: rgba(15,14,15,0.86); background-image: ${GRAIN}, ${STAIN}, linear-gradient(180deg, rgba(26,24,24,0.4), rgba(8,8,9,0.3));
  border: 1px solid rgba(48,45,42,0.9); border-radius: 6px; box-shadow: 0 2px 22px rgba(0,0,0,0.6); color: ${Palette.Bone}; }
.rg-sheet { position: relative; background-color: rgba(18,17,17,0.95); background-image: ${GRAIN}, ${STAIN}, linear-gradient(175deg, rgba(40,36,32,0.5), rgba(8,8,9,0.2));
  border: 1px solid rgba(84,77,68,0.75); border-radius: 4px; box-shadow: 0 6px 34px rgba(0,0,0,0.75); transform: rotate(-0.6deg); }
.rg-tape { position: absolute; width: 76px; height: 20px; background: rgba(208,201,188,0.38); box-shadow: 0 1px 2px rgba(0,0,0,0.3);
  top: -10px; z-index: 5; }
.rg-tape.l { left: 12%; transform: translateX(-50%) rotate(-9deg); }
.rg-tape.r { left: 88%; transform: translateX(-50%) rotate(7deg); }
.rg-caps { font-family: ${Fonts.Strong}; font-stretch: condensed; text-transform: uppercase; letter-spacing: 0.14em;
  font-size: 11px; color: ${Palette.Ash}; font-weight: 600; }
.rg-title { font-family: ${Fonts.Title}; letter-spacing: 0.04em; color: ${Palette.Bone}; }
.rg-body { font-family: ${Fonts.Body}; color: ${Palette.Bone}; line-height: 1.32; }
.rg-outline { text-shadow: 0 0 2px rgba(8,8,9,0.9), 0 1px 3px rgba(8,8,9,0.8); }
.rg-rule { height: 1px; background: rgba(48,45,42,1); }
.rg-btn { display: inline-flex; align-items: center; justify-content: center; gap: 10px; cursor: pointer; user-select: none;
  min-height: 46px; padding: 0 18px; background: rgba(26,24,24,0.92); color: ${Palette.Bone}; border: 1px solid ${Palette.StrokeDim};
  border-radius: 5px; font-family: ${Fonts.Strong}; font-size: 16px; letter-spacing: 0.1em; text-transform: uppercase;
  outline: none; transition: background 0.12s, border-color 0.12s, transform 0.08s; -webkit-tap-highlight-color: transparent; }
.rg-btn.primary { background: rgba(142,24,20,0.85); border-color: rgba(198,58,40,0.9); }
.rg-btn:hover, .rg-btn.focus { border-color: ${Palette.Bone}; background: rgba(48,45,42,0.95); }
.rg-btn.primary:hover, .rg-btn.primary.focus { background: rgba(170,34,26,0.95); border-color: ${Palette.Bone}; }
.rg-btn:active { transform: scale(0.97); }
.rg-btn[disabled] { opacity: 0.4; pointer-events: none; }
.rg-btn.small { min-height: 36px; font-size: 13px; padding: 0 12px; }
.rg-btn .rg-glyph { font-size: 11px; padding: 2px 6px; border: 1px solid rgba(208,201,188,0.5); border-radius: 4px; letter-spacing: 0.06em; }
.rg-meter { position: relative; height: 4px; background: rgba(40,37,35,0.8); border-radius: 2px; overflow: hidden; }
.rg-meter > div { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 2px; }
.rg-chip { display: inline-block; padding: 2px 8px; border-radius: 3px; font-family: ${Fonts.Strong}; font-size: 11px;
  letter-spacing: 0.14em; text-transform: uppercase; }
.rg-key { display: inline-flex; align-items: center; justify-content: center; min-width: 22px; height: 22px; padding: 0 5px;
  border: 1px solid rgba(208,201,188,0.6); border-radius: 4px; background: rgba(8,8,9,0.78); font-family: ${Fonts.Strong};
  font-size: 11px; font-weight: 700; color: ${Palette.Bone}; letter-spacing: 0.04em; }
.rg-key.round { border-radius: 50%; }
@keyframes rg-flicker { 0%, 100% { opacity: 1; } 41% { opacity: 1; } 42% { opacity: 0.55; } 43% { opacity: 1; } 77% { opacity: 0.9; } 78% { opacity: 0.4; } 80% { opacity: 1; } }
@keyframes rg-pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.55; } }
@media (max-width: 700px), (max-height: 520px) { .rg-btn { min-height: 40px; font-size: 14px; } }
`;

/** Installs the game CSS once. */
export function installStyle() {
  if (document.getElementById('rg-style')) return;
  const s = document.createElement('style');
  s.id = 'rg-style';
  s.textContent = GAME_CSS;
  document.head.appendChild(s);
}

/**
 * A tiny element builder: el('div', 'cls', parent, 'text').
 * @param {string} tag
 * @param {string} [className]
 * @param {HTMLElement|null} [parent]
 * @param {string} [text]
 * @returns {HTMLElement}
 */
export function el(tag, className, parent, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text !== undefined) e.textContent = text;
  if (parent) parent.appendChild(e);
  return e;
}

/** A thin meter: {root, set(fraction), color(c)}. */
export function meter(parent, color, width) {
  const root = el('div', 'rg-meter', parent);
  if (width) root.style.width = `${width}px`;
  const fill = el('div', '', root);
  fill.style.background = color;
  let last = -1;
  return {
    root,
    set(f) {
      const v = Math.min(1, Math.max(0, f));
      if (Math.abs(v - last) > 1e-3) {
        last = v;
        fill.style.width = `${v * 100}%`;
      }
    },
    color(c) {
      fill.style.background = c;
    },
  };
}
