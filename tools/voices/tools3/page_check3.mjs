// page_check2.mjs BOARD_DIR OUT_DIR: open board3 at 360x740 and 1366x768 (file:// only), report overflow, any non-file
// request, and load EVERY <audio> (metadata: duration > 0, no error). Saves screenshots (top and full page at 360).
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
  if (w === 360) {
    const res = await page.evaluate(async () => {
      const out = [];
      for (const a of document.querySelectorAll('audio')) {
        const src = a.getAttribute('src');
        const r = await new Promise(res => {
          const t = setTimeout(() => res({ src, ok: false, why: 'timeout' }), 8000);
          a.addEventListener('loadedmetadata', () => { clearTimeout(t); res({ src, ok: a.duration > 0, dur: a.duration }); }, { once: true });
          a.addEventListener('error', () => { clearTimeout(t); res({ src, ok: false, why: 'error ' + (a.error && a.error.code) }); }, { once: true });
          a.preload = 'metadata'; a.load();
        });
        out.push(r);
      }
      return out;
    });
    const bad = res.filter(x => !x.ok);
    console.log(JSON.stringify({ audioLoaded: res.length - bad.length, audioTotal: res.length, bad }));
    await page.screenshot({ path: `${out}/board3_360_full.png`, fullPage: true });
  }
  await page.screenshot({ path: `${out}/board3_${w}.png`, fullPage: false });
  await page.close();
}
console.log(JSON.stringify({ nonFileRequests: requests }));
await browser.close();
