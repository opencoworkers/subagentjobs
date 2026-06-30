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
        deploy-bracket migrate-bracket bracket-secret tag-resources bracket-update \
        buddy buddy-build \
        atomic toolchain \
        crawl-docs index-docs redis-start redis-stop \
        chrome-debug \
        db-start db-stop migrate env \
        schema load-tasks

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
	@printf "\n  $(BOLD)wc2026 bracket (subagentdata.com)$(RESET)\n"
	@printf "  $(CYAN)make deploy-bracket$(RESET)   wrangler deploy workers/wc2026-bracket\n"
	@printf "  $(CYAN)make migrate-bracket$(RESET)  apply dim_team/fact_match to D1 subagentjobs-dwh\n"
	@printf "  $(CYAN)make bracket-secret$(RESET)   provision Secrets Store WC2026_UPDATE_SECRET\n"
	@printf "  $(CYAN)make tag-resources$(RESET)    tag CF Worker + D1 + secret with the repo tag\n"
	@printf "  $(CYAN)make bracket-update$(RESET)   update live scores via claude -p subagent worker\n"
	@printf "  $(CYAN)make buddy$(RESET)        build + launch BuddyApp (macOS)\n"
	@printf "  $(CYAN)make atomic$(RESET)       scripts/commit-tested.sh (test-gated commits)\n"
	@printf "  $(CYAN)make toolchain$(RESET)    install full toolchain (mac or linux)\n"
	@printf "\n  $(BOLD)Docs crawler$(RESET)\n"
	@printf "  $(CYAN)make crawl-docs$(RESET)   cargo run -p docs-crawler (needs DATABASE_URL + Redis)\n"
	@printf "  $(CYAN)make index-docs$(RESET)   cargo run -p indexer -- --path docs/ (FTS index)\n"
	@printf "  $(CYAN)make redis-start$(RESET)  start local Redis via Docker (port 6379)\n"
	@printf "  $(CYAN)make redis-stop$(RESET)   stop local Redis container\n"
	@printf "  $(CYAN)make chrome-debug$(RESET)  launch Chrome with --remote-debugging-port=9222\n"
	@printf "\n  $(BOLD)Database + env$(RESET)\n"
	@printf "  $(CYAN)make db-start$(RESET)     start local Postgres 16 via Docker (port 5432)\n"
	@printf "  $(CYAN)make db-stop$(RESET)      stop local Postgres container\n"
	@printf "  $(CYAN)make migrate$(RESET)      apply all Postgres migrations (needs DATABASE_URL)\n"
	@printf "  $(CYAN)make env$(RESET)          source scripts/setup.sh (exports env vars)\n"
	@printf "\n  $(BOLD)Task management$(RESET)\n"
	@printf "  $(CYAN)make schema$(RESET)       regenerate schemas/task-session.schema.json from Rust types\n"
	@printf "  $(CYAN)make load-tasks$(RESET)   upsert sessions/tasks.yaml into Postgres fact_tasks\n"
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

# ── wc2026 bracket worker (subagentdata.com) ─────────────────────────────────
WC2026 := $(REPO)/workers/wc2026-bracket

# Deploy the bracket worker. Requires the Secrets Store secret to exist and its
# store_id pasted into workers/wc2026-bracket/wrangler.toml (see bracket-secret).
deploy-bracket:
	$(call log,Deploying workers/wc2026-bracket…)
	cd "$(WC2026)" && wrangler deploy 2>&1

# Apply the bracket D1 schema (dim_team + fact_match + seed) to subagentjobs-dwh.
migrate-bracket:
	$(call log,Applying wc2026 bracket migration to D1 subagentjobs-dwh…)
	cd "$(WC2026)" && wrangler d1 execute subagentjobs-dwh --remote \
	  --file migrations/0001_bracket.sql 2>&1

# Provision the Cloudflare Secrets Store secret used to authenticate /api/update.
# Creates the store if needed, writes WC2026_UPDATE_SECRET, prints the store_id
# to paste into the worker's wrangler.toml [[secrets_store_secrets]].store_id.
bracket-secret:
	$(call log,Provisioning Secrets Store secret WC2026_UPDATE_SECRET…)
	@cd "$(WC2026)" && wrangler secrets-store store create subagentjobs 2>/dev/null \
	  || printf "$(CYAN)  → store 'subagentjobs' already exists$(RESET)\n"
	@cd "$(WC2026)" && wrangler secrets-store secret create subagentjobs \
	  --name WC2026_UPDATE_SECRET --scopes workers 2>&1 || true
	@printf "$(YELLOW)  → paste the printed store_id into workers/wc2026-bracket/wrangler.toml$(RESET)\n"

# Tag every Cloudflare resource for this deployment (Worker + D1 + secret) with
# the repo tag from cloudflare.toml, so they are discoverable as a group.
tag-resources:
	$(call log,Tagging Cloudflare resources for the wc2026 deployment…)
	@bash "$(REPO)/scripts/cf-tag-resources.sh"

