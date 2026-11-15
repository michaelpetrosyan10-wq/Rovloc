// browser.mjs: the pre-installed Playwright (web/tools/check.mjs finds it the same way: it is not a dependency of the
// site), for the format check and the sound board's headless check.

import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';
import { ROOT } from './voices.mjs';

/** @returns {any} the playwright module */
export function loadPlaywright() {
  const require = createRequire(import.meta.url);
  const roots = [path.resolve(ROOT, '..'), process.cwd(), '/opt/node-tools/node_modules', '/opt/node22/lib/node_modules', '/usr/lib/node_modules', '/usr/local/lib/node_modules'];
  try {
    roots.push(execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim());
  } catch { /* npm missing */ }
  for (const r of roots) {
    try {
      return require(require.resolve('playwright', { paths: [r] }));
    } catch { /* next */ }
  }
  throw new Error('playwright not found (it is expected pre-installed globally)');
}
