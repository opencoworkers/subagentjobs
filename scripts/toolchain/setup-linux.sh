#!/usr/bin/env bash
# setup-linux.sh — bootstrap toolchain on the Linux inference VM (Ubuntu/Debian)
# Run once per container / worktree environment; idempotent.
# Used by: Claude Code agents running on Linux (Anthropic API inference VM)
#
# Installs / verifies:
#   • rustup + stable toolchain + rust-analyzer component
#   • swift + sourcekit-lsp  (from swift.org static SDK, for cross-editing .swift files)
#   • build essentials (cc, pkg-config, libssl-dev)
#
# Swift note: FoundationModels is macOS-only. Swift on Linux here is for
# sourcekit-lsp code intelligence only — the app itself builds on macOS.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
ok()   { printf "${GREEN}✓${RESET}  %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }

echo ""
echo "▶  subagentjobs Linux VM toolchain setup"
echo "────────────────────────────────────────"

# ── System packages ──────────────────────────────────────────────────────────
if need apt-get; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        curl git build-essential pkg-config \
        libssl-dev libclang-dev clang \
        binutils libcurl4 libxml2 libedit2 libsqlite3-0 \
        tzdata libncurses5 libpython3-dev \
        python3-pip pipx nodejs npm
    ok "system packages"
elif need dnf; then
    sudo dnf install -y curl git gcc pkg-config openssl-devel clang \
        python3-pip nodejs npm
    ok "system packages (dnf)"
fi

# ── Rust ─────────────────────────────────────────────────────────────────────
if need rustup; then
    ok "rustup $(rustup --version 2>&1 | head -1)"
else
    warn "Installing rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --no-modify-path --default-toolchain stable
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    ok "rustup installed"
fi

export PATH="$HOME/.cargo/bin:$PATH"

# Keep toolchain in sync with rust-toolchain.toml if present
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ -f "$REPO_ROOT/rust-toolchain.toml" ]; then
    rustup show active-toolchain || rustup update
    ok "toolchain matches rust-toolchain.toml"
fi

# rust-analyzer — required by rust-analyzer-lsp@claude-plugins-official
if rustup component list --installed 2>/dev/null | grep -q rust-analyzer; then
    ok "rust-analyzer (rustup component)"
else
    warn "Installing rust-analyzer"
    rustup component add rust-analyzer
    ok "rust-analyzer installed"
fi

# Verify rust-analyzer is in PATH (needed by Claude Code LSP)
RA_PATH=$(rustup which rust-analyzer 2>/dev/null || echo "")
if [ -n "$RA_PATH" ]; then
    ok "rust-analyzer → $RA_PATH"
    # Symlink into /usr/local/bin so it's on PATH for all users/agents
    if [ ! -f /usr/local/bin/rust-analyzer ]; then
        sudo ln -sf "$RA_PATH" /usr/local/bin/rust-analyzer 2>/dev/null || true
    fi
else
    warn "rust-analyzer not in rustup PATH — agents may not get LSP"
fi

# ── Node.js LSP servers (typescript-lsp + pyright-lsp) ─────────────────────
# typescript-language-server covers workers/web, workers/cron, and all .ts files.
# pyright covers screenshot.py, scripts/toolchain/*.sh, onboard scripts.
if need npm; then
    if need typescript-language-server; then
        ok "typescript-language-server ($(typescript-language-server --version 2>&1 | head -1))"
    else
        warn "Installing typescript-language-server + typescript"
        npm install -g typescript-language-server typescript
        ok "typescript-language-server installed"
    fi

    if need pyright; then
        ok "pyright ($(pyright --version 2>&1 | head -1))"
    else
        warn "Installing pyright"
        npm install -g pyright
        ok "pyright installed"
    fi
else
    warn "npm not available — skipping typescript-language-server and pyright"
    warn "Install Node.js: https://nodejs.org or via nvm"
fi

# ── Swift + sourcekit-lsp ────────────────────────────────────────────────────
# sourcekit-lsp provides .swift code intelligence to rust-analyzer-lsp-enabled
# Claude Code agents even when they can't build the macOS app targets.
SWIFT_VERSION="6.0.3"   # Update to match Xcode beta Swift version
SWIFT_INSTALL_DIR="/opt/swift"

if need sourcekit-lsp; then
    ok "sourcekit-lsp $(sourcekit-lsp --version 2>&1 | head -1)"
elif [ -f "$SWIFT_INSTALL_DIR/usr/bin/sourcekit-lsp" ]; then
    export PATH="$SWIFT_INSTALL_DIR/usr/bin:$PATH"
    ok "sourcekit-lsp (from $SWIFT_INSTALL_DIR)"
else
    warn "Swift not found — installing Swift $SWIFT_VERSION for sourcekit-lsp"
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        SWIFT_PKG="swift-${SWIFT_VERSION}-RELEASE-ubuntu22.04"
    else
        SWIFT_PKG="swift-${SWIFT_VERSION}-RELEASE-ubuntu22.04-aarch64"
    fi
    SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2204/${SWIFT_PKG}/${SWIFT_PKG}.tar.gz"
    TMP=$(mktemp -d)
    curl -fsSL "$SWIFT_URL" -o "$TMP/swift.tar.gz"
    sudo mkdir -p "$SWIFT_INSTALL_DIR"
    sudo tar -xzf "$TMP/swift.tar.gz" --strip-components=1 -C "$SWIFT_INSTALL_DIR"
    rm -rf "$TMP"
    export PATH="$SWIFT_INSTALL_DIR/usr/bin:$PATH"
    ok "Swift $SWIFT_VERSION installed → $SWIFT_INSTALL_DIR"

    # Persist PATH for future shells
    if ! grep -q "SWIFT_INSTALL_DIR" "$HOME/.bashrc" 2>/dev/null; then
        echo "export PATH=\"$SWIFT_INSTALL_DIR/usr/bin:\$PATH\"" >> "$HOME/.bashrc"
    fi
fi

# ── multilspy (LSP query venv) ───────────────────────────────────────────────
# Provides `make lsp-symbols|def|refs|hover` for Rust and TypeScript.
# (Swift symbols require sourcekit-lsp; Swift LSP works on Linux only for .swift editing,
#  not for building — FoundationModels is macOS-only.)
REPO_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LSP_SETUP="$REPO_ROOT_DIR/scripts/lsp/setup.sh"
if [ -f "$LSP_SETUP" ]; then
    bash "$LSP_SETUP"
else
    warn "scripts/lsp/setup.sh not found — skipping multilspy install"
fi

echo ""
echo "────────────────────────────────────────"
echo "✓  Linux VM toolchain ready"
echo ""
