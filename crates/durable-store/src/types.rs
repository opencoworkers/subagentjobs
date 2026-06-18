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
