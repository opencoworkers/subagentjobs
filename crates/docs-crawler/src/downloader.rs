use anyhow::Result;
use durable_store::{DocPage, DurableStore};
use tracing::{debug, warn};
use url::Url;

use crate::organizer::url_to_path;

pub struct Downloader {
    client: reqwest::Client,
}

impl Downloader {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::builder()
                .user_agent("subagentjobs-docs-crawler/1.0 (+https://subagentjobs.com)")
                .build()
                .expect("reqwest client"),
        }
    }

    /// Fetch `url`, trying the `.md` variant first if the URL doesn't already
    /// end in `.md`.  Returns `None` when the page is unchanged (CDC check via
    /// `DurableStore.check_and_record_doc_snapshot`).
    pub async fn fetch(&self, url: &str, store: &DurableStore) -> Result<Option<DocPage>> {
        let md_url = if url.ends_with(".md") {
            url.to_string()
        } else {
            format!("{url}.md")
        };

        let content = match self.try_fetch(&md_url).await {
            Ok(c) => c,
            Err(_) => match self.try_fetch(url).await {
                Ok(c) => c,
                Err(e) => {
                    warn!(url, "fetch failed: {e}");
                    return Ok(None);
                }
            },
        };

        let sha256 = DurableStore::sha256_hex(content.as_bytes());
        let cdc = store.check_and_record_doc_snapshot(url, &sha256).await?;
        if !cdc.changed {
            debug!(url, "unchanged — skipping");
            return Ok(None);
        }

        let parsed = Url::parse(url)?;
        let host = parsed.host_str().unwrap_or("unknown").to_string();
        let path = url_to_path(url)?.to_string_lossy().into_owned();

        Ok(Some(DocPage {
            url: url.to_string(),
            host,
            path,
            sha256,
            content_md: Some(content),
            admonitions: None, // populated by Harvester
            gfm: None,
            crawled_at: None,
        }))
    }

    async fn try_fetch(&self, url: &str) -> Result<String> {
        let resp = self.client.get(url).send().await?;
        if !resp.status().is_success() {
            anyhow::bail!("HTTP {}", resp.status());
        }
        Ok(resp.text().await?)
    }
}
