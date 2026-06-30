-- =============================================================================
-- wc2026-bracket — superseded
-- =============================================================================
-- This file previously carried illustrative penalty-shootout results. The real
-- shootouts (M03 Germany 1–1 Paraguay, Paraguay 4–3 pens; M04 Netherlands 1–1
-- Morocco, Morocco 3–2 pens) are now part of the authoritative data in
-- 0001_bracket.sql and 0005_real_bracket.sql. Kept as an idempotent no-op.
UPDATE fact_match SET updated_at = updated_at WHERE 1 = 0;
