-- Vendor repository registry and file index for local code search / RAG.
--
-- Design:
--   dim_vendor      — which repos are configured and their current index state
--   fact_filesystem — one row per file, SHA256 CDC-gated so re-indexing is cheap
--   dim_file_ast    — parsed symbols, imports, exports per file (JSONB for flexibility)
--
-- The indexer (crates/indexer) populates these tables.
-- The MCP server exposes them via search_code / list_symbols tools.

CREATE TABLE IF NOT EXISTS dim_vendor (
    vendor_key    TEXT        PRIMARY KEY,           -- '{org}/{repo}'
    org           TEXT        NOT NULL,
    repo          TEXT        NOT NULL,
    remote_url    TEXT,
    branch        TEXT        NOT NULL DEFAULT 'main',
    local_path    TEXT        NOT NULL,              -- relative: 'vendors/{org}/{repo}'
    pinned_sha    TEXT,                              -- git commit SHA at last index
    description   TEXT,
    file_count    INTEGER     NOT NULL DEFAULT 0,
    indexed_at    TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS fact_filesystem (
    file_key      TEXT        PRIMARY KEY,           -- '{vendor_key}:{relative/path}'
    vendor_key    TEXT        NOT NULL REFERENCES dim_vendor(vendor_key),
    relative_path TEXT        NOT NULL,
    extension     TEXT,                              -- 'rs', 'ts', 'sql', 'md', …
    language      TEXT,                              -- detected: rust, typescript, sql, …
    size_bytes    BIGINT,
    sha256        TEXT,                              -- CDC gate: skip re-parse if unchanged
    line_count    INTEGER,
    indexed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    evicted_at    TIMESTAMPTZ                        -- soft-delete when file removed
);

CREATE TABLE IF NOT EXISTS dim_file_ast (
    file_key      TEXT        PRIMARY KEY REFERENCES fact_filesystem(file_key),
    language      TEXT        NOT NULL,
    -- [{name, kind, line, visibility}] — kind: fn|struct|trait|enum|type|class|const
    symbols       JSONB       NOT NULL DEFAULT '[]',
    imports       TEXT[]      NOT NULL DEFAULT '{}', -- use/import paths
    exports       TEXT[]      NOT NULL DEFAULT '{}', -- pub / export names
    doc_summary   TEXT,                              -- first module/file doc comment
    parsed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_ff_vendor     ON fact_filesystem(vendor_key);
CREATE INDEX IF NOT EXISTS idx_ff_ext        ON fact_filesystem(extension);
CREATE INDEX IF NOT EXISTS idx_ff_lang       ON fact_filesystem(language);
CREATE INDEX IF NOT EXISTS idx_ff_evicted    ON fact_filesystem(evicted_at);
CREATE INDEX IF NOT EXISTS idx_ff_sha        ON fact_filesystem(sha256);

CREATE INDEX IF NOT EXISTS idx_fa_lang       ON dim_file_ast(language);
CREATE INDEX IF NOT EXISTS idx_fa_symbols    ON dim_file_ast USING GIN(symbols);
CREATE INDEX IF NOT EXISTS idx_fa_imports    ON dim_file_ast USING GIN(imports);
CREATE INDEX IF NOT EXISTS idx_fa_exports    ON dim_file_ast USING GIN(exports);

-- Full-text search on doc summaries
ALTER TABLE dim_file_ast ADD COLUMN IF NOT EXISTS doc_tsv TSVECTOR
    GENERATED ALWAYS AS (to_tsvector('english', coalesce(doc_summary, ''))) STORED;
CREATE INDEX IF NOT EXISTS idx_fa_fts ON dim_file_ast USING GIN(doc_tsv);