# Update live scores via a claude -p subagent worker. The subagent fetches the
# latest WC2026 Round-of-32 results, diffs them against D1, and POSTs the deltas
# to /api/update — no manual SQL, no redeploy.  (Same pattern as make review/pr.)
bracket-update: _guard-claude
	$(call log,Running bracket-updater subagent (claude -p)…)
	@$(CLAUDE) -p "You are the wc2026 bracket updater. Fetch the latest FIFA World \
	  Cup 2026 Round-of-32 results and fixtures. The live bracket API is at \
	  https://subagentdata.com/api/bracket (current state) and \
	  https://subagentdata.com/api/status (summary). For any match whose score or \
	  status changed, build a JSON body {matches:[{id,status,home_score,away_score,\
	  winner,note}]} using the M01..M16 match ids from /api/bracket, and POST it to \
	  https://subagentdata.com/api/update with header 'Authorization: Bearer '\$$WC2026_UPDATE_SECRET. \
	  Only include changed matches. Print a one-line summary of what you updated."

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

# Crawl Claude documentation sources → docs/{host}/…
# With DATABASE_URL: full CDC mode (Redis + Postgres dedup).
# Without DATABASE_URL: files-only mode (just writes .md files).
crawl-docs:
	$(call log,Running docs-crawler…)
	@if [ -n "$$DATABASE_URL" ]; then \
	  RUSTC_WRAPPER="" cargo run -p docs-crawler; \
	else \
	  RUSTC_WRAPPER="" cargo run -p docs-crawler -- --files-only; \
	fi

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

# Launch Chrome with remote-debugging enabled so chrome-devtools-mcp can connect.
# Uses an isolated profile at /tmp/chrome-devtools-mcp-profile.
chrome-debug:
	$(call log,Opening Chrome with remote debugging on :9222…)
	@open -a "Google Chrome" --args \
	  --remote-debugging-port=9222 \
	  --user-data-dir=/tmp/chrome-devtools-mcp-profile 2>/dev/null \
	  || printf "$(YELLOW)⚠  Chrome not found — install from https://google.com/chrome$(RESET)\n"
	@printf "$(CYAN)  → Chrome DevTools MCP will connect to http://127.0.0.1:9222$(RESET)\n"

# ── Database ──────────────────────────────────────────────────────────────────

# Start local Postgres 16 via Docker.  DATABASE_URL = postgres://subagentjobs:subagentjobs@localhost/subagentjobs
db-start:
	$(call log,Starting Postgres 16 on :5432…)
	@docker run -d --name subagentjobs-postgres -p 5432:5432 \
	  -e POSTGRES_DB=subagentjobs \
	  -e POSTGRES_USER=subagentjobs \
	  -e POSTGRES_PASSWORD=subagentjobs \
	  postgres:16-alpine \
	  || docker start subagentjobs-postgres
	@printf "$(CYAN)  → DATABASE_URL=postgresql://subagentjobs:subagentjobs@localhost/subagentjobs$(RESET)\n"

db-stop:
	$(call log,Stopping Postgres…)
	@docker stop subagentjobs-postgres && docker rm subagentjobs-postgres

# Apply every Postgres migration in order.  Requires DATABASE_URL.
migrate:
	$(call log,Applying Postgres migrations…)
	@[ -n "$$DATABASE_URL" ] || (printf "$(YELLOW)⚠  DATABASE_URL not set$(RESET)\n" && exit 1)
	@for f in crates/durable-store/migrations/postgres/*.sql; do \
	  printf "$(CYAN)  → $$f$(RESET)\n"; \
	  psql "$$DATABASE_URL" -f "$$f" 2>/dev/null || true; \
	done
	$(call log,Migrations done)

# Export environment variables from scripts/setup.sh into the current shell.
# Usage:  eval "$(make env)"  or  source <(make env)
env:
	@bash "$(REPO)/scripts/setup.sh" 2>/dev/null | grep -E "^export " || true

# ── Task management ───────────────────────────────────────────────────────────

# Regenerate schemas/task-session.schema.json from Rust schemars types.
# Run this after changing crates/schema/src/task.rs struct layouts.
schema:
	$(call log,Generating schemas/task-session.schema.json…)
	RUSTC_WRAPPER="" cargo run -p schema-export > "$(REPO)/schemas/task-session.schema.json"
	$(call log,Schema written to schemas/task-session.schema.json)

# Upsert pending tasks from sessions/tasks.yaml into Postgres fact_tasks.
# Idempotent — safe to run repeatedly. Requires DATABASE_URL.
load-tasks:
	$(call log,Bootstrapping tasks from sessions/tasks.yaml…)
	@[ -n "$$DATABASE_URL" ] || (printf "$(YELLOW)⚠  DATABASE_URL not set$(RESET)\n" && exit 1)
	RUSTC_WRAPPER="" cargo run -p task-bootstrap -- \
	  --tasks "$(REPO)/sessions/tasks.yaml" \
	  --database-url "$$DATABASE_URL"

