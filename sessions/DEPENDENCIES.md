# DEPENDENCIES.md — Type-Safe Dependency Graph

Every dependency listed here includes: the exact version pinned in
`Cargo.toml` / `package.json`, the Rust type or TypeScript interface
that owns it, and the data flow direction. Agents must check this file
before adding or upgrading a dependency.

---

## Layer map

```
┌─────────────────────────────────────────────────────────────────┐
│  Claude (cloud inference)                                        │
│  surface: cloud__docker_mcp__engineering_coworker               │
│  tools: mcp__MCP_DOCKER__* (17 catalog servers)                  │
└────────────────────────┬────────────────────────────────────────┘
                         │ stdio / HTTP+JSON
┌────────────────────────▼────────────────────────────────────────┐
│  macOS developer machine                                         │
│  surface: macos__desktop_cowork__engineering_coworker           │
│                                                                  │
│  Claude Desktop Cowork profile:                                  │
│    engineering-coworker (Rust MCP binary)  ← crates/            │
│    chrome-devtools-mcp  (npm, Puppeteer)                        │
│    @cloudflare/mcp-server-cloudflare (npm)                      │
│    @modelcontextprotocol/server-github (npm)                    │
│    @modelcontextprotocol/server-filesystem (npm)                │
└───────────┬────────────────────────────┬────────────────────────┘
            │ wrangler deploy            │ sqlx / redis
┌───────────▼──────────┐   ┌────────────▼────────────────────────┐
│  Cloudflare Edge      │   │  Postgres + Redis (local / Railway) │
│  workers/web  (D1)    │   │  crates/durable-store               │
│  workers/cron (D1)    │   │  crates/mcp-server                  │
│  D1: subagentjobs-dwh │   │  crates/task-state-machine          │
└──────────────────────┘   └─────────────────────────────────────┘
```

---

## Rust workspace crates

### crates/schema  `v0.0.0`
**Purpose**: Shared serde/schemars types. All inter-crate data exchange
uses types from here — no ad-hoc JSON.

