#!/usr/bin/env bash
# scripts/session-start.sh — SessionStart hook
#
# Runs after Claude Code launches on EVERY session start and resume,
# in both local and cloud environments.
#
# Configured in .claude/settings.json under hooks.SessionStart.
# Writes vars to $CLAUDE_ENV_FILE so they persist across Bash tool calls.

set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ── Cloudflare ────────────────────────────────────────────────────────────────
export CLOUDFLARE_ACCOUNT_ID="e6294e3ea89f8207af387d459824aaae"
export CLOUDFLARE_D1_DATABASE_ID="305ed041-5dae-44e5-ab1f-8a63efd8627e"
export CLOUDFLARE_D1_DATABASE_NAME="subagentjobs-dwh"

# ── Redis ─────────────────────────────────────────────────────────────────────
export REDIS_URL="${REDIS_URL:-redis://localhost:6379}"

# Cloud sessions ship Redis pre-installed but stopped — start it so the
# docs-crawler + durable-store L2 tier are reachable without manual setup.
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && ! redis-cli ping >/dev/null 2>&1; then
  service redis-server start >/dev/null 2>&1 || true
fi

# ── PostgreSQL ────────────────────────────────────────────────────────────────
# The Cloudflare remote-exec container ships PostgreSQL (16) pre-installed but
# stopped. Start it and provision the local database so durable-task tooling
# (task-bootstrap, indexer, migrations) works with no externally-supplied
# DATABASE_URL — the container IS the Postgres host.
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
  service postgresql start >/dev/null 2>&1 || true
  # Wait briefly for the socket, then provision idempotently.
  for _ in 1 2 3 4 5; do pg_isready -q && break; sleep 1; done
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='subagentjobs'" 2>/dev/null | grep -q 1 \
    || sudo -u postgres psql -c "CREATE DATABASE subagentjobs;" >/dev/null 2>&1 || true
  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='subagentjobs'" 2>/dev/null | grep -q 1 \
    || sudo -u postgres psql -c "CREATE USER subagentjobs WITH PASSWORD 'subagentjobs';" >/dev/null 2>&1 || true
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE subagentjobs TO subagentjobs;" >/dev/null 2>&1 || true
  sudo -u postgres psql -c "ALTER DATABASE subagentjobs OWNER TO subagentjobs;" >/dev/null 2>&1 || true
  export DATABASE_URL="${DATABASE_URL:-postgresql://subagentjobs:subagentjobs@localhost/subagentjobs}"
fi

# Apply pending Postgres migrations so the schema exists before task-bootstrap.
if [ -n "${DATABASE_URL:-}" ] && command -v psql >/dev/null 2>&1; then
  for sql in "$REPO"/crates/durable-store/migrations/postgres/*.sql; do
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$sql" >/dev/null 2>&1 || true
  done
fi

# ── LRU cache ─────────────────────────────────────────────────────────────────
export LRU_CAPACITY="${LRU_CAPACITY:-512}"
export MDX_CACHE_FILE="$REPO/crates/docs-crawler/.cache/mdx-lru.json"

# ── Write to CLAUDE_ENV_FILE for tool-call persistence ────────────────────────
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  cat >> "$CLAUDE_ENV_FILE" <<EOF
CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID
CLOUDFLARE_D1_DATABASE_ID=$CLOUDFLARE_D1_DATABASE_ID
CLOUDFLARE_D1_DATABASE_NAME=$CLOUDFLARE_D1_DATABASE_NAME
REDIS_URL=$REDIS_URL
LRU_CAPACITY=$LRU_CAPACITY
MDX_CACHE_FILE=$MDX_CACHE_FILE
EOF
  [ -n "${DATABASE_URL:-}" ] && echo "DATABASE_URL=$DATABASE_URL" >> "$CLAUDE_ENV_FILE"
fi

echo "✓ session-start: env vars exported (CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID)"

# ── Task bootstrap ─────────────────────────────────────────────────────────────
# Upsert pending tasks from sessions/tasks.yaml into Postgres fact_tasks.
# Only runs when DATABASE_URL is set (skips gracefully in local sessions without Postgres).
BOOTSTRAP="$REPO/target/debug/task-bootstrap"
if [ -f "$REPO/sessions/tasks.yaml" ] && [ -n "${DATABASE_URL:-}" ]; then
  if [ -x "$BOOTSTRAP" ] || cargo build -p task-bootstrap --quiet 2>/dev/null; then
    "$BOOTSTRAP" \
      --tasks "$REPO/sessions/tasks.yaml" \
      --database-url "$DATABASE_URL" \
      2>&1 || true
  fi
fi
