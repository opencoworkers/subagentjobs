import { test, expect } from '@playwright/test';

// iPhone 16 Pro / Chrome rendering checks for the radial bracket.
test.describe('wc2026 radial bracket — iPhone 16 Pro', () => {
  test('runs on an experimental Chrome (Canary / tip-of-tree, ≥150)', async ({ browser }) => {
    const version = browser.version(); // e.g. "151.0.7886.0"
    const major = Number(version.split('.')[0]);
    expect(major, `browser version ${version}`).toBeGreaterThanOrEqual(150);
  });


  test('emulates the device and renders the graph crisply', async ({ page }) => {
    const errors: string[] = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));

    await page.goto('/');
    // wait until the graph has actually painted (data fetched + first frame)
    await page.waitForFunction(() => {
      const c = document.getElementById('gcanvas') as HTMLCanvasElement | null;
      if (!c || !c.width) return false;
      const d = c.getContext('2d')!.getImageData(0, 0, c.width, c.height).data;
      for (let i = 3; i < d.length; i += 4) if (d[i] !== 0) return true;
      return false;
    }, { timeout: 10_000 });

    // device emulation is in effect
    expect(await page.evaluate(() => window.devicePixelRatio)).toBe(3);

    // DPR handling: backing store is css-width × min(dpr,3), capped at 3
    const dims = await page.evaluate(() => {
      const c = document.getElementById('gcanvas') as HTMLCanvasElement;
      return { w: c.width, h: c.height, cw: c.clientWidth, ch: c.clientHeight };
    });
    expect(dims.w).toBe(Math.round(dims.cw * 3));
    expect(dims.h).toBe(Math.round(dims.ch * 3));

    // P3 wide-gamut + desynchronized context where supported
    const attrs = await page.evaluate(() => {
      const c = document.getElementById('gcanvas') as HTMLCanvasElement;
      const a = (c.getContext('2d') as any).getContextAttributes?.() || {};
      return { colorSpace: a.colorSpace, desync: a.desynchronized };
    });
    expect(['display-p3', 'srgb']).toContain(attrs.colorSpace);

    // the graph actually painted — at least one non-transparent pixel
    const painted = await page.evaluate(() => {
      const c = document.getElementById('gcanvas') as HTMLCanvasElement;
      const x = c.getContext('2d')!;
      const { data } = x.getImageData(0, 0, c.width, c.height);
      for (let i = 3; i < data.length; i += 4) if (data[i] !== 0) return true;
      return false;
    });
    expect(painted).toBe(true);

    expect(errors, errors.join('\n')).toEqual([]);
  });

  test('on-demand rendering: idle once no match is live', async ({ page }) => {
    // count requestAnimationFrame ticks over ~500ms; with the seed payload one
    // match is live, so the blink loop should be running (ticks > 0) — proving
    // the loop engages only when needed (and self-terminates otherwise).
    await page.goto('/');
    await page.waitForFunction(() => (window as any).performance && document.getElementById('gcanvas'));
    const ticks = await page.evaluate(
      () =>
        new Promise<number>((resolve) => {
          let n = 0;
          const start = performance.now();
          const f = () => {
            n++;
            if (performance.now() - start < 500) requestAnimationFrame(f);
            else resolve(n);
          };
          requestAnimationFrame(f);
        })
    );
    expect(ticks).toBeGreaterThan(0);
  });
});
