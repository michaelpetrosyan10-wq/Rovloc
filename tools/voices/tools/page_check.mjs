// page_check.mjs BOARD_DIR OUT_DIR: open the board at 360 x 740 (phone / narrow Chromebook window) and 1366 x 768
// (a Chromebook), report horizontal overflow and the widest element, save screenshots. No network: file:// only.
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
const require = createRequire(import.meta.url);
function loadPlaywright() {
  const roots = ['/opt/node-tools/node_modules'];
  try { roots.push(execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim()); } catch {}
  for (const r of roots) { try { return require(require.resolve('playwright', { paths: [r] })); } catch {} }
  throw new Error('no playwright');
}
const [board, out] = process.argv.slice(2);
const { chromium } = loadPlaywright();
const browser = await chromium.launch();
const requests = [];
for (const [w, h] of [[360, 740], [1366, 768]]) {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  page.on('request', r => { if (!r.url().startsWith('file://')) requests.push(r.url()); });
  await page.goto('file://' + board + '/index.html');
  const r = await page.evaluate(() => {
    const de = document.documentElement;
    let widest = null, wmax = 0;
    for (const el of document.querySelectorAll('body *')) {
      const b = el.getBoundingClientRect();
      if (b.right > wmax) { wmax = b.right; widest = el.tagName + '.' + el.className; }
    }
    return { scrollWidth: de.scrollWidth, clientWidth: de.clientWidth, widestRight: Math.round(wmax), widest,
             audios: document.querySelectorAll('audio').length };
  });
  console.log(JSON.stringify({ viewport: w, ...r, overflow: r.scrollWidth > r.clientWidth }));
  await page.screenshot({ path: `${out}/board_${w}.png`, fullPage: false });
  await page.close();
}
console.log(JSON.stringify({ nonFileRequests: requests }));
await browser.close();
