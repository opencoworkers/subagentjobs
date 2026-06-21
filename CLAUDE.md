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
- `workers/web`  — Cloudflare Worker, serves subagentjobs.com, reads D1
- `workers/cron` — Cloudflare Worker, crawls 49 boards every 6h, runs eviction
- `crates/mcp-server` — Rust binary: rmcp MCP server over stdio, Postgres + Redis
- `crates/durable-store` — L2 Redis + L3 Postgres tiered store (Clone, no Mutex)
- `crates/schema` — shared serde/schemars types incl. SemVer-versioned TaskSession
- `crates/task-state-machine` — Postgres FSM: Pending→Crawling→Enriching→Active

## Active task session (schema v0.1.0)
```json
{
  "schema_version": "0.1.0",
  "name": "crate-hardening-2026-06-21",
  "queue": {
    "schema_version": "0.1.0",
    "tasks": [
      {"schema_version":"0.1.0","content":"Fix double-hash bug in check_and_record_snapshot","status":"completed","priority":"high","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Remove Arc<Mutex<DurableStore>> — derive Clone instead","status":"completed","priority":"high","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Fix search_jobs default company + get_job SHA256 URL","status":"completed","priority":"high","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Add evicted_at IS NULL to all Postgres queries","status":"completed","priority":"high","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Wire task-state-machine into crawl_board","status":"completed","priority":"medium","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Batch upserts via UNNEST + Redis pipelines","status":"completed","priority":"medium","kind":{"kind":"todo"}},
      {"schema_version":"0.1.0","content":"Add Postgres migration 003 for miss_count/evicted_at","status":"completed","priority":"medium","kind":{"kind":"migration","file":"003_add_eviction.sql"}},
      {"schema_version":"0.1.0","content":"cargo check all crates","status":"completed","priority":"low","kind":{"kind":"shell_command","command":"cargo check --workspace"}}
    ]
  }
}
```
