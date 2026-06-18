//! subagentjobs-mcp — MCP server exposing job board data via rmcp.
//! Tools: search_jobs, get_job, get_skill_graph, crawl_board
//! Cache: Redis L2 (via durable-store) → Postgres L3
use clap::Parser;
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

mod server;
mod tools;
mod crawler;

#[derive(Parser)]
struct Cli {
    #[arg(env = "DATABASE_URL", long, default_value = "postgres://postgres:postgres@localhost:5432/subagentjobs")]
    database_url: String,
    #[arg(env = "REDIS_URL", long, default_value = "redis://localhost:6379")]
    redis_url: String,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(fmt::layer().json())
        .with(EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();
    server::run(&cli.database_url, &cli.redis_url).await
}
