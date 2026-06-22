# subagentjobs

Job board aggregator and AI coworker platform built on Cloudflare Workers, Rust, and Swift.

## What it does

- **subagentjobs.com** — Cloudflare Worker serving a live job board; crawls 49 boards every 6 hours via D1 + cron
- **MCP server** — Rust binary exposing job search and session tools over stdio (Postgres + Redis)
- **A2A bridge** — Rust binary wrapping the MCP server as an Agent-to-Agent HTTP endpoint
- **Coworkers Desktop Buddy** — macOS SwiftUI companion app: tamagotchi-style pet that tracks Claude Code sessions, optionally over BLE (M5StickC Plus)

## Layout

```
workers/
  web/          Cloudflare Worker — serves subagentjobs.com, A2A routes
  cron/         Cloudflare Worker — crawls 49 job boards every 6h, eviction

crates/
  schema/               Shared serde/schemars types, SemVer-versioned TaskSession
  durable-store/        L2 Redis + L3 Postgres tiered store
  mcp-server/           rmcp MCP server (stdio)
  a2a-bridge/           axum A2A HTTP server wrapping MCP
  indexer/              Walks vendors/ → fact_filesystem + dim_file_ast
  task-state-machine/   Postgres FSM: Pending→Crawling→Enriching→Active
  engineering-coworker/ Rust MCP server — cargo/wrangler/git/D1 tools for Claude

apps/
  coworkers-desktop-buddy/  SwiftUI macOS app + Rust BLE bridge

scripts/
  commit-tested.sh   Atomic commit helper (runs tests before each commit)
  lsp/               multilspy LSP query tool (Rust, TypeScript, Swift)
  toolchain/         setup-mac.sh, setup-linux.sh
  screenshots/       screenshot.py + buddy screenshots
  llms/              LLM reference docs (Apple Foundation Models, etc.)

vendors/    Read-only vendor clones (see .vendors.toml + .gitmodules, gitignored)
sessions/   Cross-session agent memory
profiles/   Claude Desktop profiles (chat / cowork / code)
.claude/    Claude Code agents, skills, commands
```

## Quick start

```bash
# macOS
bash scripts/toolchain/setup-mac.sh

# Linux VM
bash scripts/toolchain/setup-linux.sh

# Build
cargo check --workspace
cd apps/coworkers-desktop-buddy && make build

# Test
cargo test --workspace
cd apps/coworkers-desktop-buddy && swift test

# Deploy
cd workers/web  && wrangler deploy
cd workers/cron && wrangler deploy
```

## Cloudflare

```
CLOUDFLARE_ACCOUNT_ID=e6294e3ea89f8207af387d459824aaae
```

D1 migrations: `wrangler d1 execute subagentjobs-dwh --remote --file <file>`

## Vendor repos

Declared in `.vendors.toml` and `.gitmodules`. Cloned to `vendors/` (gitignored). Never modify.

```bash
git submodule update --init --depth 1
# or:
./scripts/setup-vendors.sh --update
```

## Claude Desktop profiles

```bash
cargo build -p engineering-coworker          # required first
bash profiles/switch-profile.sh chat         # minimal
bash profiles/switch-profile.sh cowork       # + engineering-coworker MCP
bash profiles/switch-profile.sh code         # full suite + postgres + MCP dogfood
```

## Architecture

```
subagentjobs.com
  └── workers/web (CF Worker, D1)
        ├── GET  /.well-known/agent-card.json
        └── POST /a2a  (tasks/send, HTTP+JSON)

crates/a2a-bridge  (axum, long-running)
  └── stdio → crates/mcp-server (rmcp)
        └── Postgres + Redis (crates/durable-store)

apps/coworkers-desktop-buddy (macOS 26+)
  ├── BuddyApp      (SwiftUI, FoundationModels)
  └── src/main.rs   (btleplug BLE → M5StickC Plus via NUS)
```

## Naming ontology

`{device_surface}__{client_surface}__{coworker_enum}`

- `macos__desktop_cowork__engineering_coworker` — Claude Desktop Cowork on macOS
- `cloud__docker_mcp__engineering_coworker` — Claude cloud via Docker MCP Toolkit
