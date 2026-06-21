-- Seed dim_board with known platforms.
-- Greenhouse is the default (crawler.rs falls back to 'greenhouse' if token not found),
-- so only non-greenhouse boards need explicit rows here.
-- Ashby boards are not supported yet and are intentionally omitted.
-- Slug variants (no-hyphen forms) resolved via fuzzy probe against live APIs.

INSERT INTO dim_board (board_token, name, platform) VALUES
  -- Lever boards (original validated list)
  ('cred',              'Cred',              'lever'),
  ('matillion',         'Matillion',         'lever'),
  ('spotify',           'Spotify',           'lever'),
  -- Lever boards (resolved from unknown list)
  ('charmindustrial',   'Charm Industrial',  'lever')
ON CONFLICT (board_token) DO UPDATE SET platform = excluded.platform;
