#!/usr/bin/env bash
# scripts/lsp/setup.sh — create/update the LSP query venv
#
# Creates scripts/lsp/.venv/ with multilspy installed.
# multilspy is a Python LSP client library (NeurIPS 2023, Microsoft Research).
# We monkeypatch it to use the system rust-analyzer and typescript-language-server
# instead of downloading its own stale binaries.
#
# Called by:  make lsp-setup  (from apps/coworkers-desktop-buddy/Makefile)
#             scripts/toolchain/setup-mac.sh
#             scripts/toolchain/setup-linux.sh
#
# Usage:  bash scripts/lsp/setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
ok()   { printf "${GREEN}✓${RESET}  %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }

# Require Python 3.10+ (multilspy needs it for asyncio)
if ! python3 -c "import sys; assert sys.version_info >= (3,10)" 2>/dev/null; then
    warn "Python 3.10+ required for multilspy; found: $(python3 --version 2>&1)"
    warn "Install via: brew install python@3.12  (macOS) or apt-get install python3.12 (Linux)"
    exit 1
fi

if [ -f "$VENV/bin/python3" ]; then
    # Upgrade if requirements changed
    "$VENV/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt" --upgrade
    ok "multilspy venv up to date ($VENV)"
else
    warn "Creating LSP venv at $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
    "$VENV/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
    ok "multilspy installed in $VENV"
fi

# Verify system LSP servers are accessible (warn, don't fail)
if command -v rustup >/dev/null 2>&1; then
    RA=$(rustup which rust-analyzer 2>/dev/null || echo "")
    if [ -n "$RA" ]; then
        ok "rust-analyzer → $RA"
    else
        warn "rust-analyzer not installed; run: rustup component add rust-analyzer"
    fi
fi

if command -v typescript-language-server >/dev/null 2>&1; then
    ok "typescript-language-server → $(command -v typescript-language-server)"
else
    warn "typescript-language-server not found; run: npm install -g typescript-language-server typescript"
fi

echo ""
echo "Run queries with:"
echo "  $VENV/bin/python3 $SCRIPT_DIR/query.py symbols  Sources/BuddyCore/BuddyState.swift"
echo "  $VENV/bin/python3 $SCRIPT_DIR/query.py symbols  crates/schema/src/lib.rs"
echo ""
