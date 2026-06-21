//! engineering-coworker — MCP server for the macos__desktop_cowork__engineering_coworker profile.
//!
//! # Purpose
//! Bridges Claude (running in Anthropic cloud) to the developer's local macOS environment
//! so Claude can actually EXECUTE cargo, wrangler, and git operations — not just write code
//! for the human to copy-paste.
//!
//! # Naming ontology
//!   {device_surface}__{client_surface}__{coworker_enum}
//!   macos__desktop_cowork__engineering_coworker
//!     ↑ macOS dev machine
//!                 ↑ Claude Desktop in Cowork mode
//!                           ↑ this binary = the engineering coworker persona
//!
//! # Transport
//! stdio (Docker Desktop MCP gateway or direct claude_desktop_config.json entry)
//!
//! # Tools exposed
//!   cargo_check   — RUSTC_WRAPPER='' cargo check --workspace
//!   cargo_test    — cargo test --workspace --no-fail-fast (with optional filter)
//!   wrangler_deploy — cd workers/{target} && wrangler deploy
//!   d1_query      — wrangler d1 execute subagentjobs-dwh --remote --command <sql>
//!   git_status    — git status + last 10 commits
//!   git_commit_push — git add -A && git commit -m <msg> && git push
//!
//! # Usage
//!   cargo run -p engineering-coworker -- --repo-dir /path/to/subagentjobs

use anyhow::Result;
use clap::Parser;
use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    tool, tool_handler, tool_router,
};
use schemars::JsonSchema;
use serde::Deserialize;
use std::process::Stdio;
use tokio::process::Command;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

// ── CLI ────────────────────────────────────────────────────────────────────────

#[derive(Parser, Debug, Clone)]
#[command(name = "engineering-coworker")]
struct Cli {
    /// Absolute path to the subagentjobs repo root.
    /// Defaults to the directory containing this binary's workspace.
    #[arg(env = "REPO_DIR", long, default_value = "/Users/alex-opensubagents/opencoworkers/subagentjobs")]
    repo_dir: String,

    /// Cloudflare account ID (for wrangler commands).
    #[arg(env = "CLOUDFLARE_ACCOUNT_ID", long, default_value = "e6294e3ea89f8207af387d459824aaae")]
    account_id: String,
}

