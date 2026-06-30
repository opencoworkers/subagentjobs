#!/usr/bin/env bash
# scripts/setup.sh — Cloud environment setup script
#
# PURPOSE: Run ONCE before Claude Code launches in a new cloud environment.
# Paste the contents of this file into the "Setup script" field at
# claude.ai/code → environment settings.
#
# Cloud sessions (CLAUDE_CODE_REMOTE=true) have PostgreSQL 16 + Redis 7.0
# pre-installed. This script starts them, creates the database, and applies
# all pending migrations.
#
# Local use: `source scripts/setup.sh` to export env vars.
#
# Pinned tooling (keep in sync with CLAUDE.md):
#   Claude Code CLI — @anthropic-ai/claude-code@2.1.195 (latest as of 2026-06-30)
#   Install/upgrade: npm install -g @anthropic-ai/claude-code@2.1.195

set -euo pipefail

REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.195}"

# ── Cloudflare (from wrangler.toml + wrangler-account.json) ──────────────────
export CLOUDFLARE_ACCOUNT_ID="e6294e3ea89f8207af387d459824aaae"
export CLOUDFLARE_D1_DATABASE_ID="305ed041-5dae-44e5-ab1f-8a63efd8627e"
export CLOUDFLARE_D1_DATABASE_NAME="subagentjobs-dwh"

# ── Redis ─────────────────────────────────────────────────────────────────────
export REDIS_URL="${REDIS_URL:-redis://localhost:6379}"

if ! redis-cli -e ping &>/dev/null 2>&1; then
  if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    service redis-server start || true
  else
    docker run -d --name subagentjobs-redis -p 6379:6379 redis:7-alpine \
      || docker start subagentjobs-redis || true
  fi
  sleep 1
fi

# ── PostgreSQL ────────────────────────────────────────────────────────────────
# Cloud sessions: pre-installed at localhost. Local: use docker or set DATABASE_URL.
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
  service postgresql start || true
  sleep 2
  sudo -u postgres psql -c "CREATE DATABASE subagentjobs;" 2>/dev/null || true
  sudo -u postgres psql -c "CREATE USER subagentjobs WITH PASSWORD 'subagentjobs';" 2>/dev/null || true
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE subagentjobs TO subagentjobs;" 2>/dev/null || true
  export DATABASE_URL="postgresql://subagentjobs:subagentjobs@localhost/subagentjobs"
fi

# ── Apply migrations (if DATABASE_URL is set) ─────────────────────────────────
if [ -n "${DATABASE_URL:-}" ]; then
  echo "▶ Applying Postgres migrations…"
  for sql in "$REPO"/crates/durable-store/migrations/postgres/*.sql; do
    echo "  → $sql"
    psql "$DATABASE_URL" -f "$sql" 2>/dev/null || true
  done
fi

# ── LRU cache ─────────────────────────────────────────────────────────────────
export LRU_CAPACITY="${LRU_CAPACITY:-512}"
export MDX_CACHE_FILE="$REPO/crates/docs-crawler/.cache/mdx-lru.json"

# ── subagentdata.com worker toolchain (opt-in; routed through the Makefile) ───
# Installs the worker's npm deps + experimental Chrome (Canary) for the render
# tests. Off by default so cloud boots stay fast — set WC2026_SETUP=1 to enable.
# Single entrypoint: delegate to `make bracket-setup`.
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"
if [ "${WC2026_SETUP:-0}" = "1" ] && command -v make >/dev/null 2>&1; then
  echo "▶ make bracket-setup (subagentdata.com worker toolchain)…"
  make -C "$REPO" bracket-setup || echo "⚠ bracket-setup failed (non-fatal)"
fi

# ── Persist vars for Claude Code Bash tool calls ──────────────────────────────
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

echo "✓ Environment ready"
[ -n "${DATABASE_URL:-}" ] && echo "  DATABASE_URL=$DATABASE_URL"
echo "  REDIS_URL=$REDIS_URL"
echo "  CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID"
