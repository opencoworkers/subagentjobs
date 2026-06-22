use anyhow::Result;
use durable_store::{Admonition, CachedLru, HarvestResult};
use lru::LruCache;
use once_cell::sync::Lazy;
use regex::Regex;
use std::fs;
use std::num::NonZeroUsize;
use std::path::Path;

// ── MDX regex patterns ────────────────────────────────────────────────────────

static TIP_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<Tip>(.*?)</Tip>").unwrap());
static NOTE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<Note>(.*?)</Note>").unwrap());
static WARNING_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<Warning>(.*?)</Warning>").unwrap());
static CAUTION_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?s)<Caution>(.*?)</Caution>").unwrap());
static STEP_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<Step title="([^"]*)">(.*?)</Step>"#).unwrap());
static TAB_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r#"(?s)<Tab title="([^"]*)">(.*?)</Tab>"#).unwrap());

// ── Extraction ────────────────────────────────────────────────────────────────

/// Extract all MDX admonition components from a document.
pub fn extract_admonitions(content: &str) -> Vec<Admonition> {
    let mut ads = Vec::new();
    for cap in TIP_RE.captures_iter(content) {
        ads.push(Admonition::Tip { content: cap[1].trim().to_string() });
    }
    for cap in NOTE_RE.captures_iter(content) {
        ads.push(Admonition::Note { content: cap[1].trim().to_string() });
    }
    for cap in WARNING_RE.captures_iter(content) {
        ads.push(Admonition::Warning { content: cap[1].trim().to_string() });
    }
    for cap in CAUTION_RE.captures_iter(content) {
        ads.push(Admonition::Caution { content: cap[1].trim().to_string() });
    }
    for cap in STEP_RE.captures_iter(content) {
        ads.push(Admonition::Step {
            title: cap[1].trim().to_string(),
            body: cap[2].trim().to_string(),
        });
    }
    for cap in TAB_RE.captures_iter(content) {
        ads.push(Admonition::Tab {
            title: cap[1].trim().to_string(),
            body: cap[2].trim().to_string(),
        });
    }
    ads
}

/// Replace MDX component tags with GitHub-Flavored Markdown callout blocks.
pub fn convert_to_gfm(content: &str) -> String {
    let mut out = content.to_string();
    out = TIP_RE
        .replace_all(&out, |caps: &regex::Captures| {
            let body = caps[1].trim().replace('\n', "\n> ");
            format!("> [!TIP]\n> {body}")
        })
        .into_owned();
    out = NOTE_RE
        .replace_all(&out, |caps: &regex::Captures| {
            let body = caps[1].trim().replace('\n', "\n> ");
            format!("> [!NOTE]\n> {body}")
        })
        .into_owned();
    out = WARNING_RE
        .replace_all(&out, |caps: &regex::Captures| {
            let body = caps[1].trim().replace('\n', "\n> ");
            format!("> [!WARNING]\n> {body}")
        })
        .into_owned();
    out = CAUTION_RE
        .replace_all(&out, |caps: &regex::Captures| {
            let body = caps[1].trim().replace('\n', "\n> ");
            format!("> [!CAUTION]\n> {body}")
        })
        .into_owned();
    out = STEP_RE
        .replace_all(&out, |caps: &regex::Captures| {
            format!("**{}**\n\n{}", caps[1].trim(), caps[2].trim())
        })
        .into_owned();
    out = TAB_RE
        .replace_all(&out, |caps: &regex::Captures| {
            format!("#### {}\n\n{}", caps[1].trim(), caps[2].trim())
        })
        .into_owned();
    out
}

// ── Harvester ─────────────────────────────────────────────────────────────────

/// In-process LRU cache for MDX harvest results.
///
/// Backed by `.cache/mdx-lru.json` (version-controlled) for cross-session
/// pre-warming: `git pull` gives every developer and agent session a warm cache.
pub struct Harvester {
    cache: LruCache<String, HarvestResult>,
}

impl Harvester {
    pub fn new(capacity: usize) -> Self {
        let cap =
            NonZeroUsize::new(capacity).unwrap_or_else(|| NonZeroUsize::new(512).unwrap());
        Self { cache: LruCache::new(cap) }
    }

    /// Return a `HarvestResult` for `url`.  Hits the LRU cache first; only
    /// re-parses if the content SHA256 has changed.
    pub fn harvest(&mut self, url: &str, content: &str, sha256: &str) -> HarvestResult {
        if let Some(cached) = self.cache.get(url) {
            if cached.sha256 == sha256 {
                return cached.clone();
            }
        }

        let admonitions = extract_admonitions(content);
        let gfm = convert_to_gfm(content);
        let result = HarvestResult {
            url: url.to_string(),
            sha256: sha256.to_string(),
            admonitions,
            gfm,
        };
        self.cache.put(url.to_string(), result.clone());
        result
    }

