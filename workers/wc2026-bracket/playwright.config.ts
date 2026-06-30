import { defineConfig } from '@playwright/test';

// Use the container's pre-installed Chromium (full build, supports getImageData
// + P3) rather than downloading a version-matched browser.
const CHROMIUM = process.env.PW_CHROMIUM || '/opt/pw-browsers/chromium';

// iPhone 16 Pro on Chrome — emulated device metrics. The DevTools 149 dynamic
// device-mode UA is mirrored here by pinning current metrics rather than a stale
// descriptor: 402×874 CSS px, devicePixelRatio 3, touch, mobile.
const iPhone16Pro = {
  viewport: { width: 402, height: 874 },
  deviceScaleFactor: 3,
  isMobile: true,
  hasTouch: true,
  userAgent:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/537.36 (KHTML, like Gecko) CriOS/149.0.0.0 Mobile/15E148 Safari/537.36',
};

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:8788',
    ...iPhone16Pro,
    launchOptions: { executablePath: CHROMIUM },
  },
  webServer: {
    command: 'node scripts/preview-server.mjs',
    url: 'http://127.0.0.1:8788',
    reuseExistingServer: true,
    timeout: 20_000,
  },
  projects: [{ name: 'iphone-16-pro-chrome' }],
});
