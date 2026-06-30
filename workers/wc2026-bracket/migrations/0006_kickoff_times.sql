-- Adds a precise UTC kickoff timestamp per match so the scheduled() cron can
-- deterministically flip status 'scheduled' -> 'in_progress' at the real
-- kickoff instant, independent of SCORES_SOURCE_URL (which only supplies
-- scores, and is a no-op until that var is set).
--
-- Times below cross-verified three ways (ET / PT / BST agreement) against
-- https://www.si.com/soccer/every-confirmed-round-of-32-match-2026-world-cup
-- and reconciled against this table's own match_date (US-local-date) labels.
-- ALTER fails harmlessly if the column already exists (idempotent re-apply).

ALTER TABLE fact_match ADD COLUMN kickoff_utc TEXT;

UPDATE fact_match SET kickoff_utc = '2026-06-28T19:00:00Z' WHERE match_id = 'M01'; -- CAN vs RSA, Inglewood
UPDATE fact_match SET kickoff_utc = '2026-06-29T17:00:00Z' WHERE match_id = 'M02'; -- BRA vs JPN, Houston
UPDATE fact_match SET kickoff_utc = '2026-06-29T20:30:00Z' WHERE match_id = 'M03'; -- GER vs PAR, Foxborough
UPDATE fact_match SET kickoff_utc = '2026-06-30T01:00:00Z' WHERE match_id = 'M04'; -- NED vs MAR, Guadalupe
UPDATE fact_match SET kickoff_utc = '2026-06-30T17:00:00Z' WHERE match_id = 'M05'; -- CIV vs NOR, Arlington
UPDATE fact_match SET kickoff_utc = '2026-06-30T21:00:00Z' WHERE match_id = 'M06'; -- FRA vs SWE, East Rutherford
UPDATE fact_match SET kickoff_utc = '2026-07-01T01:00:00Z' WHERE match_id = 'M07'; -- MEX vs ECU, Mexico City
UPDATE fact_match SET kickoff_utc = '2026-07-01T16:00:00Z' WHERE match_id = 'M08'; -- ENG vs COD, Atlanta
UPDATE fact_match SET kickoff_utc = '2026-07-01T20:00:00Z' WHERE match_id = 'M09'; -- BEL vs SEN, Seattle
UPDATE fact_match SET kickoff_utc = '2026-07-02T00:00:00Z' WHERE match_id = 'M10'; -- USA vs BIH, Santa Clara
UPDATE fact_match SET kickoff_utc = '2026-07-02T19:00:00Z' WHERE match_id = 'M11'; -- ESP vs AUT, Inglewood
UPDATE fact_match SET kickoff_utc = '2026-07-03T03:00:00Z' WHERE match_id = 'M12'; -- SUI vs ALG, Vancouver
UPDATE fact_match SET kickoff_utc = '2026-07-02T23:00:00Z' WHERE match_id = 'M13'; -- POR vs CRO, Toronto
UPDATE fact_match SET kickoff_utc = '2026-07-03T18:00:00Z' WHERE match_id = 'M14'; -- AUS vs EGY, Arlington
UPDATE fact_match SET kickoff_utc = '2026-07-03T22:00:00Z' WHERE match_id = 'M15'; -- ARG vs CPV, Miami
UPDATE fact_match SET kickoff_utc = '2026-07-04T01:30:00Z' WHERE match_id = 'M16'; -- COL vs GHA, Kansas City
