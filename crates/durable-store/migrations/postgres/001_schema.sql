CREATE TABLE IF NOT EXISTS fact_job_posting (
    job_post_id     TEXT        PRIMARY KEY,
    title           TEXT        NOT NULL,
    location_name   TEXT,
    location_type   TEXT,
    absolute_url    TEXT,
    content_length  INTEGER     DEFAULT 0,
    first_published TEXT,
    updated_at      TEXT,
    office_count    INTEGER     DEFAULT 0,
    is_prospect     INTEGER     DEFAULT 0,
    company_name    TEXT,
    platform        TEXT        DEFAULT 'greenhouse',
    loaded_at       TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS dim_board (
    board_token         TEXT    PRIMARY KEY,
    name                TEXT,
    platform            TEXT    DEFAULT 'greenhouse',
    last_snapshot_sha256 TEXT,
    last_crawled_at     TIMESTAMPTZ,
    job_count           INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS dim_skill (
    skill_key   SERIAL  PRIMARY KEY,
    name        TEXT    NOT NULL UNIQUE,
    category    TEXT    NOT NULL,
    aliases     TEXT
);

CREATE TABLE IF NOT EXISTS bridge_job_skill (
    job_post_id TEXT    REFERENCES fact_job_posting(job_post_id) ON DELETE CASCADE,
    skill_key   INTEGER REFERENCES dim_skill(skill_key)          ON DELETE CASCADE,
    PRIMARY KEY (job_post_id, skill_key)
);

CREATE TABLE IF NOT EXISTS crawl_log (
    id              BIGSERIAL   PRIMARY KEY,
    board_token     TEXT        NOT NULL,
    crawled_at      TIMESTAMPTZ DEFAULT NOW(),
    snapshot_sha256 TEXT        NOT NULL,
    changed         BOOLEAN     DEFAULT FALSE,
    job_count       INTEGER     DEFAULT 0,
    duration_ms     INTEGER     DEFAULT 0
);
