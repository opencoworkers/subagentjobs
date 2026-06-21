//! Task data models — schema-versioned, Claude Code / Cowork-compatible.
//!
//! Every public struct implements [`Versioned`] and carries a `schema_version`
//! field so deserialised records can be migrated forward without losing data.
//!
//! # Semver bump rules (match conventional commits)
//! | Change                        | Bump   | Example           |
//! |-------------------------------|--------|-------------------|
//! | fix a helper, no field change | patch  | 0.1.0 → 0.1.1    |
//! | add an optional field         | minor  | 0.1.0 → 0.2.0    |
//! | rename / remove / retype      | major  | 0.1.0 → 1.0.0    |
//!
//! # Quick start
//! ```rust
//! use schema::task::{Task, TaskKind, TaskPriority, TaskQueue, TaskSession};
//!
//! let mut session = TaskSession::new("deploy-eviction-v2");
//!
//! session.push(Task::new(
//!     "Apply migration 005",
//!     TaskPriority::High,
//!     TaskKind::Migration { file: "005_add_salary.sql".into(), database: None },
//! ));
//! session.push(Task::new(
//!     "Deploy web worker",
//!     TaskPriority::High,
//!     TaskKind::Deploy { worker: "subagentjobs-web".into(), message: None },
//! ));
//! session.push(Task::new(
//!     "Push to GitHub",
//!     TaskPriority::Medium,
//!     TaskKind::GitPush { message: None, branch: None },
//! ));
//!
//! // Plan phase: inspect queue before executing
//! let stats = session.stats();
//! println!("{} tasks pending", stats.pending);
//!
//! // Execute phase: claim → run → complete
//! while let Some(id) = session.queue.claim_next() {
//!     let task = session.queue.get(id).unwrap();
//!     println!("executing [{}] {}", task.kind, task.content);
//!     // ... run the actual work ...
//!     session.queue.complete(id, Some("ok".into()));
//! }
//! ```

use chrono::{DateTime, Utc};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::{collections::VecDeque, fmt, str::FromStr};
use uuid::Uuid;

// ── Semantic versioning ───────────────────────────────────────────────────────

/// Semantic version (major.minor.patch) embedded in every versioned model.
///
/// Serialises as a plain string `"0.1.0"` so diffs are human-readable.
/// Deserialises from that same string form.
///
/// The version lives *inside* the serialised record, not just in the type
/// system, so a future reader can detect and migrate stale data at runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, JsonSchema)]
pub struct SemVer {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl SemVer {
    pub const fn new(major: u32, minor: u32, patch: u32) -> Self {
        Self { major, minor, patch }
    }

    /// `self` (reader) can safely deserialise a record written at `written_by` when:
    ///   - same major (no breaking changes)
    ///   - reader version ≥ written-by version (reader knows about all the fields)
    pub fn can_read(self, written_by: SemVer) -> bool {
        self.major == written_by.major && self >= written_by
    }

    pub const fn bump_patch(self) -> Self { Self::new(self.major, self.minor, self.patch + 1) }
    pub const fn bump_minor(self) -> Self { Self::new(self.major, self.minor + 1, 0) }
    pub const fn bump_major(self) -> Self { Self::new(self.major + 1, 0, 0) }
}

impl fmt::Display for SemVer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

impl FromStr for SemVer {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let parts: Vec<&str> = s.split('.').collect();
        if parts.len() != 3 {
            return Err(format!("expected major.minor.patch, got {s:?}"));
        }
        let p = |v: &str| v.parse::<u32>().map_err(|e| e.to_string());
        Ok(Self::new(p(parts[0])?, p(parts[1])?, p(parts[2])?))
    }
}

// Serialise as string "0.1.0" — compact, diff-friendly, grep-friendly.
impl Serialize for SemVer {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.to_string())
    }
}

impl<'de> Deserialize<'de> for SemVer {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        SemVer::from_str(&raw).map_err(serde::de::Error::custom)
    }
}

/// Implemented by every versioned struct.
/// The associated const is the *current* schema version — bump it in the same
/// commit that changes the struct layout.
pub trait Versioned {
    const SCHEMA_VERSION: SemVer;
}

// ── TaskStatus ────────────────────────────────────────────────────────────────

/// Execution state of a task.
///
/// String values match Claude Code's `TodoWrite` tool exactly so tasks
/// serialised here round-trip through Claude's tool calls without translation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    /// Not yet started. Default state on creation.
    #[default]
    Pending,
    /// Claimed by an executor; work is underway.
    InProgress,
    /// Work finished successfully.
    Completed,
    /// Abandoned — will not be retried.
    Cancelled,
}

impl TaskStatus {
    /// Terminal states cannot transition further.
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Completed | Self::Cancelled)
    }
}

