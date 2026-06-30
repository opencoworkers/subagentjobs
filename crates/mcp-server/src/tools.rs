use schemars::JsonSchema;
use serde::Deserialize;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SearchJobsInput {
    pub query: Option<String>,
    /// Part of the tool input schema; not yet consumed by the query builder.
    #[allow(dead_code)]
    pub skills: Option<Vec<String>>,
    pub company: Option<String>,
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetJobInput {
    /// Primary key: job_post_id from fact_job_posting.
    pub job_post_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetSkillGraphInput {
    pub min_weight: Option<i64>,
    pub category: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct CrawlBoardInput {
    pub board: String,
}
