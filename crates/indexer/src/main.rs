//! subagentjobs-indexer — vendor filesystem indexer.
//!
//! Walks vendor repos listed in `.vendors.toml`, extracts symbol ASTs,
//! and writes to fact_filesystem + dim_file_ast in Postgres.
//!
//! ## Usage
//!
//! ```
//! # Index all configured vendors
//! subagentjobs-indexer --all
//!
//! # Index one vendor
//! subagentjobs-indexer --vendor microsoft/pg_durable
//!
//! # Force re-parse even if SHA unchanged
//! subagentjobs-indexer --all --force
//! ```
//!
//! ## Environment
//!
//! DATABASE_URL — Postgres connection string (same as MCP server)
//!
//! ## Cross-platform
//!
//! Paths are normalised to forward-slash on all platforms.
//! Walker respects .gitignore on macOS, Linux, and Windows.

use anyhow::{Context, Result};
use clap::Parser;
use schema::vendor::{VendorConfig, VendorsConfig};
use std::path::PathBuf;
use tracing::{info, warn};

mod db;
mod parser;
mod walker;

// ── CLI ───────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "subagentjobs-indexer", about = "Index vendor repos into fact_filesystem + dim_file_ast")]
struct Cli {
    /// Index all vendors in .vendors.toml
    #[arg(long)]
    all: bool,

    /// Index a specific vendor (org/repo)
    #[arg(long)]
    vendor: Option<String>,

    /// Force re-parse even if file SHA hasn't changed
    #[arg(long)]
    force: bool,

    /// Path to .vendors.toml (default: repo root)
    #[arg(long, default_value = ".vendors.toml")]
    config: PathBuf,

    /// Root directory where vendors/ lives (default: current dir)
    #[arg(long, default_value = ".")]
    root: PathBuf,
}

// ── Entry point ───────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env()
            .add_directive("indexer=info".parse()?))
        .init();

    let cli = Cli::parse();

    let database_url = std::env::var("DATABASE_URL")
        .context("DATABASE_URL not set")?;

    let pg = sqlx::PgPool::connect(&database_url).await
        .context("connecting to Postgres")?;

    let config_text = std::fs::read_to_string(&cli.config)
        .with_context(|| format!("reading {:?}", cli.config))?;
    let config: VendorsConfig = toml::from_str(&config_text)
        .context("parsing .vendors.toml")?;

    let vendors_to_index: Vec<&VendorConfig> = if cli.all {
        config.vendor.iter().collect()
    } else if let Some(ref key) = cli.vendor {
        config.vendor.iter()
            .filter(|v| v.vendor_key() == *key)
            .collect()
    } else {
        eprintln!("Specify --all or --vendor org/repo");
        std::process::exit(1);
    };

    if vendors_to_index.is_empty() {
        warn!("No matching vendors found");
        return Ok(());
    }

    for vendor_config in vendors_to_index {
        let key = vendor_config.vendor_key();
        let repo_root = cli.root.join(vendor_config.local_path());

        if !repo_root.exists() {
            warn!("{key}: not cloned yet — run ./scripts/setup-vendors.sh");
            continue;
        }

        info!("{key}: walking {}", repo_root.display());
        let files = walker::walk_vendor(&repo_root, vendor_config)
            .with_context(|| format!("walking {key}"))?;

        let head_sha = walker::git_head_sha(&repo_root);
        info!("{key}: {} files found (HEAD {})", files.len(), head_sha.as_deref().unwrap_or("unknown"));

        let mut total = db::IndexStats::default();
        let seen_keys: Vec<String> = files.iter().map(|f| f.file_key.clone()).collect();

        for file in &files {
            match db::index_file(&pg, file).await {
                Ok(stats) => total += stats,
                Err(e)    => warn!("{}: {e:#}", file.file_key),
            }
        }

        // Soft-delete files removed from the repo since last run
        total.files_evicted = db::evict_missing(&pg, &key, &seen_keys).await
            .unwrap_or_else(|e| { warn!("evict_missing: {e:#}"); 0 });

        db::upsert_vendor(&pg, vendor_config, head_sha.as_deref(), files.len() as i32).await
            .with_context(|| format!("upserting vendor {key}"))?;

        info!(
            "{key}: indexed={} skipped={} symbols={} evicted={}",
            total.files_indexed, total.files_skipped,
            total.symbols_extracted, total.files_evicted
        );
    }

    Ok(())
}
