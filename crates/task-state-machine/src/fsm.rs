use anyhow::Result;
use sqlx::PgPool;
use uuid::Uuid;
use super::{CrawlTask, MAX_ATTEMPTS};

/// Create a task in Pending state for a board.
pub async fn create_task(pool: &PgPool, board_token: &str) -> Result<CrawlTask> {
    Ok(sqlx::query_as(
        "INSERT INTO crawl_task (id, board_token, state, attempts)
         VALUES ($1, $2, 'Pending', 0)
         ON CONFLICT (board_token) WHERE state NOT IN ('Active','CrawlFailed')
         DO UPDATE SET updated_at = NOW()
         RETURNING *"
    )
    .bind(Uuid::new_v7(uuid::Timestamp::now(uuid::NoContext)))
    .bind(board_token)
    .fetch_one(pool)
    .await?)
}

/// Atomically claim a Pending task → Crawling. Returns None if none available.
pub async fn claim_pending(pool: &PgPool) -> Result<Option<CrawlTask>> {
    Ok(sqlx::query_as(
        "UPDATE crawl_task SET state='Crawling', attempts=attempts+1, updated_at=NOW()
         WHERE id = (
           SELECT id FROM crawl_task
           WHERE state='Pending' AND attempts < $1
           ORDER BY created_at
           FOR UPDATE SKIP LOCKED
           LIMIT 1
         )
         RETURNING *"
    )
    .bind(MAX_ATTEMPTS)
    .fetch_optional(pool)
    .await?)
}

/// Mark Crawling → Enriching with the snapshot hash.
pub async fn advance_to_enriching(pool: &PgPool, id: Uuid, sha256: &str) -> Result<CrawlTask> {
    Ok(sqlx::query_as(
        "UPDATE crawl_task
         SET state='Enriching', snapshot_sha256=$1, error=NULL, updated_at=NOW()
         WHERE id=$2 AND state='Crawling'
         RETURNING *"
    )
    .bind(sha256).bind(id)
    .fetch_one(pool)
    .await?)
}

/// Mark Enriching → Active.
pub async fn advance_to_active(pool: &PgPool, id: Uuid) -> Result<CrawlTask> {
    Ok(sqlx::query_as(
        "UPDATE crawl_task SET state='Active', updated_at=NOW()
         WHERE id=$1 AND state='Enriching'
         RETURNING *"
    )
    .bind(id)
    .fetch_one(pool)
    .await?)
}

/// Mark any non-terminal state → CrawlFailed. Retries via claim_pending if attempts < MAX.
pub async fn mark_failed(pool: &PgPool, id: Uuid, error: &str) -> Result<CrawlTask> {
    Ok(sqlx::query_as(
        "UPDATE crawl_task
         SET state = CASE WHEN attempts >= $1 THEN 'CrawlFailed' ELSE 'Pending' END,
             error=$2, updated_at=NOW()
         WHERE id=$3
         RETURNING *"
    )
    .bind(MAX_ATTEMPTS).bind(error).bind(id)
    .fetch_one(pool)
    .await?)
}

/// DDL: create crawl_task table if not exists.
pub async fn ensure_table(pool: &PgPool) -> Result<()> {
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS crawl_task (
            id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            board_token     TEXT        NOT NULL,
            state           TEXT        NOT NULL DEFAULT 'Pending',
            attempts        INTEGER     NOT NULL DEFAULT 0,
            snapshot_sha256 TEXT,
            error           TEXT,
            created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            CONSTRAINT state_check CHECK (
                state IN ('Pending','Crawling','Enriching','Active','CrawlFailed','EnrichFailed')
            )
        );
        CREATE UNIQUE INDEX IF NOT EXISTS ux_crawl_task_board_active
            ON crawl_task(board_token) WHERE state NOT IN ('Active','CrawlFailed');"
    )
    .execute(pool)
    .await?;
    Ok(())
}
