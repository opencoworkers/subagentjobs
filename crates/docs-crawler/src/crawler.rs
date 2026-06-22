use anyhow::Result;
use durable_store::DurableStore;
use futures::stream::{self, StreamExt};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
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

/// Crawl all `targets`.
///
/// When `store` is `Some`, unchanged pages are skipped (SHA256 CDC) and
/// results are upserted into `fact_doc_pages`.  When `store` is `None`
/// (files-only mode), every reachable page is fetched and written to
/// `docs_root` with no database operations.
pub async fn crawl(
    targets: &[&str],
    store: Option<DurableStore>,
    docs_root: &PathBuf,
    harvester: &mut Harvester,
) -> Result<()> {
    let client = reqwest::Client::builder()
        .user_agent("subagentjobs-docs-crawler/1.0")
        .timeout(std::time::Duration::from_secs(15))
        .build()?;
    let downloader = Arc::new(Downloader::new());

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
    let total = all_urls.len();
    info!(total, "unique URLs to process");

    // Phase 2+3 — fetch, harvest, and write files concurrently.
    // Results are processed as they arrive (no collect() stall).
    let store_arc = store.map(Arc::new);
    let pages: Arc<Mutex<Vec<durable_store::DocPage>>> = Arc::new(Mutex::new(Vec::new()));
    let harvester_arc: Arc<Mutex<&mut Harvester>> = Arc::new(Mutex::new(harvester));
    let docs_root = Arc::new(docs_root.clone());
    let written = Arc::new(std::sync::atomic::AtomicUsize::new(0));

    stream::iter(all_urls.into_iter())
        .map(|url| {
            let store_ref = store_arc.clone();
            let dl = downloader.clone();
            async move {
                let result = dl.fetch(&url, store_ref.as_deref()).await;
                (url, result)
            }
        })
        .buffer_unordered(30)
        .for_each(|(url, result)| {
            let pages = pages.clone();
            let harvester_arc = harvester_arc.clone();
            let docs_root = docs_root.clone();
            let written = written.clone();
            async move {
                match result {
                    Ok(Some(mut page)) => {
                        if let Some(ref content) = page.content_md.clone() {
                            let sha256 = page.sha256.clone();
                            let (hr_ads, hr_gfm) = {
                                let mut h = harvester_arc.lock().unwrap();
                                let hr = h.harvest(&url, content, &sha256);
                                (hr.admonitions.clone(), hr.gfm.clone())
                            };
                            page.admonitions = serde_json::to_value(&hr_ads).ok();
                            page.gfm = Some(hr_gfm.clone());

                            if let Ok(rel) = organizer::url_to_path(&url) {
                                let file_path = docs_root.join(&rel);
                                if let Some(parent) = file_path.parent() {
                                    let _ = std::fs::create_dir_all(parent);
                                }
                                let _ = std::fs::write(&file_path, hr_gfm.as_bytes());
                                let n = written.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                                if n % 50 == 0 {
                                    info!(written = n + 1, "progress");
                                }
                            }
                        }
                        pages.lock().unwrap().push(page);
                    }
                    Ok(None) => {}
                    Err(e) => error!(url, "error: {e}"),
                }
            }
        })
        .await;

    let pages = Arc::try_unwrap(pages).unwrap().into_inner().unwrap();
    let total_written = written.load(std::sync::atomic::Ordering::Relaxed);
    info!(total_written, total, "crawl complete");

    // Phase 4 — batch upsert (skipped in files-only mode)
    if let Some(s) = store_arc {
        let s = Arc::try_unwrap(s).unwrap_or_else(|a| (*a).clone());
        if !pages.is_empty() {
            let count = s.upsert_doc_pages(&pages).await?;
            info!(count, "doc pages upserted");
        }
    } else {
        info!(count = pages.len(), "files-only: skipped DB upsert");
    }

    Ok(())
}


