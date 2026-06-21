#!/usr/bin/env bash
# Clone or update all vendor repos listed in .vendors.toml.
# Usage: ./scripts/setup-vendors.sh [--update]
# Flags:
#   --update   git pull each existing clone instead of skipping it
#
# Repos land at vendors/{org}/{repo} — these dirs are gitignored.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDORS_DIR="$REPO_ROOT/vendors"
CONFIG="$REPO_ROOT/.vendors.toml"
UPDATE=${1:-""}

if ! command -v git &>/dev/null; then
  echo "error: git not found" >&2; exit 1
fi

# Parse .vendors.toml with awk (no toml tooling required)
parse_vendors() {
  awk '
    /^\[\[vendor\]\]/ { if (org && repo && url) print org "|" repo "|" url "|" branch; org=""; repo=""; url=""; branch="main" }
    /^org/    { gsub(/[" \t]/, ""); split($0,a,"="); org=a[2] }
    /^repo/   { gsub(/[" \t]/, ""); split($0,a,"="); repo=a[2] }
    /^url/    { gsub(/[" \t]/, ""); split($0,a,"="); url=a[2] }
    /^branch/ { gsub(/[" \t]/, ""); split($0,a,"="); branch=a[2] }
    END        { if (org && repo && url) print org "|" repo "|" url "|" branch }
  ' "$CONFIG"
}

mkdir -p "$VENDORS_DIR"

parse_vendors | while IFS='|' read -r org repo url branch; do
  dest="$VENDORS_DIR/$org/$repo"
  mkdir -p "$VENDORS_DIR/$org"

  if [ -d "$dest/.git" ]; then
    if [ "$UPDATE" = "--update" ]; then
      echo "↑ updating $org/$repo ($branch)…"
      git -C "$dest" fetch origin
      git -C "$dest" checkout "$branch" 2>/dev/null || true
      git -C "$dest" pull --ff-only origin "$branch"
    else
      echo "✓ $org/$repo already cloned (pass --update to refresh)"
    fi
  else
    echo "⬇ cloning $url → vendors/$org/$repo ($branch)…"
    git clone --depth 1 --branch "$branch" "$url" "$dest"
  fi
done

echo ""
echo "Done. Index with: cargo run -p indexer -- --all"
