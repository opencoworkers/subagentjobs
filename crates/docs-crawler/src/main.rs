use anyhow::Result;
use clap::Parser;
use std::path::PathBuf;
use tracing_subscriber::{fmt, EnvFilter};

mod crawler;
mod downloader;
mod harvest;
mod llms_txt;
mod organizer;
mod sitemap;

#[derive(Parser)]
#[command(
    name = "docs-crawler",
    about = "Crawl Claude documentation sources into docs/{host}/…"
)]
struct Cli {
    /// Override target URLs (space-separated).  Defaults to all Claude doc sources.
    #[arg(long, num_args = 1.., value_delimiter = ' ')]
    targets: Vec<String>,

    /// Root directory for saved .md files.
    #[arg(long, default_value = "docs")]
    docs_root: PathBuf,

    /// In-process LRU harvest cache capacity (entries).
    #[arg(long, default_value_t = 512, env = "LRU_CAPACITY")]
    lru_capacity: usize,

    /// Path to the version-controlled LRU pre-warm file.
    #[arg(
        long,
        default_value = "crates/docs-crawler/.cache/mdx-lru.json",
        env = "MDX_CACHE_FILE"
    )]
    cache_file: PathBuf,

    /// Postgres connection URL.
    #[arg(long, env = "DATABASE_URL")]
    database_url: String,

    /// Redis connection URL.
    #[arg(long, env = "REDIS_URL", default_value = "redis://localhost:6379")]
    redis_url: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    fmt().with_env_filter(EnvFilter::from_default_env()).init();

    let cli = Cli::parse();

    let store =
        durable_store::DurableStore::connect(&cli.database_url, &cli.redis_url).await?;
    let mut harvester = harvest::Harvester::load_cache(&cli.cache_file, cli.lru_capacity)?;

    let owned: Vec<String>;
    let targets: Vec<&str> = if cli.targets.is_empty() {
        crawler::DEFAULT_TARGETS.to_vec()
    } else {
        owned = cli.targets;
        owned.iter().map(|s| s.as_str()).collect()
    };

    crawler::crawl(&targets, &store, &cli.docs_root, &mut harvester).await?;
    harvester.save_cache(&cli.cache_file)?;

    Ok(())
}
