# =============================================================================
# coworkers-desktop-buddy — single point of entry
# =============================================================================
#
# Targets:
#   make              → help (default)
#   make build        → build Swift package + Rust bridge
#   make test         → run all tests (Swift)
#   make run          → launch BuddyApp (macOS GUI)
#   make run-cli      → launch buddy CLI (terminal, watch mode)
#   make run-bridge   → launch Rust BLE bridge
#   make screenshot   → capture the running BuddyApp window
#   make clean        → remove all build artefacts
#   make check        → verify toolchain prerequisites
#
# Environment overrides (can be set before make or in .env.local):
#   DEVELOPER_DIR     Xcode developer directory (auto-detected)
#   COWORK_SESSIONS   Path to sessions/ directory (auto-detected)
#   ANTHROPIC_API_KEY Anthropic API key (used by buddy CLI)
#   BUDDY_CHARACTER   Path to character pack dir (default: vendors bufo)
#   WATCH_INTERVAL    Seconds between CLI polls (default: 10)
# =============================================================================

# ── Toolchain detection ───────────────────────────────────────────────────────

# Prefer Xcode beta (required for macOS 27 / FoundationModels).
# Falls back to whatever xcode-select points at.
XCODE_BETA        := /Applications/Xcode-beta.app/Contents/Developer
XCODE_RELEASE     := $(shell xcode-select -p 2>/dev/null)
DEVELOPER_DIR     ?= $(if $(wildcard $(XCODE_BETA)),$(XCODE_BETA),$(XCODE_RELEASE))

# /usr/bin/swift is a shim that reads DEVELOPER_DIR to select the toolchain.
# Do NOT use $(DEVELOPER_DIR)/usr/bin/swift — that path does not exist.
SWIFT             := swift
SWIFTC            := swiftc

# ── Paths ─────────────────────────────────────────────────────────────────────

# Repo root = two directories above this Makefile (apps/coworkers-desktop-buddy → …)
REPO_ROOT         := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))../..)
APP_DIR           := $(dir $(lastword $(MAKEFILE_LIST)))
BUILD_DIR         := $(APP_DIR).build/out

COWORK_SESSIONS   ?= $(REPO_ROOT)/sessions
BUDDY_CHARACTER   ?= $(REPO_ROOT)/vendors/anthropics/claude-desktop-buddy/characters/bufo
SCREENSHOT_TOOL   := $(REPO_ROOT)/screenshot.py

# ── Credentials (lazy — evaluated only when the target runs) ─────────────────

# Reads the Claude Code OAuth token from local credentials.
# Never hard-coded; falls back gracefully if the file is absent.
OAUTH_TOKEN       = $(shell python3 -c \
  "import json,sys; d=json.load(open('$(HOME)/.claude/.credentials.json')); \
   print(d['claudeAiOauth']['accessToken'])" 2>/dev/null)

# ── Build configuration ───────────────────────────────────────────────────────

SWIFT_CONFIG      ?= debug     # or release
WATCH_INTERVAL    ?= 10

# ── Colours (disable with NO_COLOR=1) ────────────────────────────────────────

