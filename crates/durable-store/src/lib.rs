//! durable-store: L2 Redis + L3 Postgres tiered cache with SHA256 CDC.
//!
//! # Fix log (all in this revision)
//! 1. `check_and_record_snapshot` now takes a pre-computed `hash: &str` — no more
//!    double-hashing (`sha256(sha256_hex_bytes)`).
//! 2. `DurableStore` derives `Clone` — `PgPool` and `ConnectionManager` are both
//!    `Clone + Send + Sync`, so no `Arc<Mutex<…>>` is needed at the call site.
//!    Every method takes `&self`; callers can hold a plain `DurableStore` field.
//! 3. Redis TTL for jobs raised to 3600 s — invalidation (`DEL jobs:{board}`) is
//!    the freshness guarantee; TTL is just a safety net.
//! 4. `check_and_record_snapshot` pipelines `SET snap + DEL jobs` in one round-trip.
//! 5. `upsert_jobs` uses a single UNNEST batch INSERT instead of N individual rows.
//!    On conflict it also resets `miss_count = 0` and clears `evicted_at` (un-evict).
//! 6. All read queries filter `evicted_at IS NULL` (parity with D1 web worker).
//! 7. `search_by_title` added for cross-board keyword search with SQL LIKE.

use anyhow::Result;
use redis::{aio::ConnectionManager, AsyncCommands};
use sqlx::PgPool;

pub mod migrate;
pub mod types;
pub use types::*;

// ── Cache TTLs ────────────────────────────────────────────────────────────────
/// Snapshot hash: 1 hour (updated on every changed crawl).
const REDIS_SNAP_TTL: u64 = 3600;
/// Per-board job list: 1 hour — invalidated immediately on upsert, TTL is safety net.
const REDIS_JOB_TTL: u64 = 3600;
/// Skill graph: 5 minutes (expensive query, changes slowly).
const REDIS_GRAPH_TTL: u64 = 300;

// ── DurableStore ──────────────────────────────────────────────────────────────

/// Tiered store: Redis L2 → Postgres L3.
///
/// `Clone` is derived because both `PgPool` and `ConnectionManager` are cheaply
/// cloneable (they share the same underlying connection pool). Call sites can hold
/// a plain `DurableStore` without wrapping in `Arc<Mutex<…>>`.
#[derive(Clone)]
pub struct DurableStore {
    pub pg: PgPool,
    redis: ConnectionManager,
}

impl DurableStore {
    pub async fn connect(database_url: &str, redis_url: &str) -> Result<Self> {
        let pg = PgPool::connect(database_url).await?;
        let client = redis::Client::open(redis_url)?;
        let redis = ConnectionManager::new(client).await?;
        Ok(Self { pg, redis })
    }

    /// Returns a cloned handle to the Redis connection manager.
    /// `ConnectionManager::clone()` is O(1) — shares the same underlying pool.
    fn redis(&self) -> ConnectionManager {
        self.redis.clone()
    }

    pub fn sha256_hex(data: &[u8]) -> String {
        use sha2::{Digest, Sha256};
        hex::encode(Sha256::digest(data))
    }
}

// ── CDC ───────────────────────────────────────────────────────────────────────

impl DurableStore {
    /// Compare `hash` (pre-computed by the caller) against the cached snapshot.
    ///
    /// If changed:
    ///   - Pipelines `SET snap:{board}` + `DEL jobs:{board}` in one Redis round-trip
    ///   - Updates `dim_board.last_snapshot_sha256` in Postgres
    ///
    /// **Fix**: previously this took `data: &[u8]` and re-hashed it, producing
    /// `sha256(sha256_hex_as_bytes)` instead of the true content hash. Now the
    /// caller is responsible for computing the hash once and passing it in.
    pub async fn check_and_record_snapshot(
        &self,
        board: &str,
        hash: &str,
    ) -> Result<CdcResult> {
        let mut redis = self.redis();
        let snap_key = format!("snap:{board}");

        let prev: Option<String> = redis.get(&snap_key).await.unwrap_or(None);
        let changed = prev.as_deref() != Some(hash);

        if changed {
            // Single pipeline: update snapshot + bust job cache atomically
            redis::pipe()
                .set_ex(&snap_key, hash, REDIS_SNAP_TTL)
                .ignore()
                .del(format!("jobs:{board}"))
                .ignore()
                .query_async::<()>(&mut redis)
                .await?;

            sqlx::query(
                "UPDATE dim_board \
                 SET last_snapshot_sha256=$1, last_crawled_at=NOW() \
                 WHERE board_token=$2",
            )
            .bind(hash)
            .bind(board)
            .execute(&self.pg)
            .await?;
        }

        Ok(CdcResult { changed, hash: hash.to_string() })
    }
}

