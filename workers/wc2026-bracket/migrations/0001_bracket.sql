-- =============================================================================
-- wc2026-bracket — D1 schema (Kimball star, mirrors subagentjobs-dwh style)
-- Applied to D1 `subagentjobs-dwh`.  Tagged: github:opencoworkers/subagentjobs
-- =============================================================================

-- ── dim_team ────────────────────────────────────────────────────────────────
-- One row per national team in the Round of 32.
CREATE TABLE IF NOT EXISTS dim_team (
  team_code TEXT PRIMARY KEY,   -- ISO-ish 3-letter code, e.g. 'CAN'
  name      TEXT NOT NULL,      -- 'Canada'
  flag      TEXT NOT NULL       -- '🇨🇦'
);

-- ── fact_match ──────────────────────────────────────────────────────────────
-- One row per Round-of-32 match.  `r16_group` pairs the two matches whose
-- winners meet in the same Round-of-16 tie (used for the radial bracket edges).
CREATE TABLE IF NOT EXISTS fact_match (
  match_id    TEXT PRIMARY KEY,                    -- 'M01'
  seq         INTEGER NOT NULL,                    -- ordering around the radial
  match_date  TEXT,                                -- 'Jun 28'
  venue       TEXT,
  status      TEXT NOT NULL DEFAULT 'scheduled',   -- scheduled|in_progress|final
  home_code   TEXT NOT NULL REFERENCES dim_team(team_code),
  away_code   TEXT NOT NULL REFERENCES dim_team(team_code),
  home_score  INTEGER,
  away_score  INTEGER,
  winner_code TEXT,                                -- set when status='final'
  prob_home   REAL,                                -- pre-match win prob for home (0-100)
  note        TEXT,                                -- 'AET', 'pens 4-2', …
  r16_group   INTEGER NOT NULL,                    -- 1..8 — pairs feeding one R16 tie
  updated_at  TEXT
);

CREATE INDEX IF NOT EXISTS idx_fact_match_status ON fact_match(status);
CREATE INDEX IF NOT EXISTS idx_fact_match_seq    ON fact_match(seq);

-- ── seed: 32 teams ───────────────────────────────────────────────────────────
INSERT OR IGNORE INTO dim_team (team_code, name, flag) VALUES
  ('CAN','Canada','🇨🇦'),       ('RSA','South Africa','🇿🇦'),
  ('USA','United States','🇺🇸'),('JPN','Japan','🇯🇵'),
  ('MEX','Mexico','🇲🇽'),       ('KOR','South Korea','🇰🇷'),
  ('BRA','Brazil','🇧🇷'),       ('NGA','Nigeria','🇳🇬'),
  ('ARG','Argentina','🇦🇷'),    ('AUS','Australia','🇦🇺'),
  ('FRA','France','🇫🇷'),       ('SEN','Senegal','🇸🇳'),
  ('ENG','England','🏴󠁧󠁢󠁥󠁮󠁧󠁿'),     ('ECU','Ecuador','🇪🇨'),
  ('ESP','Spain','🇪🇸'),        ('MAR','Morocco','🇲🇦'),
  ('GER','Germany','🇩🇪'),      ('CRC','Costa Rica','🇨🇷'),
  ('POR','Portugal','🇵🇹'),     ('URU','Uruguay','🇺🇾'),
  ('NED','Netherlands','🇳🇱'),  ('CRO','Croatia','🇭🇷'),
  ('BEL','Belgium','🇧🇪'),      ('SUI','Switzerland','🇨🇭'),
  ('ITA','Italy','🇮🇹'),        ('COL','Colombia','🇨🇴'),
  ('POL','Poland','🇵🇱'),       ('QAT','Qatar','🇶🇦'),
  ('DEN','Denmark','🇩🇰'),      ('GHA','Ghana','🇬🇭'),
  ('SRB','Serbia','🇷🇸'),       ('IRN','Iran','🇮🇷');

-- ── seed: 16 matches (M01..M16), r16_group 1..8 ──────────────────────────────
-- A few finals + one live to exercise every status path.
INSERT OR IGNORE INTO fact_match
  (match_id,seq,match_date,venue,status,home_code,away_code,home_score,away_score,winner_code,prob_home,note,r16_group,updated_at) VALUES
  ('M01', 1,'Jun 28','Toronto',     'final',      'CAN','RSA',1,0,'CAN',  61, NULL,            1,'2026-06-28T22:00:00Z'),
  ('M02', 2,'Jun 28','Los Angeles', 'final',      'USA','JPN',2,1,'USA',  54, NULL,            1,'2026-06-28T22:00:00Z'),
  ('M03', 3,'Jun 29','Mexico City', 'final',      'MEX','KOR',0,0,'MEX',  58,'pens 4-3',       2,'2026-06-29T20:00:00Z'),
  ('M04', 4,'Jun 29','New York',    'in_progress','BRA','NGA',2,1,NULL,   72, NULL,            2,'2026-06-30T18:00:00Z'),
  ('M05', 5,'Jun 30','Miami',       'scheduled',  'ARG','AUS',NULL,NULL,NULL,77, NULL,         3,NULL),
  ('M06', 6,'Jun 30','Dallas',      'scheduled',  'FRA','SEN',NULL,NULL,NULL,68, NULL,         3,NULL),
  ('M07', 7,'Jul 01','Seattle',     'scheduled',  'ENG','ECU',NULL,NULL,NULL,70, NULL,         4,NULL),
  ('M08', 8,'Jul 01','Atlanta',     'scheduled',  'ESP','MAR',NULL,NULL,NULL,64, NULL,         4,NULL),
  ('M09', 9,'Jul 02','Houston',     'scheduled',  'GER','CRC',NULL,NULL,NULL,75, NULL,         5,NULL),
  ('M10',10,'Jul 02','Boston',      'scheduled',  'POR','URU',NULL,NULL,NULL,59, NULL,         5,NULL),
  ('M11',11,'Jul 03','Philadelphia','scheduled',  'NED','CRO',NULL,NULL,NULL,57, NULL,         6,NULL),
  ('M12',12,'Jul 03','Kansas City', 'scheduled',  'BEL','SUI',NULL,NULL,NULL,60, NULL,         6,NULL),
  ('M13',13,'Jul 04','San Francisco','scheduled', 'ITA','COL',NULL,NULL,NULL,55, NULL,         7,NULL),
  ('M14',14,'Jul 04','Guadalajara', 'scheduled',  'POL','QAT',NULL,NULL,NULL,63, NULL,         7,NULL),
  ('M15',15,'Jul 05','Vancouver',   'scheduled',  'DEN','GHA',NULL,NULL,NULL,58, NULL,         8,NULL),
  ('M16',16,'Jul 05','Monterrey',   'scheduled',  'SRB','IRN',NULL,NULL,NULL,56, NULL,         8,NULL);
