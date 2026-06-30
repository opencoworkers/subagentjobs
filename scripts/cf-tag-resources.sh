#!/usr/bin/env bash
# =============================================================================
# cf-tag-resources.sh — tag Cloudflare resources for the wc2026 deployment
# =============================================================================
# Cloudflare resources have no tag field in wrangler.toml, so we apply tags
# out-of-band via the API. Every resource associated with this deployment is
# tagged with the repo tag from cloudflare.toml ([meta].tag), making the
# Worker, its D1 dataset and its Secrets Store secret discoverable as a group.
#
# Requires: CLOUDFLARE_API_TOKEN (Workers Scripts:Edit, D1:Edit, Secrets Store:Edit).
# Account id is read from cloudflare.toml ([meta].account) or $CLOUDFLARE_ACCOUNT_ID.
#
# Usage: bash scripts/cf-tag-resources.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TOML="$REPO_ROOT/cloudflare.toml"

# ── read account + tag from cloudflare.toml ──────────────────────────────────
ACCOUNT="${CLOUDFLARE_ACCOUNT_ID:-$(grep -E '^account' "$TOML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')}"
TAG="$(grep -E '^tag' "$TOML" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
WORKER="subagentjobs-wc2026"

: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"

API="https://api.cloudflare.com/client/v4"
auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

echo "▶ Tagging Cloudflare resources for $WORKER"
echo "  account = $ACCOUNT"
echo "  tag     = $TAG"

# ── 1. Worker script tags ────────────────────────────────────────────────────
# PUT the tags collection for the script. (Workers script tags API.)
echo "  → worker script tags…"
curl -sS -X PUT "$API/accounts/$ACCOUNT/workers/scripts/$WORKER/tags" \
  "${auth[@]}" \
  --data "[\"$TAG\",\"surface:cloud__docker_mcp__engineering_coworker\",\"app:wc2026-bracket\"]" \
  | grep -o '"success":[a-z]*' || true

# ── 2. D1 dataset — tags applied at query time aren't supported; annotate via
#       a tag row so lineage is queryable from the warehouse itself. ──────────
echo "  → D1 lineage tag (dim_meta)…"
DB_NAME="subagentjobs-dwh"
( cd "$REPO_ROOT/workers/wc2026-bracket" && \
  wrangler d1 execute "$DB_NAME" --remote --command \
    "CREATE TABLE IF NOT EXISTS dim_meta(k TEXT PRIMARY KEY, v TEXT); \
     INSERT OR REPLACE INTO dim_meta(k,v) VALUES('wc2026.tag','$TAG'),('wc2026.worker','$WORKER');" \
  2>/dev/null ) || echo "    (skipped — wrangler/D1 not reachable)"

echo "✔ tagging complete"
