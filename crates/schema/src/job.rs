use serde::{Deserialize, Serialize};
use schemars::JsonSchema;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Platform { Greenhouse, Lever }

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct NormalizedJob {
    pub id: String,
    pub title: String,
    pub location: String,
    pub location_type: Option<String>,
    pub url: String,
    pub content_length: usize,
    pub published: String,
    pub updated: String,
    pub office_count: usize,
    pub is_prospect: bool,
    pub company: String,
    pub platform: Platform,
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Board {
    pub token: String,
    pub name: String,
    pub platform: Platform,
    pub job_count: u32,
    pub last_sha256: Option<String>,
    pub last_crawled: Option<String>,
}

/// Lever-specific API types
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LeverJob {
    pub id: String,
    pub text: String,
    pub created_at: i64,
    #[serde(default)]
    pub workplace_type: Option<String>,
    #[serde(default)]
    pub country: Option<String>,
    pub categories: LeverCategories,
    pub hosted_url: String,
    pub apply_url: String,
    #[serde(default)]
    pub description_plain: Option<String>,
    #[serde(default)]
    pub additional_plain: Option<String>,
    #[serde(default)]
    pub lists: Vec<LeverList>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LeverCategories {
    pub commitment: Option<String>,
    pub location: Option<String>,
    pub team: Option<String>,
    pub all_locations: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LeverList {
    pub text: String,
    pub content: String,
}

impl LeverJob {
    pub fn normalize(self, company: &str) -> NormalizedJob {
        let lt = self.workplace_type.as_deref().map(|w| match w {
            "remote" => "Remote", "hybrid" => "Hybrid (Travel-Required)",
            "onsite" => "On-Site", _ => "Unspecified",
        }.to_string());
        let cl = self.description_plain.as_deref().map_or(0, |s| s.len())
            + self.additional_plain.as_deref().map_or(0, |s| s.len());
        NormalizedJob {
            id: self.id, title: self.text,
            location: self.categories.location.unwrap_or_default(),
            location_type: lt, url: self.hosted_url, content_length: cl,
            published: String::new(), updated: String::new(),
            office_count: self.categories.all_locations.as_ref().map_or(1, |v| v.len()),
            is_prospect: false, company: company.to_string(),
            platform: Platform::Lever, sha256: None,
        }
    }
}
