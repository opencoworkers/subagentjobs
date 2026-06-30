# subagentjobs — Claude Code context

## Pinned tooling
- Claude Code CLI: **@anthropic-ai/claude-code@2.1.195** (latest as of 2026-06-30).
  Upgrade with `npm install -g @anthropic-ai/claude-code@2.1.195`. Also exported as
  `CLAUDE_CODE_VERSION` by `scripts/setup.sh`.
- Postgres **16** + Redis **7.0** are pre-installed in the Cloudflare remote-exec
  container and auto-started by `scripts/session-start.sh` (no manual `DATABASE_URL`
  needed — the container is the Postgres host: `postgresql://subagentjobs:subagentjobs@localhost/subagentjobs`).

## Key commands
```
# Rust
cargo check -p schema
cargo check -p durable-store
cargo check -p mcp-server
cargo test --workspace

# Cloudflare
cd workers/web  && wrangler deploy
cd workers/cron && wrangler deploy
wrangler d1 execute subagentjobs-dwh --remote --file <migration>

# DB
CLOUDFLARE_ACCOUNT_ID=e6294e3ea89f8207af387d459824aaae
```

## Architecture
- `workers/web`   — Cloudflare Worker, serves subagentjobs.com, reads D1; A2A agent at POST /a2a
- `workers/cron`  — Cloudflare Worker, crawls 49 boards every 6h, runs eviction
- `crates/mcp-server`  — Rust binary: rmcp MCP server over stdio, Postgres + Redis
- `crates/a2a-bridge`  — Rust binary: exposes MCP server as A2A agent (axum HTTP, a2a-server-lf)
- `crates/indexer`     — Rust binary: walks .vendors.toml repos → fact_filesystem + dim_file_ast
- `crates/durable-store` — L2 Redis + L3 Postgres tiered store (Clone, no Mutex)
- `crates/schema`  — shared serde/schemars types incl. SemVer-versioned TaskSession
- `crates/task-state-machine` — Postgres FSM: Pending→Crawling→Enriching→Active

## A2A integration
- **CF Worker** (`workers/web`): serves `GET /.well-known/agent-card.json` and `POST /a2a` (tasks/send, HTTP+JSON transport). No gRPC — CF Workers is not Node.js.
- **Rust bridge** (`crates/a2a-bridge`): long-running axum server that wraps the MCP binary via stdio. Set `A2A_ADDR` + `MCP_BINARY` env vars. Agent card at `/.well-known/agent-card.json`.
- **SDK note**: `a2a-server-lf` / `a2a-client-lf` / `a2a-lf` are the published crate names for `a2aproject/a2a-rs` (Linux Foundation naming). Not on crates.io yet — git dep required.
- **npm**: `@a2a-js/sdk` v0.3.13. gRPC bindings require `@grpc/grpc-js` (Node.js-only). Use JSON-RPC or HTTP+JSON in Workers.

## Vendor catalog (migrations/postgres/006_ecosystem_catalog.sql)
- `fact_orgs`         — GitHub orgs (a2aproject, modelcontextprotocol, redis-rs, microsoft)
- `fact_repositories` — repos with stars/language/archived, FK to dim_vendor for cloned repos
- `dim_packages`      — npm + crates packages incl. `last_updated_at`, `is_archived`, `is_deprecated`

## .vendors.toml repos (11 entries, all cloned to vendors/)
Kuberwastaken/claurst, modelcontextprotocol/servers, opencoworkers/subagentjobs,
microsoft/pg_durable, microsoft/duroxide, microsoft/duroxide-pg,
a2aproject/a2a-rs, a2aproject/a2a-js, modelcontextprotocol/typescript-sdk,
modelcontextprotocol/rust-sdk, redis-rs/redis-rs

## Naming ontology: {device_surface}__{client_surface}__{coworker_enum}
- `macos__desktop_cowork__engineering_coworker` — Claude Desktop Cowork on macOS (= profiles/claude_desktop_cowork.json + Docker MCP profile of same name)
- `cloud__docker_mcp__engineering_coworker` — Claude inference in Anthropic cloud using Docker MCP Toolkit catalog servers (17 servers snapshotted in Docker Desktop MCP Toolkit)
- Rationale: code written for `cloud__*` surface must use `mcp__MCP_DOCKER__*` tools only. Code for `macos__*` surface can use npx/binary MCPs on the Mac.

## Type-safe agent system
- `crates/schema/src/agent.rs` — `AgentConfig`, `AgentModel`, `AgentTool` enums with `validate()` + `to_yaml()`
- `crates/agent-gen/` — binary: `cargo run -p agent-gen` regenerates `.claude/agents/*.yaml`
- `.claude/agents/` — 8 generated agents: cargo-check, migrator, deployer, crawler, vendor-sync, indexer, engineering-coworker, a2a-bridge
- `scripts/agents/schema.ts` / `agents.ts` / `generate.ts` — TypeScript+Zod mirror; `npx ts-node scripts/agents/generate.ts`

## macOS Claude Desktop profiles
- `profiles/claude_desktop_chat.json` — minimal, no MCP servers (Chat tab)
- `profiles/claude_desktop_cowork.json` — surface: macos__desktop_cowork__engineering_coworker; MCPs: Cloudflare + GitHub + filesystem + chrome-devtools (npx) + engineering-coworker (Rust binary)
- `profiles/claude_desktop_code.json` — full suite: + postgres + subagentjobs-mcp dogfood (Code tab)
- `profiles/switch-profile.sh chat|cowork|code` — swap config + restart Claude Desktop
- **Build engineering-coworker binary first**: `cargo build -p engineering-coworker`

## engineering-coworker MCP server (crates/engineering-coworker)
- Rust MCP server (rmcp, stdio transport) that exposes cargo/wrangler/git/D1 tools
- Tools: `cargo_check`, `cargo_test`, `wrangler_deploy`, `d1_query`, `git_status`, `git_commit_push`
- For Claude cloud (me) to EXECUTE operations on the developer's Mac — not just suggest code
- Binary: `target/debug/engineering-coworker` (after `cargo build -p engineering-coworker`)
- Docker MCP profile: `macos__desktop_cowork__engineering_coworker` (17 catalog servers snapshotted)

## Pending tasks

- Apply migration 006 to Postgres: `psql $DATABASE_URL -f crates/durable-store/migrations/postgres/006_ecosystem_catalog.sql`
- Implement `AgentExecutor` trait in `crates/a2a-bridge` once `a2a-server-lf` API stabilises
- Run indexer over vendor repos: `cargo run -p indexer -- --all`
- Switch Claude Desktop to cowork profile: `bash profiles/switch-profile.sh cowork`
- Refresh `CLAUDE_CODE_OAUTH_TOKEN` if expired: `claude auth login`

## Repo hygiene

- Atomic commits: `bash scripts/commit-tested.sh` — runs `swift test` before each commit
- Vendor gitignore: `vendors/*/` (org-level) + `!vendors/*/.gitkeep`
- Build artifacts ignored: `.build/`, `.swiftpm/`, `node_modules/`, `.wrangler/`, `target/`
- Current branch for active work: `feature/readme-docs-swift-linux`
