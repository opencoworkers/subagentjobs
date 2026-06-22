# sessions/ — Cross-Session Agent Memory

This directory bridges the gap until Anthropic ships persistent memory
(`memory_stores`, `managed-agents/memory`, `managed-agents/dreams`).
When those APIs stabilise, migrate: the schemas below map directly to
the planned `MemoryStore` and `DreamLog` types.

## What lives here

| File | Tracked? | Purpose |
|---|---|---|
| `CLAUDE.md` | ✓ git | This file — orientation for any agent entering a new session |
| `DEPENDENCIES.md` | ✓ git | Type-safe dependency graph; read before touching any crate or worker |
| `scheduled-tasks.json` | ✓ git | Active Cowork scheduled tasks (source of truth) |
| `session-index.json` | ✓ git | Lightweight index of past sessions (no blobs) |
| `*.jsonl` | ✗ .gitignore | Raw conversation transcripts (~5–30 MB each, stay local) |
| `local_*.json` | ✗ .gitignore | Full session export blobs |

## How sessions work (current implementation)

Session transcripts live at:
```
~/Library/Application Support/Claude/local-agent-mode-sessions/
  {session_id}/                         ← one per Claude Desktop workspace
    {conversation_id}/
      local_{instance_id}.json          ← full session export blob
      local_{instance_id}/
        audit.jsonl                     ← tool call audit log
        .claude/projects/…/
          {uuid}.jsonl                  ← conversation transcript
      scheduled-tasks.json              ← active scheduled tasks
      cowork-*.json                     ← runtime caches (ephemeral)
```

Current session IDs:
- session:      `5af96f5e-8c3f-4aea-a817-47d68184874c`
- conversation: `098b24ed-f969-4f93-a46c-2c42abe0f9b7`
- primary instance: `local_fafa287d-e4a1-481d-b489-c44bdca75bdd` (7.1 MB audit)

## Authentication — CLAUDE_CODE_OAUTH_TOKEN

The Claude CLI uses OAuth, not API keys. When you need to call the
Anthropic API programmatically (e.g. from the engineering-coworker MCP),
use the OAuth access token from the credentials file as a drop-in for
`ANTHROPIC_API_KEY`:

```bash
# Extract current token (refresh it if expiresAt is in the past)
CLAUDE_CODE_OAUTH_TOKEN=$(python3 -c "
import json, pathlib, time
c = json.loads(pathlib.Path('$HOME/.claude/.credentials.json').read_text())
oa = c['claudeAiOauth']
exp_ms = oa['expiresAt']
if exp_ms < time.time() * 1000:
    print('TOKEN EXPIRED — run: claude auth login', flush=True)
else:
    print(oa['accessToken'])
")
export CLAUDE_CODE_OAUTH_TOKEN
```

The credentials file: `~/.claude/.credentials.json`
- `claudeAiOauth.accessToken`  → use as `CLAUDE_CODE_OAUTH_TOKEN`
- `claudeAiOauth.refreshToken` → use to get a new access token if expired
- `claudeAiOauth.scopes`       → `["user:inference", "user:mcp_servers", …]`

No Rust SDK yet — use `reqwest` with the `x-api-key: $CLAUDE_CODE_OAUTH_TOKEN`
header, or `ANTHROPIC_API_KEY=$CLAUDE_CODE_OAUTH_TOKEN` for the Python SDK.
See `DEPENDENCIES.md` for the planned Rust SDK tracker.

## Planned Anthropic memory features (not yet available)

These docs don't resolve yet but define the target architecture:

| Feature | Planned URL | Current workaround |
|---|---|---|
| Memory stores | `platform.claude.com/docs/en/api/cli/beta/memory_stores.md` | `sessions/session-index.json` + CLAUDE.md |
| Managed agent memory | `platform.claude.com/docs/en/managed-agents/memory.md` | CLAUDE.md TaskSession JSON in root |
| Dreams (reflection) | `platform.claude.com/docs/en/managed-agents/dreams.md` | Manual decomposition into durable tasks |
| Apple Foundation Models | `platform.claude.com/docs/en/cli-sdks-libraries/libraries/apple-foundation-models.md` | N/A (macOS only, future) |
| Middleware SDK | `platform.claude.com/docs/en/cli-sdks-libraries/middleware.md` | rmcp + axum in crates/a2a-bridge |

## Active durable tasks (as of 2026-06-21)

```json
[
  {
    "id": "task-sessions-scaffold",
    "description": "Create sessions/ directory, CLAUDE.md, DEPENDENCIES.md, .gitignore",
    "status": "in_progress",
    "priority": "high"
  },
  {
    "id": "task-migration-006-postgres",
    "description": "Apply crates/durable-store/migrations/postgres/006_ecosystem_catalog.sql to Postgres. Requires DATABASE_URL env var. Run: psql $DATABASE_URL -f crates/durable-store/migrations/postgres/006_ecosystem_catalog.sql",
    "status": "pending",
    "priority": "medium",
    "blocked_by": ["DATABASE_URL environment variable"]
  },
  {
    "id": "task-indexer-run",
    "description": "Run cargo run -p indexer -- --all to index all 11 vendor repos into fact_filesystem + dim_file_ast",
    "status": "pending",
    "priority": "low",
    "blocked_by": ["task-migration-006-postgres"]
  },
  {
    "id": "task-a2a-bridge-executor",
    "description": "Implement AgentExecutor trait in crates/a2a-bridge once a2a-server-lf API stabilises",
    "status": "pending",
    "priority": "low"
  },
  {
    "id": "task-engineering-coworker-profile-switch",
    "description": "Run: bash profiles/switch-profile.sh cowork — switches Claude Desktop to macos__desktop_cowork__engineering_coworker profile with engineering-coworker MCP + chrome-devtools loaded",
    "status": "pending",
    "priority": "medium",
    "note": "Run after ending the current Claude Desktop session"
  },
  {
    "id": "task-migration-007-doc-pages",
    "description": "Apply migration 007 to Postgres: psql $DATABASE_URL -f crates/durable-store/migrations/postgres/007_doc_pages.sql",
    "status": "pending",
    "priority": "high",
    "blocked_by": ["DATABASE_URL environment variable"]
  },
  {
    "id": "task-redis-start",
    "description": "Start local Redis for docs-crawler + durable-store: make redis-start (requires Docker). Verify: redis-cli ping",
    "status": "completed",
    "note": "Redis 7-alpine running on :6379 (container: subagentjobs-redis). Verify: redis-cli ping → PONG"
  },
  {
    "id": "task-first-crawl",
    "description": "Run first Claude docs crawl: DATABASE_URL=$DATABASE_URL make crawl-docs. Expected: ~500 pages fetched, docs/{code,platform,support,claude}.claude.com/ populated, fact_doc_pages upserted.",
    "status": "pending",
    "priority": "high",
    "blocked_by": ["task-migration-007-doc-pages", "task-redis-start"]
  },
  {
    "id": "task-index-docs",
    "description": "Index downloaded docs for MCP search: make index-docs (cargo run -p indexer -- --path docs/). Populates fact_filesystem + dim_file_ast for FTS.",
    "status": "pending",
    "priority": "medium",
    "blocked_by": ["task-first-crawl"]
  }
]
```

## Quick orientation for a new agent session

1. Read `CLAUDE.md` (root) — architecture, key commands, active TaskSession
2. Read `sessions/DEPENDENCIES.md` — type-safe dependency graph
3. Check `sessions/scheduled-tasks.json` — what's running automatically
4. Check git log: `git log --oneline -10`
5. Run `RUSTC_WRAPPER='' cargo check --workspace` before any Rust changes
