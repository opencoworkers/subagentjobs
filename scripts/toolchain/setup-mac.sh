#!/usr/bin/env bash
# setup-mac.sh — bootstrap the full macOS toolchain for subagentjobs + coworkers-desktop-buddy
# Run once per machine; safe to re-run (idempotent).
# Used by: human developers, Claude Code agents on macOS
#
# Installs / verifies:
#   • Homebrew
#   • rustup + rust-analyzer component  (for Rust crates + Claude Code LSP)
#   • Xcode beta                        (for Swift 6 / macOS 27 / FoundationModels)
#   • sourcekit-lsp                     (bundled with Xcode, verified here)
#   • wrangler (npm)                    (for Cloudflare Worker deploys)
#   • Claude Code LSP plugins           (rust-analyzer-lsp, swift-lsp — via settings patch)

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { printf "${GREEN}✓${RESET}  %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }
err()  { printf "${RED}✗${RESET}  %s\n" "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1; }

echo ""
echo "▶  subagentjobs macOS toolchain setup"
echo "────────────────────────────────────────"

# ── Homebrew ────────────────────────────────────────────────────────────────
if need brew; then
    ok "brew $(brew --version | head -1)"
else
    warn "Homebrew not found — installing"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# ── Rust / rustup ───────────────────────────────────────────────────────────
if need rustup; then
    ok "rustup $(rustup --version 2>&1 | head -1)"
else
    warn "rustup not found — installing"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    source "$HOME/.cargo/env"
fi

if need cargo; then
    ok "cargo $(cargo --version)"
else
    err "cargo not in PATH after rustup install — add \$HOME/.cargo/bin to PATH"
    exit 1
fi

# rust-analyzer — required by rust-analyzer-lsp@claude-plugins-official
if rustup component list --installed 2>/dev/null | grep -q rust-analyzer; then
    ok "rust-analyzer (rustup component)"
else
    warn "Installing rust-analyzer component"
    rustup component add rust-analyzer
    ok "rust-analyzer installed"
fi

# ── Xcode beta (macOS 27 / FoundationModels / Swift 6.4) ───────────────────
XCODE_BETA="/Applications/Xcode-beta.app"
if [ -d "$XCODE_BETA" ]; then
    XCODE_VER=$(DEVELOPER_DIR="$XCODE_BETA/Contents/Developer" \
        swift --version 2>&1 | head -1)
    ok "Xcode beta → $XCODE_VER"
else
    warn "Xcode beta not found at $XCODE_BETA"
    warn "Install from https://developer.apple.com/download/applications/"
    warn "Required for: FoundationModels, macOS 27 SDK, Swift 6.4"
fi

# ── sourcekit-lsp — required by swift-lsp@claude-plugins-official ───────────
SKL=$(DEVELOPER_DIR="${XCODE_BETA}/Contents/Developer" \
    xcrun --find sourcekit-lsp 2>/dev/null \
    || xcrun --find sourcekit-lsp 2>/dev/null \
    || echo "")
if [ -n "$SKL" ]; then
    ok "sourcekit-lsp → $SKL"
else
    err "sourcekit-lsp not found — install Xcode or Command Line Tools"
    exit 1
fi

# ── Node.js tooling (wrangler + TypeScript/Python LSP) ──────────────────────
if ! need node; then
    warn "node not found — install from https://nodejs.org or via: brew install node"
fi

if need wrangler; then
    ok "wrangler $(wrangler --version 2>&1 | head -1)"
else
    warn "wrangler not found — installing globally via npm"
    npm install -g wrangler
    ok "wrangler installed"
fi

# typescript-language-server — required by typescript-lsp@claude-plugins-official
# Covers workers/web (TS), workers/cron (TS), and any .ts/.tsx files.
if need typescript-language-server; then
    ok "typescript-language-server $(typescript-language-server --version 2>&1 | head -1)"
else
    warn "Installing typescript-language-server + typescript"
    npm install -g typescript-language-server typescript
    ok "typescript-language-server installed"
fi

# pyright — required by pyright-lsp@claude-plugins-official
# Covers screenshot.py, scripts/toolchain/*.sh (imports), scripts/*.py, and
# the onboard scripts in build-with-claude/onboard/scripts/.
# Prefer npm (same global bin dir as typescript-language-server, always on PATH).
if need pyright; then
    ok "pyright $(pyright --version 2>&1 | head -1)"
elif need npm; then
    warn "Installing pyright via npm"
    npm install -g pyright
    ok "pyright installed"
else
    warn "Installing pyright via pip (add ~/Library/Python/3.x/bin to PATH if missing)"
    pip3 install --user pyright
    # Ensure pip user bin is on PATH for this shell and future shells
    PY_USER_BIN="$(python3 -m site --user-base)/bin"
    export PATH="$PY_USER_BIN:$PATH"
    for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
        if [ -f "$RC" ] && ! grep -q "python.*user-base" "$RC" 2>/dev/null; then
            echo 'export PATH="$(python3 -m site --user-base)/bin:$PATH"' >> "$RC"
        fi
    done
    ok "pyright installed (PATH updated)"
fi

# ── Claude Code LSP plugins ─────────────────────────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
    python3 - "$SETTINGS" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
plugins = cfg.setdefault("enabledPlugins", {})
changed = False
for p in ["cwc-makers@claude-plugins-official",
          "pyright-lsp@claude-plugins-official",
          "typescript-lsp@claude-plugins-official",
          "rust-analyzer-lsp@claude-plugins-official",
          "swift-lsp@claude-plugins-official"]:
    if not plugins.get(p):
        plugins[p] = True
        changed = True
if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    print(f"  updated {path}")
else:
    print(f"  already set in {path}")
PYEOF
    ok "Claude Code LSP plugins: cwc-makers + pyright + typescript + rust-analyzer + swift"
else
    warn "~/.claude/settings.json not found — start Claude Code once to create it"
fi

# ── multilspy (LSP query venv) ───────────────────────────────────────────────
# Provides `make lsp-symbols|def|refs|hover` for Rust, TypeScript, and Swift.
# Uses system rust-analyzer + typescript-language-server (never downloads its own).
REPO_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LSP_SETUP="$REPO_ROOT_DIR/scripts/lsp/setup.sh"
if [ -f "$LSP_SETUP" ]; then
    bash "$LSP_SETUP"
else
    warn "scripts/lsp/setup.sh not found — skipping multilspy install"
fi

echo ""
echo "────────────────────────────────────────"
echo "✓  macOS toolchain ready"
echo ""