ifeq ($(NO_COLOR),)
  BOLD  := \033[1m
  GREEN := \033[32m
  CYAN  := \033[36m
  YELLOW:= \033[33m
  RED   := \033[31m
  RESET := \033[0m
else
  BOLD  :=
  GREEN :=
  CYAN  :=
  YELLOW:=
  RED   :=
  RESET :=
endif

# Note: these macros must be used as standalone recipe lines only (not inside
# shell continuations) because Make's @ suppressor is not valid inside $(...).
define log
	@printf "$(BOLD)$(GREEN)▶ $(1)$(RESET)\n"
endef
define warn
	@printf "$(YELLOW)⚠  $(1)$(RESET)\n"
endef
define err
	@printf "$(RED)✗  $(1)$(RESET)\n"
endef

# ── Phony targets ─────────────────────────────────────────────────────────────

.PHONY: all help build build-swift build-rust \
        test test-swift test-verbose \
        run run-cli run-watch run-bridge \
        screenshot clean check toolchain \
        lsp-setup lsp-symbols lsp-def lsp-refs lsp-hover

# ── Default ───────────────────────────────────────────────────────────────────

all: help

# ── Help ──────────────────────────────────────────────────────────────────────

help:
	@printf "\n$(BOLD)coworkers-desktop-buddy$(RESET)\n\n"
	@printf "  $(CYAN)make build$(RESET)          Build Swift package + Rust BLE bridge\n"
	@printf "  $(CYAN)make build-swift$(RESET)    Build Swift package only\n"
	@printf "  $(CYAN)make build-rust$(RESET)     Build Rust BLE bridge only\n"
	@printf "  $(CYAN)make test$(RESET)           Run all tests\n"
	@printf "  $(CYAN)make test-verbose$(RESET)   Run tests with verbose output\n"
	@printf "  $(CYAN)make run$(RESET)            Launch BuddyApp (macOS GUI)\n"
	@printf "  $(CYAN)make run-cli$(RESET)        Launch buddy CLI (single poll)\n"
	@printf "  $(CYAN)make run-watch$(RESET)      Launch buddy CLI in watch mode\n"
	@printf "  $(CYAN)make run-bridge$(RESET)     Launch Rust BLE bridge\n"
	@printf "  $(CYAN)make screenshot$(RESET)     Capture the running BuddyApp window\n"
	@printf "  $(CYAN)make toolchain$(RESET)      Install full toolchain (mac or linux)\n"
	@printf "  $(CYAN)make lsp-setup$(RESET)      Create/update LSP query venv (multilspy)\n"
	@printf "  $(CYAN)make lsp-symbols$(RESET)    List symbols  FILE=path/to/file.rs|.ts|.swift\n"
	@printf "  $(CYAN)make lsp-def$(RESET)        Go to definition  FILE=… LINE=N COL=N\n"
	@printf "  $(CYAN)make lsp-refs$(RESET)       Find references   FILE=… LINE=N COL=N\n"
	@printf "  $(CYAN)make lsp-hover$(RESET)      Hover info        FILE=… LINE=N COL=N\n"
	@printf "  $(CYAN)make clean$(RESET)          Remove all build artefacts\n"
	@printf "  $(CYAN)make check$(RESET)          Verify toolchain prerequisites\n"
	@printf "\n  $(YELLOW)DEVELOPER_DIR$(RESET) = $(DEVELOPER_DIR)\n"
	@printf "  $(YELLOW)COWORK_SESSIONS$(RESET) = $(COWORK_SESSIONS)\n\n"

# ── Prerequisite checks ───────────────────────────────────────────────────────

check:
	$(call log,Checking prerequisites…)
	@command -v $(SWIFT) >/dev/null 2>&1 \
	  && printf "  $(GREEN)✓$(RESET) swift  $$(DEVELOPER_DIR=$(DEVELOPER_DIR) $(SWIFT) --version 2>&1 | head -1)\n" \
	  || (printf "$(RED)✗  swift not found — install Xcode or Command Line Tools$(RESET)\n" && exit 1)
	@command -v cargo >/dev/null 2>&1 \
	  && printf "  $(GREEN)✓$(RESET) cargo  $$(cargo --version)\n" \
	  || printf "$(YELLOW)⚠  cargo not found — Rust bridge will not build$(RESET)\n"
	@test -f "$(COWORK_SESSIONS)/session-index.json" \
	  && printf "  $(GREEN)✓$(RESET) sessions index: $(COWORK_SESSIONS)/session-index.json\n" \
	  || printf "$(YELLOW)⚠  session-index.json not found at $(COWORK_SESSIONS)$(RESET)\n"
	@test -f "$(SCREENSHOT_TOOL)" \
	  && printf "  $(GREEN)✓$(RESET) screenshot tool: $(SCREENSHOT_TOOL)\n" \
	  || printf "$(YELLOW)⚠  screenshot.py not found at $(SCREENSHOT_TOOL)$(RESET)\n"
	@printf "  $(GREEN)✓$(RESET) DEVELOPER_DIR = $(DEVELOPER_DIR)\n"

# ── Build ─────────────────────────────────────────────────────────────────────

build: build-swift build-rust

build-swift: _guard-swift
	$(call log,Building Swift package ($(SWIFT_CONFIG))…)
	DEVELOPER_DIR="$(DEVELOPER_DIR)" \
	  $(SWIFT) build \
	    $(if $(filter release,$(SWIFT_CONFIG)),-c release,) \
	    2>&1

build-rust:
	$(call log,Building Rust BLE bridge…)
	@command -v cargo >/dev/null 2>&1 \
	  || (printf "$(YELLOW)⚠  cargo not found — skipping Rust build$(RESET)\n" && exit 0)
	@command -v cargo >/dev/null 2>&1 \
	  && (cd "$(APP_DIR)" && RUSTC_WRAPPER="" cargo build 2>&1) || true

# ── Test ──────────────────────────────────────────────────────────────────────

test: test-swift

test-swift: _guard-swift
	$(call log,Running Swift tests…)
	DEVELOPER_DIR="$(DEVELOPER_DIR)" \
	COWORK_SESSIONS_DIR="$(COWORK_SESSIONS)" \
	  $(SWIFT) test 2>&1

test-verbose: _guard-swift
	$(call log,Running Swift tests (verbose)…)
	DEVELOPER_DIR="$(DEVELOPER_DIR)" \
	COWORK_SESSIONS_DIR="$(COWORK_SESSIONS)" \
	  $(SWIFT) test --verbose 2>&1

# ── Run ───────────────────────────────────────────────────────────────────────

run: build-swift
	$(call log,Launching BuddyApp…)
	DEVELOPER_DIR="$(DEVELOPER_DIR)" \
	CLAUDE_CODE_OAUTH_TOKEN="$(OAUTH_TOKEN)" \
	COWORK_SESSIONS_DIR="$(COWORK_SESSIONS)" \
	BUDDY_CHARACTER_DIR="$(BUDDY_CHARACTER)" \
	  $(SWIFT) run BuddyApp 2>&1

run-cli: build-swift
	$(call log,Running buddy CLI…)
	@test -n "$(ANTHROPIC_API_KEY)$(OAUTH_TOKEN)" \
	  || printf "$(YELLOW)⚠  No API key found — running with --no-claude$(RESET)\n"
	DEVELOPER_DIR="$(DEVELOPER_DIR)" \
	ANTHROPIC_API_KEY="$(ANTHROPIC_API_KEY)" \
	CLAUDE_CODE_OAUTH_TOKEN="$(OAUTH_TOKEN)" \
	COWORK_SESSIONS_DIR="$(COWORK_SESSIONS)" \
	  $(SWIFT) run buddy 2>&1

run-watch: build-swift
	$(call log,Running buddy CLI in watch mode (interval=$(WATCH_INTERVAL)s)…)
	DEVELOPER_DIR="$(DEVELOPER_DIR)" \
	ANTHROPIC_API_KEY="$(ANTHROPIC_API_KEY)" \
	CLAUDE_CODE_OAUTH_TOKEN="$(OAUTH_TOKEN)" \
	COWORK_SESSIONS_DIR="$(COWORK_SESSIONS)" \
	  $(SWIFT) run buddy --watch --interval $(WATCH_INTERVAL) 2>&1

run-bridge: build-rust
	$(call log,Launching Rust BLE bridge…)
	cd "$(APP_DIR)" && \
	COWORK_SESSIONS_DIR="$(COWORK_SESSIONS)" \
	RUST_LOG=info \
	  cargo run 2>&1

# ── Screenshot ────────────────────────────────────────────────────────────────

screenshot:
	$(call log,Capturing BuddyApp window…)
	@test -f "$(SCREENSHOT_TOOL)" \
	  || (printf "$(RED)✗  screenshot.py not found at $(SCREENSHOT_TOOL)$(RESET)\n" && exit 1)
	python3 "$(SCREENSHOT_TOOL)" \
	  --window BuddyApp \
	  --out /tmp/buddy_shot.jpg \
	  --max-px 800 \
	  --quality 80
	@open /tmp/buddy_shot.jpg 2>/dev/null || true
	@printf "  Saved: /tmp/buddy_shot.jpg\n"

# ── Toolchain ─────────────────────────────────────────────────────────────────
# Installs Rust+rust-analyzer, Swift+sourcekit-lsp, wrangler, and patches
# ~/.claude/settings.json to enable Claude Code LSP plugins (rust-analyzer-lsp
# and swift-lsp from claude-plugins-official).  Idempotent; safe to re-run.
# Selects the OS-appropriate script automatically.

TOOLCHAIN_SCRIPTS := $(REPO_ROOT)/scripts/toolchain
LSP_SCRIPTS       := $(REPO_ROOT)/scripts/lsp
LSP_PYTHON        := $(LSP_SCRIPTS)/.venv/bin/python3

toolchain:
	$(call log,Installing toolchain…)
	@case "$$(uname -s)" in \
	  Darwin) bash "$(TOOLCHAIN_SCRIPTS)/setup-mac.sh" ;; \
	  Linux)  bash "$(TOOLCHAIN_SCRIPTS)/setup-linux.sh" ;; \
	  *)      printf "$(RED)✗  Unsupported OS: $$(uname -s)$(RESET)\n"; exit 1 ;; \
	esac
	$(call log,Setting up LSP query venv…)
	@bash "$(LSP_SCRIPTS)/setup.sh"

# ── LSP code-intelligence (multilspy + sourcekit-lsp) ────────────────────────
# Uses system LSP servers — never downloads its own binaries.
# Queries: symbols (all languages), def / refs / hover (Rust + TypeScript).
#
# Examples:
#   make lsp-symbols FILE=Sources/BuddyCore/BuddyState.swift
#   make lsp-symbols FILE=../../crates/schema/src/lib.rs
#   make lsp-def     FILE=../../crates/schema/src/lib.rs LINE=42 COL=10
#   make lsp-refs    FILE=src/protocol.rs LINE=12 COL=6
#   make lsp-hover   FILE=workers/web/src/index.ts LINE=55 COL=15

FILE ?=
LINE ?= 0
COL  ?= 0

_lsp-guard:
	@test -f "$(LSP_PYTHON)" || \
	  (printf "$(RED)✗  LSP venv not found — run: make lsp-setup$(RESET)\n" && exit 1)
	@test -n "$(FILE)" || \
	  (printf "$(RED)✗  FILE not set — e.g.: make lsp-symbols FILE=src/protocol.rs$(RESET)\n" && exit 1)

lsp-setup:
	$(call log,Setting up LSP query venv (multilspy)…)
	@bash "$(LSP_SCRIPTS)/setup.sh"

lsp-symbols: _lsp-guard
	$(call log,LSP symbols: $(FILE))
	@"$(LSP_PYTHON)" "$(LSP_SCRIPTS)/query.py" symbols "$(FILE)"

lsp-def: _lsp-guard
	$(call log,LSP definition: $(FILE):$(LINE):$(COL))
	@"$(LSP_PYTHON)" "$(LSP_SCRIPTS)/query.py" def "$(FILE)" $(LINE) $(COL)

lsp-refs: _lsp-guard
	$(call log,LSP references: $(FILE):$(LINE):$(COL))
	@"$(LSP_PYTHON)" "$(LSP_SCRIPTS)/query.py" refs "$(FILE)" $(LINE) $(COL)

lsp-hover: _lsp-guard
	$(call log,LSP hover: $(FILE):$(LINE):$(COL))
	@"$(LSP_PYTHON)" "$(LSP_SCRIPTS)/query.py" hover "$(FILE)" $(LINE) $(COL)

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	$(call log,Cleaning build artefacts…)
	rm -rf "$(BUILD_DIR)"
	@command -v cargo >/dev/null 2>&1 \
	  && (cd "$(APP_DIR)" && cargo clean) || true
	@printf "  $(GREEN)✓$(RESET) clean\n"

# ── Internal guards ───────────────────────────────────────────────────────────

_guard-swift:
	@command -v $(SWIFT) >/dev/null 2>&1 \
	  || (printf "$(RED)✗  swift not found — install Xcode or Command Line Tools$(RESET)\n" && exit 1)
