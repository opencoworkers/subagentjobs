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
    await page.waitForFunction(() => typeof (window as any).zoomAt === 'function' && (window as any).DATA && (window as any).DATA.graph);
    const drift = await page.evaluate(() => {
      const w = window as any;
      const fx = 50, fy = 50; // viewBox centre (trophy)
      const before = { x: (fx - w.px) / w.Z, y: (fy - w.py) / w.Z };
      w.zoomAt(fx, fy, 2.5); // zoom in toward the centre
      const after = { x: (fx - w.px) / w.Z, y: (fy - w.py) / w.Z };
      return Math.hypot(after.x - before.x, after.y - before.y);
    });
    // The world point under the focal stays put — no drift → trophy doesn't break.
    expect(drift).toBeLessThan(0.5);
  });

  test('renders as crisp SVG DOM (no canvas) with real tap targets + a11y', async ({ page }) => {
    const errors: string[] = [];
    page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
    page.on('pageerror', (e) => errors.push(String(e)));

    await page.goto('/');
    await page.waitForFunction(() => document.querySelectorAll('.node[data-id]').length > 0, { timeout: 10_000 });

    expect(await page.evaluate(() => window.devicePixelRatio)).toBe(3);
    // Vector rendering — no canvas anywhere (resolution-independent, no DPR math).
    expect(await page.locator('canvas').count()).toBe(0);

    const c = await page.evaluate(() => ({
      matchNodes: document.querySelectorAll('.node[data-id]').length,
      buttons: document.querySelectorAll('.node[role="button"][tabindex]').length,
      labelled: document.querySelectorAll('.node[aria-label]').length,
      teams: document.querySelectorAll('.tm').length,
      links: document.querySelectorAll('.lk').length,
      sr: document.querySelectorAll('#srlist a').length,
    }));
    expect(c.matchNodes).toBe(16);
    expect(c.buttons).toBe(16);   // native tap targets + keyboard focus
    expect(c.labelled).toBe(16);  // screen-reader text per node
    expect(c.teams).toBe(32);
    expect(c.links).toBe(62);
    expect(c.sr).toBe(16);        // accessible, deep-linkable mirror list

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

  test('tapping a match node opens the detail card and deep-links the hash', async ({ page }) => {
    await page.goto('/');
    await page.waitForFunction(() => document.querySelectorAll('.node[data-id]').length > 0);
    // M04 is BRA 2(5)–2(4) NGA (penalty result) — focus+context, not pinch-to-read.
    await page.locator('.node[data-id="M04"]').dispatchEvent('click');
    await expect(page.locator('#detail')).toBeVisible();
    await expect(page.locator('#detail')).toContainText('(5)');
    expect(await page.evaluate(() => location.hash)).toBe('#M04');
  });

  test('deep-link to #M07 selects that match on load', async ({ page }) => {
    await page.goto('/#M07');
    await page.waitForFunction(() => document.querySelector('.node[data-sel]') !== null, { timeout: 10_000 });
    const sel = await page.evaluate(() => document.querySelector('.node[data-sel]')?.getAttribute('data-id'));
    expect(sel).toBe('M07');
  });
});
