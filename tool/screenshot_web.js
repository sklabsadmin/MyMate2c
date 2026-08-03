// Screenshot the running app with headless Chromium.
//
// Driven by tool/preview_web.sh; not usually run directly. Two workarounds
// here exist purely because of how a sandboxed CI/agent container differs from
// a real browser — neither indicates anything wrong with the app:
//
//   1. Flutter web loads its CanvasKit renderer from gstatic.com at runtime.
//      A container with restricted egress cannot reach it and the engine never
//      boots — you get the splash screen forever. `flutter build web` already
//      copies an identical CanvasKit into build/web/canvaskit, so we intercept
//      those requests and serve the local files.
//
//   2. Headless Chromium reports no locale, and Flutter's Intl init throws
//      "RangeError: Incorrect locale information provided" before first frame.
//      Setting an explicit locale on the context avoids it.
//
// Google Fonts is also usually blocked, which leaves text unpainted. That is
// cosmetic and sandbox-only, so it is not worked around.

const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const URL_UNDER_TEST = process.env.SHOT_URL || 'http://127.0.0.1:8788/';
const OUT = process.env.SHOT_OUT || 'build/preview-shots';
const CANVASKIT_DIR = path.resolve(__dirname, '..', 'build', 'web', 'canvaskit');

const CONTENT_TYPES = {
  '.js': 'text/javascript',
  '.wasm': 'application/wasm',
  '.json': 'application/json',
  '.symbols': 'text/plain',
};

const VIEWPORTS = [
  ['mobile', { width: 390, height: 844 }],
  ['desktop', { width: 1280, height: 860 }],
];

async function serveCanvasKitLocally(page) {
  await page.route('**www.gstatic.com/flutter-canvaskit/**', (route) => {
    // URL shape: /flutter-canvaskit/<engine-hash>/<file...>
    const rest = new URL(route.request().url()).pathname.split('/').slice(3).join('/');
    const file = path.join(CANVASKIT_DIR, rest);
    if (!file.startsWith(CANVASKIT_DIR) || !fs.existsSync(file)) return route.abort();
    route.fulfill({
      status: 200,
      contentType: CONTENT_TYPES[path.extname(file)] || 'application/octet-stream',
      body: fs.readFileSync(file),
    });
  });
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({
    // Containers have no GPU; without this CanvasKit cannot get a WebGL context.
    args: ['--enable-unsafe-swiftshader', '--use-gl=swiftshader'],
  });

  const problems = [];
  for (const [name, viewport] of VIEWPORTS) {
    const page = await browser.newPage({
      viewport,
      deviceScaleFactor: 2,
      locale: 'en-US',
      timezoneId: 'America/New_York',
    });
    page.on('pageerror', (e) => problems.push(`[${name}] ${e.message.split('\n')[0]}`));
    await serveCanvasKitLocally(page);

    await page.goto(URL_UNDER_TEST, { waitUntil: 'load', timeout: 60000 });
    // Flutter paints into a canvas it injects after the engine boots; waiting
    // for it is what distinguishes "rendered" from "stuck on the splash".
    await page.waitForSelector('flutter-view, flt-glass-pane, canvas', { timeout: 90000 });
    await page.waitForTimeout(8000); // let first paint settle before capturing

    await page.screenshot({ path: path.join(OUT, `${name}.png`) });
    console.log(`${name}: rendered -> ${path.join(OUT, `${name}.png`)}`);
    await page.close();
  }

  await browser.close();
  if (problems.length) {
    console.log('\npage errors:');
    console.log(problems.slice(0, 10).join('\n'));
    process.exitCode = 1;
  }
})();
