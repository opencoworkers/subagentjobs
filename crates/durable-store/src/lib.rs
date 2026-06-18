//! durable-store: L2 Redis + L3 Postgres tiered cache with SHA256 CDC.
//! Uses runtime sqlx (not query! macros) so no DATABASE_URL at compile time.

use anyhow::Result;
use redis::{aio::ConnectionManager, AsyncCommands};
use sha2::{Digest, Sha256};
use sqlx::PgPool;

pub mod types;
pub use types::*;

const REDIS_JOB_TTL: u64 = 60;
const REDIS_GRAPH_TTL: u64 = 300;
const REDIS_SNAP_TTL: u64 = 3600;

pub struct DurableStore {
    pub pg: PgPool,
    pub redis: ConnectionManager,
}

impl DurableStore {
    pub async fn connect(database_url: &str, redis_url: &str) -> Result<Self> {
        let pg = PgPool::connect(database_url).await?;
        let client = redis::Client::open(redis_url)?;
        let redis = ConnectionManager::new(client).await?;
        Ok(Self { pg, redis })
    }

    pub fn sha256_hex(data: &[u8]) -> String {
        hex::encode(Sha256::digest(data))
    }

    /// Check if snapshot changed; record new hash in Redis + Postgres if so.
    pub async fn check_and_record_snapshot(
        &mut self, board: &str, data: &[u8],
    ) -> Result<CdcResult> {
        let new_hash = Self::sha256_hex(data);
        let key = format!("snap:{board}");
        let prev: Option<String> = self.redis.get(&key).await.unwrap_or(None);
        let changed = prev.as_deref() != Some(&new_hash);
        if changed {
            let _: () = self.redis.set_ex(&key, &new_hash, REDIS_SNAP_TTL).await?;
            sqlx::query(
                "UPDATE dim_board SET last_snapshot_sha256=$1, last_crawled_at=NOW() WHERE board_token=$2"
            )
            .bind(&new_hash)
            .bind(board)
            .execute(&self.pg)
            .await?;
        }
        Ok(CdcResult { changed, hash: new_hash })
    }

    /// L2→L3: Redis hit returns immediately; miss populates from Postgres.
    pub async fn get_jobs_for_board(
        &mut self, board: &str,
    ) -> Result<(Vec<JobRow>, CacheSource)> {
        let key = format!("jobs:{board}");
        if let Ok(raw) = self.redis.get::<_, String>(&key).await {
            if let Ok(jobs) = serde_json::from_str::<Vec<JobRow>>(&raw) {
                tracing::debug!(board, "redis hit");
                return Ok((jobs, CacheSource::Redis));
            }
        }
        let rows: Vec<JobRow> = sqlx::query_as(
            "SELECT job_post_id, title, location_name, location_type, absolute_url, \
             content_length, first_published, updated_at, office_count, is_prospect, \
             company_name, platform FROM fact_job_posting WHERE company_name=$1 ORDER BY title"
        )
        .bind(board)
        .fetch_all(&self.pg)
        .await?;
        let _: () = self.redis.set_ex(&key, serde_json::to_string(&rows)?, REDIS_JOB_TTL).await?;
        Ok((rows, CacheSource::Postgres))
    }

    /// Upsert batch; caller must call invalidate_board_cache after.
    pub async fn upsert_jobs(&self, jobs: &[JobRow]) -> Result<u64> {
        let mut n = 0u64;
        for j in jobs {
            sqlx::query(
                "INSERT INTO fact_job_posting \
                 (job_post_id,title,location_name,location_type,absolute_url,content_length,\
                  first_published,updated_at,office_count,is_prospect,company_name,platform) \
                 VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) \
                 ON CONFLICT(job_post_id) DO UPDATE SET \
                   title=EXCLUDED.title, updated_at=EXCLUDED.updated_at, \
                   content_length=EXCLUDED.content_length"
            )
            .bind(&j.job_post_id).bind(&j.title).bind(&j.location_name)
            .bind(&j.location_type).bind(&j.absolute_url).bind(j.content_length)
            .bind(&j.first_published).bind(&j.updated_at).bind(j.office_count)
            .bind(j.is_prospect).bind(&j.company_name).bind(&j.platform)
            .execute(&self.pg)
            .await?;
            n += 1;
        }
        Ok(n)
    }

    pub async fn invalidate_board_cache(&mut self, board: &str) -> Result<()> {
        let _: () = self.redis.del(format!("jobs:{board}")).await?;
        Ok(())
    }

    pub async fn log_crawl(&self, e: &CrawlLog) -> Result<()> {
        sqlx::query(
            "INSERT INTO crawl_log(board_token,snapshot_sha256,changed,job_count,duration_ms) \
             VALUES($1,$2,$3,$4,$5)"
        )
        .bind(&e.board_token).bind(&e.snapshot_sha256)
        .bind(e.changed).bind(e.job_count).bind(e.duration_ms)
        .execute(&self.pg)
        .await?;
        Ok(())
    }

    pub async fn get_skill_graph(
        &mut self, min_weight: i64,
    ) -> Result<(Vec<SkillNode>, Vec<SkillEdge>)> {
        let key = format!("graph:{min_weight}");
        if let Ok(raw) = self.redis.get::<_, String>(&key).await {
            if let Ok(v) = serde_json::from_str(&raw) { return Ok(v); }
        }
        let nodes: Vec<SkillNode> = sqlx::query_as(
            "SELECT s.name, s.category, COUNT(*)::bigint AS job_count \
             FROM bridge_job_skill b JOIN dim_skill s ON b.skill_key=s.skill_key \
             GROUP BY s.skill_key ORDER BY job_count DESC"
        )
        .fetch_all(&self.pg).await?;

        let edges: Vec<SkillEdge> = sqlx::query_as(
            "SELECT s1.name AS source, s2.name AS target, COUNT(*)::bigint AS weight \
             FROM bridge_job_skill a \
             JOIN bridge_job_skill b ON a.job_post_id=b.job_post_id AND a.skill_key<b.skill_key \
             JOIN dim_skill s1 ON a.skill_key=s1.skill_key \
             JOIN dim_skill s2 ON b.skill_key=s2.skill_key \
             GROUP BY a.skill_key,b.skill_key HAVING COUNT(*)>=$1 \
             ORDER BY weight DESC LIMIT 80"
        )
        .bind(min_weight)
        .fetch_all(&self.pg).await?;

        let _: () = self.redis.set_ex(&key, serde_json::to_string(&(&nodes,&edges))?, REDIS_GRAPH_TTL).await?;
        Ok((nodes, edges))
    }
}

pub mod migrate;
