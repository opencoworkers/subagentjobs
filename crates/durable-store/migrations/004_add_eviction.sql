-- Job eviction: tombstone + consecutive-miss counter + two-phase deletion
--
-- Eviction algorithm (runs after each board crawl):
--   1. Fetch live job IDs from source API
--   2. Jobs NOT in live set: miss_count++
--   3. Jobs IN live set: miss_count = 0, evicted_at = NULL (auto-restore)
--   4. miss_count >= 3 AND evicted_at IS NULL → soft-delete (evicted_at = now())
--   5. evicted_at < now() - 30 days → hard delete
--
-- miss_count=3 = 3 consecutive 6-hour crawl cycles = 18 hours absent from source API
-- Grace period = 30 days before hard delete

ALTER TABLE fact_job_posting ADD COLUMN miss_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE fact_job_posting ADD COLUMN evicted_at TEXT;     -- ISO-8601, NULL = active

CREATE INDEX IF NOT EXISTS idx_fjp_evicted   ON fact_job_posting(evicted_at);
CREATE INDEX IF NOT EXISTS idx_fjp_miss      ON fact_job_posting(miss_count);
CREATE INDEX IF NOT EXISTS idx_fjp_co_evict  ON fact_job_posting(company_name, evicted_at);
