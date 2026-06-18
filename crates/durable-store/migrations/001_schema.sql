-- fact_job_posting: TEXT PK (supports Lever UUIDs + Greenhouse int IDs)
CREATE TABLE IF NOT EXISTS fact_job_posting (
    job_post_id     TEXT        PRIMARY KEY,
    internal_job_id TEXT,
    title           TEXT        NOT NULL,
    requisition_id  TEXT,
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
    loaded_at       TEXT        DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS dim_board (
    board_key           INTEGER PRIMARY KEY AUTOINCREMENT,
    board_token         TEXT    NOT NULL UNIQUE,
    name                TEXT,
    platform            TEXT    DEFAULT 'greenhouse',
    last_snapshot_sha256 TEXT,
    last_crawled_at     TEXT,
    job_count           INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS dim_department (
    department_key  INTEGER PRIMARY KEY AUTOINCREMENT,
    department_id   INTEGER NOT NULL UNIQUE,
    name            TEXT    NOT NULL,
    parent_id       INTEGER,
    is_current      INTEGER DEFAULT 1,
    effective_from  TEXT    DEFAULT (datetime('now')),
    effective_to    TEXT
);

CREATE TABLE IF NOT EXISTS dim_office (
    office_key  INTEGER PRIMARY KEY AUTOINCREMENT,
    office_id   INTEGER NOT NULL UNIQUE,
    name        TEXT    NOT NULL,
    location    TEXT,
    country     TEXT,
    region      TEXT,
    parent_id   INTEGER,
    is_current  INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS dim_skill (
    skill_key   INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL UNIQUE,
    category    TEXT    NOT NULL,   -- language | framework | platform | domain
    aliases     TEXT                -- pipe-separated match patterns
);

CREATE TABLE IF NOT EXISTS bridge_job_skill (
    job_post_id TEXT    REFERENCES fact_job_posting(job_post_id) ON DELETE CASCADE,
    skill_key   INTEGER REFERENCES dim_skill(skill_key)          ON DELETE CASCADE,
    PRIMARY KEY (job_post_id, skill_key)
);

CREATE TABLE IF NOT EXISTS bridge_job_office (
    job_post_id     TEXT    REFERENCES fact_job_posting(job_post_id) ON DELETE CASCADE,
    office_key      INTEGER REFERENCES dim_office(office_key)        ON DELETE CASCADE,
    allocation_factor REAL  DEFAULT 1.0,
    PRIMARY KEY (job_post_id, office_key)
);

CREATE TABLE IF NOT EXISTS crawl_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    board_token     TEXT    NOT NULL,
    crawled_at      TEXT    DEFAULT (datetime('now')),
    snapshot_sha256 TEXT    NOT NULL,
    changed         INTEGER DEFAULT 0,
    job_count       INTEGER DEFAULT 0,
    duration_ms     INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS streams_job_change (
    sequence_id     INTEGER PRIMARY KEY AUTOINCREMENT,
    change_type     TEXT    CHECK(change_type IN ('Insert','Update','Delete')),
    job_post_id     TEXT,
    changed_at      TEXT    DEFAULT (datetime('now')),
    previous_title  TEXT,
    new_title       TEXT,
    diff_json       TEXT
);
