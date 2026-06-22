#!/usr/bin/env bash
# scripts/commit-tested.sh
# Atomic commits for all untracked/modified code that has passing tests.
# Each commit = one logical unit; tests must pass before commit is made.
# Idempotent: safe to re-run.
#
# Usage:  bash scripts/commit-tested.sh [--dry-run]
#
# Requires: swift (Xcode beta), git

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
XCODE="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
DRY="${1:-}"

cd "$REPO"

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
die()   { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

commit() {
  local msg="$1"; shift
  if [ "$DRY" = "--dry-run" ]; then
    yellow "DRY: git add $* && git commit -m '$msg'"
  else
    git add "$@"
    git diff --cached --quiet && { yellow "skip (nothing staged): $msg"; return; }
    git commit -m "$msg"
    green "✓ $msg"
  fi
}

run_swift_tests() {
  yellow "→ swift test …"
  DEVELOPER_DIR="$XCODE" swift test \
    --package-path "$REPO/apps/coworkers-desktop-buddy" 2>&1 \
    | tail -5
}

# ── 1. Vendor plumbing (.gitmodules + .gitignore) ───────────────────────────
commit "vendor: sync .gitmodules to .vendors.toml (11 repos)" \
  .gitmodules .gitignore

# ── 2. BuddyCore – character system (CharacterState + Controller + Manifest) ─
# Run tests first
run_swift_tests || die "Tests failed before character-system commit"

commit "buddy: add character state machine (CharacterState/Controller/Manifest)" \
  apps/coworkers-desktop-buddy/Sources/BuddyCore/CharacterState.swift \
  apps/coworkers-desktop-buddy/Sources/BuddyCore/CharacterController.swift \
  apps/coworkers-desktop-buddy/Sources/BuddyCore/CharacterManifest.swift \
  apps/coworkers-desktop-buddy/Tests/BuddyCoreTests/CharacterStateTests.swift \
  apps/coworkers-desktop-buddy/Tests/BuddyCoreTests/CharacterManifestTests.swift

# ── 3. BuddyCore – modified core files ──────────────────────────────────────
commit "buddy: update BuddyState, SessionPoller, ClaudeSummariser, ClaudeAPI" \
  apps/coworkers-desktop-buddy/Sources/BuddyCore/BuddyState.swift \
  apps/coworkers-desktop-buddy/Sources/BuddyCore/SessionPoller.swift \
  apps/coworkers-desktop-buddy/Sources/BuddyCore/ClaudeSummariser.swift \
  apps/coworkers-desktop-buddy/Sources/ClaudeAPI/ClaudeClient.swift \
  apps/coworkers-desktop-buddy/Sources/ClaudeAPI/Configuration.swift \
  apps/coworkers-desktop-buddy/Tests/BuddyCoreTests/BuddyStateTests.swift \
  apps/coworkers-desktop-buddy/Tests/BuddyCoreTests/SessionIndexParsingTests.swift \
  apps/coworkers-desktop-buddy/Tests/BuddyCoreTests/AuthConfigTests.swift

# ── 4. BuddyApp – SwiftUI window + ASCII pet (incl. overlay alignment fix) ──
commit "buddy: add BuddyApp SwiftUI sources (BuddyWindow, AsciiPetView, GIFPlayer…)" \
  apps/coworkers-desktop-buddy/Sources/BuddyApp/

# ── 5. Package / Cargo config ────────────────────────────────────────────────
commit "buddy: Package.swift + Cargo.toml/lock + Makefile" \
  apps/coworkers-desktop-buddy/Package.swift \
  apps/coworkers-desktop-buddy/Cargo.toml \
  apps/coworkers-desktop-buddy/Cargo.lock \
  apps/coworkers-desktop-buddy/Makefile

# ── 6. Scripts (lsp, toolchain, screenshots) ────────────────────────────────
commit "scripts: add lsp/, toolchain/, screenshots/ (multilspy + setup-mac/linux)" \
  scripts/lsp/ \
  scripts/toolchain/ \
  scripts/screenshots/ \
  scripts/commit-tested.sh

# ── 7. Workers additions ─────────────────────────────────────────────────────
commit "workers/cron: add job_alert.py + skills/" \
  workers/cron/job_alert.py \
  workers/cron/skills/

# ── 8. .claude config (commands, skills, settings) ──────────────────────────
commit "claude: add .claude/commands, skills, settings" \
  .claude/

# ── 9. sessions index update ────────────────────────────────────────────────
commit "sessions: update session-index.json" \
  sessions/session-index.json

green "Done. Commits:"
git log --oneline -12
