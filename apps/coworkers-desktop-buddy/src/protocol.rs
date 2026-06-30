//! Type-safe wire protocol for the Claude Hardware Buddy BLE bridge.
//!
//! All messages are newline-delimited JSON over Nordic UART Service (NUS).
//! Source of truth: vendors/anthropics/claude-desktop-buddy/REFERENCE.md

use serde::{Deserialize, Serialize};

// ── Desktop → Device ────────────────────────────────────────────────────────

/// Sent whenever session state changes, plus a keepalive every 10 s.
/// If no snapshot arrives for ~30 s the device treats the link as dead.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HeartbeatSnapshot {
    /// Total open sessions.
    pub total: u32,
    /// Sessions actively generating.
    pub running: u32,
    /// Sessions blocked on a permission prompt.
    pub waiting: u32,
    /// One-line summary for a small display.
    pub msg: String,
    /// Recent transcript lines, newest first.
    #[serde(default)]
    pub entries: Vec<String>,
    /// Cumulative output tokens since the desktop app started.
    #[serde(default)]
    pub tokens: u64,
    /// Output tokens since local midnight (persisted across restarts).
    #[serde(default)]
    pub tokens_today: u64,
    /// Present only when a permission decision is needed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt: Option<PermissionPrompt>,
}

/// Pending tool-call approval attached to a `HeartbeatSnapshot`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionPrompt {
    /// Opaque ID — must be echoed back in `PermissionDecision`.
    pub id: String,
    /// Tool name, e.g. `"Bash"`.
    pub tool: String,
    /// Short hint shown on the device display, e.g. `"rm -rf /tmp/foo"`.
    #[serde(default)]
    pub hint: String,
    /// Which coworker raised this gate, e.g. `"design"` or `"finance"`. Absent for
    /// plain session permission prompts. Lets the device show *who* is asking.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
}

/// Fired once per completed assistant turn (dropped if > 4 KB serialised).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TurnEvent {
    /// Always `"turn"`.
    pub evt: String,
    /// `"assistant"` or `"user"`.
    pub role: String,
    /// Raw SDK content array — text blocks, tool calls, etc.
    pub content: Vec<serde_json::Value>,
}

/// One-shot time sync sent on connect.
/// `[epoch_seconds, tz_offset_seconds]`
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimeSync {
    pub time: [i64; 2],
}

// ── Desktop commands (expect an ack from device) ─────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum DesktopCommand {
    Status,
    Name  { name: String },
    Owner { name: String },
    Unpair,
    // Folder-push transport
    CharBegin { name: String, total: u64 },
    File      { path: String, size: u64 },
    Chunk     { d: String },  // base64-encoded bytes
    FileEnd,
    CharEnd,
}

// ── Device → Desktop ─────────────────────────────────────────────────────────

/// Permission decision the physical device sends back.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PermissionDecision {
    pub cmd: String, // always "permission"
    pub id: String,
    pub decision: PermissionDecisionKind,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PermissionDecisionKind {
    Once,
    Deny,
}

/// Generic ack the device sends for every `cmd` it receives.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CommandAck {
    pub ack: String,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub n: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<StatusData>,
}

/// Payload inside a `status` ack.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StatusData {
    pub name: String,
    #[serde(default)]
    pub sec: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bat: Option<BatteryStatus>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sys: Option<SysInfo>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stats: Option<DeviceStats>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatteryStatus {
    pub pct: u8,
    #[serde(rename = "mV")]
    pub mv: u16,
    #[serde(rename = "mA")]
    pub ma: i16,   // negative = charging
    pub usb: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SysInfo {
    pub up: u32,   // uptime seconds
    pub heap: u32, // free heap bytes
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceStats {
    pub appr: u16,  // lifetime approvals
    pub deny: u16,  // lifetime denials
    pub vel: u16,   // median seconds-to-respond
    pub nap: u32,   // cumulative nap seconds
    pub lvl: u8,    // current level (tokens / 50_000)
}

// ── VM-side inference session state (our additions) ──────────────────────────

/// Snapshot of an active inference session running in the Linux VM.
/// Built by reading session_info MCP + scheduled-task state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InferenceSession {
    pub id: String,
    pub title: String,
    pub status: InferenceSessionStatus,
    pub tokens_out: u64,
    pub pending_tool: Option<PendingToolCall>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InferenceSessionStatus {
    Running,
    Waiting, // blocked on permission
    Idle,
}

/// A tool call awaiting a permission decision from the physical device.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PendingToolCall {
    pub request_id: String,
    pub tool: String,
    pub hint: String,
}

// ── Aggregate: what the bridge emits to the BLE device ───────────────────────

impl From<Vec<InferenceSession>> for HeartbeatSnapshot {
    fn from(sessions: Vec<InferenceSession>) -> Self {
        let total   = sessions.len() as u32;
        let running = sessions.iter().filter(|s| s.status == InferenceSessionStatus::Running).count() as u32;
        let waiting = sessions.iter().filter(|s| s.status == InferenceSessionStatus::Waiting).count() as u32;
        let tokens  = sessions.iter().map(|s| s.tokens_out).sum();
        let prompt  = sessions.iter()
            .find(|s| s.pending_tool.is_some())
            .and_then(|s| s.pending_tool.as_ref())
            .map(|t| PermissionPrompt {
                id: t.request_id.clone(),
                tool: t.tool.clone(),
                hint: t.hint.clone(),
                role: None,
            });
        let msg = if waiting > 0 {
            format!("approve: {}", prompt.as_ref().map(|p| p.tool.as_str()).unwrap_or("?"))
        } else if running > 0 {
            format!("{} session{} running", running, if running == 1 { "" } else { "s" })
        } else {
            format!("{} session{} idle", total, if total == 1 { "" } else { "s" })
        };
        HeartbeatSnapshot { total, running, waiting, msg, entries: vec![], tokens, tokens_today: 0, prompt }
    }
}
