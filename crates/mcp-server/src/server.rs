//! MCP server for subagentjobs.
//!
//! # Fix log
//! 1. `JobServer` holds `DurableStore` directly — no `Arc<Mutex<…>>`.
//!    `DurableStore: Clone` (PgPool + ConnectionManager are both cheaply cloneable),
//!    so rmcp's required `Clone` on the handler is trivially satisfied.
//! 2. `search_jobs` no longer defaults to "anthropic": if `company` is None it runs
//!    a cross-board Postgres LIKE query via `store.search_by_title`.
//! 3. `get_job` looks up by `job_post_id` (primary key) and returns the canonical
//!    `absolute_url` from the source ATS — no more 404-prone SHA256 URL.
//! 4. `crawl_board` passes the pre-computed `raw_sha256` string directly to
//!    `check_and_record_snapshot` — fixes the double-hash bug.
//! 5. `crawl_board` wires the task-state-machine FSM:
//!    Pending → Crawling → Enriching → Active (with `mark_failed` on error).
//! 6. `run()` calls `ensure_table` on startup so the FSM table is always present.

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
use std::time::Instant;
use task_state_machine as fsm;

use crate::{crawler, tools::*};

#[derive(Clone)]
pub struct JobServer {
    store: DurableStore,
    http: Client,
    tool_router: ToolRouter<Self>,
}