impl fmt::Display for TaskStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Pending    => "pending",
            Self::InProgress => "in_progress",
            Self::Completed  => "completed",
            Self::Cancelled  => "cancelled",
        })
    }
}

// ── TaskPriority ──────────────────────────────────────────────────────────────

/// Priority level. `Ord` is defined so that `High < Medium < Low`,
/// meaning ascending sort yields highest-priority tasks first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskPriority {
    High,
    #[default]
    Medium,
    Low,
}

impl TaskPriority {
    fn sort_key(self) -> u8 {
        match self { Self::High => 0, Self::Medium => 1, Self::Low => 2 }
    }
}

impl PartialOrd for TaskPriority {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for TaskPriority {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.sort_key().cmp(&other.sort_key())
    }
}

impl fmt::Display for TaskPriority {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::High   => "high",
            Self::Medium => "medium",
            Self::Low    => "low",
        })
    }
}

// ── TaskKind ──────────────────────────────────────────────────────────────────

/// Discriminated union describing what kind of work a task represents.
///
/// Used by the executor to route tasks to the correct MCP tool, CLI command,
/// or agent without parsing the `content` string.
///
/// Serialises with an internal `"kind"` tag:
/// ```json
/// {"kind": "crawl_board", "board": "stripe", "platform": "greenhouse"}
/// {"kind": "deploy", "worker": "subagentjobs-web"}
/// {"kind": "todo"}
/// ```
///
/// Add new variants as new tool types are introduced — existing serialised
/// records are unaffected (unknown `kind` values deserialise to `Unknown`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TaskKind {
    /// Generic Claude Code–compatible todo. No special executor routing.
    Todo,

    /// Crawl a Greenhouse or Lever board via the Rust MCP server.
    CrawlBoard {
        board: String,
        platform: String,
    },

    /// Run a job eviction cycle (miss-count + tombstone pass).
    EvictStale {
        /// None = all boards in the cron worker.
        #[serde(skip_serializing_if = "Option::is_none")]
        board: Option<String>,
    },

    /// Deploy a Cloudflare Worker via `wrangler deploy`.
    Deploy {
        worker: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    /// Apply a SQL migration file to a D1 or Postgres database.
    Migration {
        file: String,
        /// Defaults to `subagentjobs-dwh` if None.
        #[serde(skip_serializing_if = "Option::is_none")]
        database: Option<String>,
    },

    /// Commit staged changes and push to GitHub.
    GitPush {
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        branch: Option<String>,
    },

    /// Review a pull request or diff.
    CodeReview {
        #[serde(skip_serializing_if = "Option::is_none")]
        pr_url: Option<String>,
        /// E.g. "security", "performance", "correctness"
        #[serde(skip_serializing_if = "Option::is_none")]
        focus: Option<String>,
    },

    /// A subtask spawned by a parent agent session.
    SubTask {
        parent_id: Uuid,
        /// Claude Code agent type: "claude", "explore", "plan", etc.
        #[serde(skip_serializing_if = "Option::is_none")]
        agent_type: Option<String>,
    },

    /// Raw shell command to run in the workspace sandbox.
    ShellCommand {
        command: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        working_dir: Option<String>,
    },

    /// Fallback for future variants not yet known by this version of the code.
    /// Preserves the raw JSON so the task can be re-serialised without data loss.
    #[serde(other)]
    Unknown,
}

impl fmt::Display for TaskKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Todo                          => write!(f, "todo"),
            Self::CrawlBoard { board, .. }      => write!(f, "crawl:{board}"),
            Self::EvictStale { board }          => write!(f, "evict:{}", board.as_deref().unwrap_or("all")),
            Self::Deploy { worker, .. }         => write!(f, "deploy:{worker}"),
            Self::Migration { file, .. }        => write!(f, "migration:{file}"),
            Self::GitPush { branch, .. }        => write!(f, "git:push{}", branch.as_deref().map(|b| format!(":{b}")).unwrap_or_default()),
            Self::CodeReview { pr_url, .. }     => write!(f, "review:{}", pr_url.as_deref().unwrap_or("local")),
            Self::SubTask { parent_id, .. }     => write!(f, "subtask:{parent_id}"),
            Self::ShellCommand { command, .. }  => write!(f, "shell:{command}"),
            Self::Unknown                       => write!(f, "unknown"),
        }
    }
}

// ── Task ─────────────────────────────────────────────────────────────────────

