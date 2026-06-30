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
if [ -f "$REPO/sessions/tasks.yaml" ] && [ -n "${DATABASE_URL:-}" ]; then
  if cargo build -p task-bootstrap --quiet 2>/dev/null; then
    "$REPO/target/debug/task-bootstrap" \
      --tasks "$REPO/sessions/tasks.yaml" \
      --database-url "$DATABASE_URL" \
      2>&1 || true
  fi
fi