// ── Tool inputs ────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, JsonSchema)]
struct CargoCheckInput {
    /// Optional: single package name to check (e.g. "schema"). Omit for --workspace.
    package: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct CargoTestInput {
    /// Optional test filter string (passed as the positional argument to cargo test).
    filter: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct WranglerDeployInput {
    /// Which worker directory to deploy from: "web" or "cron".
    target: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct D1QueryInput {
    /// SQL statement to execute against subagentjobs-dwh (remote, read-write).
    /// Use SELECT queries for inspection; INSERT/UPDATE/DELETE for mutations.
    /// Avoid DROP or ALTER without explicit human confirmation.
    sql: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct GitCommitPushInput {
    /// Commit message. Should follow conventional commits: feat/fix/chore/docs(scope): ...
    message: String,
    /// If true, stage all changes (git add -A) before committing. Default: true.
    add_all: Option<bool>,
}

// ── Server ─────────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct EngineeringCoworker {
    repo_dir: String,
    account_id: String,
    tool_router: ToolRouter<Self>,
}

impl EngineeringCoworker {
    fn new(repo_dir: String, account_id: String) -> Self {
        Self {
            repo_dir,
            account_id,
            tool_router: Self::tool_router(),
        }
    }

    /// Run a shell command in the repo directory and return stdout+stderr.
    async fn exec(&self, program: &str, args: &[&str], env: &[(&str, &str)]) -> String {
        let mut cmd = Command::new(program);
        cmd.args(args)
            .current_dir(&self.repo_dir)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env_remove("RUSTC_WRAPPER"); // never use sccache in MCP context

        for (k, v) in env {
            cmd.env(k, v);
        }

        match cmd.output().await {
            Ok(out) => {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let stderr = String::from_utf8_lossy(&out.stderr);
                let status = out.status;
                format!(
                    "exit={}\n\nstdout:\n{}\nstderr:\n{}",
                    status.code().unwrap_or(-1),
                    stdout.trim(),
                    stderr.trim()
                )
            }
            Err(e) => format!("error: failed to spawn {program}: {e}"),
        }
    }
}

// ── Tool implementations ───────────────────────────────────────────────────────

#[tool_router(router = tool_router)]
impl EngineeringCoworker {
    /// Run `cargo check` across the workspace (or a single package).
    /// Use this before any deployment to catch compile errors.
    #[tool(description = "Run `cargo check` in the repo. Optionally scope to one package with `package`. Always run this after editing Rust code.")]
    async fn cargo_check(&self, input: Parameters<CargoCheckInput>) -> String {
        let args: Vec<&str> = if let Some(ref pkg) = input.0.package {
            vec!["check", "-p", pkg.as_str()]
        } else {
            vec!["check", "--workspace"]
        };
        self.exec("cargo", &args, &[]).await
    }

    /// Run `cargo test` across the workspace with an optional filter.
    #[tool(description = "Run `cargo test --workspace`. Pass `filter` to run only matching tests.")]
    async fn cargo_test(&self, input: Parameters<CargoTestInput>) -> String {
        let mut args = vec!["test", "--workspace", "--no-fail-fast"];
        let filter_owned;
        if let Some(ref f) = input.0.filter {
            filter_owned = f.clone();
            args.push(filter_owned.as_str());
        }
        self.exec("cargo", &args, &[]).await
    }

    /// Deploy a Cloudflare Worker via `wrangler deploy`.
    /// `target` must be "web" (subagentjobs.com) or "cron" (crawl scheduler).
    #[tool(description = "Deploy a CF Worker. `target` = \"web\" or \"cron\". Runs `wrangler deploy` in workers/{target}/.")]
    async fn wrangler_deploy(&self, input: Parameters<WranglerDeployInput>) -> String {
        let worker_dir = format!("{}/workers/{}", self.repo_dir, input.0.target);
        let mut cmd = tokio::process::Command::new("wrangler");
        cmd.arg("deploy")
            .current_dir(&worker_dir)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        match cmd.output().await {
            Ok(out) => format!(
                "exit={}\n\nstdout:\n{}\nstderr:\n{}",
                out.status.code().unwrap_or(-1),
                String::from_utf8_lossy(&out.stdout).trim(),
                String::from_utf8_lossy(&out.stderr).trim()
            ),
            Err(e) => format!("error: {e}"),
        }
    }

    /// Execute a SQL statement against the remote D1 database (subagentjobs-dwh).
    /// SELECT for inspection; INSERT/UPDATE/DELETE for mutations.
    /// Never runs DROP or ALTER — reject those automatically.
    #[tool(description = "Run SQL against D1 (remote, subagentjobs-dwh). SELECT queries return data; INSERT/UPDATE for mutations. No DDL.")]
    async fn d1_query(&self, input: Parameters<D1QueryInput>) -> String {
        let sql = input.0.sql.trim().to_lowercase();
        if sql.starts_with("drop") || sql.starts_with("alter") {
            return "error: DDL (DROP/ALTER) rejected — confirm with the user and use wrangler CLI directly".into();
        }
        self.exec(
            "wrangler",
            &[
                "d1", "execute", "subagentjobs-dwh",
                "--remote",
                "--command", input.0.sql.as_str(),
                "--json",
            ],
            &[("CLOUDFLARE_ACCOUNT_ID", self.account_id.as_str())],
        ).await
    }

    /// Show git status and the last 10 commits.
    #[tool(description = "Show `git status` + last 10 commits. Use to understand current dirty state before committing.")]
    async fn git_status(&self, _input: Parameters<()>) -> String {
        let status = self.exec("git", &["status", "--short"], &[]).await;
        let log = self.exec("git", &["log", "--oneline", "-10"], &[]).await;
        format!("=== git status ===\n{status}\n\n=== last 10 commits ===\n{log}")
    }

    /// Stage all changes, commit, and push to origin/main.
    #[tool(description = "Stage all changes (`git add -A`), commit with message, and `git push`. Use conventional commits: feat/fix/chore(scope): description.")]
    async fn git_commit_push(&self, input: Parameters<GitCommitPushInput>) -> String {
        let add_all = input.0.add_all.unwrap_or(true);
        if add_all {
            let add = self.exec("git", &["add", "-A"], &[]).await;
            if add.starts_with("error") {
                return add;
            }
        }
        let commit = self.exec(
            "git",
            &["commit", "-m", input.0.message.as_str()],
            &[],
        ).await;
        if commit.contains("nothing to commit") || commit.starts_with("error") {
            return commit;
        }
        let push = self.exec("git", &["push"], &[]).await;
        format!("{commit}\n\n{push}")
    }
}

// ── rmcp glue ──────────────────────────────────────────────────────────────────

#[tool_handler(router = self.tool_router,
               name    = "engineering-coworker",
               version = "0.1.0",
               instructions = "Execute cargo/wrangler/git/D1 operations on the developer's macOS \
                               machine on behalf of Claude (cloud). \
                               Profile: macos__desktop_cowork__engineering_coworker. \
                               Repo: subagentjobs — Rust workspace + Cloudflare Workers.")]
impl ServerHandler for EngineeringCoworker {}

// ── main ───────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::registry()
        .with(fmt::layer().with_writer(std::io::stderr))
        .with(EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();

    tracing::info!(
        repo_dir = %cli.repo_dir,
        profile = "macos__desktop_cowork__engineering_coworker",
        "engineering-coworker MCP server starting"
    );

    let server = EngineeringCoworker::new(cli.repo_dir, cli.account_id);

    let service = server.serve(rmcp::transport::io::stdio()).await
        .map_err(|e| anyhow::anyhow!("server error: {e}"))?;

    service.waiting().await?;
    Ok(())
}
