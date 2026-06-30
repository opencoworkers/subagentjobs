-- =============================================================================
-- wc2026-bracket — penalty columns (schema upgrade for pre-existing databases)
-- =============================================================================
-- Fresh databases already get home_pens/away_pens from 0001. This file upgrades
-- a production table created before those columns existed. ALTER ADD COLUMN is
-- NOT re-runnable in SQLite, so this file is expected to FAIL HARMLESSLY once
-- the columns exist — the migrate tooling applies each file tolerantly. The
-- penalty *data* lives in 0004 (idempotent UPDATEs) so it runs regardless.
ALTER TABLE fact_match ADD COLUMN home_pens INTEGER;
ALTER TABLE fact_match ADD COLUMN away_pens INTEGER;
