# wc2026-bracket — subagentdata.com

World Cup 2026 Round-of-32 **radial bracket**, built to the same design system
as `workers/web` (subagentjobs.com): TypeScript module Worker, **D1-backed**,
**server-rendered HTML**, terminal aesthetic (`#0a0a0a` / `#51c4ff`), and an
A2A agent card.

## Storage — Cloudflare D1 (not KV)

Match data lives in the shared `subagentjobs-dwh` D1 database as a Kimball star
(`migrations/0001_bracket.sql`):

| Table        | Grain                | Notes                                        |
| ------------ | -------------------- | -------------------------------------------- |
| `dim_team`   | one national team    | `team_code`, `name`, `flag`                  |
| `fact_match` | one R32 match        | scores, status, winner, `r16_group`, prob    |

The Worker JOINs `fact_match` to `dim_team` (home + away) and shapes rows for the
page and the JSON API. Score updates are plain SQL `UPDATE`s — **no redeploy**.

## Auth — Cloudflare Secrets Store

`/api/update` is gated by `WC2026_UPDATE_SECRET`, bound from the **Secrets Store**
(`[[secrets_store_secrets]]` in `wrangler.toml`), not a plaintext `[vars]` value.
Code reads it with `await env.UPDATE_SECRET.get()`. Provision it with
`make bracket-secret`, then paste the printed `store_id` into `wrangler.toml`.

## Resource tagging

Worker, D1 dataset, and secret are tagged `github:opencoworkers/subagentjobs`
(from `cloudflare.toml` `[meta].tag`) via `make tag-resources` →
`scripts/cf-tag-resources.sh`, so the deployment's resources are discoverable
as a group. The new worker is also registered in `cloudflare.toml`.

## Routes

| Route                          | Method | Description                                  |
| ------------------------------ | ------ | -------------------------------------------- |
| `/`                            | GET    | Server-rendered bracket + matches page       |
| `/api/bracket`                 | GET    | Bracket JSON (matches + r16 pairs + meta)    |
| `/api/status`                  | GET    | Summary counts + final results               |
| `/api/update`                  | POST   | Apply score/status deltas — `Bearer` secret  |
| `/health`                      | GET    | Liveness probe                               |
| `/.well-known/agent-card.json` | GET    | A2A agent card (`get_bracket` skill)         |
| `/a2a`                         | POST   | A2A `tasks/send` → bracket data artifact     |

## Makefile (run from repo root — single entrypoint)

```bash
make bracket-setup     # toolchain: npm deps + experimental Chrome (Canary)
make build-bracket     # typecheck + bundle (wrangler dry-run)
make bracket-render-test  # iPhone 16 Pro render tests on Chrome Canary
make migrate-bracket   # apply ALL migrations (schema + seed + latest scores)
make bracket-secret    # provision Secrets Store WC2026_UPDATE_SECRET (prints store_id)
make deploy-bracket    # build → wrangler deploy
make deploy-bracket-full  # build → migrate → deploy → tag (post-merge ship)
make tag-resources     # tag Worker + D1 + secret with the repo tag
make bracket-update    # update live scores via a `claude -p` subagent worker
make bracket-install-channels  # also install Chrome Beta + Dev channels
```

`scripts/wc2026/setup.sh` is the centralized toolchain bootstrap; the Linux VM
toolchain (`scripts/toolchain/setup-linux.sh`) and the cloud `scripts/setup.sh`
(`WC2026_SETUP=1`) both route through `make bracket-setup`.

## CI / deploy (`.github/workflows/wc2026.yml`)

- **Every PR**: typecheck → wrangler dry-run bundle → Chrome Canary render tests
  (gates merge).
- **On merge to `main`**: applies D1 migrations and `wrangler deploy` — guarded
  on the `CLOUDFLARE_API_TOKEN` secret and the `WC2026_SECRETS_STORE_ID` repo
  variable (injected into `wrangler.toml` at deploy time).

`make bracket-update` runs a **`claude -p` subagent worker** that fetches the
latest results, diffs them against `/api/bracket`, and POSTs only the changed
matches to `/api/update` — the same agent-driven pattern as `make review` / `make pr`.

## Radial graph — symmetric layout (d3-hierarchy)