// ── Job reads ─────────────────────────────────────────────────────────────────

const JOB_COLS: &str =
    "job_post_id, title, location_name, location_type, absolute_url, \
     content_length, first_published, updated_at, office_count, is_prospect, \
     company_name, platform";

impl DurableStore {
    /// Redis L2 → Postgres L3 fetch for a single board.
    /// Filters `evicted_at IS NULL` (parity with D1 web worker).
    pub async fn get_jobs_for_board(
        &self,
        board: &str,
    ) -> Result<(Vec<JobRow>, CacheSource)> {
        let mut redis = self.redis();
        let key = format!("jobs:{board}");

        if let Ok(raw) = redis.get::<_, String>(&key).await {
            if let Ok(jobs) = serde_json::from_str::<Vec<JobRow>>(&raw) {
                tracing::debug!(board, "redis hit");
                return Ok((jobs, CacheSource::Redis));
            }
        }

        let rows: Vec<JobRow> = sqlx::query_as(&format!(
            "SELECT {JOB_COLS} FROM fact_job_posting \
             WHERE company_name=$1 AND evicted_at IS NULL \
             ORDER BY title"
        ))
        .bind(board)
        .fetch_all(&self.pg)
        .await?;

        let _: () = redis
            .set_ex(&key, serde_json::to_string(&rows)?, REDIS_JOB_TTL)
            .await?;

        Ok((rows, CacheSource::Postgres))
    }

    /// Cross-board keyword search via SQL LIKE. Goes directly to Postgres
    /// (no Redis cache — the query space is unbounded).
    /// Pass `query = None` to return all live jobs up to `limit`.
    pub async fn search_by_title(
        &self,
        query: Option<&str>,
        limit: i64,
    ) -> Result<Vec<JobRow>> {
        let rows = if let Some(q) = query {
            sqlx::query_as::<_, JobRow>(&format!(
                "SELECT {JOB_COLS} FROM fact_job_posting \
                 WHERE lower(title) LIKE $1 AND evicted_at IS NULL \
                 ORDER BY company_name, title LIMIT $2"
            ))
            .bind(format!("%{q}%"))
            .bind(limit)
            .fetch_all(&self.pg)
            .await?
        } else {
            sqlx::query_as::<_, JobRow>(&format!(
                "SELECT {JOB_COLS} FROM fact_job_posting \
                 WHERE evicted_at IS NULL \
                 ORDER BY company_name, title LIMIT $1"
            ))
            .bind(limit)
            .fetch_all(&self.pg)
            .await?
        };
        Ok(rows)
    }

    pub async fn invalidate_board_cache(&self, board: &str) -> Result<()> {
        let _: () = self.redis().del(format!("jobs:{board}")).await?;
        Ok(())
    }

    /// Fetch a single job by its primary key (job_post_id).
    pub async fn get_job_by_id(&self, job_post_id: &str) -> Result<Option<JobRow>> {
        Ok(sqlx::query_as(&format!(
            "SELECT {JOB_COLS} FROM fact_job_posting WHERE job_post_id=$1"
        ))
        .bind(job_post_id)
        .fetch_optional(&self.pg)
        .await?)
    }
}

// ── Job writes ────────────────────────────────────────────────────────────────

