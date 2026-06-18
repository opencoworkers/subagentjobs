CREATE INDEX IF NOT EXISTS idx_job_company  ON fact_job_posting(company_name);
CREATE INDEX IF NOT EXISTS idx_job_updated  ON fact_job_posting(updated_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_job_loctype  ON fact_job_posting(location_type);
CREATE INDEX IF NOT EXISTS idx_bridge_skill ON bridge_job_skill(skill_key);
CREATE INDEX IF NOT EXISTS idx_crawl_board  ON crawl_log(board_token, crawled_at DESC);

-- GIN index for fast full-text search on title + company
CREATE INDEX IF NOT EXISTS idx_job_fts ON fact_job_posting
    USING gin(to_tsvector('english', coalesce(title,'') || ' ' || coalesce(company_name,'')));
