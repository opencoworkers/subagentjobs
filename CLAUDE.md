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

## .vendors.toml repos (11 entries)
Kuberwastaken/claurst, modelcontextprotocol/servers, opensubagents/subagentjobs,
microsoft/pg_durable, microsoft/duroxide, microsoft/duroxide-pg,
a2aproject/a2a-rs, a2aproject/a2a-js, modelcontextprotocol/typescript-sdk,
modelcontextprotocol/rust-sdk, redis-rs/redis-rs

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
      {"schema_version":"0.1.0","content":"Add @a2a-js/sdk + @modelcontextprotocol/hono to workers/web/package.json","status":"completed","priority":"medium","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"cargo check --workspace after axum + a2a-rs wiring","status":"pending","priority":"high","kind":{"kind":"shell_command","command":"RUSTC_WRAPPER='' cargo check --workspace"}},
      {"schema_version":"0.1.0","content":"Run migration 006 remotely: wrangler d1 execute subagentjobs-dwh --remote --file crates/durable-store/migrations/postgres/006_ecosystem_catalog.sql","status":"pending","priority":"medium","kind":{"kind":"shell_command","command":"wrangler d1 execute subagentjobs-dwh --remote --file crates/durable-store/migrations/postgres/006_ecosystem_catalog.sql"}},
      {"schema_version":"0.1.0","content":"Deploy updated CF Worker (A2A routes) via wrangler deploy","status":"pending","priority":"medium","kind":{"kind":"shell_command","command":"cd workers/web && wrangler deploy"}},
      {"schema_version":"0.1.0","content":"Clone new vendor repos: a2a-rs, a2a-js, typescript-sdk, rust-sdk, redis-rs via setup-vendors.sh","status":"pending","priority":"low","kind":{"kind":"shell_command","command":"./scripts/setup-vendors.sh"}},
      {"schema_version":"0.1.0","content":"Implement AgentExecutor trait in a2a-bridge once a2a-server-lf API stabilises (replaces axum stubs)","status":"pending","priority":"low","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Commit and push all ecosystem wiring changes","status":"pending","priority":"medium","kind":{"kind":"shell_command","command":"git add -A && git commit -m 'feat(ecosystem): A2A wiring, vendor catalog, migration 006' && git push"}}
    ]
  }
}
```
