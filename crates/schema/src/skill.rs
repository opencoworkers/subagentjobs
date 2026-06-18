use serde::{Deserialize, Serialize};
use schemars::JsonSchema;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SkillCategory { Language, Framework, Platform, Domain }

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Skill {
    pub key: u32,
    pub name: String,
    pub category: SkillCategory,
    pub aliases: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct SkillMatch {
    pub job_id: String,
    pub skill_key: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct GraphNode {
    pub name: String,
    pub category: SkillCategory,
    pub job_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct GraphEdge {
    pub source: String,
    pub target: String,
    pub weight: u32,
}
