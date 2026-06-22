//! coworkers-desktop-buddy
//!
//! Bridges the inference-runtime session state (Linux VM) to a physical
//! Claude Hardware Buddy device over BLE (Nordic UART Service).
//!
//! Data flow:
//!   InferenceRuntime (VM sessions) → CoworkersBridge → BLE/NUS → ESP32 device
//!   ESP32 device → BLE/NUS → CoworkersBridge → PermissionDecision → session manager
//!
//! See apps/coworkers-desktop-buddy/src/protocol.rs for all wire types.
//! See vendors/anthropics/claude-desktop-buddy/REFERENCE.md for the BLE spec.

mod protocol;

use protocol::{HeartbeatSnapshot, InferenceSession, InferenceSessionStatus};
use tracing::info;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    info!("coworkers-desktop-buddy starting");

    // TODO(bridge): scan for BLE device advertising Nordic UART Service
    //               with name prefix "Claude"
    // TODO(bridge): on connect, send TimeSync + OwnerCmd
    // TODO(bridge): poll InferenceSession state every 1s, emit HeartbeatSnapshot
    // TODO(bridge): receive PermissionDecision from device, forward to session manager

    // Stub: build a snapshot from fake sessions to verify types compile
    let sessions = vec![
        InferenceSession {
            id:          "local_fafa287d".into(),
            title:       "Job listings normalization".into(),
            status:      InferenceSessionStatus::Running,
            tokens_out:  42_000,
            pending_tool: None,
        },
    ];
    let snapshot = HeartbeatSnapshot::from(sessions);
    info!(?snapshot, "snapshot built");

    Ok(())
}