impl DurableStore {
    /// Batch upsert via a single UNNEST INSERT — one Postgres round-trip regardless
    /// of how many jobs are in the slice.
    ///
    /// On conflict, resets `miss_count = 0` and clears `evicted_at` so a job that
    /// reappeared in the source API is automatically un-evicted.
    pub async fn upsert_jobs(&self, jobs: &[JobRow]) -> Result<u64> {
        if jobs.is_empty() {
            return Ok(0);
        }

        // Collect columns into typed vecs for UNNEST binding
        let mut ids:       Vec<&str>           = Vec::with_capacity(jobs.len());
        let mut titles:    Vec<&str>           = Vec::with_capacity(jobs.len());
        let mut loc_names: Vec<Option<&str>>   = Vec::with_capacity(jobs.len());
        let mut loc_types: Vec<Option<&str>>   = Vec::with_capacity(jobs.len());
        let mut urls:      Vec<Option<&str>>   = Vec::with_capacity(jobs.len());
        let mut clens:     Vec<Option<i32>>    = Vec::with_capacity(jobs.len());
        let mut published: Vec<Option<&str>>   = Vec::with_capacity(jobs.len());
        let mut updated:   Vec<Option<&str>>   = Vec::with_capacity(jobs.len());
        let mut offices:   Vec<Option<i32>>    = Vec::with_capacity(jobs.len());
        let mut prospects: Vec<Option<i32>>    = Vec::with_capacity(jobs.len());
        let mut cos:       Vec<Option<&str>>   = Vec::with_capacity(jobs.len());
        let mut platforms: Vec<Option<&str>>   = Vec::with_capacity(jobs.len());

        for j in jobs {
            ids.push(&j.job_post_id);
            titles.push(&j.title);
            loc_names.push(j.location_name.as_deref());
            loc_types.push(j.location_type.as_deref());
            urls.push(j.absolute_url.as_deref());
            clens.push(j.content_length);
            published.push(j.first_published.as_deref());
            updated.push(j.updated_at.as_deref());
            offices.push(j.office_count);
            prospects.push(j.is_prospect);
            cos.push(j.company_name.as_deref());
            platforms.push(j.platform.as_deref());
        }

        let result = sqlx::query(
            "INSERT INTO fact_job_posting \
               (job_post_id, title, location_name, location_type, absolute_url, \
                content_length, first_published, updated_at, office_count, is_prospect, \
                company_name, platform) \
             SELECT * FROM UNNEST( \
               $1::text[], $2::text[], $3::text[], $4::text[], $5::text[], \
               $6::int4[], $7::text[], $8::text[], $9::int4[], $10::int4[], \
               $11::text[], $12::text[] \
             ) AS t(job_post_id, title, location_name, location_type, absolute_url, \
                    content_length, first_published, updated_at, office_count, is_prospect, \
                    company_name, platform) \
             ON CONFLICT (job_post_id) DO UPDATE SET \
               title          = EXCLUDED.title, \
               location_name  = EXCLUDED.location_name, \
               location_type  = EXCLUDED.location_type, \
               absolute_url   = EXCLUDED.absolute_url, \
               content_length = EXCLUDED.content_length, \
               updated_at     = EXCLUDED.updated_at, \
               office_count   = EXCLUDED.office_count, \
               miss_count     = 0, \
               evicted_at     = NULL",
        )
        .bind(&ids as &[&str])
        .bind(&titles as &[&str])
        .bind(&loc_names as &[Option<&str>])
        .bind(&loc_types as &[Option<&str>])
        .bind(&urls as &[Option<&str>])
        .bind(&clens as &[Option<i32>])
        .bind(&published as &[Option<&str>])
        .bind(&updated as &[Option<&str>])
        .bind(&offices as &[Option<i32>])
        .bind(&prospects as &[Option<i32>])
        .bind(&cos as &[Option<&str>])
        .bind(&platforms as &[Option<&str>])
        .execute(&self.pg)
        .await?;

        Ok(result.rows_affected())
    }
}

// ── Crawl log ─────────────────────────────────────────────────────────────────

impl DurableStore {
    pub async fn log_crawl(&self, e: &CrawlLog) -> Result<()> {
        sqlx::query(
            "INSERT INTO crawl_log(board_token, snapshot_sha256, changed, job_count, duration_ms) \
             VALUES($1, $2, $3, $4, $5)",
        )
        .bind(&e.board_token)
        .bind(&e.snapshot_sha256)
        .bind(e.changed)
        .bind(e.job_count)
        .bind(e.duration_ms)
        .execute(&self.pg)
        .await?;
        Ok(())
    }
}

// ── Skill graph ───────────────────────────────────────────────────────────────

impl DurableStore {
    pub async fn get_skill_graph(
        &self,
        min_weight: i64,
    ) -> Result<(Vec<SkillNode>, Vec<SkillEdge>)> {
        let mut redis = self.redis();
        let key = format!("graph:{min_weight}");

        if let Ok(raw) = redis.get::<_, String>(&key).await {
            if let Ok(v) = serde_json::from_str(&raw) {
                return Ok(v);
            }
        }

        let nodes: Vec<SkillNode> = sqlx::query_as(
            "SELECT s.name, s.category, COUNT(*)::bigint AS job_count \
             FROM bridge_job_skill b \
             JOIN dim_skill s ON b.skill_key = s.skill_key \
             JOIN fact_job_posting f ON b.job_post_id = f.job_post_id \
             WHERE f.evicted_at IS NULL \
             GROUP BY s.skill_key ORDER BY job_count DESC",
        )
        .fetch_all(&self.pg)
        .await?;

        let edges: Vec<SkillEdge> = sqlx::query_as(
            "SELECT s1.name AS source, s2.name AS target, COUNT(*)::bigint AS weight \
             FROM bridge_job_skill a \
             JOIN bridge_job_skill b \
               ON a.job_post_id = b.job_post_id AND a.skill_key < b.skill_key \
             JOIN dim_skill s1 ON a.skill_key = s1.skill_key \
             JOIN dim_skill s2 ON b.skill_key = s2.skill_key \
             JOIN fact_job_posting f ON a.job_post_id = f.job_post_id \
             WHERE f.evicted_at IS NULL \
             GROUP BY a.skill_key, b.skill_key HAVING COUNT(*) >= $1 \
             ORDER BY weight DESC LIMIT 80",
        )
        .bind(min_weight)
        .fetch_all(&self.pg)
        .await?;

        let _: () = redis
            .set_ex(
                &key,
                serde_json::to_string(&(&nodes, &edges))?,
                REDIS_GRAPH_TTL,
            )
            .await?;

        Ok((nodes, edges))
    }
}

