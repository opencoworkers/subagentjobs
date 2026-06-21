-- Eviction: tombstone + consecutive-miss counter + two-phase delete (Postgres parity with D1 migration 004)
ALTER TABLE fact_job_posting ADD COLUMN IF NOT EXISTS miss_count  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE fact_job_posting ADD COLUMN IF NOT EXISTS evicted_at  TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_fjp_evicted  ON fact_job_posting(evicted_at);
CREATE INDEX IF NOT EXISTS idx_fjp_miss     ON fact_job_posting(miss_count);
CREATE INDEX IF NOT EXISTS idx_fjp_co_evict ON fact_job_posting(company_name, evicted_at);
