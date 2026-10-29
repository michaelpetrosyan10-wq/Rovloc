// The HUD's look (UIKit.luau): near-black desaturated panels with a faint warm grain and hairline borders, bone-white
// text, one restrained accent per meaning (amber light, moss stamina, cold cyan air, blood for danger). Titles and
// narrative lines use a typewriter face, data and controls a condensed sans. Only installed / generic fonts: no
// download ever happens (school networks block font CDNs and the file must work offline).

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
  Grain: 'rgb(255,238,214)',
  GamepadA: 'rgb(126,168,112)',
  GamepadB: 'rgb(196,96,82)',
  GamepadX: 'rgb(104,140,186)',
  GamepadY: 'rgb(206,178,98)',
});

export const Fonts = Object.freeze({
  Title: '"Special Elite", "Courier Prime", "American Typewriter", Cousine, "Courier New", Courier, monospace',
  Strong: 'Oswald, "Bebas Neue", "Roboto Condensed", "Arial Narrow", "Liberation Sans Narrow", "DejaVu Sans Condensed", "Helvetica Neue", Arial, sans-serif',
  Body: '"Segoe UI", Roboto, Arimo, "Helvetica Neue", Arial, sans-serif',
});

// A warm noise tile (inline SVG turbulence), the panels' grain.
const GRAIN = `url("data:image/svg+xml;utf8,${encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" width="160" height="160"><filter id="n"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" stitchTiles="stitch"/><feColorMatrix values="0 0 0 0 1  0 0 0 0 0.93  0 0 0 0 0.84  0 0 0 0.09 0"/></filter><rect width="160" height="160" filter="url(#n)"/></svg>',
)}")`;

