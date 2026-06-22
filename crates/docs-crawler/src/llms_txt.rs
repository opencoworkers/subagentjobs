use once_cell::sync::Lazy;
use regex::Regex;

static LINK_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\[([^\]]*)\]\((https?://[^)]+)\)").expect("valid regex"));

/// Extract all HTTP/HTTPS URLs from a CommonMark document by scanning
/// `[text](url)` link syntax.  Headings, blockquotes, and plain text lines
/// that contain no links are ignored.
pub fn parse_llms_txt(text: &str) -> Vec<String> {
    LINK_RE
        .captures_iter(text)
        .map(|cap| cap[2].to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extracts_links() {
        let text = "# Claude Code\n\n> Docs index\n\n\
            - [VS Code](https://code.claude.com/docs/en/vs-code.md): info\n\
            - [Setup](https://code.claude.com/docs/en/setup.md): info\n";
        let urls = parse_llms_txt(text);
        assert_eq!(
            urls,
            vec![
                "https://code.claude.com/docs/en/vs-code.md",
                "https://code.claude.com/docs/en/setup.md",
            ]
        );
    }

    #[test]
    fn test_ignores_non_links() {
        let text = "# Title\n\n> blockquote\n\nPlain text without links.\n";
        let urls = parse_llms_txt(text);
        assert!(urls.is_empty());
    }

    #[test]
    fn test_mixed_content() {
        let text = "# Title\n\n## Section\n\n\
            [Link 1](https://a.com/page.md)\n\
            Plain text\n\
            > blockquote\n\
            [Link 2](https://b.com/other.md)\n";
        let urls = parse_llms_txt(text);
        assert_eq!(urls.len(), 2);
        assert!(urls[0].contains("a.com"));
        assert!(urls[1].contains("b.com"));
    }
}
