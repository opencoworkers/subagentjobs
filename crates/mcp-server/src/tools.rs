use schemars::JsonSchema;
use serde::Deserialize;

#[derive(Debug, Deserialize, JsonSchema)]
pub struct SearchJobsInput {
    pub query: Option<String>,
    pub skills: Option<Vec<String>>,
    pub company: Option<String>,
    pub limit: Option<u32>,
}

#[derive(Debug, Deserialize, JsonSchema)]
pub struct GetJobInput {
    pub sha256: String,
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