impl JobServer {
    pub fn new(store: DurableStore) -> Self {
        Self {
            store,
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
    /// Search jobs by free-text query or company board token.
    /// If `company` is omitted, searches across all boards via Postgres LIKE.
    /// If `company` is provided, uses the Redis-cached board list (fast path).
    #[tool(description = "Search 7000+ jobs by free-text or company filter. Returns job_post_id, title, url.")]
    async fn search_jobs(&self, input: Parameters<SearchJobsInput>) -> String {
        let input = input.0;
        let limit = input.limit.unwrap_or(20).min(100);
        let q = input.query.as_deref().unwrap_or("").to_lowercase();

        let results: Vec<_> = if let Some(company) = &input.company {
            // Board-scoped: Redis L2 → Postgres L3
            let Ok((jobs, _)) = self.store.get_jobs_for_board(company).await else {
                return "[]".into();
            };
            jobs.into_iter()
                .filter(|j| {
                    q.is_empty()
                        || j.title.to_lowercase().contains(&q)
                        || j.location_name
                            .as_deref()
                            .unwrap_or("")
                            .to_lowercase()
                            .contains(&q)
                })
                .take(limit as usize)
                .map(|j| {
                    json!({
                        "job_post_id": j.job_post_id,
                        "title": j.title,
                        "company": j.company_name,
                        "location": j.location_name,
                        "location_type": j.location_type,
                        "url": j.absolute_url,
                        "posted": j.first_published,
                    })
                })
                .collect()
        } else {
            // Cross-board: direct Postgres LIKE (unbounded query space, skip Redis)
            let Ok(jobs) = self
                .store
                .search_by_title(if q.is_empty() { None } else { Some(&q) }, limit as i64)
                .await
            else {
                return "[]".into();
            };
            jobs.into_iter()
                .map(|j| {
                    json!({
                        "job_post_id": j.job_post_id,
                        "title": j.title,
                        "company": j.company_name,
                        "location": j.location_name,
                        "location_type": j.location_type,
                        "url": j.absolute_url,
                        "posted": j.first_published,
                    })
                })
                .collect()
        };

        serde_json::to_string(&results).unwrap_or_default()
    }

    /// Get full job details and canonical ATS URL by job_post_id.
    #[tool(description = "Get job details + canonical URL by job_post_id")]
    async fn get_job(&self, input: Parameters<GetJobInput>) -> String {
        let Ok(Some(job)) = self.store.get_job_by_id(&input.0.job_post_id).await else {
            return json!({
                "error": "job not found",
                "job_post_id": input.0.job_post_id,
            })
            .to_string();
        };
        json!({
            "job_post_id": job.job_post_id,
            "title": job.title,
            "company": job.company_name,
            "location": job.location_name,
            "location_type": job.location_type,
            "url": job.absolute_url,
            "posted": job.first_published,
            "updated_at": job.updated_at,
        })
        .to_string()
    }

    /// Skill co-occurrence knowledge graph. Filter by category: language|framework|platform|domain.
    #[tool(description = "Skill co-occurrence graph — nodes (job_count) + edges (weight)")]
    async fn get_skill_graph(&self, input: Parameters<GetSkillGraphInput>) -> String {
        let min_weight = input.0.min_weight.unwrap_or(15);
        let Ok((mut nodes, mut edges)) = self.store.get_skill_graph(min_weight).await else {
            return "{}".into();
        };
        if let Some(cat) = &input.0.category {
            nodes.retain(|n| &n.category == cat);
            let names: std::collections::HashSet<_> =
                nodes.iter().map(|n| n.name.as_str()).collect();
            edges.retain(|e| {
                names.contains(e.source.as_str()) && names.contains(e.target.as_str())
            });
        }
        json!({
            "nodes": nodes.iter().map(|n| json!({"name":n.name,"category":n.category,"job_count":n.job_count})).collect::<Vec<_>>(),
            "edges": edges.iter().map(|e| json!({"source":e.source,"target":e.target,"weight":e.weight})).collect::<Vec<_>>(),
        })
        .to_string()
    }

    /// Crawl a Greenhouse or Lever board. CDC-gated — only writes on SHA256 change.
    /// Wires through task-state-machine FSM for retry safety.
    #[tool(description = "Crawl a job board (CDC-gated). Returns {changed, jobs, sha256, duration_ms}.")]
    async fn crawl_board(&self, input: Parameters<CrawlBoardInput>) -> String {
        let t0 = Instant::now();
        let board = &input.0.board;

        let platform = self
            .store
            .get_platform(board)
            .await
            .unwrap_or_else(|| "greenhouse".to_string());

        // FSM: upsert Pending task then claim it for this board specifically
        let task_id = match fsm::create_task(&self.store.pg, board).await {
            Ok(_) => match fsm::claim_board_task(&self.store.pg, board).await {
                Ok(Some(t)) => {
                    tracing::debug!(board, id=%t.id, "fsm: crawling");
                    Some(t.id)
                }
                Ok(None) => {
                    // Another process already has this board in Crawling/Enriching/Active
                    tracing::info!(board, "fsm: board already claimed, proceeding stateless");
                    None
                }
                Err(e) => {
                    tracing::warn!(board, "fsm claim_board_task: {e}");
                    None
                }
            },
            Err(e) => {
                tracing::warn!(board, "fsm create_task: {e}");
                None
            }
        };

        // Fetch board data
        let fetched = match crawler::fetch_board(&self.http, board, &platform).await {
            Ok(f) => f,
            Err(e) => {
                if let Some(id) = task_id {
                    let _ = fsm::mark_failed(&self.store.pg, id, &e.to_string()).await;
                }
                return json!({
                    "error": "fetch failed",
                    "board": board,
                    "detail": e.to_string(),
                })
                .to_string();
            }
        };
        let job_count = fetched.jobs.len();

        // CDC: compare pre-computed sha256 (not re-hashed)
        let cdc = match self
            .store
            .check_and_record_snapshot(board, &fetched.raw_sha256)
            .await
        {
            Ok(c) => c,
            Err(e) => {
                if let Some(id) = task_id {
                    let _ = fsm::mark_failed(&self.store.pg, id, &e.to_string()).await;
                }
                return json!({
                    "error": "cdc failed",
                    "detail": e.to_string(),
                })
                .to_string();
            }
        };

        // FSM: Crawling → Enriching (snapshot hash recorded)
        if let Some(id) = task_id {
            let _ = fsm::advance_to_enriching(&self.store.pg, id, &cdc.hash).await;
        }

        // Batch upsert (UNNEST, one round-trip)
        if cdc.changed {
            if let Err(e) = self.store.upsert_jobs(&fetched.jobs).await {
                tracing::error!(board, "upsert_jobs: {e}");
            }
        }

        // FSM: Enriching → Active
        if let Some(id) = task_id {
            let _ = fsm::advance_to_active(&self.store.pg, id).await;
        }

        let ms = t0.elapsed().as_millis() as i32;
        let _ = self
            .store
            .log_crawl(&durable_store::CrawlLog {
                board_token: board.clone(),
                snapshot_sha256: cdc.hash.clone(),
                changed: cdc.changed,
                job_count: job_count as i32,
                duration_ms: ms,
            })
            .await;

        json!({
            "board": board,
            "platform": platform,
            "changed": cdc.changed,
            "jobs": job_count,
            "sha256": &cdc.hash[..16],
            "duration_ms": ms,
        })
        .to_string()
    }
}

#[tool_handler(router = self.tool_router,
               name = "subagentjobs-mcp",
               version = "0.2.0",
               instructions = "Job board explorer: 7000+ jobs across 49 companies, skill graph, CDC crawler")]
impl ServerHandler for JobServer {}

pub async fn run(database_url: &str, redis_url: &str) -> Result<()> {
    let store = DurableStore::connect(database_url, redis_url).await?;
    // Ensure FSM table exists (idempotent DDL)
    fsm::ensure_table(&store.pg).await?;
    let running = JobServer::new(store)
        .serve((tokio::io::stdin(), tokio::io::stdout()))
        .await?;
    running.waiting().await?;
    Ok(())
}
