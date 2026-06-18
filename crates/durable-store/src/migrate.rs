//! Run Postgres migrations from the embedded SQL files.
use anyhow::Result;
use sqlx::PgPool;

/// Idempotent — safe to call on every startup.
pub async fn run(pool: &PgPool) -> Result<()> {
    let schema = include_str!("../migrations/postgres/001_schema.sql");
    let indexes = include_str!("../migrations/postgres/002_indexes.sql");
    sqlx::raw_sql(schema).execute(pool).await?;
    sqlx::raw_sql(indexes).execute(pool).await?;
    tracing::info!("migrations applied");
    Ok(())
}
