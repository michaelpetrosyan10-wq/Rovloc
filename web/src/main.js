// Boot: loading screen -> engine (world data decoded from this very file) -> the game (W4's title screen, lobby and
// run; `start(engine)` from src/game/index.js). Until the game module exists the build links the engine's sandbox
// in its place, a free walk through the real school (build.mjs resolves "@rovloc/game").
//
// The page works from file:// with no network: every byte (code, world, textures) is inside the HTML.

import { Engine } from './engine/index.js';
import { CSS } from './engine/ui/style.js';
import { getString } from './engine/strings.js';
import * as Game from '@rovloc/game';

function el(tag, className, parent, text) {
  const e = document.createElement(tag);
  if (className) e.className = className;
  if (text !== undefined) e.textContent = text;
  if (parent) parent.appendChild(e);
  return e;
}

/** The boot screen (LoadingCurtain): black, the typewriter title, a thin bar. */
function bootScreen(root) {
  const style = el('style');
  style.id = 'rv-style';
  style.textContent = CSS;
  document.head.appendChild(style);
  const screen = el('div', 'rv-loading', root);
  screen.style.zIndex = '50';
  el('div', 'rv-title', screen, getString('Boot.Generating'));
  const bar = el('div', 'rv-loading-bar', screen);
  const fill = el('div', '', bar);
  const sub = el('div', 'rv-loading-sub', screen, '');
  return {
    progress(f, text) {
      const pct = Math.round(Math.min(1, Math.max(0, f)) * 100);
      fill.style.width = `${pct}%`;
      sub.textContent = text || getString('Boot.Receiving', pct);
    },
    fail(message) {
      sub.textContent = message;
      sub.style.color = 'rgb(198,58,40)';
      sub.style.maxWidth = '80vw';
      sub.style.textAlign = 'center';
    },
    hide() {
      screen.style.opacity = '0';
      setTimeout(() => screen.remove(), 900);
    },
  };
}

function webgl2Available() {
  try {
    return !!document.createElement('canvas').getContext('webgl2');
  } catch {
    return false;
  }
}

async function boot() {
  const root = document.getElementById('rv-root') || el('div', '', document.body);
  root.id = 'rv-root';
  const screen = bootScreen(root);
  window.__rovloc = { ready: false, engine: null, error: null };
  if (!webgl2Available()) {
    screen.fail('This browser cannot run WebGL 2. Turn on hardware acceleration in Chrome settings and reload.');
    window.__rovloc.error = 'webgl2';
    return;
  }
  // yield so the boot screen paints before the heavy decode
  await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)));
  try {
    const engine = await Engine.create({ root, onProgress: (f) => screen.progress(f) });
    window.__rovloc.engine = engine;
    screen.progress(1, getString('Boot.Ready'));
    engine.start();
    await Game.start(engine);
    window.__rovloc.ready = true;
    screen.hide();
  } catch (err) {
    console.error(err);
    window.__rovloc.error = String(err && err.message ? err.message : err);
    screen.fail(getString('Boot.Error', window.__rovloc.error));
  }
}

boot();
