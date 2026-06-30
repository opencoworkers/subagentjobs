# Radial bracket — research findings & recommendation

Deep-research run (105 agents, 23 sources fetched, 25 claims adversarially
verified, 3 killed). Question: best 2026 approach for an interactive 32-team
knockout bracket on a 402px phone, served from a Cloudflare Worker.

## Recommendation: rebuild Canvas 2D → SVG (keep the radial look)

Confirmed (3-0 adversarial votes) that the hand-rolled Canvas base is the wrong
foundation at this scale:

1. **Blurry under zoom / Retina** unless you hand-track `devicePixelRatio` and
   re-render — a permanent tax, never truly crisp.
2. **No object identity** — every tap target + focal-zoom point needs hand-rolled
   hit-testing (the code that kept growing).
3. **Invisible to screen readers** — canvas is a flat bitmap outside the a11y tree.
4. At 32 teams (~16 nodes, low-hundreds of objects) we're far below SVG's
   degradation threshold (~3–5k elements). SVG fixes all three at once: crisp
   vectors, DOM nodes = free tap targets + CSS + `:focus`, searchable/SR text.

**Adversarially killed** (do NOT rely on these): "horizontal swipe-through-rounds
is the best mobile pattern", "pure CSS-flexbox bracket is a viable mobile answer",
and the absolutist "SVG scales with zero quality loss". → No slam-dunk *layout*;
it's a design call. Radial is fine as a zoomable overview; pair it with
**focus+context** (tap a node → detail card), not "pinch to read 8px labels".

## Chrome-150 / web-platform features adopted in the prototype
- **CSS anchor positioning** + `@position-try` flip fallbacks → the match-detail
  card stays on-screen against the 402px edge (resolves popover-vs-edge, not
  sibling-label overlap → that's why focus+context, not denser labels).
- **View Transitions** for the node→detail morph (reduced-motion guarded).
- **Deep-linking** via `#M07`; **`<dialog>`** + ARIA roles + a visually-hidden
  `<ul>` mirror for screen-reader/keyboard users.

## Open questions (still design calls)
- Radial-as-primary vs focus+context list as primary (radial as secondary "map").
- Concrete ARIA keyboard model (arrow-key zigzag traversal).
- Graceful degradation where anchor positioning / view transitions are absent.

## Prototype
`svg-radial.html` — self-contained, runnable. Demonstrates the SVG rebuild:
crisp, real tap targets, a11y text, deep-link, anchor-positioned detail card,
pinch/wheel focal-zoom on the SVG camera `<g>`. Verified on Chrome Canary 151,
emulated iPhone 16 Pro, zero console errors.

Sources incl.: tapflare web-graphics comparison, dev3lop SVG-vs-Canvas-vs-WebGL,
g-loot/react-tournament-brackets, dev.to accessible-tournament-brackets,
developer.chrome.com anchor-positioning + web.dev view-transitions.
