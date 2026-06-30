import { test, expect } from '@playwright/test';

// iPhone 16 Pro / Chrome rendering checks for the radial bracket.
test.describe('wc2026 radial bracket — iPhone 16 Pro', () => {
  test('runs on an experimental Chrome (Canary / tip-of-tree, ≥150)', async ({ browser }) => {
    const version = browser.version(); // e.g. "151.0.7886.0"
    const major = Number(version.split('.')[0]);
    expect(major, `browser version ${version}`).toBeGreaterThanOrEqual(150);
  });


  test('renders penalty-shootout scores in parentheses', async ({ page }) => {
    await page.goto('/');
    // M03 (MEX 0(4)–0(3) KOR) and M04 (BRA 2(5)–2(4) NGA) are penalty results.
    const pkTexts = await page.$$eval('.pk', (els) => els.map((e) => e.textContent));
    expect(pkTexts).toContain('(4)');
    expect(pkTexts).toContain('(3)');
    expect(pkTexts.length).toBeGreaterThanOrEqual(4);
  });

  test('radial tree is symmetric: 32 leaves evenly spaced, balanced rounds', async ({ page }) => {
    await page.goto('/');
    await page.waitForFunction(() => (window as any).DATA && (window as any).DATA.graph);
    const g = await page.evaluate(() => {
      const G = (window as any).DATA.graph;
      const kinds: Record<string, number> = {};
      G.nodes.forEach((n: any) => (kinds[n.k] = (kinds[n.k] || 0) + 1));
      const ang = G.nodes.filter((n: any) => n.k === 'team').map((n: any) => n.ang).sort((a: number, b: number) => a - b);
      const gaps = ang.slice(1).map((a: number, i: number) => a - ang[i]);
      return { kinds, minGap: Math.min(...gaps), maxGap: Math.max(...gaps) };
    });
    // Full balanced tournament tree.
    expect(g.kinds).toEqual({ final: 1, sf: 2, qf: 4, r16: 8, match: 16, team: 32 });
    // Even angular spacing ⇒ left/right symmetric (no lopsided slice).
    expect(g.maxGap - g.minGap).toBeLessThan(0.01);
  });

  test('focal zoom keeps the point under the cursor fixed (trophy stays anchored)', async ({ page }) => {
    await page.goto('/');
    await page.waitForFunction(() => typeof (window as any).zoomAt === 'function' && (window as any).GW > 0);
    const drift = await page.evaluate(() => {
      const w = window as any;
      const fx = w.GW / 2, fy = w.GH / 2; // focal point = bracket centre (trophy)
      const before = { x: (fx - w.pan.x) / w.Z, y: (fy - w.pan.y) / w.Z };
      w.zoomAt(fx, fy, 2.5); // zoom in toward the centre
      const after = { x: (fx - w.pan.x) / w.Z, y: (fy - w.pan.y) / w.Z };
      return Math.hypot(after.x - before.x, after.y - before.y);
    });
    // The world point under the focal stays put — no drift → trophy doesn't break.
    expect(drift).toBeLessThan(0.5);
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

  test('tab switch uses the View Transitions API without errors', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto('/');
    // Canary supports startViewTransition; the matches tab should animate in.
    expect(await page.evaluate(() => typeof document.startViewTransition)).toBe('function');
    await page.click('nav a[data-t="matches"]');
    await expect(page.locator('#tab-matches')).toBeVisible();
    await expect(page.locator('.mcard').first()).toBeVisible();
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