export const CSS = `
#rv-root { position: fixed; inset: 0; overflow: hidden; background: #000; user-select: none; -webkit-user-select: none;
  touch-action: none; font-family: ${Fonts.Body}; color: ${Palette.Bone}; }
#rv-root canvas.rv-canvas { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }
.rv-layer { position: absolute; inset: 0; pointer-events: none; }
.rv-hud { transition: opacity 0.4s linear; }
.rv-panel { background-color: rgba(15,14,15,0.82); background-image: ${GRAIN}, linear-gradient(180deg, rgba(26,24,24,0.35), rgba(8,8,9,0.25));
  border: 1px solid rgba(48,45,42,0.85); border-radius: 6px; box-shadow: 0 2px 18px rgba(0,0,0,0.55); }
.rv-caps { font-family: ${Fonts.Strong}; font-stretch: condensed; text-transform: uppercase; letter-spacing: 0.14em;
  font-size: 11px; color: ${Palette.Ash}; font-weight: 600; }
.rv-title { font-family: ${Fonts.Title}; letter-spacing: 0.04em; color: ${Palette.Bone}; }
.rv-strong { font-family: ${Fonts.Strong}; font-stretch: condensed; font-weight: 600; letter-spacing: 0.04em; }
.rv-outline { text-shadow: 0 0 2px rgba(8,8,9,0.9), 0 1px 3px rgba(8,8,9,0.8); }

/* status bars (bottom-left) */
.rv-status { position: absolute; left: 22px; bottom: 22px; display: flex; flex-direction: column-reverse; gap: 2px; }
.rv-status.touch { bottom: auto; top: 104px; flex-direction: column; }
.rv-meter-row { height: 24px; width: 168px; display: flex; flex-direction: column; justify-content: center; gap: 4px;
  transition: opacity 0.25s linear; }
.rv-meter-row.collapsed { height: 0; overflow: hidden; }
.rv-meter { position: relative; height: 4px; width: 168px; background: rgba(40,37,35,0.65); border-radius: 2px; overflow: hidden; }
.rv-meter-fill { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 2px;
  background-image: linear-gradient(90deg, rgba(0,0,0,0.35), rgba(0,0,0,0) 85%); }
.rv-pips { display: flex; gap: 4px; margin-top: 4px; }
.rv-pip { width: 6px; height: 14px; border-radius: 2px; background: ${Palette.Ember}; opacity: 0.85; }

/* prompts */
.rv-prompt { position: absolute; display: flex; align-items: center; gap: 12px; width: 270px; height: 54px;
  transform: translate(-23px, -27px); transition: opacity 0.12s linear; pointer-events: auto; }
.rv-prompt-ring { position: relative; width: 46px; height: 46px; flex: none; }
.rv-prompt-ring svg { position: absolute; inset: 0; }
.rv-prompt-text { display: flex; flex-direction: column; min-width: 0; }
.rv-prompt-object { font-family: ${Fonts.Strong}; text-transform: uppercase; letter-spacing: 0.14em; font-size: 11px; color: ${Palette.Ash}; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.rv-prompt-action { font-family: ${Fonts.Body}; font-size: 17px; color: ${Palette.Bone}; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

/* key caps */
.rv-key { position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); display: flex; align-items: center;
  justify-content: center; background: rgba(8,8,9,0.78); border: 1px solid rgba(208,201,188,0.55);
  font-family: ${Fonts.Strong}; font-weight: 700; color: ${Palette.Bone}; }
.rv-key.keyboard { border-radius: 18%; }
.rv-key.gamepad, .rv-key.touch { border-radius: 50%; }
.rv-key.touch::after { content: ''; width: 38%; height: 38%; border-radius: 50%; background: ${Palette.Bone};
  box-shadow: 0 0 0 3px rgba(8,8,9,0.8), 0 0 0 4.5px rgba(208,201,188,0.65); }
.rv-key-inline { position: relative; display: inline-flex; vertical-align: middle; margin: 0 4px; }
.rv-key-inline .rv-key { position: relative; left: auto; top: auto; transform: none; }

/* centre column: hint + captions */
.rv-centre { position: absolute; left: 50%; bottom: 96px; transform: translateX(-50%); width: min(640px, 92vw);
  display: flex; flex-direction: column; align-items: center; gap: 6px; }
.rv-hint { font-family: ${Fonts.Title}; font-size: 19px; text-align: center; padding: 6px 14px; opacity: 0;
  transition: opacity 1.4s linear; }
.rv-hint.on { opacity: 1; transition: opacity 3s linear; }
.rv-lock { position: absolute; left: 50%; top: 42%; transform: translateX(-50%); font-family: ${Fonts.Strong}; font-size: 14px;
  letter-spacing: 0.12em; text-transform: uppercase; padding: 6px 14px; border-radius: 4px; background: rgba(8,8,9,0.6);
  opacity: 0; pointer-events: none; transition: opacity 0.4s linear; }
.rv-lock.on { opacity: 0.9; }
.rv-captions { display: flex; flex-direction: column; align-items: center; gap: 4px; }
.rv-caption { font-family: ${Fonts.Body}; font-size: 15px; padding: 3px 12px 3px 10px; border-radius: 4px;
  background: rgba(8,8,9,0.72); color: ${Palette.Bone}; border-left: 2px solid transparent; transition: opacity 0.7s linear; }
.rv-caption.danger { border-left-color: ${Palette.Blood}; }

/* toasts */
.rv-toasts { position: absolute; top: 10px; left: 50%; transform: translateX(-50%); width: min(520px, 94vw);
  display: flex; flex-direction: column; align-items: center; gap: 6px; }
.rv-toast { width: 100%; text-align: center; padding: 8px 18px; font-family: ${Fonts.Strong}; letter-spacing: 0.06em;
  font-size: 15px; background: linear-gradient(90deg, rgba(8,8,9,0), rgba(8,8,9,0.82) 18%, rgba(8,8,9,0.82) 82%, rgba(8,8,9,0));
  transition: opacity 0.6s linear; }
.rv-toast.danger { color: ${Palette.Ember}; }
.rv-toast.good { color: ${Palette.Moss}; }

/* floor card */
.rv-card { position: absolute; left: 50%; top: 32%; transform: translate(-50%, -50%); text-align: center;
  transition: opacity 1.2s linear; }
.rv-card-title { font-family: ${Fonts.Title}; font-size: 40px; letter-spacing: 0.08em; }
.rv-card-sub { font-family: ${Fonts.Strong}; font-size: 15px; letter-spacing: 0.28em; text-transform: uppercase; color: ${Palette.Ash}; margin-top: 8px; }
.rv-card-rule { height: 1px; margin: 10px auto 0; width: 60%; background: linear-gradient(90deg, transparent, ${Palette.Stroke}, transparent); }

/* fade */
/* above the game's HUD layers (objectives 11, lobby HUD 12, hints 13): a fade to black hides them too */
.rv-fade { position: absolute; inset: 0; background: #000; opacity: 0; pointer-events: none; z-index: 20; }

/* crosshair dot */
.rv-dot { position: absolute; left: 50%; top: 50%; width: 3px; height: 3px; margin: -1.5px 0 0 -1.5px; border-radius: 50%;
  background: rgba(208,201,188,0.35); }

/* touch controls */
.rv-touch { position: absolute; inset: 0; pointer-events: none; }
.rv-touch > * { pointer-events: auto; }
.rv-thumb { position: absolute; left: 40px; bottom: 40px; width: 140px; height: 140px; border-radius: 50%;
  background: rgba(8,8,9,0.35); border: 1.5px solid rgba(208,201,188,0.3); }
.rv-thumb-knob { position: absolute; left: 45px; top: 45px; width: 50px; height: 50px; border-radius: 50%;
  background: rgba(208,201,188,0.35); }
.rv-round { position: absolute; border-radius: 50%; background: rgba(8,8,9,0.55); border: 1.5px solid rgba(208,201,188,0.4);
  color: ${Palette.Bone}; font-family: ${Fonts.Strong}; font-size: 12px; letter-spacing: 0.06em; padding: 0 6px; }
.rv-round.pressed { background: rgba(8,8,9,0.75); transform: scale(0.9); border-color: rgba(208,201,188,0.85); }
.rv-round.latched { border-color: ${Palette.Amber}; color: ${Palette.Amber}; box-shadow: inset 0 0 14px rgba(204,158,88,0.35); }

/* menus */
/* the pause menu covers the game's HUD layers, the floor card and the lobby terminals (25); the title (30) and the
   results (40) own their screens */
.rv-menu { position: absolute; inset: 0; display: none; align-items: center; justify-content: center;
  background: rgba(0,0,0,0.55); pointer-events: auto; z-index: 35; }
.rv-menu.open { display: flex; }
.rv-menu-panel { width: min(520px, 92vw); max-height: 86vh; overflow: auto; padding: 22px 26px; }
.rv-menu h2 { font-family: ${Fonts.Title}; font-weight: normal; font-size: 26px; margin: 0 0 14px; letter-spacing: 0.06em; }
.rv-btn { display: block; width: 100%; margin: 8px 0; padding: 10px 14px; text-align: left; cursor: pointer;
  background: rgba(26,24,24,0.9); color: ${Palette.Bone}; border: 1px solid ${Palette.StrokeDim}; border-radius: 5px;
  font-family: ${Fonts.Strong}; font-size: 15px; letter-spacing: 0.08em; text-transform: uppercase; }
.rv-btn:hover, .rv-btn:focus { border-color: ${Palette.Stroke}; background: rgba(40,37,35,0.95); outline: none; }
.rv-setting { display: grid; grid-template-columns: 1fr 160px 44px; align-items: center; gap: 10px; margin: 8px 0; font-size: 14px; }
.rv-setting input[type=range] { width: 160px; accent-color: ${Palette.Bone}; }
.rv-setting .val { text-align: right; color: ${Palette.Ash}; font-family: ${Fonts.Strong}; }
.rv-setting select { background: ${Palette.Raised}; color: ${Palette.Bone}; border: 1px solid ${Palette.StrokeDim}; padding: 4px; }
.rv-toggle { width: 38px; height: 20px; border-radius: 10px; background: ${Palette.Track}; position: relative; cursor: pointer; border: 1px solid ${Palette.StrokeDim}; }
.rv-toggle::after { content: ''; position: absolute; top: 2px; left: 2px; width: 14px; height: 14px; border-radius: 50%; background: ${Palette.Ash}; transition: left 0.15s; }
.rv-toggle.on { background: rgba(150,158,132,0.45); }
.rv-toggle.on::after { left: 20px; background: ${Palette.Bone}; }

/* loading */
.rv-loading { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center;
  background: #000; transition: opacity 0.8s linear; pointer-events: auto; }
.rv-loading .rv-title { font-size: 26px; letter-spacing: 0.18em; }
.rv-loading-bar { margin-top: 18px; width: 240px; height: 3px; background: ${Palette.Track}; border-radius: 2px; overflow: hidden; }
.rv-loading-bar > div { height: 100%; width: 0; background: ${Palette.Bone}; transition: width 0.25s linear; }
.rv-loading-sub { margin-top: 12px; font-size: 13px; color: ${Palette.Ash}; font-family: ${Fonts.Strong}; letter-spacing: 0.1em; }
.rv-stats { position: absolute; right: 8px; top: 6px; font: 11px monospace; color: rgba(208,201,188,0.6); white-space: pre; text-align: right; }
`;
