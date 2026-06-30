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

  test('match nodes have enlarged tap targets and a brighter dedicated focus ring', async ({ page }) => {
    await page.goto('/#M07');
    await page.waitForFunction(() => document.querySelector('.node[data-sel]') !== null, { timeout: 10_000 });

    // (1) Bigger invisible hit circles on the interactive match nodes — Apple's
    // 44px-equiv guidance on a 402px phone (16 tappable match nodes).
    const hitRadii = await page.$$eval('.node[data-id] .hit', (els) => els.map((e) => e.getAttribute('r')));
    expect(hitRadii.length).toBe(16);
    expect(hitRadii.every((r) => r === '5.2')).toBe(true);

    // (2) The focus ring sits 1.5 units outside the dot and carries an explicit stroke-width.
    const ring = await page.evaluate(() => {
      const sel = document.querySelector('.node[data-sel]')!;
      const foc = sel.querySelector('.foc')!, dot = sel.querySelector('.dot')!;
      return {
        focR: parseFloat(foc.getAttribute('r')!),
        dotR: parseFloat(dot.getAttribute('r')!),
        sw: parseFloat(foc.getAttribute('stroke-width')!),
        stroke: getComputedStyle(foc as Element).stroke,
      };
    });
    expect(ring.focR).toBeCloseTo(ring.dotR + 1.5, 5);
    expect(ring.sw).toBeGreaterThanOrEqual(0.5);
    expect(ring.stroke).not.toBe('none'); // visible when selected

    // (3) Dedicated --focus token, distinct from (brighter than) the body --cyan.
    const tokens = await page.evaluate(() => {
      const s = getComputedStyle(document.documentElement);
      return { focus: s.getPropertyValue('--focus').trim(), cyan: s.getPropertyValue('--cyan').trim() };
    });
    expect(tokens.focus).toBeTruthy();
    expect(tokens.focus).not.toBe(tokens.cyan);
  });

  test('match detail dialog: focus moves in, Tab is trapped, Escape closes + restores focus', async ({ page }) => {
    await page.goto('/');
    await page.waitForFunction(() => document.querySelectorAll('.node[data-id]').length > 0);

    // Open via the keyboard path: focus the match node, press Enter.
    await page.locator('.node[data-id="M04"]').focus();
    await page.keyboard.press('Enter');
    await expect(page.locator('#detail')).toBeVisible();

    // Non-modal disclosure: a labelled role=dialog, but NOT aria-modal (the background
    // stays interactive, so claiming modality would mislead assistive tech).
    expect(await page.locator('#detail').getAttribute('role')).toBe('dialog');
    expect(await page.locator('#detail').getAttribute('aria-modal')).toBeNull();
    expect(await page.locator('#detail').getAttribute('aria-label')).toBeTruthy();

    // Focus moves into the dialog (onto the close button) on user-initiated open.
    await page.waitForFunction(() => document.activeElement?.classList.contains('dclose') === true, { timeout: 5_000 });

    // Tab is trapped while focus is inside — focus stays in the dialog (single focusable).
    await page.keyboard.press('Tab');
    expect(await page.evaluate(() => document.getElementById('detail')!.contains(document.activeElement))).toBe(true);
    await page.keyboard.press('Shift+Tab');
    expect(await page.evaluate(() => document.getElementById('detail')!.contains(document.activeElement))).toBe(true);

    // Escape closes the dialog and restores focus to the originating match node.
    await page.keyboard.press('Escape');
    await expect(page.locator('#detail')).toBeHidden();
    expect(await page.evaluate(() => document.activeElement?.getAttribute('data-id'))).toBe('M04');
    expect(await page.evaluate(() => location.hash)).toBe('');
  });

  test('Escape closes the detail card even when focus has moved to a background control', async ({ page }) => {
    await page.goto('/');
    await page.waitForFunction(() => document.querySelectorAll('.node[data-id]').length > 0);

    // Open the card, then move focus OUT of it onto a zoom button (the background stays
    // interactive for a non-modal card). A #detail-scoped Escape handler would go dead here.
    await page.locator('.node[data-id="M04"]').dispatchEvent('click');
    await expect(page.locator('#detail')).toBeVisible();
    await page.locator('.zc button[data-z="in"]').focus();
    expect(await page.evaluate(() => document.getElementById('detail')!.contains(document.activeElement))).toBe(false);

    // Escape from the document still closes the card.
    await page.keyboard.press('Escape');
    await expect(page.locator('#detail')).toBeHidden();
  });

  test('deep-link load opens the detail card WITHOUT stealing focus into it', async ({ page }) => {
    await page.goto('/#M07');
    await page.waitForFunction(() => document.querySelector('.node[data-sel]') !== null, { timeout: 10_000 });
    await expect(page.locator('#detail')).toBeVisible();
    // No user gesture occurred, so focus must not be yanked into the modal on load.
    expect(await page.evaluate(() => document.activeElement?.classList.contains('dclose') === true)).toBe(false);
  });

  test('roving tabindex + arrow-key ring navigation with an aria-live region', async ({ page }) => {
    await page.goto('/');
    await page.waitForFunction(() => Array.isArray((window as any).NAV) && (window as any).NAV.length === 16);

    // Roving tabindex: exactly one match node is in the tab order; the rest are -1.
    const counts = await page.evaluate(() => {
      const ns = Array.from(document.querySelectorAll('.node[data-id]'));
      return {
        zero: ns.filter((n) => n.getAttribute('tabindex') === '0').length,
        negone: ns.filter((n) => n.getAttribute('tabindex') === '-1').length,
      };
    });
    expect(counts.zero).toBe(1);
    expect(counts.negone).toBe(15);

    // The ring order the arrows walk (match nodes sorted by angle).
    const order: string[] = await page.evaluate(() => (window as any).NAV.map((n: any) => n.id));
    expect(order.length).toBe(16);

    // Focus the tab stop, then ArrowRight → next clockwise by angle (with wrap).
    const startId = await page.evaluate(() => {
      const s = document.querySelector('.node[data-id][tabindex="0"]') as SVGElement;
      s.focus();
      return s.getAttribute('data-id');
    });
    const si = order.indexOf(startId!);

    await page.keyboard.press('ArrowRight');
    expect(await page.evaluate(() => document.activeElement?.getAttribute('data-id'))).toBe(order[(si + 1) % 16]);
    // The single tab stop roves with focus.
    const tabstops = await page.evaluate(() =>
      Array.from(document.querySelectorAll('.node[data-id][tabindex="0"]')).map((n) => n.getAttribute('data-id')),
    );
    expect(tabstops).toEqual([order[(si + 1) % 16]]);

    // ArrowLeft returns; ArrowDown / ArrowUp mirror Right / Left on the single ring.
    await page.keyboard.press('ArrowLeft');
    expect(await page.evaluate(() => document.activeElement?.getAttribute('data-id'))).toBe(startId);
    await page.keyboard.press('ArrowDown');
    expect(await page.evaluate(() => document.activeElement?.getAttribute('data-id'))).toBe(order[(si + 1) % 16]);
    await page.keyboard.press('ArrowUp');
    expect(await page.evaluate(() => document.activeElement?.getAttribute('data-id'))).toBe(startId);

    // Home / End → first / last by angle.
    await page.keyboard.press('Home');
    expect(await page.evaluate(() => document.activeElement?.getAttribute('data-id'))).toBe(order[0]);
    await page.keyboard.press('End');
    expect(await page.evaluate(() => document.activeElement?.getAttribute('data-id'))).toBe(order[15]);

    // Per-move feedback is the focused node's COMPLETE aria-label (matchup + status),
    // announced natively — not a duplicate live-region echo (APG roving-tabindex).
    const label = await page.evaluate(() => document.activeElement?.getAttribute('aria-label') || '');
    expect(label).toMatch(/ versus /);

    // The polite live region exists but stays quiet during pure navigation (no double-speech).
    const liveAttrs = await page.evaluate(() => {
      const l = document.getElementById('sr-updates');
      return { present: !!l, live: l?.getAttribute('aria-live'), navText: (l?.textContent || '').trim() };
    });
    expect(liveAttrs.present).toBe(true);
    expect(liveAttrs.live).toBe('polite');
    expect(liveAttrs.navText).toBe(''); // not echoing the focused node

    // It DOES announce the match when its detail card opens (focus jumps to "close").
    await page.keyboard.press('Enter');
    await expect(page.locator('#detail')).toBeVisible();
    await page.waitForFunction(() => / versus /.test(document.getElementById('sr-updates')?.textContent || ''));
  });

  test('status is conveyed without colour alone (WCAG 1.4.1): glyphs, live ring, legend', async ({ page }) => {
    await page.goto('/');
    await page.waitForFunction(() => document.querySelectorAll('.node[data-id]').length > 0);

    // Advanced / eliminated team crests carry a ✓ / ✕ glyph (not colour alone).
    const codes = await page.evaluate(() => ({
      adv: Array.from(document.querySelectorAll('.code.st-adv')).map((e) => e.textContent || ''),
      elim: Array.from(document.querySelectorAll('.code.st-elim')).map((e) => e.textContent || ''),
    }));
    expect(codes.adv.length).toBe(6); // 6 finals → 6 advancing teams
    expect(codes.elim.length).toBe(6);
    expect(codes.adv.every((t) => t.includes('✓'))).toBe(true);
    expect(codes.elim.every((t) => t.includes('✕'))).toBe(true);

    // Live matches carry a static halo ring — a shape cue that survives reduced-motion.
    expect(await page.locator('.livering').count()).toBe(2); // M07, M08

    // The legend teaches the non-colour cues.
    const legendText = await page.evaluate(() => document.querySelector('.legend')?.textContent || '');
    expect(legendText).toContain('✓');
    expect(legendText).toContain('✕');

    // Match cards mark the winner with ✓ (6 finals → 6 winners), color-independently.
    expect(await page.locator('.wmark').count()).toBe(6);
  });

  test('detail card degrades to a full-width bottom sheet on a ≤420px phone', async ({ page }) => {
    await page.goto('/');
    await page.waitForFunction(() => document.querySelectorAll('.node[data-id]').length > 0);
    await page.locator('.node[data-id="M07"]').dispatchEvent('click');
    await expect(page.locator('#detail')).toBeVisible();
    // On a ≤420px phone the card is no longer an anchored popover (which can clip at the
    // edge) but a sheet pinned to the bottom of the graph panel, spanning its full width.
    const geo = await page.evaluate(() => {
      const d = document.getElementById('detail')!.getBoundingClientRect();
      const w = document.getElementById('graph-wrap')!.getBoundingClientRect();
      return {
        vw: window.innerWidth,
        dxOff: Math.abs(d.left - w.left),
        widthOff: Math.abs(d.width - w.width),
        bottomOff: Math.abs(d.bottom - w.bottom),
      };
    });
    expect(geo.vw).toBeLessThanOrEqual(420); // iPhone 16 Pro is 402
    // Within the panel's 1px border on each side (sheet spans the content box).
    expect(geo.dxOff).toBeLessThanOrEqual(2);     // flush to the panel's left edge
    expect(geo.widthOff).toBeLessThanOrEqual(2);  // full panel width (never clips)
    expect(geo.bottomOff).toBeLessThanOrEqual(2); // sat on the panel's bottom edge
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
