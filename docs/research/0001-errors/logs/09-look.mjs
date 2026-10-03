import puppeteer from '/Users/lennartbuttner/Projects/1charta/test/e2e/node_modules/puppeteer-core/lib/esm/puppeteer/puppeteer-core.js';
const url = 'file://' + new URL('../index.html', import.meta.url).pathname;
const browser = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
try {
  for (const scheme of ['light', 'dark']) for (const w of [1280, 390]) {
    const page = await browser.newPage();
    await page.setViewport({ width: w, height: 900 });
    await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: scheme }]);
    await page.goto(url, { waitUntil: 'load' });
    const r = await page.evaluate(() => {
      const iw = innerWidth, over = [];
      for (const el of document.querySelectorAll('body *')) {
        const b = el.getBoundingClientRect();
        if (b.right > iw + 1 && !el.closest('.scroll,.dwrap')) over.push(el.tagName + '.' + el.className + ' ' + Math.round(b.right));
      }
      return { sw: document.documentElement.scrollWidth, iw, over: over.slice(0, 8) };
    });
    console.log(scheme, w, JSON.stringify(r));
    // Chrome repeats tiles past ~16k px in one full-page capture, so shoot in parts
    const H = 4000, total = await page.evaluate(() => document.documentElement.scrollHeight);
    for (let y = 0, i = 0; y < total; y += H, i++)
      await page.screenshot({ path: new URL(`../shots/09-${scheme}-${w}-${i}.png`, import.meta.url).pathname, clip: { x: 0, y, width: w, height: Math.min(H, total - y) }, captureBeyondViewport: true });
    await page.close();
  }
} finally { await browser.close(); }
