//! Greenhouse + Lever fetch → NormalizedJob.
//! Replaces the inline JS ETL worker entirely.
use anyhow::Result;
use durable_store::JobRow;
use reqwest::Client;
use serde::Deserialize;
use sha2::{Digest, Sha256};

const UA: &str = "SubagentJobsCrawler/2.0 (Rust; +https://subagentjobs.com/)";

pub struct FetchResult {
    pub jobs: Vec<JobRow>,
    pub raw_sha256: String,
}

pub async fn fetch_board(client: &Client, token: &str, platform: &str) -> Result<FetchResult> {
    match platform {
        "lever" => fetch_lever(client, token).await,
        _ => fetch_greenhouse(client, token).await,
    }
}

// ── Greenhouse ────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
struct GhResponse { jobs: Vec<GhJob> }

#[derive(Deserialize)]
struct GhJob {
    id: u64,
    title: String,
    location: GhLocation,
    absolute_url: String,
    first_published: Option<String>,
    updated_at: Option<String>,
    offices: Option<Vec<serde_json::Value>>,
    metadata: Option<Vec<GhMeta>>,
    content: Option<String>,
}

#[derive(Deserialize)]
struct GhLocation { name: String }

#[derive(Deserialize)]
struct GhMeta { name: String, value: Option<String> }

async fn fetch_greenhouse(client: &Client, token: &str) -> Result<FetchResult> {
    let url = format!("https://boards-api.greenhouse.io/v1/boards/{token}/jobs?content=true");
    let raw = client.get(&url).header("User-Agent", UA).send().await?.bytes().await?;
    let sha256 = hex::encode(Sha256::digest(&raw));
    let resp: GhResponse = serde_json::from_slice(&raw)?;

    let jobs = resp.jobs.into_iter().map(|j| {
        let lt = j.metadata.as_ref()
            .and_then(|ms| ms.iter().find(|m| m.name == "Location Type"))
            .and_then(|m| m.value.clone());
        JobRow {
            job_post_id: j.id.to_string(),
            title: j.title.trim().to_string(),
            location_name: Some(j.location.name),
            location_type: lt,
            absolute_url: Some(j.absolute_url),
            content_length: j.content.as_ref().map(|c| c.len() as i32),
            first_published: j.first_published,
            updated_at: j.updated_at,
            office_count: j.offices.as_ref().map(|o| o.len() as i32),
            is_prospect: None,
            company_name: Some(token.to_string()),
            platform: Some("greenhouse".to_string()),
        }
    }).collect();

    Ok(FetchResult { jobs, raw_sha256: sha256 })
}

// ── Lever ─────────────────────────────────────────────────────────────────────

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LeverJob {
    id: String,
    text: String,
    created_at: i64,
    workplace_type: Option<String>,
    categories: LeverCats,
    hosted_url: String,
    description_plain: Option<String>,
    additional_plain: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LeverCats {
    location: Option<String>,
    all_locations: Option<Vec<String>>,
}

async fn fetch_lever(client: &Client, token: &str) -> Result<FetchResult> {
    let mut all_raw: Vec<u8> = Vec::new();
    let mut jobs: Vec<JobRow> = Vec::new();
    let mut skip = 0usize;

    loop {
        let url = format!("https://api.lever.co/v0/postings/{token}?limit=250&skip={skip}");
        let raw = client.get(&url).header("User-Agent", UA).send().await?.bytes().await?;
        all_raw.extend_from_slice(&raw);
        let batch: Vec<LeverJob> = serde_json::from_slice(&raw)?;
        let n = batch.len();
        for j in batch {
            let lt = j.workplace_type.as_deref().map(|w| match w {
                "remote" => "Remote", "hybrid" => "Hybrid (Travel-Required)",
                "onsite" => "On-Site", _ => "Unspecified",
            }.to_string());
            let cl = j.description_plain.as_ref().map_or(0, |s| s.len())
                + j.additional_plain.as_ref().map_or(0, |s| s.len());
            let ts = j.created_at / 1000;
            let published = chrono::DateTime::from_timestamp(ts, 0)
                .map(|d| d.to_rfc3339())
                .unwrap_or_default();
            jobs.push(JobRow {
                job_post_id: j.id,
                title: j.text,
                location_name: j.categories.location,
                location_type: lt,
                absolute_url: Some(j.hosted_url),
                content_length: Some(cl as i32),
                first_published: Some(published.clone()),
                updated_at: Some(published),
                office_count: j.categories.all_locations.as_ref().map(|v| v.len() as i32),
                is_prospect: Some(0),
                company_name: Some(token.to_string()),
                platform: Some("lever".to_string()),
            });
        }
        if n < 250 { break; }
        skip += 250;
    }

    Ok(FetchResult { jobs, raw_sha256: hex::encode(Sha256::digest(&all_raw)) })
}
