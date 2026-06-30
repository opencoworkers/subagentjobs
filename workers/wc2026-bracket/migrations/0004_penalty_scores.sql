-- =============================================================================
-- wc2026-bracket — Jun 29 penalty-shootout results (idempotent UPDATEs)
-- A tie decided on penalties is shown as goals + a parenthesised shootout score,
-- e.g. 0 (4) – 0 (3). Safe to re-run.
-- =============================================================================

-- M03 MEX–KOR: 0–0, Mexico won 4–3 on penalties.
UPDATE fact_match SET status='final', home_score=0, away_score=0,
  home_pens=4, away_pens=3, winner_code='MEX', note='pens',
  updated_at='2026-06-29T22:30:00Z' WHERE match_id='M03';

-- M04 BRA–NGA: 2–2 (AET), Brazil won 5–4 on penalties.
UPDATE fact_match SET status='final', home_score=2, away_score=2,
  home_pens=5, away_pens=4, winner_code='BRA', note='AET · pens',
  updated_at='2026-06-29T23:10:00Z' WHERE match_id='M04';