    /// Persist LRU state to `path` as JSON.
    pub fn save_cache(&self, path: &Path) -> Result<()> {
        // iter() returns MRU→LRU; reverse so file is LRU→MRU for sequential put restore.
        let entries: Vec<(String, HarvestResult)> = self
            .cache
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();

        let cached = CachedLru { version: 1, capacity: self.cache.cap().get(), entries };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, serde_json::to_string_pretty(&cached)?)?;
        Ok(())
    }

    /// Load LRU state from `path` (if it exists), otherwise return empty cache.
    pub fn load_cache(path: &Path, capacity: usize) -> Result<Self> {
        let mut harvester = Self::new(capacity);
        if path.exists() {
            let json = fs::read_to_string(path)?;
            let cached: CachedLru = serde_json::from_str(&json)?;
            for (k, v) in cached.entries {
                harvester.cache.put(k, v);
            }
        }
        Ok(harvester)
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tip_extraction() {
        let content = "<Tip>Use Option+K to insert an @-mention reference.</Tip>";
        let ads = extract_admonitions(content);
        assert_eq!(ads.len(), 1);
        match &ads[0] {
            Admonition::Tip { content } => assert!(content.contains("Option+K")),
            _ => panic!("expected Tip"),
        }
    }

    #[test]
    fn test_note_extraction() {
        let content = "<Note>Restart VS Code after installation.</Note>";
        let ads = extract_admonitions(content);
        assert_eq!(ads.len(), 1);
        assert!(matches!(&ads[0], Admonition::Note { .. }));
    }

    #[test]
    fn test_steps_extraction() {
        let content = r#"<Step title="Open panel">Click the icon.</Step><Step title="Sign in">Complete auth.</Step>"#;
        let ads = extract_admonitions(content);
        assert_eq!(ads.len(), 2);
        match &ads[0] {
            Admonition::Step { title, body } => {
                assert_eq!(title, "Open panel");
                assert!(body.contains("Click"));
            }
            _ => panic!("expected Step"),
        }
    }

    #[test]
    fn test_tip_to_gfm() {
        let content = "<Tip>Enable plan mode for shared repos.</Tip>";
        let gfm = convert_to_gfm(content);
        assert!(gfm.contains("> [!TIP]"), "missing callout: {gfm}");
        assert!(gfm.contains("Enable plan mode"));
        assert!(!gfm.contains("<Tip>"), "raw tag should be gone: {gfm}");
    }

    #[test]
    fn test_note_to_gfm() {
        let content = "<Note>Reload Window if the extension disappears.</Note>";
        let gfm = convert_to_gfm(content);
        assert!(gfm.contains("> [!NOTE]"));
        assert!(!gfm.contains("<Note>"));
    }

    #[test]
    fn test_lru_hit_same_sha() {
        let mut h = Harvester::new(10);
        let content = "<Tip>Hello</Tip>";
        let sha = "abc123";
        let first = h.harvest("https://example.com/page.md", content, sha);
        // Second call with same SHA — must return from LRU (same result)
        let second = h.harvest("https://example.com/page.md", content, sha);
        assert_eq!(first.sha256, second.sha256);
        assert_eq!(first.admonitions.len(), second.admonitions.len());
    }

    #[test]
    fn test_lru_miss_on_changed_sha() {
        let mut h = Harvester::new(10);
        let content1 = "<Tip>Old content</Tip>";
        let content2 = "<Tip>New content</Tip><Note>Added</Note>";
        h.harvest("https://example.com/page.md", content1, "sha1");
        let second = h.harvest("https://example.com/page.md", content2, "sha2");
        assert_eq!(second.admonitions.len(), 2); // cache invalidated
    }

    #[test]
    fn test_cache_serialize_round_trip() {
        let mut h = Harvester::new(4);
        h.harvest("https://a.com/1.md", "<Tip>A</Tip>", "sha-a");
        h.harvest("https://b.com/2.md", "<Note>B</Note>", "sha-b");

        let tmp = tempfile::NamedTempFile::new().unwrap();
        h.save_cache(tmp.path()).unwrap();

        let h2 = Harvester::load_cache(tmp.path(), 4).unwrap();
        assert!(h2.cache.contains("https://a.com/1.md"));
        assert!(h2.cache.contains("https://b.com/2.md"));
    }
}
