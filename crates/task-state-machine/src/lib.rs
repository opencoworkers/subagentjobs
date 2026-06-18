//! pg_durable-style FSM for board crawl lifecycle.
//! States: Pending → Crawling → Enriching → Active
//!         Pending → CrawlFailed (retry ≤5)
//!         Crawling → CrawlFailed
//!         Enriching → EnrichFailed
//! Transitions are atomic via SELECT FOR UPDATE SKIP LOCKED.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

mod fsm;
pub use fsm::*;

/// A single crawl task for one board snapshot.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct CrawlTask {
    pub id: Uuid,
    pub board_token: String,
    pub state: String,      // Pending|Crawling|Enriching|Active|CrawlFailed|EnrichFailed
    pub attempts: i32,
    pub snapshot_sha256: Option<String>,
    pub error: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub updated_at: chrono::DateTime<chrono::Utc>,
}

pub const MAX_ATTEMPTS: i32 = 5;
