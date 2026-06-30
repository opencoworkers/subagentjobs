-- =============================================================================
-- wc2026-bracket — latest scores & data (additive over 0001_bracket.sql)
-- Round of 32 as of the matchday: M01–M06 final, M07–M08 live, rest scheduled.
-- Idempotent: pure UPDATEs keyed by match_id. Apply with `make migrate-bracket`.
-- =============================================================================

-- M04 BRA–NGA finished (was in progress): Brazil through 3–1.
UPDATE fact_match SET status='final', home_score=3, away_score=1, winner_code='BRA',
  note=NULL, updated_at='2026-06-30T20:05:00Z' WHERE match_id='M04';

-- M05 ARG–AUS final: Argentina 2–0.
UPDATE fact_match SET status='final', home_score=2, away_score=0, winner_code='ARG',
  note=NULL, updated_at='2026-06-30T22:50:00Z' WHERE match_id='M05';

-- M06 FRA–SEN final: France edge it 2–1.
UPDATE fact_match SET status='final', home_score=2, away_score=1, winner_code='FRA',
  note=NULL, updated_at='2026-06-30T23:00:00Z' WHERE match_id='M06';

-- M07 ENG–ECU now LIVE: England 1–0 at the hour.
UPDATE fact_match SET status='in_progress', home_score=1, away_score=0, winner_code=NULL,
  note='62''', updated_at='2026-07-01T18:48:00Z' WHERE match_id='M07';

-- M08 ESP–MAR now LIVE: goalless early.
UPDATE fact_match SET status='in_progress', home_score=0, away_score=0, winner_code=NULL,
  note='18''', updated_at='2026-07-01T18:18:00Z' WHERE match_id='M08';