/// A single task unit — schema v0.1.0.
///
/// `id`, `content`, `status`, and `priority` are intentionally named and valued
/// to match Claude Code's `TodoWrite` tool, so this struct can be hydrated
/// directly from or serialised directly into a Claude Code task list.
///
/// Additional fields (`kind`, `notes`, timestamps) are preserved on round-trip
/// but ignored by Claude Code.
///
/// ## Schema evolution
/// When you need to add a field, add it as `Option<T>` with
/// `#[serde(skip_serializing_if = "Option::is_none")]` and bump `SCHEMA_VERSION`
/// minor. Existing serialised tasks will deserialise with the new field as `None`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Task {
    /// Schema version of *this record*. Compare against `Task::SCHEMA_VERSION`
    /// at read time to detect records that need migration.
    pub schema_version: SemVer,

    /// Time-ordered UUID v7 — sortable by creation time without a timestamp index.
    pub id: Uuid,

    /// What to do — shown verbatim in the Claude Code task list.
    pub content: String,

    pub status: TaskStatus,
    pub priority: TaskPriority,

    /// Typed task discriminant — tells the executor *how* to do it.
    pub kind: TaskKind,

    /// Execution output, error message, or human notes written back after the run.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,

    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<DateTime<Utc>>,
}

impl Versioned for Task {
    const SCHEMA_VERSION: SemVer = SemVer::new(0, 1, 0);
}

impl Task {
    pub fn new(
        content: impl Into<String>,
        priority: TaskPriority,
        kind: TaskKind,
    ) -> Self {
        let now = Utc::now();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            id: Uuid::now_v7(),
            content: content.into(),
            status: TaskStatus::default(),
            priority,
            kind,
            notes: None,
            created_at: now,
            updated_at: now,
            completed_at: None,
        }
    }

    /// `Pending → InProgress`. No-op if already in a terminal state.
    pub fn start(&mut self) {
        if !self.status.is_terminal() {
            self.status = TaskStatus::InProgress;
            self.updated_at = Utc::now();
        }
    }

    /// `InProgress → Completed`.
    pub fn complete(&mut self, notes: Option<String>) {
        self.status = TaskStatus::Completed;
        if notes.is_some() { self.notes = notes; }
        let now = Utc::now();
        self.updated_at = now;
        self.completed_at = Some(now);
    }

    /// Any non-terminal state → `Cancelled`.
    pub fn cancel(&mut self, reason: Option<String>) {
        if !self.status.is_terminal() {
            self.status = TaskStatus::Cancelled;
            if reason.is_some() { self.notes = reason; }
            self.updated_at = Utc::now();
        }
    }

    /// Returns true when the current `Task::SCHEMA_VERSION` can safely read
    /// this record (i.e. the record was not written by a future major version).
    pub fn is_schema_compatible(&self) -> bool {
        Task::SCHEMA_VERSION.can_read(self.schema_version)
    }
}

// ── QueueStats ────────────────────────────────────────────────────────────────

/// Snapshot of task counts by status — cheap to compute, useful for progress bars.
#[derive(Debug, Default, Clone, Serialize, Deserialize, JsonSchema)]
pub struct QueueStats {
    pub pending: usize,
    pub in_progress: usize,
    pub completed: usize,
    pub cancelled: usize,
}

impl QueueStats {
    pub fn total(&self) -> usize {
        self.pending + self.in_progress + self.completed + self.cancelled
    }

    /// Fraction complete in [0.0, 1.0]. Returns 0.0 on empty queue.
    pub fn progress(&self) -> f64 {
        let done = (self.completed + self.cancelled) as f64;
        let total = self.total() as f64;
        if total == 0.0 { 0.0 } else { done / total }
    }
}

impl fmt::Display for QueueStats {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}/{} done ({} in_progress, {} cancelled)",
            self.completed,
            self.total(),
            self.in_progress,
            self.cancelled,
        )
    }
}

// ── TaskQueue ─────────────────────────────────────────────────────────────────

/// Priority-ordered task queue — schema v0.1.0.
///
/// Push tasks in any order during the *planning* phase, then call `claim_next`
/// in the *execution* phase. `claim_next` always returns the highest-priority
/// `Pending` task, with FIFO tie-breaking via UUIDv7 time-ordering.
///
/// The queue is intentionally serialisable so it can be:
/// - written to disk between sessions
/// - stored in Redis as a durable work list
/// - sent over the wire to a remote executor
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TaskQueue {
    pub schema_version: SemVer,
    /// Ordered by insertion. Claim logic selects by priority, not position.
    tasks: VecDeque<Task>,
}

impl Versioned for TaskQueue {
    const SCHEMA_VERSION: SemVer = SemVer::new(0, 1, 0);
}

impl Default for TaskQueue {
    fn default() -> Self {
        Self {
            schema_version: Self::SCHEMA_VERSION,
            tasks: VecDeque::new(),
        }
    }
}

impl TaskQueue {
    pub fn new() -> Self { Self::default() }

