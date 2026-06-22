use anyhow::Result;
use durable_store::DurableStore;
use futures::stream::{self, StreamExt};
use std::path::PathBuf;
use tracing::{error, info, warn};

use crate::{downloader::Downloader, harvest::Harvester, llms_txt, organizer, sitemap};

/// Default Claude documentation sources.
pub const DEFAULT_TARGETS: &[&str] = &[
    "https://code.claude.com/docs/llms.txt",
    "https://code.claude.com/sitemap.xml",
    "https://platform.claude.com/llms.txt",
    "https://platform.claude.com/sitemap.xml",
    "https://support.claude.com/sitemap.xml",
    "https://claude.com/sitemap.xml",
    "https://claude.com/docs/llms.txt",
];

/// Crawl all `targets`, writing `.md` files under `docs_root` and upserting
/// into `fact_doc_pages` via `store`.  `harvester` provides in-process LRU
/// caching of MDX extraction results.
pub async fn crawl(
    targets: &[&str],
    store: &DurableStore,
    docs_root: &PathBuf,
    harvester: &mut Harvester,
) -> Result<()> {
    let client = reqwest::Client::builder()
        .user_agent("subagentjobs-docs-crawler/1.0")
        .build()?;
    let downloader = Downloader::new();

    // Phase 1 — collect all page URLs from every target
    let mut all_urls: Vec<String> = Vec::new();

    for target in targets {
        info!(target, "fetching target");
        let body = match client.get(*target).send().await {
            Ok(r) if r.status().is_success() => r.text().await.unwrap_or_default(),
            Ok(r) => {
                warn!(target, status = %r.status(), "target returned non-2xx");
                continue;
            }
            Err(e) => {
                warn!(target, "target unreachable: {e}");
                continue;
            }
        };

        if target.ends_with("llms.txt") {
            let urls = llms_txt::parse_llms_txt(&body);
            info!(target, count = urls.len(), "parsed llms.txt");
            all_urls.extend(urls);
        } else {
            let (page_urls, ref_urls) = sitemap::parse_sitemap(&body);
            info!(
                target,
                page_count = page_urls.len(),
                ref_count = ref_urls.len(),
                "parsed sitemap"
            );
            // Recursively resolve nested sitemapindex entries
            for ref_url in ref_urls {
                match client.get(&ref_url).send().await {
                    Ok(r) if r.status().is_success() => {
                        if let Ok(text) = r.text().await {
                            let (sub_urls, _) = sitemap::parse_sitemap(&text);
                            all_urls.extend(sub_urls);
                        }
                    }
                    _ => warn!(ref_url, "nested sitemap unreachable"),
                }
            }
            all_urls.extend(page_urls);
        }
    }

    all_urls.sort();
    all_urls.dedup();
    info!(total = all_urls.len(), "unique URLs to process");

    // Phase 2 — fetch + CDC check (5 concurrent)
    let fetch_results: Vec<_> = stream::iter(all_urls.iter())
        .map(|url| {
            let store = store.clone();
            let dl = &downloader;
            async move { dl.fetch(url, &store).await }
        })
        .buffer_unordered(5)
        .collect()
        .await;

    // Phase 3 — harvest MDX + write files
    let mut pages = Vec::new();
    for (url, result) in all_urls.iter().zip(fetch_results) {
        match result {
            Ok(Some(mut page)) => {
                if let Some(ref content) = page.content_md {
                    let hr = harvester.harvest(url, content, &page.sha256);
                    page.admonitions =
                        serde_json::to_value(&hr.admonitions).ok();
                    page.gfm = Some(hr.gfm.clone());

                    // Write converted .md to docs/{host}/{path}
                    if let Ok(rel) = organizer::url_to_path(url) {
                        let file_path = docs_root.join(&rel);
                        if let Some(parent) = file_path.parent() {
                            let _ = std::fs::create_dir_all(parent);
                        }
                        let _ = std::fs::write(&file_path, hr.gfm.as_bytes());
                    }
                }
                pages.push(page);
            }
            Ok(None) => {} // unchanged — skip
            Err(e) => error!(url, "error: {e}"),
        }
    }

    // Phase 4 — batch upsert
    if !pages.is_empty() {
        let count = store.upsert_doc_pages(&pages).await?;
        info!(count, "doc pages upserted");
    }

    Ok(())
}
