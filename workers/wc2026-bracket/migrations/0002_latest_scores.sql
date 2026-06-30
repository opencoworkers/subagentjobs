-- =============================================================================
-- wc2026-bracket — superseded
-- =============================================================================
-- This file previously carried illustrative/placeholder score updates. The
-- authoritative Round-of-32 data (real results as of 2026-06-30) now lives in
-- 0001_bracket.sql (fresh seed) and 0005_real_bracket.sql (corrects existing
-- production rows). Kept as an idempotent no-op so the ordered migration
-- history stays intact and re-applies cleanly.
UPDATE fact_match SET updated_at = updated_at WHERE 1 = 0;
