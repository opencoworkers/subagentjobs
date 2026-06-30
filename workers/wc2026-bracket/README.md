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
so d3 never ships to the browser — the client renders the precomputed tree as
**SVG** (team crests on the outer ring, match scores one ring in, round dots
inward, trophy at the centre). A test asserts the 32 leaves are evenly spaced and
the round counts are balanced.

## Radial graph — SVG rendering (rebuilt from Canvas)

Deep research (`prototypes/RESEARCH.md`) found the hand-rolled Canvas base wrong
at this scale: blurry under zoom/Retina (needs manual DPR), no object identity
(hand-rolled hit-testing), invisible to screen readers. At 32 teams (~63 nodes)
we're far below SVG's degradation threshold, so the bracket is now **SVG DOM**:

- **Crisp vectors** at any zoom/DPR — no `devicePixelRatio` math, no blur (the
  whole graph lives in a `0 0 100 100` viewBox).
- **Real DOM nodes** = native tap targets, `:focus`, and CSS — no hand-rolled
  hit-testing. Each match node is a `role="button"` with `aria-label` + `<title>`.
- **Screen-reader + keyboard**: every node is focusable; a visually-hidden
  `<ul id="srlist">` mirrors the bracket and is **deep-linkable** (`#M07`).
- **Live pulse** is a CSS animation on `.node.live .dot` (no JS rAF loop),
  disabled under `prefers-reduced-motion`.

## Radial graph — interaction (focus + context)

The radial is a zoomable overview; tapping a node opens a detail card rather than
forcing pinch-to-read tiny labels:

- **Focal-anchored zoom** on a single SVG camera `<g>` — pinch and trackpad/
  ⌘-scroll zoom toward the fingers/cursor (`pan` rebased each step). The trophy
  and every node share that transform, so nothing drifts. A regression test
  asserts the zero-drift invariant.
- **Two-finger pan, wheel zoom, double-tap reset**, on-screen **＋ / − / ⤢**, eased
  glide; zoom clamped 0.6×–6×.
- **Match detail card** (`<dialog>`) anchored to the tapped node via **CSS anchor
  positioning** + `@position-try` flip fallbacks (stays on-screen at 402px), with
  a **View Transition** morph and `#M07` deep-link.

## Penalty-shootout scores

Ties decided on penalties carry a separate shootout score per side
(`fact_match.home_pens` / `away_pens`), rendered as a parenthesised sub-score —
`0 (4) – 0 (3)` on the match cards and `0(4)-0(3)` on the radial node. Yesterday's
(Jun 29) results are penalty dramas: MEX 0 (4)–(3) KOR and BRA 2 (5)–(4) NGA.

## Styling — iPhone 16 Pro / Chrome

- **P3 palette + Chrome 150 relative-color alpha** — the accent palette is
  widened to `color(display-p3 …)` on `@media (color-gamut: p3)` screens, and
  translucent variants use `rgb(from var(--c) r g b / α)` with an sRGB fallback.
- **`text-wrap: balance/pretty`**, `color-scheme: dark`, and
  **`content-visibility` / `contain`** on match cards + the graph wrapper.
- **`prefers-reduced-motion`** disables the live pulse and View Transitions.

### Render test

```bash
make bracket-render-test     # or: npm run test:render
```

Builds an offline preview (`scripts/render-preview.mjs`, esbuild-bundles the
worker and calls the exported `page()`), serves it (`scripts/preview-server.mjs`),
and drives it through **Chrome Canary at emulated iPhone 16 Pro metrics**
(`playwright.config.ts`) to assert: an experimental engine (≥150), crisp **SVG
DOM** (no canvas) with 16 match nodes / 32 crests / 62 links, `role="button"` +
`aria-label` tap targets, the symmetric layout, the focal-zoom invariant, the
penalty scores, the tap→detail card, `#M07` deep-linking, and zero console errors.

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
| **SVG DOM bracket** — crisp vectors, tap targets, a11y, deep-link | `buildSVG()`, `src/layout.ts` | <https://github.com/d3/d3-hierarchy> + `prototypes/RESEARCH.md` |
| **CSS anchor positioning** + `@position-try` — on-screen match detail card | `#detail`, `selectMatch()` | <https://developer.chrome.com/docs/css-ui/anchor-positioning-api> (Chrome 125+) |
| **View Transitions API** — tab switch + node→detail morph | `showTab()`, `selectMatch()` | <https://developer.chrome.com/docs/web-platform/view-transitions/same-document> (Chrome 111+) |
| **Display-P3 + relative-color** — wider-gamut accents | `@media (color-gamut: p3)`, `rgb(from … / α)` | <https://developer.chrome.com/blog/chrome-150-beta> (Chrome 150) |
| **`text-wrap: balance` / `pretty`** — tidy headings + names | `.sl`, `.mteam .nm` | <https://developer.chrome.com/blog/css-text-wrap-balance> |
| **`content-visibility` / `contain`** — capped layout/paint | match cards, graph | <https://web.dev/articles/content-visibility> |
| **`prefers-reduced-motion`** — disables blink loop + transitions | client JS + CSS | <https://web.dev/articles/prefers-reduced-motion> |
| **Chrome Canary (tip-of-tree)** test target | `playwright.config.ts` | <https://www.google.com/chrome/canary/> |