| Type | Fields | Used by |
|---|---|---|
| `TaskSession` | `schema_version: SemVer`, `name: String`, `queue: TaskQueue` | CLAUDE.md embedding, agent-gen |
| `TaskQueue` | `tasks: Vec<Task>` | All agents reading task state |
| `Task` | `content`, `status: TaskStatus`, `priority`, `kind: TaskKind` | durable-store, agent-gen |
| `TaskStatus` | `pending \| completed` (enum) | task-state-machine FSM |
| `TaskKind` | `Todo \| Migration{file} \| ShellCommand{command}` | agent routing |
| `AgentConfig` | `name`, `description`, `model: AgentModel`, `tools: Vec<AgentTool>`, `max_turns`, `system_prompt` | agent-gen → .claude/agents/*.yaml |
| `AgentModel` | `Opus48 \| Sonnet46 \| Haiku45` | agent-gen |
| `AgentTool` | 21-variant enum (Bash, Read, Write, …) | agent-gen, validate() |
| `VendorEntry` | `org`, `repo`, `url`, `branch`, `description` | .vendors.toml → indexer |

**Key constraint**: `AgentConfig::validate()` is called at compile time
in `agent-gen`. Typos in tool names are `E0004` (non-exhaustive match).

---

### crates/durable-store  `v0.0.0`
**Purpose**: L2 Redis + L3 Postgres tiered store. `DurableStore: Clone`
(no `Mutex` — `PgPool` + `ConnectionManager` are cheaply cloneable).

| Type | Fields | Notes |
|---|---|---|
| `DurableStore` | `pg: PgPool`, `redis: ConnectionManager` | Clone, not Arc<Mutex<>> |
| `Snapshot` | `raw_sha256: String`, `board_token: String`, `fetched_at: DateTime<Utc>` | Used for CDC deduplication |

**Dependencies**:
```toml
sqlx      = "0.8"   # runtime-tokio, tls-rustls, postgres, uuid, json, chrono, migrate
redis     = "1"     # tokio-comp, connection-manager, json
```

**Migrations** (Postgres, NOT D1):
- `001` – `fact_job_posting` (primary job table)
- `002` – `fact_board_snapshot` (CDC dedup)
- `003–005` – board configs, crawl state
- `006` – `fact_orgs`, `fact_repositories`, `dim_packages` (vendor catalog)
  **STATUS: pending** — requires `DATABASE_URL` env var

---

### crates/mcp-server  `v0.0.0`
**Purpose**: rmcp stdio MCP server. Exposed as `subagentjobs-mcp` binary.

| Tool | Input type | Returns |
|---|---|---|
| `search_jobs` | `SearchJobsInput { query, company?, limit? }` | JSON array of job stubs |
| `get_job` | `{ job_post_id: String }` | Full `JobPosting` JSON |
| `get_skill_graph` | `{ job_post_id: String }` | Skill adjacency JSON |
| `crawl_board` | `{ board_token: String }` | Crawl result summary |

**Dependencies**:
```toml
rmcp = "1"   # server, client, transport-io, schemars, macros
```

---

### crates/engineering-coworker  `v0.0.0`
**Purpose**: MCP server that executes local dev operations on behalf of
Claude (cloud). Profile: `macos__desktop_cowork__engineering_coworker`.

Binary: `target/debug/engineering-coworker`
Build: `cargo build -p engineering-coworker`

| Tool | Input | Executes |
|---|---|---|
| `cargo_check` | `{ package?: String }` | `RUSTC_WRAPPER='' cargo check [--workspace \| -p {pkg}]` |
| `cargo_test` | `{ filter?: String }` | `cargo test --workspace --no-fail-fast [filter]` |
| `wrangler_deploy` | `{ target: "web" \| "cron" }` | `cd workers/{target} && wrangler deploy` |
| `d1_query` | `{ sql: String }` | `wrangler d1 execute subagentjobs-dwh --remote --command {sql}` (DDL rejected) |
| `git_status` | `{}` | `git status --short` + `git log --oneline -10` |
| `git_commit_push` | `{ message: String, add_all?: bool }` | `git add -A && git commit -m {msg} && git push` |

---

### crates/a2a-bridge  `v0.0.0`
**Purpose**: Exposes mcp-server as an A2A agent over HTTP+JSON (axum).
**NOT gRPC** — CF Workers blocks gRPC (Node.js only).

| Endpoint | Method | Handler |
|---|---|---|
| `/.well-known/agent-card.json` | GET | Returns `AgentCard` JSON |
| `/` | POST | `tasks/send` JSON-RPC 2.0 — proxies to MCP binary via stdio |

**Dependencies**:
```toml
axum           = "0.8"   # json feature
a2a-server-lf  = git     # github.com/a2aproject/a2a-rs (not on crates.io)
```

**Status**: Stub implementation. `AgentExecutor` trait pending once
`a2a-server-lf` API stabilises.

---

### crates/agent-gen  `v0.0.0`
**Purpose**: Generates `.claude/agents/*.yaml` from type-safe Rust structs.

```
cargo run -p agent-gen                    # write .claude/agents/
cargo run -p agent-gen -- --check         # validate only (CI)
npx ts-node scripts/agents/generate.ts   # TypeScript mirror
```

Generated agents (8 total):
`cargo-check`, `migrator`, `deployer`, `crawler`, `vendor-sync`,
`indexer`, `engineering-coworker`, `a2a-bridge`

---

## Cloudflare Workers

### workers/web  (TypeScript, Hono)
**Serves**: `subagentjobs.com`
**DB binding**: `env.DB` → D1 `subagentjobs-dwh`

| Route | Handler |
|---|---|
| `GET /.well-known/agent-card.json` | Returns A2A `AgentCard` |
| `POST /a2a` | `tasks/send` JSON-RPC over D1 |
| `GET /` | Job board SPA |

**Dependencies**:
```json
{
  "hono":        "^4",
  "@a2a-js/sdk": "^0.3.13"
}
```

**Note**: `@modelcontextprotocol/hono` not yet at v1 — not in package.json.

### workers/cron
**Runs**: every 6h via Cloudflare Cron Trigger
**Purpose**: Crawls 49 job boards → D1 `fact_job_posting`

---

## npm / npx MCP servers (macOS Cowork profile only)

| Server | Package | Cloud usable? | Notes |
|---|---|---|---|
| `cloudflare` | `@cloudflare/mcp-server-cloudflare` | via Docker catalog | Docs, D1, KV, R2, Workers |
| `github` | `@modelcontextprotocol/server-github` | via Docker `github-official` | Needs `GITHUB_TOKEN` |
| `filesystem` | `@modelcontextprotocol/server-filesystem` | ✗ | Local paths only |
| `chrome-devtools` | `chrome-devtools-mcp@latest` | ✗ | Spawns Chrome via Puppeteer; macOS only |
| `engineering-coworker` | (Rust binary) | ✗ direct; ✓ future Docker | Must run on Mac with repo |

---

## Docker MCP Toolkit catalog (cloud inference surface)

Profile: `macos__desktop_cowork__engineering_coworker` (17 servers)

| Server | Type | Auth |
|---|---|---|
| `cloudflare-docs` | SSE endpoint | OAuth |
| `cloudflare-workers-builds` | SSE endpoint | OAuth |
| `cloudflare-workers-bindings` | SSE endpoint | OAuth |
| `cloudflare-browser-rendering` | SSE endpoint | OAuth |
| `cloudflare-observability` | SSE endpoint | OAuth |
| `cloudflare-ai-gateway` | SSE endpoint | OAuth |
| `cloudflare-graphql` | SSE endpoint | OAuth |
| `cloudflare-container` | SSE endpoint | OAuth |
| `cloudflare-autorag` | SSE endpoint | OAuth |
| `github-official` | Docker image | `github.personal_access_token` secret |
| `redis` | Docker image | `redis.password` secret |
| `atlassian-remote` | SSE endpoint | OAuth |
| `gitmcp` | SSE endpoint | none |
| `stripe-remote` | SSE endpoint | OAuth |
| `kubernetes` | Docker image | kubeconfig |
| `database-server` | Docker image | configured |
| `tailscale` | Docker image | configured |

---

## Authentication

| Credential | Source | Usage |
|---|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | `e6294e3ea89f8207af387d459824aaae` | wrangler, mcp-server env |
| `GITHUB_TOKEN` | `$GITHUB_TOKEN` env | github MCP server |
| `DATABASE_URL` | env var (not committed) | sqlx in durable-store, mcp-server, indexer |
| `REDIS_URL` | env var (not committed) | durable-store |
| `CLAUDE_CODE_OAUTH_TOKEN` | `~/.claude/.credentials.json` → `claudeAiOauth.accessToken` | Anthropic API (replaces ANTHROPIC_API_KEY) |

### Extracting CLAUDE_CODE_OAUTH_TOKEN
```bash
python3 -c "
import json, pathlib, time
c = json.loads(pathlib.Path.home().joinpath('.claude/.credentials.json').read_text())
oa = c['claudeAiOauth']
exp_sec = oa['expiresAt'] / 1000
remaining = exp_sec - time.time()
if remaining < 0:
    print(f'EXPIRED {-remaining/3600:.1f}h ago — run: claude auth login')
else:
    print(oa['accessToken'])
"
```

**No Rust Anthropic SDK yet** (`platform.claude.com/docs/en/cli-sdks-libraries/overview`
lists Python + TypeScript only). Workaround:
```rust
// In reqwest-based Rust code:
let token = std::env::var("CLAUDE_CODE_OAUTH_TOKEN")?;
let resp = client
    .post("https://api.anthropic.com/v1/messages")
    .header("x-api-key", token)
    .header("anthropic-version", "2023-06-01")
    .json(&body)
    .send()
    .await?;
```

---

## Vendor repos (.vendors.toml — 11 entries)

| Org/Repo | Primary type | Used for |
|---|---|---|
| `a2aproject/a2a-rs` | Rust crates (`a2a-lf`, `a2a-server-lf`, `a2a-client-lf`) | A2A bridge (git dep) |
| `a2aproject/a2a-js` | npm `@a2a-js/sdk@0.3.13` | A2A in CF Worker |
| `modelcontextprotocol/typescript-sdk` | npm `@modelcontextprotocol/sdk@1.29.0` | MCP in TS |
| `modelcontextprotocol/rust-sdk` | Rust (alternative to rmcp) | Research only |
| `modelcontextprotocol/servers` | Reference MCP servers | Patterns |
| `microsoft/pg_durable` | pgrx extension | Future: replace task-state-machine |
| `microsoft/duroxide` | Rust durable task framework | Future: orchestration |
| `microsoft/duroxide-pg` | PostgreSQL duroxide backend | Future: state persistence |
| `redis-rs/redis-rs` | Rust `redis@1` crate | Pattern reference |
| `opencoworkers/subagentjobs` | This repo (self-indexed) | MCP code search |
| `Kuberwastaken/claurst` | Rust Claude Code rewrite | Research |

Index command: `cargo run -p indexer -- --all`

---

## Planned SDK integrations (not yet available)

| SDK | Status | Notes |
|---|---|---|
| Anthropic Rust SDK | ✗ not published | Use reqwest + CLAUDE_CODE_OAUTH_TOKEN |
| Apple Foundation Models | ✗ macOS SDK only | `platform.claude.com/…/apple-foundation-models.md` |
| Claude middleware SDK | ✗ planned | `platform.claude.com/…/middleware.md`; today use rmcp |
| Memory stores API | ✗ beta planned | `platform.claude.com/…/memory_stores.md`; today use sessions/CLAUDE.md |
| Managed agent dreams | ✗ planned | `platform.claude.com/…/dreams.md`; today use TaskSession JSON |
