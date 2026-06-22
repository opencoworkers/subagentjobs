-- Migration 007: Claude documentation pages
-- Follows the fact_filesystem pattern from 004_vendor_filesystem.sql.
-- Populated by `cargo run -p docs-crawler`.

CREATE TABLE IF NOT EXISTS fact_doc_pages (
    url         TEXT PRIMARY KEY,
    host        TEXT        NOT NULL,
    path        TEXT        NOT NULL,
    sha256      TEXT        NOT NULL,
    content_md  TEXT,
    admonitions JSONB,
    gfm         TEXT,
    crawled_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_doc_pages_host
    ON fact_doc_pages(host);

-- Full-text search over raw markdown content (English tokenisation).
CREATE INDEX IF NOT EXISTS idx_doc_pages_fts
    ON fact_doc_pages
    USING gin(to_tsvector('english', coalesce(content_md, '')));
