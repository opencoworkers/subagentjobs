use anyhow::Result;
use std::path::PathBuf;
use url::Url;

/// Map a URL to a `docs/{host}/{path}.md` `PathBuf`.
///
/// Rules:
/// - Query strings and fragments are stripped.
/// - Root path (`/` or empty) becomes `index.md`.
/// - Paths already ending in `.md` are kept as-is.
/// - All other paths get `.md` appended.
pub fn url_to_path(url_str: &str) -> Result<PathBuf> {
    let url = Url::parse(url_str)?;
    let host = url.host_str().unwrap_or("unknown");
    let raw_path = url.path();

    let rel = if raw_path == "/" || raw_path.is_empty() {
        "index.md".to_string()
    } else {
        let p = raw_path.trim_start_matches('/');
        if p.ends_with(".md") {
            p.to_string()
        } else {
            format!("{p}.md")
        }
    };

    Ok(PathBuf::from("docs").join(host).join(rel))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_md_url_kept() {
        let p = url_to_path("https://code.claude.com/docs/en/vs-code.md").unwrap();
        assert_eq!(p, PathBuf::from("docs/code.claude.com/docs/en/vs-code.md"));
    }

    #[test]
    fn test_non_md_appended() {
        let p = url_to_path("https://code.claude.com/docs/en/vs-code").unwrap();
        assert_eq!(p, PathBuf::from("docs/code.claude.com/docs/en/vs-code.md"));
    }

    #[test]
    fn test_deep_path() {
        let p =
            url_to_path("https://support.claude.com/hc/en-us/articles/123").unwrap();
        assert_eq!(
            p,
            PathBuf::from("docs/support.claude.com/hc/en-us/articles/123.md")
        );
    }

    #[test]
    fn test_root_path() {
        let p = url_to_path("https://claude.com/").unwrap();
        assert_eq!(p, PathBuf::from("docs/claude.com/index.md"));
    }

    #[test]
    fn test_strips_query_and_fragment() {
        let p =
            url_to_path("https://code.claude.com/docs/en/vs-code?ref=nav#section").unwrap();
        assert_eq!(
            p,
            PathBuf::from("docs/code.claude.com/docs/en/vs-code.md")
        );
    }
}
