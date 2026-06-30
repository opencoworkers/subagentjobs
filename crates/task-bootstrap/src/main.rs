//! Reads sessions/tasks.yaml and upserts pending tasks into fact_tasks (Postgres).
//!
//! Idempotent: ON CONFLICT (id) DO NOTHING — safe to run on every session start.
//! Task IDs are derived from the human-readable `id` + `session` via UUID v5 so
//! they are stable across runs without storing state.

use anyhow::{Context, Result};
use chrono::Utc;
use clap::Parser;
use serde::Deserialize;
use sqlx::PgPool;
use uuid::Uuid;

fn stable_id(label: &str, session: &str) -> Uuid {
    // UUID v5 / DNS namespace — stable IDs across sessions.
    let ns = Uuid::parse_str("6ba7b810-9dad-11d1-80b4-00c04fd430c8").unwrap();
    Uuid::new_v5(&ns, format!("{session}:{label}").as_bytes())
}

// ── YAML input types ──────────────────────────────────────────────────────────
// Separate from schema::Task to allow a friendlier YAML syntax.

#[derive(Debug, Deserialize)]
struct TaskFile {
    session: String,
    #[serde(default = "default_version")]
    schema_version: String,
    tasks: Vec<YamlTask>,
}

fn default_version() -> String { "0.1.0".into() }

#[derive(Debug, Deserialize)]
struct YamlTask {
    /// Human-readable slug like "task-migration-007"; drives the stable UUID.
    #[serde(default)]
    id: Option<String>,
    content: String,
    #[serde(default)]
    priority: YamlPriority,
    #[serde(default)]
    status: YamlStatus,
    #[serde(default)]
    kind: YamlKind,
}

#[derive(Debug, Deserialize, Default, PartialEq)]
#[serde(rename_all = "snake_case")]
enum YamlStatus {
    #[default]
    Pending,
    InProgress,
    Completed,
    Cancelled,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
enum YamlPriority {
    High,
    #[default]
    Medium,
    Low,
}

impl YamlPriority {
    fn as_str(&self) -> &'static str {
        match self {
            Self::High   => "high",
            Self::Medium => "medium",
            Self::Low    => "low",
        }
    }
}

/// External-tagged kind for human-friendly YAML. Unit variants are plain strings.
///
/// ```yaml
/// kind: todo
/// kind:
///   migration:
///     file: path/to/file.sql
/// kind:
///   deploy:
///     worker: subagentjobs-web
/// kind:
///   shell_command:
///     command: make crawl-docs
/// ```
#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
enum YamlKind {
    #[default]
    Todo,
    Migration {
        file: String,
        #[serde(default)]
        database: Option<String>,
    },
    Deploy {
        worker: String,
        #[serde(default)]
        message: Option<String>,
    },
    GitPush {
        #[serde(default)]
        message: Option<String>,
        #[serde(default)]
        branch: Option<String>,
    },
    CrawlBoard {
        board: String,
        platform: String,
    },
    ShellCommand {
        command: String,
        #[serde(default)]
        working_dir: Option<String>,
    },
}

impl YamlKind {
    fn to_json(&self) -> serde_json::Value {
        match self {
            Self::Todo => serde_json::json!({"kind": "todo"}),
            Self::Migration { file, database } => serde_json::json!({
                "kind": "migration", "file": file, "database": database
            }),
            Self::Deploy { worker, message } => serde_json::json!({
                "kind": "deploy", "worker": worker, "message": message
            }),
            Self::GitPush { message, branch } => serde_json::json!({
                "kind": "git_push", "message": message, "branch": branch
            }),
            Self::CrawlBoard { board, platform } => serde_json::json!({
                "kind": "crawl_board", "board": board, "platform": platform
            }),
            Self::ShellCommand { command, working_dir } => serde_json::json!({
                "kind": "shell_command", "command": command, "working_dir": working_dir
            }),
        }
    }
}

// ── CLI ───────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(about = "Bootstrap pending tasks from YAML into Postgres fact_tasks")]
struct Cli {
    #[arg(long, env = "TASKS_FILE", default_value = "sessions/tasks.yaml")]
    tasks: String,
    #[arg(long, env = "DATABASE_URL")]
    database_url: String,
}

// ── Main ──────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let raw = std::fs::read_to_string(&cli.tasks)
        .with_context(|| format!("reading {}", cli.tasks))?;
    let file: TaskFile = serde_yaml::from_str(&raw)
        .with_context(|| format!("parsing {}", cli.tasks))?;

    let pool = PgPool::connect(&cli.database_url)
        .await
        .context("connecting to Postgres")?;

    let pending: Vec<&YamlTask> = file.tasks.iter()
        .filter(|t| t.status == YamlStatus::Pending)
        .collect();

    println!(
        "▶ task-bootstrap: session={} pending={}/{}",
        file.session,
        pending.len(),
        file.tasks.len()
    );

    for task in &pending {
        let label = task.id.as_deref().unwrap_or(&task.content);
        let id = stable_id(label, &file.session);
        let kind_json = task.kind.to_json();
        let now = Utc::now();

        let rows = sqlx::query(
            r#"
            INSERT INTO fact_tasks (id, session_name, schema_version, content, status, priority, kind, created_at)
            VALUES ($1, $2, $3, $4, 'pending', $5, $6, $7)
            ON CONFLICT (id) DO NOTHING
            "#,
        )
        .bind(id)
        .bind(&file.session)
        .bind(&file.schema_version)
        .bind(&task.content)
        .bind(task.priority.as_str())
        .bind(kind_json)
        .bind(now)
        .execute(&pool)
        .await
        .with_context(|| format!("upserting task {:?}", label))?;

        if rows.rows_affected() > 0 {
            sqlx::query(
                r#"
                INSERT INTO event_task_states (task_id, from_state, to_state, session_name, reason)
                VALUES ($1, NULL, 'pending', $2, 'bootstrapped from tasks.yaml')
                "#,
            )
            .bind(id)
            .bind(&file.session)
            .execute(&pool)
            .await?;

            println!("  ✓ inserted [{}] {}", label, task.content);
        } else {
            println!("  · skipped (exists) [{}]", label);
        }
    }

    println!("✓ task-bootstrap complete");
    Ok(())
}
