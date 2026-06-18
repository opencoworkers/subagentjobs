use anyhow::Result;
use durable_store::DurableStore;
use reqwest::Client;
use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, Content, ServerInfo, Implementation},
    tool, tool_handler, tool_router,
};
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Instant};
use tokio::sync::Mutex;

use crate::{crawler, tools::*};

#[derive(Clone)]
pub struct JobServer {
    store: Arc<Mutex<DurableStore>>,
    http: Client,
    tool_router: ToolRouter<Self>,
}

impl JobServer {
    pub fn new(store: DurableStore) -> Self {
        Self {
            store: Arc::new(Mutex::new(store)),
            http: Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap(),
            tool_router: Self::tool_router(),
        }
    }
}

#[tool_router(router = tool_router)]
impl JobServer {
    /// Search jobs by query, skills, or company board token.
    #[tool(description = "Search 4500+ jobs by free-text or company filter. Returns sha256 per job.")]
    async fn search_jobs(&self, input: Parameters<SearchJobsInput>) -> String {
        let input = input.0;
        let limit = input.limit.unwrap_or(20).min(100) as usize;
        let company = input.company.as_deref().unwrap_or("anthropic");
        let mut store = self.store.lock().await;
        let Ok((jobs, _)) = store.get_jobs_for_board(company).await else {
            return "[]".into();
        };
        let q = input.query.as_deref().unwrap_or("").to_lowercase();
        let results: Vec<_> = jobs.into_iter()
            .filter(|j| q.is_empty()
                || j.title.to_lowercase().contains(&q)
                || j.location_name.as_deref().unwrap_or("").to_lowercase().contains(&q))
            .take(limit)
            .map(|j| {
                let sha = hex::encode(Sha256::digest(
                    format!("{}:{}:{}", j.job_post_id, j.title,
                        j.updated_at.as_deref().unwrap_or("")).as_bytes()));
                json!({"sha256":sha,"title":j.title,"company":j.company_name,
                       "location":j.location_name,"location_type":j.location_type,
                       "posted":j.first_published})
            })
            .collect();
        serde_json::to_string(&results).unwrap_or_default()
    }

    /// Get canonical job URL by SHA256 hash.
    #[tool(description = "Get job URL by SHA256")]
    async fn get_job(&self, input: Parameters<GetJobInput>) -> String {
        format!("https://subagentjobs.com/jobs/{}", input.0.sha256)
    }

    /// Skill co-occurrence knowledge graph. Filter by category: language|framework|platform|domain.
    #[tool(description = "Skill co-occurrence graph — nodes (job_count) + edges (weight)")]
    async fn get_skill_graph(&self, input: Parameters<GetSkillGraphInput>) -> String {
        let min_weight = input.0.min_weight.unwrap_or(15);
        let mut store = self.store.lock().await;
        let Ok((mut nodes, mut edges)) = store.get_skill_graph(min_weight).await else {
            return "{}".into();
        };
        if let Some(cat) = &input.0.category {
            nodes.retain(|n| &n.category == cat);
            let names: std::collections::HashSet<_> = nodes.iter().map(|n| n.name.as_str()).collect();
            edges.retain(|e| names.contains(e.source.as_str()) && names.contains(e.target.as_str()));
        }
        json!({
            "nodes": nodes.iter().map(|n| json!({"name":n.name,"category":n.category,"job_count":n.job_count})).collect::<Vec<_>>(),
            "edges": edges.iter().map(|e| json!({"source":e.source,"target":e.target,"weight":e.weight})).collect::<Vec<_>>(),
        }).to_string()
    }

    /// Crawl a Greenhouse or Lever board. CDC-gated — only writes to Postgres on SHA256 change.
    #[tool(description = "Crawl a job board (CDC-gated). Returns {changed, jobs, sha256, duration_ms}.")]
    async fn crawl_board(&self, input: Parameters<CrawlBoardInput>) -> String {
        let t0 = Instant::now();
        let board = &input.0.board;

        let platform = {
            let store = self.store.lock().await;
            sqlx::query_scalar::<_, Option<String>>(
                "SELECT platform FROM dim_board WHERE board_token=$1"
            )
            .bind(board)
            .fetch_optional(&store.pg)
            .await
            .ok()
            .flatten()
            .flatten()
            .unwrap_or_else(|| "greenhouse".to_string())
        };

        let Ok(fetched) = crawler::fetch_board(&self.http, board, &platform).await else {
            return json!({"error":"fetch failed","board":board}).to_string();
        };
        let job_count = fetched.jobs.len();
        let mut store = self.store.lock().await;

        let Ok(cdc) = store.check_and_record_snapshot(board, fetched.raw_sha256.as_bytes()).await else {
            return json!({"error":"cdc failed"}).to_string();
        };

        if cdc.changed {
            let _ = store.upsert_jobs(&fetched.jobs).await;
            let _ = store.invalidate_board_cache(board).await;
        }

        let ms = t0.elapsed().as_millis() as i32;
        let _ = store.log_crawl(&durable_store::CrawlLog {
            board_token: board.clone(),
            snapshot_sha256: cdc.hash.clone(),
            changed: cdc.changed,
            job_count: job_count as i32,
            duration_ms: ms,
        }).await;

        json!({"board":board,"platform":platform,"changed":cdc.changed,
               "jobs":job_count,"sha256":&cdc.hash[..16],"duration_ms":ms}).to_string()
    }
}

#[tool_handler(router = self.tool_router,
               name = "subagentjobs-mcp",
               version = "0.1.0",
               instructions = "Job board explorer: 4500+ jobs, skill graph, CDC crawler")]
impl ServerHandler for JobServer {}

pub async fn run(database_url: &str, redis_url: &str) -> Result<()> {
    let store = DurableStore::connect(database_url, redis_url).await?;
    let running = JobServer::new(store)
        
        .serve((tokio::io::stdin(), tokio::io::stdout()))
        .await?;
    running.waiting().await?;
    Ok(())
}