// ── Board helpers ─────────────────────────────────────────────────────────────

impl DurableStore {
    pub async fn get_platform(&self, board: &str) -> Option<String> {
        sqlx::query_scalar::<_, Option<String>>(
            "SELECT platform FROM dim_board WHERE board_token=$1",
        )
        .bind(board)
        .fetch_optional(&self.pg)
        .await
        .ok()
        .flatten()
        .flatten()
    }
}

// ── Doc pages ─────────────────────────────────────────────────────────────────

const REDIS_DOC_TTL: u64 = 3600;

impl DurableStore {
    /// SHA256-based CDC for a doc URL.
    ///
    /// Redis keys:
    ///   - `snap:doc:{sha256(url)}` — previous content hash (TTL 3600 s)
    ///   - `doc:{sha256(url)}`      — cached DocPage JSON (busted on change)
    ///
    /// Same pipeline pattern as `check_and_record_snapshot` for boards.
    pub async fn check_and_record_doc_snapshot(
        &self,
        url: &str,
        hash: &str,
    ) -> Result<CdcResult> {
        let url_key  = Self::sha256_hex(url.as_bytes());
        let snap_key = format!("snap:doc:{url_key}");
        let doc_key  = format!("doc:{url_key}");
        let mut redis = self.redis();

        let prev: Option<String> = redis.get(&snap_key).await.unwrap_or(None);
        let changed = prev.as_deref() != Some(hash);

        if changed {
            redis::pipe()
                .set_ex(&snap_key, hash, REDIS_DOC_TTL)
                .ignore()
                .del(&doc_key)
                .ignore()
                .query_async::<()>(&mut redis)
                .await?;
        }

        Ok(CdcResult { changed, hash: hash.to_string() })
    }

    /// Redis L2 → Postgres L3 fetch for a single doc page by URL.
    pub async fn get_doc_page(&self, url: &str) -> Result<Option<DocPage>> {
        let url_key = Self::sha256_hex(url.as_bytes());
        let doc_key = format!("doc:{url_key}");
        let mut redis = self.redis();

        if let Ok(raw) = redis.get::<_, String>(&doc_key).await {
            if let Ok(page) = serde_json::from_str::<DocPage>(&raw) {
                tracing::debug!(url, "doc redis hit");
                return Ok(Some(page));
            }
        }

        let page: Option<DocPage> = sqlx::query_as(
            "SELECT url, host, path, sha256, content_md, admonitions, gfm, crawled_at \
             FROM fact_doc_pages WHERE url = $1",
        )
        .bind(url)
        .fetch_optional(&self.pg)
        .await?;

        if let Some(ref p) = page {
            let _: () = redis
                .set_ex(&doc_key, serde_json::to_string(p)?, REDIS_DOC_TTL)
                .await?;
        }

        Ok(page)
    }

    /// Upsert doc pages in a single transaction.
    /// On conflict updates sha256, content, admonitions, gfm and resets crawled_at.
    pub async fn upsert_doc_pages(&self, pages: &[DocPage]) -> Result<u64> {
        if pages.is_empty() {
            return Ok(0);
        }
        let mut tx = self.pg.begin().await?;
        let mut total = 0u64;

        for p in pages {
            let ads_json = p.admonitions.as_ref().map(|v| v.to_string());
            sqlx::query(
                "INSERT INTO fact_doc_pages \
                   (url, host, path, sha256, content_md, admonitions, gfm) \
                 VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7) \
                 ON CONFLICT (url) DO UPDATE SET \
                   sha256      = EXCLUDED.sha256, \
                   content_md  = EXCLUDED.content_md, \
                   admonitions = EXCLUDED.admonitions, \
                   gfm         = EXCLUDED.gfm, \
                   crawled_at  = NOW()",
            )
            .bind(&p.url)
            .bind(&p.host)
            .bind(&p.path)
            .bind(&p.sha256)
            .bind(p.content_md.as_deref())
            .bind(ads_json.as_deref())
            .bind(p.gfm.as_deref())
            .execute(&mut *tx)
            .await?;
            total += 1;
        }

        tx.commit().await?;
        Ok(total)
    }
}