The bracket is a **full balanced tournament tree** — 32 teams → 16 R32 → 8 R16 →
4 QF → 2 SF → final — laid out radially by **[`d3-hierarchy`](https://github.com/d3/d3-hierarchy)**
(`d3.cluster()`), the standard tree-layout package. The cluster places leaves
evenly on the outer ring and centres every parent on its children, so the
left/right halves are **symmetric by construction** (no lopsided slice). The
layout runs **in the Worker** (`src/layout.ts`): it emits each node's normalized
polar coordinates (`ang`, `r ∈ [0,1]`) plus links into `/api/bracket` → `graph`,
so d3 never ships to the browser — the client just draws the precomputed tree on
canvas (team crests on the outer ring, match scores one ring in, round dots
inward, trophy at the centre). A test asserts the 32 leaves are evenly spaced and
the round counts are balanced.

## Radial graph — interaction (the core of the app)

The radial bracket is the product; its zoom/pan is built to feel native:

- **Unified world transform** — the graph *and* the label layer (team names,
  scores, the centre trophy) draw under the **same** `translate(pan)·scale(Z)`
  matrix. The trophy is a world-space element at the bracket centre, so it stays
  locked to the graph at any zoom/pan (fixing the drifting-crown bug).
- **Focal-anchored zoom** — pinch and trackpad/⌘-scroll zoom toward the
  fingers/cursor: `pan` is rebased each step so the world point under the focal
  stays fixed. A regression test asserts this invariant (zero drift).
- **Two-finger pan, mouse-wheel zoom, double-tap / double-click** to zoom-in or
  reset, plus on-screen **＋ / − / ⤢ controls** for desktop and accessibility.
- **Eased glide** (`requestAnimationFrame`) for reset/step zoom; pinch tracks the
  fingers 1:1 for zero-lag response. Zoom clamped to 0.6×–6×.

## Penalty-shootout scores

Ties decided on penalties carry a separate shootout score per side
(`fact_match.home_pens` / `away_pens`), rendered as a parenthesised sub-score —
`0 (4) – 0 (3)` on the match cards and `0(4)-0(3)` on the radial node. Yesterday's
(Jun 29) results are penalty dramas: MEX 0 (4)–(3) KOR and BRA 2 (5)–(4) NGA.

## Radial-graph rendering — iPhone 16 Pro / Chrome

The bracket canvas is tuned for the iPhone 16 Pro panel (DPR 3, Display-P3,
120 Hz ProMotion) and modern Chrome:

- **Display-P3 + `desynchronized` 2D context** — wider-gamut, lower-latency
  paint, with graceful fallback to sRGB.
- **DPR capped at 3** — full retina sharpness without letting a pathological
  `devicePixelRatio` blow up the backing store.
- **On-demand ("dirty") rendering** — a continuous `requestAnimationFrame` loop
  runs *only* while a match is live (the blinking node); otherwise the graph
  paints once and idles, so ProMotion isn't pinned at 120 Hz. Pan, pinch-zoom
  and resize each schedule a single coalesced frame.
- **`prefers-reduced-motion`** disables the blink loop entirely.
- **P3 palette + Chrome 150 relative-color alpha** — the accent palette is
  widened to `color(display-p3 …)` on `@media (color-gamut: p3)` screens, and
  translucent variants use `rgb(from var(--c) r g b / α)` with an sRGB fallback
  declared first.
- **`content-visibility` / `contain`** on match cards + the graph wrapper to cap
  layout/paint work.

### Render test

```bash
make bracket-render-test     # or: npm run test:render
```

Builds an offline preview (`scripts/render-preview.mjs`, esbuild-bundles the
worker and calls the exported `page()`), serves it (`scripts/preview-server.mjs`),
and drives it through **Chrome Canary at emulated iPhone 16 Pro metrics**
(`playwright.config.ts`) to assert: an experimental engine (≥150), DPR-3 backing
store, P3/desynchronized context, a non-blank painted canvas, the on-demand
loop, and zero console errors.

### Experimental browser (Chrome Canary)

The render tests run on the **nightly Canary** channel so new-in-Chrome features
(P3 canvas, Chrome 150 relative-color, …) are exercised on the build that ships
them first.

- **Linux / CI** (this container): Playwright's `chromium-tip-of-tree` *is*
  "Chrome Canary for Testing" (currently **151.x**). Install once:
  ```bash
  npm run install:canary        # playwright install chromium-tip-of-tree
  ```
  `playwright.config.ts` auto-detects the installed build under
  `$PLAYWRIGHT_BROWSERS_PATH`.
- **macOS / Windows** dev machines: install Chrome Canary from
  <https://www.google.com/chrome/canary/> and run with `PW_CHANNEL=chrome-canary`.

Resolution order: `PW_CHROMIUM` (explicit path) → `PW_CHANNEL`
(`chrome-canary` | `chrome-dev` | `chrome-beta` | `chrome`) → auto-detected
tip-of-tree → the `chromium-tip-of-tree` channel.

## State-of-the-art features & references

The web app deliberately uses recent web-platform features for a better customer
UX, each feature-detected with a graceful fallback:

| Feature | Where | Reference |
| --- | --- | --- |
| **View Transitions API** (same-document) — cross-fade tab switches | `showTab()` + `::view-transition-*` | <https://developer.chrome.com/docs/web-platform/view-transitions/same-document> (Chrome 111+) |
| **Display-P3 canvas + CSS** — wider-gamut accents on P3 screens | `ctx2d()`, `@media (color-gamut: p3)` | <https://developer.chrome.com/blog/new-canvas-features> |
| **Relative color syntax** — `rgb(from … / α)` translucent variants | `sharedCss()` | <https://developer.chrome.com/blog/chrome-150-beta> (Chrome 150) |
| **`text-wrap: balance` / `pretty`** — tidy headings + names | `.sl`, `.mteam .nm` | <https://developer.chrome.com/blog/css-text-wrap-balance> |
| **`content-visibility` / `contain`** — capped layout/paint | match cards, graph | <https://web.dev/articles/content-visibility> |
| **`prefers-reduced-motion`** — disables blink loop + transitions | client JS + CSS | <https://web.dev/articles/prefers-reduced-motion> |
| **Chrome Canary (tip-of-tree)** test target | `playwright.config.ts` | <https://www.google.com/chrome/canary/> |