    /// Append a task to the back of the queue.
    /// Ordering within the queue is insertion order; priority is resolved at claim time.
    pub fn push(&mut self, task: Task) {
        self.tasks.push_back(task);
    }

    pub fn len(&self) -> usize  { self.tasks.len() }
    pub fn is_empty(&self) -> bool { self.tasks.is_empty() }

    pub fn pending(&self)     -> impl Iterator<Item = &Task> { self.tasks.iter().filter(|t| t.status == TaskStatus::Pending) }
    pub fn in_progress(&self) -> impl Iterator<Item = &Task> { self.tasks.iter().filter(|t| t.status == TaskStatus::InProgress) }
    pub fn completed(&self)   -> impl Iterator<Item = &Task> { self.tasks.iter().filter(|t| t.status == TaskStatus::Completed) }

    /// Peek at the next task that `claim_next` would return.
    /// Does not mutate state.
    pub fn peek_next(&self) -> Option<&Task> {
        self.tasks.iter()
            .filter(|t| t.status == TaskStatus::Pending)
            .min_by(|a, b| {
                // Lower sort_key = higher priority; UUIDv7 breaks ties (older = first)
                a.priority.cmp(&b.priority)
                    .then_with(|| a.id.cmp(&b.id))
            })
    }

    /// Transition the highest-priority `Pending` task to `InProgress`.
    /// Returns the task's `Uuid` so the caller can retrieve it with `get()`.
    pub fn claim_next(&mut self) -> Option<Uuid> {
        let id = self.peek_next()?.id;
        self.tasks.iter_mut().find(|t| t.id == id)?.start();
        Some(id)
    }

    /// Mark a task `Completed` by id. Returns `false` if id not found.
    pub fn complete(&mut self, id: Uuid, notes: Option<String>) -> bool {
        match self.tasks.iter_mut().find(|t| t.id == id) {
            Some(t) => { t.complete(notes); true }
            None    => false,
        }
    }

    /// Mark a task `Cancelled` by id. Returns `false` if id not found.
    pub fn cancel(&mut self, id: Uuid, reason: Option<String>) -> bool {
        match self.tasks.iter_mut().find(|t| t.id == id) {
            Some(t) => { t.cancel(reason); true }
            None    => false,
        }
    }

    pub fn get(&self, id: Uuid) -> Option<&Task> {
        self.tasks.iter().find(|t| t.id == id)
    }

    pub fn get_mut(&mut self, id: Uuid) -> Option<&mut Task> {
        self.tasks.iter_mut().find(|t| t.id == id)
    }

    /// Iterate all tasks in insertion order.
    pub fn iter(&self) -> impl Iterator<Item = &Task> {
        self.tasks.iter()
    }

    pub fn stats(&self) -> QueueStats {
        let mut s = QueueStats::default();
        for t in &self.tasks {
            match t.status {
                TaskStatus::Pending    => s.pending    += 1,
                TaskStatus::InProgress => s.in_progress += 1,
                TaskStatus::Completed  => s.completed  += 1,
                TaskStatus::Cancelled  => s.cancelled  += 1,
            }
        }
        s
    }
}

// ── TaskSession ───────────────────────────────────────────────────────────────

/// A named agent session containing a task queue — schema v0.1.0.
///
/// One `TaskSession` maps to one Claude Code or Cowork session's work list.
/// Serialise to JSON at session start/end to make task state durable across
/// context resets.
///
/// ## Usage pattern
/// ```text
/// Plan:    session.push(task_a); session.push(task_b); session.push(task_c);
/// Review:  inspect session.stats(), reorder if needed
/// Execute: loop { claim_next → run → complete }
/// Persist: serde_json::to_string(&session) → write to CLAUDE.md or Redis
/// ```
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct TaskSession {
    pub schema_version: SemVer,

    /// Time-ordered UUID v7 — unique across sessions.
    pub id: Uuid,

    /// Human-readable name shown in progress output.
    pub name: String,

    pub queue: TaskQueue,

    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl Versioned for TaskSession {
    const SCHEMA_VERSION: SemVer = SemVer::new(0, 1, 0);
}

impl TaskSession {
    pub fn new(name: impl Into<String>) -> Self {
        let now = Utc::now();
        Self {
            schema_version: Self::SCHEMA_VERSION,
            id: Uuid::now_v7(),
            name: name.into(),
            queue: TaskQueue::new(),
            created_at: now,
            updated_at: now,
        }
    }

    pub fn push(&mut self, task: Task) {
        self.queue.push(task);
        self.updated_at = Utc::now();
    }

    pub fn stats(&self) -> QueueStats { self.queue.stats() }

    pub fn is_complete(&self) -> bool {
        self.queue.pending().next().is_none()
            && self.queue.in_progress().next().is_none()
    }
}
