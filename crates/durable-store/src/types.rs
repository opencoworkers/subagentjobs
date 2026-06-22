use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct JobRow {
    pub job_post_id: String,
    pub title: String,
    pub location_name: Option<String>,
    pub location_type: Option<String>,
    pub absolute_url: Option<String>,
    pub content_length: Option<i32>,
    pub first_published: Option<String>,
    pub updated_at: Option<String>,
    pub office_count: Option<i32>,
    pub is_prospect: Option<i32>,
    pub company_name: Option<String>,
    pub platform: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct SkillNode {
    pub name: String,
    pub category: String,
    pub job_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct SkillEdge {
    pub source: String,
    pub target: String,
    pub weight: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrawlLog {
    pub board_token: String,
    pub snapshot_sha256: String,
    pub changed: bool,
    pub job_count: i32,
    pub duration_ms: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CacheSource { Redis, Postgres }

#[derive(Debug, Clone)]
pub struct CdcResult {
    pub changed: bool,
    pub hash: String,
}

// ── Doc pages ─────────────────────────────────────────────────────────────────

/// A fetched and processed documentation page.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct DocPage {
    pub url: String,
    pub host: String,
    pub path: String,
    pub sha256: String,
    pub content_md: Option<String>,
    /// Extracted MDX admonitions serialized as a JSON array.
    pub admonitions: Option<serde_json::Value>,
    pub gfm: Option<String>,
    pub crawled_at: Option<DateTime<Utc>>,
}

/// An extracted MDX admonition component.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Admonition {
    Tip { content: String },
    Note { content: String },
    Warning { content: String },
    Caution { content: String },
    Step { title: String, body: String },
    Tab { title: String, body: String },
}

impl Admonition {
    /// Convert to a GitHub-Flavored Markdown callout block.
    pub fn to_gfm(&self) -> String {
        match self {
            Admonition::Tip { content } =>
                format!("> [!TIP]\n> {}", content.replace('\n', "\n> ")),
            Admonition::Note { content } =>
                format!("> [!NOTE]\n> {}", content.replace('\n', "\n> ")),
            Admonition::Warning { content } =>
                format!("> [!WARNING]\n> {}", content.replace('\n', "\n> ")),
            Admonition::Caution { content } =>
                format!("> [!CAUTION]\n> {}", content.replace('\n', "\n> ")),
            Admonition::Step { title, body } =>
                format!("**{title}**\n\n{body}"),
            Admonition::Tab { title, body } =>
                format!("#### {title}\n\n{body}"),
        }
    }
}

/// In-memory harvest result, held in the LRU cache and persisted to
/// `crates/docs-crawler/.cache/mdx-lru.json` between runs.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HarvestResult {
    pub url: String,
    pub sha256: String,
    pub admonitions: Vec<Admonition>,
    pub gfm: String,
}

/// Serialised form of the LRU cache written to `.cache/mdx-lru.json`.
/// `entries` are ordered least-recently-used → most-recently-used so that
/// deserialising with sequential `put` calls restores the original recency.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CachedLru {
    pub version: u8,
    pub capacity: usize,
    pub entries: Vec<(String, HarvestResult)>,
}
