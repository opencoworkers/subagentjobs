-- Full-text search on title (SQLite FTS5)
CREATE VIRTUAL TABLE IF NOT EXISTS fts_jobs USING fts5(
    job_post_id UNINDEXED,
    title,
    location_name,
    company_name,
    content=fact_job_posting,
    content_rowid=rowid
);

-- Populate FTS index
INSERT INTO fts_jobs(fts_jobs) VALUES('rebuild');

-- Standard indexes
CREATE INDEX IF NOT EXISTS idx_job_company   ON fact_job_posting(company_name);
CREATE INDEX IF NOT EXISTS idx_job_platform  ON fact_job_posting(platform);
CREATE INDEX IF NOT EXISTS idx_job_updated   ON fact_job_posting(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_job_location_type ON fact_job_posting(location_type);

CREATE INDEX IF NOT EXISTS idx_bridge_skill  ON bridge_job_skill(skill_key);
CREATE INDEX IF NOT EXISTS idx_crawl_board   ON crawl_log(board_token, crawled_at DESC);
