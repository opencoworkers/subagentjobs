# subagentjobs — Claude Code context

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

## Active task session (schema v0.1.0)
```json
{
  "schema_version": "0.1.0",
  "name": "ecosystem-wiring-2026-06-21",
  "queue": {
    "schema_version": "0.1.0",
    "tasks": [
      {"schema_version":"0.1.0","content":"Write migration 006_ecosystem_catalog.sql (fact_orgs, fact_repositories, dim_packages + seed)","status":"completed","priority":"high","kind":{"kind":"migration","file":"006_ecosystem_catalog.sql"}},
      {"schema_version":"0.1.0","content":"Update .vendors.toml with a2a-rs, a2a-js, mcp/typescript-sdk, mcp/rust-sdk, redis-rs","status":"completed","priority":"high","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Wire crates/a2a-bridge: main.rs with axum + a2a-server-lf stub, AgentCard endpoint, tasks/send→MCP stdio proxy","status":"completed","priority":"high","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Add A2A routes to workers/web: GET /.well-known/agent-card.json + POST /a2a (tasks/send, HTTP+JSON)","status":"completed","priority":"high","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Add @a2a-js/sdk to workers/web/package.json (removed @modelcontextprotocol/hono — no v1 published)","status":"completed","priority":"medium","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"cargo check --workspace after axum + a2a-rs wiring","status":"completed","priority":"high","kind":{"kind":"shell_command","command":"RUSTC_WRAPPER='' cargo check --workspace"}},
      {"schema_version":"0.1.0","content":"Deploy updated CF Worker (A2A routes) via wrangler deploy","status":"completed","priority":"medium","kind":{"kind":"shell_command","command":"cd workers/web && wrangler deploy"}},
      {"schema_version":"0.1.0","content":"Clone all vendor repos via setup-vendors.sh (11 repos in vendors/)","status":"completed","priority":"low","kind":{"kind":"shell_command","command":"./scripts/setup-vendors.sh --update"}},
      {"schema_version":"0.1.0","content":"Type-safe sub-agent system: crates/agent-gen + scripts/agents/ + .claude/agents/*.yaml (7 agents)","status":"completed","priority":"high","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"macOS Claude Desktop profiles: chat/cowork/code + profiles/switch-profile.sh","status":"completed","priority":"medium","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Commit and push all changes (6e709b3)","status":"completed","priority":"medium","kind":{"kind":"shell_command","command":"git add -A && git commit && git push"}},
      {"schema_version":"0.1.0","content":"Apply migration 006 to Postgres (not D1 — Postgres-only schema). Requires DATABASE_URL env var pointing to the Postgres instance. Run: psql $DATABASE_URL -f crates/durable-store/migrations/postgres/006_ecosystem_catalog.sql","status":"pending","priority":"medium","kind":{"kind":"migration","file":"006_ecosystem_catalog.sql"}},
      {"schema_version":"0.1.0","content":"Implement AgentExecutor trait in a2a-bridge once a2a-server-lf API stabilises (replaces axum stubs)","status":"pending","priority":"low","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Run indexer over vendor repos: cargo run -p indexer -- --all","status":"pending","priority":"low","kind":{"kind":"shell_command","command":"cargo run -p indexer -- --all"}}
    ]
  }
}
```
