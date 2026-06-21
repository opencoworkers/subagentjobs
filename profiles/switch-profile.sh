#!/usr/bin/env bash
# Switch the active Claude Desktop profile.
#
# Usage:
#   ./profiles/switch-profile.sh chat       # minimal, Chat tab only
#   ./profiles/switch-profile.sh cowork     # Cowork-focused, Cloudflare + GitHub MCPs
#   ./profiles/switch-profile.sh code       # full Code tab, all MCP servers
#   ./profiles/switch-profile.sh            # show current profile

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/Library/Application Support/Claude"
CONFIG="$CONFIG_DIR/claude_desktop_config.json"

show_current() {
  if [[ -f "$CONFIG" ]]; then
    profile=$(python3 -c "import json,sys; d=json.load(open('$CONFIG')); print(d.get('_profile','unknown'))" 2>/dev/null || echo "unknown/non-profile config")
    echo "current profile: $profile"
  else
    echo "no claude_desktop_config.json found at: $CONFIG"
  fi
}

if [[ $# -eq 0 ]]; then
  show_current
  echo ""
  echo "available profiles: chat | cowork | code"
  exit 0
fi

PROFILE="$1"
SRC="$SCRIPT_DIR/claude_desktop_${PROFILE}.json"

if [[ ! -f "$SRC" ]]; then
  echo "error: unknown profile '${PROFILE}'" >&2
  echo "available: chat | cowork | code" >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR"
cp "$SRC" "$CONFIG"

echo "✓ switched to profile: ${PROFILE}"
echo "  source: $SRC"
echo "  target: $CONFIG"
echo ""

# Restart Claude Desktop if it's running.
if pgrep -x "Claude" > /dev/null 2>&1; then
  echo "restarting Claude Desktop to apply changes..."
  pkill -x "Claude" 2>/dev/null || true
  sleep 1
  open -a Claude
  echo "✓ Claude Desktop restarted"
else
  echo "Claude Desktop is not running. Launch it to apply the new profile."
fi
