use quick_xml::events::Event;
use quick_xml::Reader;

/// Parse a sitemap XML document.
///
/// Returns `(page_urls, sitemap_index_refs)`:
/// - `page_urls` — `<loc>` values inside `<urlset>` (leaf pages to crawl)
/// - `sitemap_index_refs` — `<loc>` values inside `<sitemapindex>` (nested sitemaps)
pub fn parse_sitemap(xml: &str) -> (Vec<String>, Vec<String>) {
    let mut urls: Vec<String> = Vec::new();
    let mut sitemap_refs: Vec<String> = Vec::new();

    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);

    let mut buf = Vec::new();
    let mut in_loc = false;
    let mut in_sitemap_index = false;
    let mut in_sitemap_entry = false;

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(ref e)) => match e.name().as_ref() {
                b"sitemapindex" => in_sitemap_index = true,
                b"sitemap" if in_sitemap_index => in_sitemap_entry = true,
                b"loc" => in_loc = true,
                _ => {}
            },
            Ok(Event::End(ref e)) => match e.name().as_ref() {
                b"sitemap" => in_sitemap_entry = false,
                b"loc" => in_loc = false,
                _ => {}
            },
            Ok(Event::Text(ref e)) if in_loc => {
                let text = e.unescape().unwrap_or_default().trim().to_string();
                if !text.is_empty() {
                    if in_sitemap_entry {
                        sitemap_refs.push(text);
                    } else {
                        urls.push(text);
                    }
                }
            }
            Ok(Event::Eof) | Err(_) => break,
            _ => {}
        }
        buf.clear();
    }

    (urls, sitemap_refs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_urlset() {
        let xml = r#"<?xml version="1.0"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <url><loc>https://code.claude.com/docs/en/vs-code</loc></url>
            <url><loc>https://code.claude.com/docs/en/setup</loc></url>
        </urlset>"#;
        let (urls, refs) = parse_sitemap(xml);
        assert_eq!(urls.len(), 2);
        assert!(urls[0].contains("vs-code"));
        assert!(refs.is_empty());
    }

    #[test]
    fn test_sitemapindex() {
        let xml = r#"<?xml version="1.0"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <sitemap><loc>https://example.com/sitemap-1.xml</loc></sitemap>
            <sitemap><loc>https://example.com/sitemap-2.xml</loc></sitemap>
        </sitemapindex>"#;
        let (urls, refs) = parse_sitemap(xml);
        assert!(urls.is_empty());
        assert_eq!(refs.len(), 2);
        assert!(refs[0].ends_with("sitemap-1.xml"));
    }

    #[test]
    fn test_empty_urlset() {
        let xml = r#"<?xml version="1.0"?><urlset></urlset>"#;
        let (urls, refs) = parse_sitemap(xml);
        assert!(urls.is_empty());
        assert!(refs.is_empty());
    }
}
