# =============================================================================
# subagentjobs — root Makefile
# =============================================================================
#
# Quality pipeline (runs in order):
#   make qa           → test → simplify → review → commit
#
# Individual plugin targets:
#   make simplify     → code-simplifier agent  (cleans up recent changes)
#   make review       → /code-review           (4-agent PR review, ≥80 confidence)
#   make commit       → /commit                (stage + commit with generated message)
#   make pr           → /commit-push-pr        (commit + push + open PR)
#   make clean-br     → /clean_gone            (prune local branches deleted remotely)
#   make setup        → claude-code-setup      (scan codebase, recommend automations)
#
# Build / test:
#   make check        → cargo check --workspace
#   make test         → cargo test + swift test
#   make deploy-web   → wrangler deploy workers/web
#   make deploy-cron  → wrangler deploy workers/cron
#   make buddy        → build + run BuddyApp (macOS only)
#
# Commit helpers:
#   make atomic       → bash scripts/commit-tested.sh (tests before each commit)
#
# =============================================================================

CLAUDE        := claude
REPO          := $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
BUDDY         := $(REPO)/apps/coworkers-desktop-buddy
XCODE         ?= /Applications/Xcode-beta.app/Contents/Developer
DEVELOPER_DIR ?= $(XCODE)

# ── Colours ──────────────────────────────────────────────────────────────────
BOLD  := \033[1m
GREEN := \033[32m
CYAN  := \033[36m
YELLOW:= \033[33m
RESET := \033[0m

define log
	@printf "$(BOLD)$(GREEN)▶ $(1)$(RESET)\n"
endef

.PHONY: all help \
        qa simplify review commit pr clean-br setup \
        check test test-rust test-swift \
        deploy-web deploy-cron \
        buddy buddy-build \
        atomic toolchain \
        crawl-docs index-docs redis-start redis-stop

# ── Default ───────────────────────────────────────────────────────────────────

all: help

help:
	@printf "\n$(BOLD)subagentjobs$(RESET)\n\n"
	@printf "  $(CYAN)make qa$(RESET)           Full quality pipeline: test → simplify → review → commit\n"
	@printf "\n  $(BOLD)Claude plugins$(RESET)\n"
	@printf "  $(CYAN)make simplify$(RESET)     code-simplifier agent — clean up recent changes\n"
	@printf "  $(CYAN)make review$(RESET)       /code-review — 4-agent PR review (≥80 confidence)\n"
	@printf "  $(CYAN)make commit$(RESET)       /commit — stage + commit with generated message\n"
	@printf "  $(CYAN)make pr$(RESET)           /commit-push-pr — commit + push + open PR\n"
	@printf "  $(CYAN)make clean-br$(RESET)     /clean_gone — prune stale local branches\n"
	@printf "  $(CYAN)make setup$(RESET)        claude-code-setup — scan + recommend automations\n"
	@printf "\n  $(BOLD)Build / test$(RESET)\n"
	@printf "  $(CYAN)make check$(RESET)        cargo check --workspace\n"
	@printf "  $(CYAN)make test$(RESET)         cargo test + swift test\n"
	@printf "  $(CYAN)make deploy-web$(RESET)   wrangler deploy workers/web\n"
	@printf "  $(CYAN)make deploy-cron$(RESET)  wrangler deploy workers/cron\n"
	@printf "  $(CYAN)make buddy$(RESET)        build + launch BuddyApp (macOS)\n"
	@printf "  $(CYAN)make atomic$(RESET)       scripts/commit-tested.sh (test-gated commits)\n"
	@printf "  $(CYAN)make toolchain$(RESET)    install full toolchain (mac or linux)\n"
	@printf "\n  $(BOLD)Docs crawler$(RESET)\n"
	@printf "  $(CYAN)make crawl-docs$(RESET)   cargo run -p docs-crawler (needs DATABASE_URL + Redis)\n"
	@printf "  $(CYAN)make index-docs$(RESET)   cargo run -p indexer -- --path docs/ (FTS index)\n"
	@printf "  $(CYAN)make redis-start$(RESET)  start local Redis via Docker (port 6379)\n"
	@printf "  $(CYAN)make redis-stop$(RESET)   stop local Redis container\n"
	@printf "\n"

# ── Quality pipeline ──────────────────────────────────────────────────────────
# Runs the full chain: tests must pass, then simplify, then review, then commit.

qa: test simplify review commit
	$(call log,QA pipeline complete)

# ── Claude plugin targets ─────────────────────────────────────────────────────

_guard-claude:
	@command -v $(CLAUDE) >/dev/null 2>&1 \
	  || (printf "$(YELLOW)⚠  'claude' not found — install Claude Code: https://claude.ai/code$(RESET)\n" && exit 1)

# code-simplifier: subagent — refines recently modified code, preserves behaviour.
# Invoked as a subagent via --agent flag. Runs over current working diff.
simplify: _guard-claude
	$(call log,Running code-simplifier agent on recent changes…)
	@$(CLAUDE) --agent code-simplifier \
	  "Simplify recently modified files in this repo. Preserve all functionality. \
	   Follow CLAUDE.md standards. Focus on: $(shell git diff --name-only HEAD 2>/dev/null | head -20 | tr '\n' ' ')"

# code-review: 4 parallel agents audit the current PR for bugs + CLAUDE.md compliance.
# Requires: gh CLI authenticated, current branch has an open PR.
review: _guard-claude
	$(call log,Running /code-review on current PR…)
	@$(CLAUDE) -p "/code-review"

# commit: analyze changes, generate message, stage + commit.
commit: _guard-claude
	$(call log,Running /commit…)
	@$(CLAUDE) -p "/commit"

# commit-push-pr: commit + push branch + open GitHub PR.
# Creates branch automatically if on main.
pr: _guard-claude
	$(call log,Running /commit-push-pr…)
	@$(CLAUDE) -p "/commit-push-pr"

# clean-br: delete local branches already merged/deleted on remote.
clean-br: _guard-claude
	$(call log,Running /clean_gone…)
	@$(CLAUDE) -p "/clean_gone"
	@git fetch --prune

# claude-code-setup: scan codebase and recommend hooks, MCP servers, skills, agents.
setup: _guard-claude
	$(call log,Running claude-code-setup — scanning for automation opportunities…)
	@$(CLAUDE) --agent claude-code-setup \
	  "Analyze this repository and recommend the top 1-2 automations per category \
	   (MCP servers, skills, hooks, subagents, slash commands). Read CLAUDE.md first."

# ── Build / test ──────────────────────────────────────────────────────────────

check:
	$(call log,cargo check --workspace…)
	RUSTC_WRAPPER="" cargo check --workspace 2>&1

test: test-rust test-swift

test-rust:
	$(call log,cargo test --workspace…)
	RUSTC_WRAPPER="" cargo test --workspace 2>&1

test-swift:
	$(call log,swift test (coworkers-desktop-buddy)…)
	@command -v swift >/dev/null 2>&1 \
	  || (printf "$(YELLOW)⚠  swift not found — run: make toolchain$(RESET)\n" && exit 0)
	DEVELOPER_DIR="$(DEVELOPER_DIR)" \
	  swift test --package-path "$(BUDDY)" 2>&1

# ── Deploy ────────────────────────────────────────────────────────────────────

deploy-web:
	$(call log,Deploying workers/web…)
	cd "$(REPO)/workers/web" && wrangler deploy 2>&1

deploy-cron:
	$(call log,Deploying workers/cron…)
	cd "$(REPO)/workers/cron" && wrangler deploy 2>&1

# ── BuddyApp (macOS) ─────────────────────────────────────────────────────────

buddy: buddy-build
	$(call log,Launching BuddyApp…)
	cd "$(BUDDY)" && make run

buddy-build:
	$(call log,Building coworkers-desktop-buddy…)
	cd "$(BUDDY)" && make build

# ── Helpers ───────────────────────────────────────────────────────────────────

# Test-gated atomic commits (runs swift test before each commit).
atomic:
	$(call log,Running test-gated atomic commits…)
	@bash "$(REPO)/scripts/commit-tested.sh"

toolchain:
	$(call log,Installing toolchain…)
	@case "$$(uname -s)" in \
	  Darwin) bash "$(REPO)/scripts/toolchain/setup-mac.sh" ;; \
	  Linux)  bash "$(REPO)/scripts/toolchain/setup-linux.sh" ;; \
	  *)      printf "$(YELLOW)⚠  Unsupported OS$(RESET)\n"; exit 1 ;; \
	esac

# ── Docs crawler ──────────────────────────────────────────────────────────────

# Crawl Claude documentation sources → docs/{host}/…  Requires DATABASE_URL + Redis.
crawl-docs:
	$(call log,Running docs-crawler…)
	RUSTC_WRAPPER="" cargo run -p docs-crawler

# Index downloaded .md files into fact_filesystem + dim_file_ast for MCP search.
index-docs:
	$(call log,Indexing docs/ into Postgres…)
	RUSTC_WRAPPER="" DATABASE_URL="$$DATABASE_URL" cargo run -p indexer -- --path docs

# Start a local Redis instance via Docker (used by docs-crawler + durable-store).
redis-start:
	$(call log,Starting Redis on :6379…)
	@docker run -d --name subagentjobs-redis -p 6379:6379 redis:7-alpine \
	  || docker start subagentjobs-redis

# Stop and remove the local Redis container.
redis-stop:
	$(call log,Stopping Redis…)
	@docker stop subagentjobs-redis && docker rm subagentjobs-redis

