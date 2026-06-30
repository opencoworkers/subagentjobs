#!/usr/bin/env bash
# =============================================================================
# scripts/wc2026/setup.sh — toolchain bootstrap for the subagentdata.com worker
# =============================================================================
# Centralised, idempotent setup for workers/wc2026-bracket. Invoked through the
# Makefile (`make bracket-setup`) so the repo keeps a single entrypoint; the
# Linux VM toolchain (scripts/toolchain/setup-linux.sh) calls it too.
#
# Installs:
#   • the worker's npm dependencies (wrangler, typescript, esbuild, playwright)
#   • the most experimental Chrome for the render tests — the nightly Canary
#     channel. On Linux/CI that is Playwright's `chromium-tip-of-tree`, which is
#     literally "Chrome Canary for Testing" (Chrome 151.x at time of writing).
#     Refs: https://playwright.dev/docs/browsers#chromium-tip-of-tree
#           https://www.google.com/chrome/canary/  (macOS/Windows desktop build)
#   • optionally the Chrome Beta + Dev channels (WC2026_INSTALL_CHANNELS=1).
#     Refs: https://playwright.dev/docs/browsers#google-chrome--microsoft-edge
#
# Env knobs:
#   WC2026_INSTALL_CHANNELS=1   also install chrome-beta + chrome-dev (apt, sudo)
#   PLAYWRIGHT_BROWSERS_PATH    where browsers live (default /opt/pw-browsers)
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RESET='\033[0m'
ok()   { printf "${GREEN}✓${RESET}  %s\n" "$*"; }
warn() { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }
step() { printf "${CYAN}▶${RESET}  %s\n" "$*"; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKER="$REPO/workers/wc2026-bracket"
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1   # we manage browsers explicitly below

cd "$WORKER"

echo ""
step "subagentdata.com (wc2026-bracket) toolchain setup"
echo "────────────────────────────────────────"

# ── 1. npm dependencies ──────────────────────────────────────────────────────
if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund 2>/dev/null || npm install --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi
ok "npm dependencies"

# ── 2. Experimental Chrome (Canary / tip-of-tree) ────────────────────────────
# Resolve the pinned install location + download URL from Playwright itself
# (its browsers.json is not a public export, so we read the dry-run plan).
runs() { [ -x "$1/chrome-linux/chrome" ] && "$1/chrome-linux/chrome" --version >/dev/null 2>&1; }

install_canary() {
  # Already installed (any tip-of-tree build that actually runs)? Done.
  for d in "$PLAYWRIGHT_BROWSERS_PATH"/chromium_tip_of_tree-*; do
    if runs "$d"; then ok "Chrome Canary already installed → $("$d/chrome-linux/chrome" --version 2>&1 | head -1)"; return 0; fi
  done

  local plan loc url
  plan="$(PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=0 npx playwright install --dry-run chromium-tip-of-tree 2>/dev/null || true)"
  loc="$(printf '%s\n' "$plan" | awk '/Install location/{print $3; exit}')"
  url="$(printf '%s\n' "$plan" | awk '/Download url/{print $3; exit}')"
  if [ -z "$loc" ] || [ -z "$url" ]; then
    warn "could not resolve Canary download plan — render tests fall back to PW_CHANNEL/PW_CHROMIUM"; return 1
  fi
  runs "$loc" && { ok "Chrome Canary already installed"; return 0; }

  step "Installing Chrome Canary for Testing → $loc"
  # The 178 MB CDN download drops mid-stream behind the proxy; curl resumes
  # (-C -) where Playwright can't. Build atomically in a temp dir; never touch a
  # good existing install until the new download is verified.
  local tmp; tmp="$(mktemp -d)"
  if curl -L -C - --retry 8 --retry-all-errors -o "$tmp/cft.zip" "$url" \
     && unzip -tq "$tmp/cft.zip" >/dev/null 2>&1 \
     && unzip -q -o "$tmp/cft.zip" -d "$tmp"; then
    mkdir -p "$loc"
    rm -rf "$loc/chrome-linux"
    mv "$tmp/chrome-linux64" "$loc/chrome-linux"
    : > "$loc/INSTALLATION_COMPLETE"; : > "$loc/DEPENDENCIES_VALIDATED"
    chmod +x "$loc/chrome-linux/chrome"; rm -rf "$tmp"
    ok "Chrome Canary installed → $("$loc/chrome-linux/chrome" --version 2>&1 | head -1)"
  else
    rm -rf "$tmp"
    warn "Could not install Chrome Canary — render tests fall back to PW_CHANNEL/PW_CHROMIUM"; return 1
  fi
}
install_canary || true

# ── 3. Optional: Chrome Beta + Dev channels ──────────────────────────────────
# Opt-in (apt-installs Google's .deb, needs sudo). On Linux you must run the
# deps step as root so HTTPS_PROXY reaches apt.
# Ref: https://playwright.dev/docs/browsers#install-system-dependencies
if [ "${WC2026_INSTALL_CHANNELS:-0}" = "1" ]; then
  step "Installing Chrome Beta + Dev channels (opt-in)…"
  for ch in chrome-beta chrome-dev; do
    if PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=0 sudo -E npx playwright install --with-deps "$ch" 2>/dev/null; then
      ok "$ch installed"
    else
      warn "$ch unavailable in this environment (skipped)"
    fi
  done
else
  printf "${CYAN}  → set WC2026_INSTALL_CHANNELS=1 to also install chrome-beta + chrome-dev${RESET}\n"
fi

echo ""
echo "────────────────────────────────────────"
ok "subagentdata.com toolchain ready"
echo ""
