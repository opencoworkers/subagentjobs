-- =============================================================================
-- wc2026-bracket — authoritative Round-of-32 data (real WC 2026, as of 2026-06-30)
-- =============================================================================
-- Production was seeded from an earlier, placeholder dataset; INSERT OR IGNORE in
-- 0001 cannot overwrite those rows, so this migration replaces them with the real
-- bracket. Runs after 0003 (so home_pens/away_pens exist) and is idempotent —
-- INSERT OR REPLACE re-asserts the canonical snapshot on every deploy.
--
-- State on 2026-06-30: four ties complete (M03 & M04 decided on penalties), the
-- rest scheduled (the Jun 30 trio kick off 1/5/9pm ET — none live yet).
-- Sources: FIFA match centre; Wikipedia "2026 FIFA World Cup knockout stage"; CBS bracket.

-- Real 32 teams. INSERT OR IGNORE adds the ones not in the earlier seed and leaves
-- any already-present rows untouched (avoids disturbing fact_match foreign keys).
INSERT OR IGNORE INTO dim_team (team_code, name, flag) VALUES
  ('CAN','Canada','🇨🇦'),       ('RSA','South Africa','🇿🇦'),
  ('BRA','Brazil','🇧🇷'),       ('JPN','Japan','🇯🇵'),
  ('GER','Germany','🇩🇪'),      ('PAR','Paraguay','🇵🇾'),
  ('NED','Netherlands','🇳🇱'),  ('MAR','Morocco','🇲🇦'),
  ('CIV','Ivory Coast','🇨🇮'),  ('NOR','Norway','🇳🇴'),
  ('FRA','France','🇫🇷'),       ('SWE','Sweden','🇸🇪'),
  ('MEX','Mexico','🇲🇽'),       ('ECU','Ecuador','🇪🇨'),
  ('ENG','England','🏴󠁧󠁢󠁥󠁮󠁧󠁿'),     ('COD','DR Congo','🇨🇩'),
  ('USA','United States','🇺🇸'),('BIH','Bosnia & Herzegovina','🇧🇦'),
  ('BEL','Belgium','🇧🇪'),      ('SEN','Senegal','🇸🇳'),
  ('ESP','Spain','🇪🇸'),        ('AUT','Austria','🇦🇹'),
  ('POR','Portugal','🇵🇹'),     ('CRO','Croatia','🇭🇷'),
  ('AUS','Australia','🇦🇺'),    ('EGY','Egypt','🇪🇬'),
  ('SUI','Switzerland','🇨🇭'),  ('ALG','Algeria','🇩🇿'),
  ('ARG','Argentina','🇦🇷'),    ('CPV','Cape Verde','🇨🇻'),
  ('COL','Colombia','🇨🇴'),     ('GHA','Ghana','🇬🇭');

-- Real 16 Round-of-32 ties. INSERT OR REPLACE overwrites the placeholder rows
-- by primary key (M01..M16). r16_group pairs the two ties whose winners meet in
-- the same Round-of-16 match (real bracket).
INSERT OR REPLACE INTO fact_match
  (match_id,seq,match_date,venue,status,home_code,away_code,home_score,away_score,home_pens,away_pens,winner_code,prob_home,note,r16_group,updated_at) VALUES
  ('M01', 1,'Jun 28','Inglewood',      'final',    'CAN','RSA',1,0,NULL,NULL,'CAN',58,NULL,  1,'2026-06-28T22:00:00Z'),
  ('M02', 2,'Jun 29','Houston',        'final',    'BRA','JPN',2,1,NULL,NULL,'BRA',64,NULL,  3,'2026-06-29T20:00:00Z'),
  ('M03', 3,'Jun 29','Foxborough',     'final',    'GER','PAR',1,1,3,4,   'PAR',60,'pens', 2,'2026-06-29T22:30:00Z'),
  ('M04', 4,'Jun 29','Guadalupe',      'final',    'NED','MAR',1,1,2,3,   'MAR',62,'pens', 1,'2026-06-29T23:10:00Z'),
  ('M05', 5,'Jun 30','Arlington',      'scheduled','CIV','NOR',NULL,NULL,NULL,NULL,NULL,42,NULL, 3,NULL),
  ('M06', 6,'Jun 30','East Rutherford','scheduled','FRA','SWE',NULL,NULL,NULL,NULL,NULL,66,NULL, 2,NULL),
  ('M07', 7,'Jun 30','Mexico City',    'scheduled','MEX','ECU',NULL,NULL,NULL,NULL,NULL,52,NULL, 4,NULL),
  ('M08', 8,'Jul 01','Atlanta',        'scheduled','ENG','COD',NULL,NULL,NULL,NULL,NULL,74,NULL, 4,NULL),
  ('M09', 9,'Jul 01','Seattle',        'scheduled','BEL','SEN',NULL,NULL,NULL,NULL,NULL,55,NULL, 6,NULL),
  ('M10',10,'Jul 01','Santa Clara',    'scheduled','USA','BIH',NULL,NULL,NULL,NULL,NULL,60,NULL, 6,NULL),
  ('M11',11,'Jul 02','Inglewood',      'scheduled','ESP','AUT',NULL,NULL,NULL,NULL,NULL,70,NULL, 5,NULL),
  ('M12',12,'Jul 02','Vancouver',      'scheduled','SUI','ALG',NULL,NULL,NULL,NULL,NULL,53,NULL, 8,NULL),
  ('M13',13,'Jul 02','Toronto',        'scheduled','POR','CRO',NULL,NULL,NULL,NULL,NULL,56,NULL, 5,NULL),
  ('M14',14,'Jul 03','Arlington',      'scheduled','AUS','EGY',NULL,NULL,NULL,NULL,NULL,47,NULL, 7,NULL),
  ('M15',15,'Jul 03','Miami',          'scheduled','ARG','CPV',NULL,NULL,NULL,NULL,NULL,82,NULL, 7,NULL),
  ('M16',16,'Jul 03','Kansas City',    'scheduled','COL','GHA',NULL,NULL,NULL,NULL,NULL,62,NULL, 8,NULL);
