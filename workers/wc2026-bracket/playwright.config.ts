import { defineConfig } from '@playwright/test';
import { existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

// We test against the most experimental Chrome available — the nightly Canary
// channel — so new-in-Chrome features (P3 canvas, Chrome 150 relative-color,
// etc.) are exercised on the build that ships them first.
//
//   • Linux/CI (this container): Playwright's `chromium-tip-of-tree` IS
//     "Chrome Canary for Testing" (currently 151.x). Install with
//     `npm run install:canary`; this config auto-detects the installed build.
//   • macOS/Windows dev machines: install Chrome Canary from
//     https://www.google.com/chrome/canary/ and run with PW_CHANNEL=chrome-canary.
//
// Resolution order: PW_CHROMIUM (explicit path) → PW_CHANNEL (a channel name) →
// auto-detected tip-of-tree (Canary) build → 'chromium-tip-of-tree' channel.
function findCanary(): string {
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers';
  try {
    const dir = readdirSync(base).filter((d) => d.startsWith('chromium_tip_of_tree-')).sort().pop();
    if (dir) {
      const bin = join(base, dir, 'chrome-linux', 'chrome');
      if (existsSync(bin)) return bin;
    }
  } catch { /* base missing */ }
  return '';
}
const CHANNEL = process.env.PW_CHANNEL || '';
const CHROMIUM = process.env.PW_CHROMIUM || (CHANNEL ? '' : findCanary());
const browser = CHROMIUM
  ? { launchOptions: { executablePath: CHROMIUM } }
  : { channel: CHANNEL || 'chromium-tip-of-tree' };

// iPhone 16 Pro on Chrome — emulated device metrics. The DevTools 149 dynamic
// device-mode UA is mirrored here by pinning current metrics rather than a stale
// descriptor: 402×874 CSS px, devicePixelRatio 3, touch, mobile.
const iPhone16Pro = {
  viewport: { width: 402, height: 874 },
  deviceScaleFactor: 3,
  isMobile: true,
  hasTouch: true,
  userAgent:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) CriOS/151.0.0.0 Mobile/15E148 Safari/537.36',
};

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:8788',
    ...iPhone16Pro,
    ...browser,
  },
  webServer: {
    command: 'node scripts/preview-server.mjs',
    url: 'http://127.0.0.1:8788',
    reuseExistingServer: true,
    timeout: 20_000,
  },
  projects: [{ name: 'iphone-16-pro-chrome' }],
});
