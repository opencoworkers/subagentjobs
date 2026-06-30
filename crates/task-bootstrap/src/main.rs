//! Reads sessions/tasks.yaml and upserts pending tasks into fact_tasks (Postgres).
//!
//! Idempotent: ON CONFLICT (id) DO NOTHING — safe to run on every session start.
//! Task IDs are derived from the human-readable `id` + `session` via UUID v5 so
//! they are stable across runs without storing state.

use std::path::PathBuf;

use anyhow::{Context, Result};
use chrono::Utc;
use clap::Parser;
use schema::{TaskKind, TaskPriority, TaskStatus};
use serde::Deserialize;
use sqlx::PgPool;
use uuid::{uuid, Uuid};

const NAMESPACE: Uuid = uuid!("6ba7b810-9dad-11d1-80b4-00c04fd430c8");

fn stable_id(label: &str, session: &str) -> Uuid {
    Uuid::new_v5(&NAMESPACE, format!("{session}:{label}").as_bytes())
}

// ── YAML input types ──────────────────────────────────────────────────────────

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
    id: Option<String>,
    content: String,
    #[serde(default)]
    priority: TaskPriority,
    #[serde(default)]
    status: TaskStatus,
    #[serde(default)]
    kind: YamlKind,
}

/// External-tagged kind for human-friendly YAML. serde_yaml renders enum variants
/// as YAML tags, so unit variants are bare strings (`kind: todo`) and struct
/// variants use a `!` tag (`kind: !migration { file: ... }`).
#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum YamlKind {
    #[default]
    Todo,
    Migration {
        file: String,
        database: Option<String>,
    },
    Deploy {
        worker: String,
        message: Option<String>,
    },
    GitPush {
        message: Option<String>,
        branch: Option<String>,
    },
    CrawlBoard {
        board: String,
        platform: String,
    },
    ShellCommand {
        command: String,
        working_dir: Option<String>,
    },
}

impl From<&YamlKind> for TaskKind {
    fn from(y: &YamlKind) -> Self {
        match y {
            YamlKind::Todo => TaskKind::Todo,
            YamlKind::Migration { file, database } => TaskKind::Migration {
                file: file.clone(),
                database: database.clone(),
            },
            YamlKind::Deploy { worker, message } => TaskKind::Deploy {
                worker: worker.clone(),
                message: message.clone(),
            },
            YamlKind::GitPush { message, branch } => TaskKind::GitPush {
                message: message.clone(),
                branch: branch.clone(),
            },
            YamlKind::CrawlBoard { board, platform } => TaskKind::CrawlBoard {
                board: board.clone(),
                platform: platform.clone(),
            },
            YamlKind::ShellCommand { command, working_dir } => TaskKind::ShellCommand {
                command: command.clone(),
                working_dir: working_dir.clone(),
            },
        }
    }
}

// ── CLI ───────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(about = "Bootstrap pending tasks from YAML into Postgres fact_tasks")]
struct Cli {
    #[arg(long, env = "TASKS_FILE", default_value = "sessions/tasks.yaml")]
    tasks: PathBuf,
    #[arg(long, env = "DATABASE_URL")]
    database_url: String,
}

// ── Main ──────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let raw = std::fs::read_to_string(&cli.tasks)
        .with_context(|| format!("reading {}", cli.tasks.display()))?;
    let file: TaskFile = serde_yaml::from_str(&raw)
        .with_context(|| format!("parsing {}", cli.tasks.display()))?;

    let pool = PgPool::connect(&cli.database_url)
        .await
        .context("connecting to Postgres")?;

    let pending: Vec<&YamlTask> = file.tasks.iter()
        .filter(|t| t.status == TaskStatus::Pending)
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
        let kind_json = serde_json::to_value(TaskKind::from(&task.kind))?;
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
        .bind(task.priority.to_string())
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
