-- Migration 006: ecosystem catalog
-- fact_orgs, fact_repositories, dim_packages
-- Tracks GitHub orgs, their repos, and published packages (npm/crates/pypi).
-- All scraped data flows here from the indexer or a future sync job.
--
-- Design notes:
--   org_key   = '{platform}:{org_name}'       e.g. 'github:a2aproject'
--   repo_key  = '{platform}:{full_name}'       e.g. 'github:a2aproject/a2a-rs'
--   pkg_key   = '{platform}:{pkg_name}'        e.g. 'npm:@modelcontextprotocol/sdk'
--   All tables use evicted_at for soft-delete parity with fact_job_posting.

-- ── fact_orgs ─────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS fact_orgs (
    org_key          TEXT PRIMARY KEY,           -- 'github:a2aproject'
    platform         TEXT NOT NULL DEFAULT 'github',
    org_name         TEXT NOT NULL,              -- 'a2aproject'
    display_name     TEXT,
    description      TEXT,
    homepage_url     TEXT,
    github_url       TEXT,
    avatar_url       TEXT,
    repo_count       INTEGER NOT NULL DEFAULT 0,
    member_count     INTEGER,
    topics           TEXT[] NOT NULL DEFAULT '{}',
    scraped_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    evicted_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_fact_orgs_platform ON fact_orgs(platform);
CREATE INDEX IF NOT EXISTS idx_fact_orgs_evicted  ON fact_orgs(evicted_at);

-- ── fact_repositories ─────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS fact_repositories (
    repo_key         TEXT PRIMARY KEY,           -- 'github:a2aproject/a2a-rs'
    org_key          TEXT NOT NULL REFERENCES fact_orgs(org_key),
    platform         TEXT NOT NULL DEFAULT 'github',
    full_name        TEXT NOT NULL,              -- 'a2aproject/a2a-rs'
    name             TEXT NOT NULL,              -- 'a2a-rs'
    description      TEXT,
    homepage_url     TEXT,
    github_url       TEXT NOT NULL,
    default_branch   TEXT NOT NULL DEFAULT 'main',
    primary_language TEXT,
    topics           TEXT[] NOT NULL DEFAULT '{}',
    license          TEXT,
    stars            INTEGER NOT NULL DEFAULT 0,
    forks            INTEGER NOT NULL DEFAULT 0,
    open_issues      INTEGER NOT NULL DEFAULT 0,
    open_prs         INTEGER NOT NULL DEFAULT 0,
    is_archived      BOOLEAN NOT NULL DEFAULT FALSE,
    is_fork          BOOLEAN NOT NULL DEFAULT FALSE,
    is_template      BOOLEAN NOT NULL DEFAULT FALSE,
    last_pushed_at   TIMESTAMPTZ,
    vendor_key       TEXT REFERENCES dim_vendor(vendor_key),  -- set if cloned locally
    scraped_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    evicted_at       TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_fact_repos_org      ON fact_repositories(org_key);
CREATE INDEX IF NOT EXISTS idx_fact_repos_lang     ON fact_repositories(primary_language);
CREATE INDEX IF NOT EXISTS idx_fact_repos_archived ON fact_repositories(is_archived);
CREATE INDEX IF NOT EXISTS idx_fact_repos_stars    ON fact_repositories(stars DESC);
CREATE INDEX IF NOT EXISTS idx_fact_repos_pushed   ON fact_repositories(last_pushed_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_fact_repos_evicted  ON fact_repositories(evicted_at);
CREATE INDEX IF NOT EXISTS idx_fact_repos_vendor   ON fact_repositories(vendor_key) WHERE vendor_key IS NOT NULL;

-- Full-text search over repo name + description
ALTER TABLE fact_repositories
    ADD COLUMN IF NOT EXISTS fts TSVECTOR
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(name, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(description, '')), 'B')
    ) STORED;
CREATE INDEX IF NOT EXISTS idx_fact_repos_fts ON fact_repositories USING GIN(fts);

-- ── dim_packages ──────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS dim_packages (
    package_key       TEXT PRIMARY KEY,          -- 'npm:@modelcontextprotocol/sdk'
    platform          TEXT NOT NULL,             -- 'npm' | 'crates' | 'pypi' | 'maven'
    scope             TEXT,                       -- '@modelcontextprotocol' (npm scopes)
    name              TEXT NOT NULL,              -- full package name incl. scope
    display_name      TEXT,
    description       TEXT,
    version_latest    TEXT,
    version_latest_at TIMESTAMPTZ,              -- when latest was published
    version_count     INTEGER,
    downloads_weekly  INTEGER,
    downloads_monthly INTEGER,
    homepage_url      TEXT,
    repository_url    TEXT,
    repo_key          TEXT REFERENCES fact_repositories(repo_key),
    keywords          TEXT[] NOT NULL DEFAULT '{}',
    maintainers       TEXT[] NOT NULL DEFAULT '{}',
    license           TEXT,
    is_deprecated     BOOLEAN NOT NULL DEFAULT FALSE,
    is_archived       BOOLEAN NOT NULL DEFAULT FALSE,
    last_updated_at   TIMESTAMPTZ,              -- last registry write (npm: time.modified)
    scraped_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    evicted_at        TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_dim_pkg_platform    ON dim_packages(platform);
CREATE INDEX IF NOT EXISTS idx_dim_pkg_scope       ON dim_packages(scope) WHERE scope IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_dim_pkg_repo        ON dim_packages(repo_key) WHERE repo_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_dim_pkg_updated     ON dim_packages(last_updated_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_dim_pkg_deprecated  ON dim_packages(is_deprecated, is_archived);
CREATE INDEX IF NOT EXISTS idx_dim_pkg_evicted     ON dim_packages(evicted_at);

ALTER TABLE dim_packages
    ADD COLUMN IF NOT EXISTS fts TSVECTOR
    GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(name, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(description, '')), 'B')
    ) STORED;
CREATE INDEX IF NOT EXISTS idx_dim_pkg_fts ON dim_packages USING GIN(fts);

-- ── Seed: orgs ────────────────────────────────────────────────────────────────

INSERT INTO fact_orgs (org_key, platform, org_name, display_name, description, github_url, repo_count)
VALUES
  ('github:a2aproject',           'github', 'a2aproject',           'Agent2Agent (A2A) Project',
   'Donated to the Linux Foundation by Google. Open protocol enabling communication and interoperability between opaque agentic applications.',
   'https://github.com/a2aproject', 16),

  ('github:modelcontextprotocol', 'github', 'modelcontextprotocol', 'Model Context Protocol',
   'An open protocol that enables seamless integration between LLM applications and external data sources and tools.',
   'https://github.com/modelcontextprotocol', 42),

  ('github:redis-rs',             'github', 'redis-rs',             'redis-rs',
   'Rust Redis client library.',
   'https://github.com/redis-rs', 1),

  ('github:microsoft',            'github', 'microsoft',            'Microsoft',
   'Open source projects and samples from Microsoft.',
   'https://github.com/microsoft', NULL),

  ('npm:modelcontextprotocol',    'npm',    'modelcontextprotocol', '@modelcontextprotocol',
   'Official @modelcontextprotocol npm organization — 50 packages.',
   NULL, 50),

  ('npm:a2a-js',                  'npm',    'a2a-js',               '@a2a-js',
   'Official @a2a-js npm organization.',
   NULL, 1)

ON CONFLICT (org_key) DO UPDATE SET
  repo_count  = EXCLUDED.repo_count,
  description = EXCLUDED.description,
  scraped_at  = NOW();

-- ── Seed: repositories ────────────────────────────────────────────────────────

INSERT INTO fact_repositories
  (repo_key, org_key, full_name, name, description, github_url, primary_language,
   license, stars, forks, open_issues, open_prs, is_archived, last_pushed_at, topics)
VALUES
  -- a2aproject
  ('github:a2aproject/A2A', 'github:a2aproject', 'a2aproject/A2A', 'A2A',
   'Agent2Agent (A2A) is an open protocol enabling communication and interoperability between opaque agentic applications.',
   'https://github.com/a2aproject/A2A', 'Shell', 'Apache-2.0',
   24000, 2400, 235, 35, FALSE, '2026-05-29', ARRAY['agents','linux-foundation','a2a','generative-ai','a2a-protocol']),

  ('github:a2aproject/a2a-rs', 'github:a2aproject', 'a2aproject/a2a-rs', 'a2a-rs',
   'A2A Rust SDK — core types, async client/server, protobuf, gRPC bindings.',
   'https://github.com/a2aproject/a2a-rs', 'Rust', 'Apache-2.0',
   28, 8, 6, 2, FALSE, '2026-05-27', ARRAY['a2a','rust','sdk']),

  ('github:a2aproject/a2a-js', 'github:a2aproject', 'a2aproject/a2a-js', 'a2a-js',
   'Official JavaScript SDK for the Agent2Agent (A2A) Protocol.',
   'https://github.com/a2aproject/a2a-js', 'TypeScript', 'Apache-2.0',
   552, 141, 25, 22, FALSE, '2026-05-29', ARRAY['a2a','typescript','sdk']),

  ('github:a2aproject/a2a-python', 'github:a2aproject', 'a2aproject/a2a-python', 'a2a-python',
   'Official Python SDK for the Agent2Agent (A2A) Protocol.',
   'https://github.com/a2aproject/a2a-python', 'Python', 'Apache-2.0',
   1900, 439, 25, 8, FALSE, '2026-05-29', ARRAY['agents','a2a','generative-ai','a2a-protocol']),

  ('github:a2aproject/a2a-java', 'github:a2aproject', 'a2aproject/a2a-java', 'a2a-java',
   'Official Java SDK for the Agent2Agent (A2A) Protocol.',
   'https://github.com/a2aproject/a2a-java', 'Java', 'Apache-2.0',
   428, 148, 44, 18, FALSE, '2026-05-29', ARRAY['java','ai','a2a']),

  ('github:a2aproject/a2a-go', 'github:a2aproject', 'a2aproject/a2a-go', 'a2a-go',
   'Golang SDK for A2A Protocol.',
   'https://github.com/a2aproject/a2a-go', 'Go', 'Apache-2.0',
   385, 78, 7, 1, FALSE, '2026-05-15', ARRAY['go','sdk','ai','a2a']),

  ('github:a2aproject/a2a-inspector', 'github:a2aproject', 'a2aproject/a2a-inspector', 'a2a-inspector',
   'Validation Tools for A2A Agents.',
   'https://github.com/a2aproject/a2a-inspector', 'TypeScript', 'Apache-2.0',
   425, 137, 19, 23, FALSE, '2026-02-28', ARRAY['a2a','inspector','validation']),

  ('github:a2aproject/a2a-samples', 'github:a2aproject', 'a2aproject/a2a-samples', 'a2a-samples',
   'Samples using the Agent2Agent (A2A) Protocol.',
   'https://github.com/a2aproject/a2a-samples', 'Jupyter Notebook', 'Apache-2.0',
   1600, 679, 121, 127, FALSE, '2026-05-21', ARRAY['agents','a2a','generative-ai']),

  ('github:a2aproject/a2a-dotnet', 'github:a2aproject', 'a2aproject/a2a-dotnet', 'a2a-dotnet',
   'C#/.NET SDK for A2A Protocol.',
   'https://github.com/a2aproject/a2a-dotnet', 'C#', 'Apache-2.0',
   236, 59, 34, 24, FALSE, '2026-05-28', ARRAY['dotnet','csharp','a2a']),

  ('github:a2aproject/a2a-tck', 'github:a2aproject', 'a2aproject/a2a-tck', 'a2a-tck',
   'Test Compatibility Kit for A2A SDKs.',
   'https://github.com/a2aproject/a2a-tck', 'Python', 'Apache-2.0',
   37, 29, 33, 4, FALSE, '2026-05-27', '{}'),

  -- modelcontextprotocol — key repos
  ('github:modelcontextprotocol/typescript-sdk', 'github:modelcontextprotocol',
   'modelcontextprotocol/typescript-sdk', 'typescript-sdk',
   'The official TypeScript SDK for Model Context Protocol servers and clients.',
   'https://github.com/modelcontextprotocol/typescript-sdk', 'TypeScript', NULL,
   13000, 1900, 255, 203, FALSE, '2026-06-14', ARRAY['mcp','typescript']),

  ('github:modelcontextprotocol/rust-sdk', 'github:modelcontextprotocol',
   'modelcontextprotocol/rust-sdk', 'rust-sdk',
   'The official Rust SDK for the Model Context Protocol.',
   'https://github.com/modelcontextprotocol/rust-sdk', 'Rust', NULL,
   3500, 537, 36, 12, FALSE, '2026-06-12', ARRAY['mcp','rust']),

  ('github:modelcontextprotocol/python-sdk', 'github:modelcontextprotocol',
   'modelcontextprotocol/python-sdk', 'python-sdk',
   'The official Python SDK for Model Context Protocol servers and clients.',
   'https://github.com/modelcontextprotocol/python-sdk', 'Python', 'MIT',
   23000, 3500, 268, 284, FALSE, '2026-06-12', ARRAY['mcp','python']),

  ('github:modelcontextprotocol/servers', 'github:modelcontextprotocol',
   'modelcontextprotocol/servers', 'servers',
   'Model Context Protocol Servers — reference implementations.',
   'https://github.com/modelcontextprotocol/servers', 'TypeScript', NULL,
   87000, 11000, 337, 236, FALSE, '2026-06-07', ARRAY['mcp','mcp-servers']),

  ('github:modelcontextprotocol/inspector', 'github:modelcontextprotocol',
   'modelcontextprotocol/inspector', 'inspector',
   'Visual testing tool for MCP servers.',
   'https://github.com/modelcontextprotocol/inspector', 'TypeScript', NULL,
   10000, 1400, 166, 119, FALSE, '2026-06-14', ARRAY['mcp','inspector']),

  ('github:modelcontextprotocol/registry', 'github:modelcontextprotocol',
   'modelcontextprotocol/registry', 'registry',
   'A community driven registry service for Model Context Protocol (MCP) servers.',
   'https://github.com/modelcontextprotocol/registry', 'Go', NULL,
   6900, 863, 95, 32, FALSE, '2026-06-10', ARRAY['mcp','mcp-servers']),

  ('github:modelcontextprotocol/go-sdk', 'github:modelcontextprotocol',
   'modelcontextprotocol/go-sdk', 'go-sdk',
   'The official Go SDK for Model Context Protocol servers and clients.',
   'https://github.com/modelcontextprotocol/go-sdk', 'Go', NULL,
   4700, 448, 37, 24, FALSE, '2026-06-12', ARRAY['go','mcp']),

  ('github:modelcontextprotocol/modelcontextprotocol', 'github:modelcontextprotocol',
   'modelcontextprotocol/modelcontextprotocol', 'modelcontextprotocol',
   'Specification and documentation for the Model Context Protocol.',
   'https://github.com/modelcontextprotocol/modelcontextprotocol', 'TypeScript', NULL,
   8400, 1600, 147, 94, FALSE, '2026-06-13', ARRAY['mcp','specification']),

  ('github:modelcontextprotocol/ext-apps', 'github:modelcontextprotocol',
   'modelcontextprotocol/ext-apps', 'ext-apps',
   'Official repo for spec & SDK of MCP Apps protocol.',
   'https://github.com/modelcontextprotocol/ext-apps', 'TypeScript', NULL,
   2400, 317, 90, 71, FALSE, '2026-06-05', ARRAY['ui','ai','mcp','apps']),

  ('github:modelcontextprotocol/use-mcp', 'github:modelcontextprotocol',
   'modelcontextprotocol/use-mcp', 'use-mcp',
   'React hooks for MCP clients.',
   'https://github.com/modelcontextprotocol/use-mcp', 'TypeScript', 'MIT',
   1000, 81, 10, 10, TRUE, '2026-01-12', '{}'),

  -- redis-rs
  ('github:redis-rs/redis-rs', 'github:redis-rs', 'redis-rs/redis-rs', 'redis-rs',
   'Redis library for Rust.',
   'https://github.com/redis-rs/redis-rs', 'Rust', NULL,
   3700, 520, 120, 40, FALSE, NULL, ARRAY['rust','redis','async']),

  -- microsoft
  ('github:microsoft/pg_durable', 'github:microsoft', 'microsoft/pg_durable', 'pg_durable',
   'Durable execution extension for PostgreSQL built with pgrx.',
   'https://github.com/microsoft/pg_durable', 'Rust', 'MIT',
   NULL, NULL, NULL, NULL, FALSE, NULL, ARRAY['postgres','durable-execution','pgrx','rust']),

  ('github:microsoft/duroxide', 'github:microsoft', 'microsoft/duroxide', 'duroxide',
   'Durable execution orchestration runtime.',
   'https://github.com/microsoft/duroxide', 'Rust', 'MIT',
   NULL, NULL, NULL, NULL, FALSE, NULL, '{}'),

  ('github:microsoft/duroxide-pg', 'github:microsoft', 'microsoft/duroxide-pg', 'duroxide-pg',
   'PostgreSQL state provider for duroxide.',
   'https://github.com/microsoft/duroxide-pg', 'Rust', 'MIT',
   NULL, NULL, NULL, NULL, FALSE, NULL, '{}')

ON CONFLICT (repo_key) DO UPDATE SET
  stars          = EXCLUDED.stars,
  forks          = EXCLUDED.forks,
  open_issues    = EXCLUDED.open_issues,
  open_prs       = EXCLUDED.open_prs,
  last_pushed_at = EXCLUDED.last_pushed_at,
  scraped_at     = NOW();

-- ── Seed: packages ────────────────────────────────────────────────────────────
-- 50 @modelcontextprotocol npm packages + @a2a-js/sdk + crates for a2a-rs

INSERT INTO dim_packages
  (package_key, platform, scope, name, description, version_latest,
   version_latest_at, version_count, repo_key, last_updated_at, is_archived)
VALUES
  -- Core SDK (key packages with data from registry API)
  ('npm:@modelcontextprotocol/sdk', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/sdk',
   'Model Context Protocol implementation for TypeScript',
   '1.29.0', '2026-03-30T16:50:42Z', 78,
   'github:modelcontextprotocol/typescript-sdk', '2026-06-04T19:46:40Z', FALSE),

  ('npm:@modelcontextprotocol/inspector', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/inspector',
   'Visual testing tool for MCP servers', NULL, NULL, NULL,
   'github:modelcontextprotocol/inspector', NULL, FALSE),

  ('npm:@modelcontextprotocol/inspector-client', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/inspector-client',
   'MCP inspector client', NULL, NULL, NULL, 'github:modelcontextprotocol/inspector', NULL, FALSE),

  ('npm:@modelcontextprotocol/inspector-server', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/inspector-server',
   'MCP inspector server', NULL, NULL, NULL, 'github:modelcontextprotocol/inspector', NULL, FALSE),

  ('npm:@modelcontextprotocol/inspector-cli', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/inspector-cli',
   'MCP inspector CLI', NULL, NULL, NULL, 'github:modelcontextprotocol/inspector', NULL, FALSE),

  ('npm:@modelcontextprotocol/conformance', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/conformance',
   'Conformance tests for MCP', NULL, NULL, NULL, NULL, NULL, FALSE),

  ('npm:@modelcontextprotocol/ext-apps', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/ext-apps',
   'MCP Apps protocol SDK', NULL, NULL, NULL, 'github:modelcontextprotocol/ext-apps', NULL, FALSE),

  -- Transport adapters (new in 2026)
  ('npm:@modelcontextprotocol/express', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/express',
   'Express adapter for MCP', NULL, NULL, NULL, 'github:modelcontextprotocol/typescript-sdk', NULL, FALSE),
  ('npm:@modelcontextprotocol/hono', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/hono',
   'Hono adapter for MCP (Cloudflare Workers compatible)', NULL, NULL, NULL,
   'github:modelcontextprotocol/typescript-sdk', NULL, FALSE),
  ('npm:@modelcontextprotocol/fastify', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/fastify',
   'Fastify adapter for MCP', NULL, NULL, NULL, 'github:modelcontextprotocol/typescript-sdk', NULL, FALSE),
  ('npm:@modelcontextprotocol/client', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/client',
   'MCP client package', NULL, NULL, NULL, 'github:modelcontextprotocol/typescript-sdk', NULL, FALSE),
  ('npm:@modelcontextprotocol/server', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/server',
   'MCP server package', NULL, NULL, NULL, 'github:modelcontextprotocol/typescript-sdk', NULL, FALSE),
  ('npm:@modelcontextprotocol/node', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/node',
   'MCP Node.js transport', NULL, NULL, NULL, 'github:modelcontextprotocol/typescript-sdk', NULL, FALSE),
  ('npm:@modelcontextprotocol/server-lazy-auth', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-lazy-auth',
   'MCP server lazy auth', NULL, NULL, NULL, NULL, NULL, FALSE),
  ('npm:@modelcontextprotocol/create-server', 'npm', '@modelcontextprotocol', '@modelcontextprotocol/create-server',
   'CLI to scaffold a new MCP server', NULL, NULL, NULL, NULL, NULL, FALSE),

  -- Reference servers (all from @modelcontextprotocol/servers repo)
  ('npm:@modelcontextprotocol/server-everything',        'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-everything',        'Everything MCP server',             NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-filesystem',        'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-filesystem',        'Filesystem MCP server',             NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-memory',            'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-memory',            'In-memory knowledge graph server',  NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-sequential-thinking','npm','@modelcontextprotocol','@modelcontextprotocol/server-sequential-thinking','Sequential thinking MCP server',   NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-brave-search',      'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-brave-search',      'Brave Search MCP server',           NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-github',            'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-github',            'GitHub MCP server',                 NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-gitlab',            'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-gitlab',            'GitLab MCP server',                 NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-gdrive',            'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-gdrive',            'Google Drive MCP server',           NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-google-maps',       'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-google-maps',       'Google Maps MCP server',            NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-postgres',          'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-postgres',          'PostgreSQL MCP server',             NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-redis',             'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-redis',             'Redis MCP server',                  NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-puppeteer',         'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-puppeteer',         'Puppeteer browser MCP server',      NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-slack',             'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-slack',             'Slack MCP server',                  NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-everart',           'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-everart',           'EverArt MCP server',                NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-aws-kb-retrieval',  'npm', '@modelcontextprotocol', '@modelcontextprotocol/server-aws-kb-retrieval',  'AWS Knowledge Base Retrieval',      NULL,NULL,NULL,'github:modelcontextprotocol/servers',NULL,FALSE),
  -- MCP Apps UI servers (ext-apps)
  ('npm:@modelcontextprotocol/server-budget-allocator',  'npm','@modelcontextprotocol','@modelcontextprotocol/server-budget-allocator',   'Budget Allocator MCP App server',   NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-cohort-heatmap',    'npm','@modelcontextprotocol','@modelcontextprotocol/server-cohort-heatmap',     'Cohort Heatmap MCP App server',     NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-customer-segmentation','npm','@modelcontextprotocol','@modelcontextprotocol/server-customer-segmentation','Customer Segmentation MCP App', NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-map',               'npm','@modelcontextprotocol','@modelcontextprotocol/server-map',               'Map MCP App server',                NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-pdf',               'npm','@modelcontextprotocol','@modelcontextprotocol/server-pdf',               'PDF MCP App server',                NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-scenario-modeler',  'npm','@modelcontextprotocol','@modelcontextprotocol/server-scenario-modeler',  'Scenario Modeler MCP App server',   NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-shadertoy',         'npm','@modelcontextprotocol','@modelcontextprotocol/server-shadertoy',         'Shadertoy MCP App server',          NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-sheet-music',       'npm','@modelcontextprotocol','@modelcontextprotocol/server-sheet-music',       'Sheet Music MCP App server',        NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-system-monitor',    'npm','@modelcontextprotocol','@modelcontextprotocol/server-system-monitor',    'System Monitor MCP App server',     NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-threejs',           'npm','@modelcontextprotocol','@modelcontextprotocol/server-threejs',           'Three.js MCP App server',           NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-transcript',        'npm','@modelcontextprotocol','@modelcontextprotocol/server-transcript',        'Transcript MCP App server',         NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-video-resource',    'npm','@modelcontextprotocol','@modelcontextprotocol/server-video-resource',    'Video Resource MCP App server',     NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-wiki-explorer',     'npm','@modelcontextprotocol','@modelcontextprotocol/server-wiki-explorer',     'Wiki Explorer MCP App server',      NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-basic-preact',      'npm','@modelcontextprotocol','@modelcontextprotocol/server-basic-preact',      'Basic Preact MCP App server',       NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-basic-react',       'npm','@modelcontextprotocol','@modelcontextprotocol/server-basic-react',       'Basic React MCP App server',        NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-basic-solid',       'npm','@modelcontextprotocol','@modelcontextprotocol/server-basic-solid',       'Basic Solid MCP App server',        NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-basic-svelte',      'npm','@modelcontextprotocol','@modelcontextprotocol/server-basic-svelte',      'Basic Svelte MCP App server',       NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-basic-vanillajs',   'npm','@modelcontextprotocol','@modelcontextprotocol/server-basic-vanillajs',   'Basic VanillaJS MCP App server',    NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-basic-vue',         'npm','@modelcontextprotocol','@modelcontextprotocol/server-basic-vue',         'Basic Vue MCP App server',          NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),
  ('npm:@modelcontextprotocol/server-debug',             'npm','@modelcontextprotocol','@modelcontextprotocol/server-debug',             'Debug MCP App server',              NULL,NULL,NULL,'github:modelcontextprotocol/ext-apps',NULL,FALSE),

  -- a2a-js
  ('npm:@a2a-js/sdk', 'npm', '@a2a-js', '@a2a-js/sdk',
   'Server & Client SDK for Agent2Agent protocol',
   '0.3.13', '2026-03-16T11:04:38Z', 20,
   'github:a2aproject/a2a-js', '2026-05-11T14:58:15Z', FALSE),

  -- a2a-rs on crates.io (package published as a2a-lf due to Linux Foundation)
  ('crates:a2a-lf', 'crates', NULL, 'a2a-lf',
   'Core A2A protocol types, errors, events, JSON-RPC wire types',
   NULL, NULL, NULL, 'github:a2aproject/a2a-rs', NULL, FALSE),

  ('crates:a2a-client-lf', 'crates', NULL, 'a2a-client-lf',
   'Async A2A client with transport abstraction',
   NULL, NULL, NULL, 'github:a2aproject/a2a-rs', NULL, FALSE),

  ('crates:a2a-server-lf', 'crates', NULL, 'a2a-server-lf',
   'Async A2A server framework built on axum',
   NULL, NULL, NULL, 'github:a2aproject/a2a-rs', NULL, FALSE)

ON CONFLICT (package_key) DO UPDATE SET
  version_latest    = COALESCE(EXCLUDED.version_latest, dim_packages.version_latest),
  version_latest_at = COALESCE(EXCLUDED.version_latest_at, dim_packages.version_latest_at),
  last_updated_at   = COALESCE(EXCLUDED.last_updated_at, dim_packages.last_updated_at),
  scraped_at        = NOW();

-- ── Useful views ──────────────────────────────────────────────────────────────

-- Active repos with their vendor clone status
CREATE OR REPLACE VIEW v_repos_with_vendor AS
SELECT
    r.repo_key,
    r.org_key,
    r.full_name,
    r.primary_language,
    r.stars,
    r.last_pushed_at,
    r.is_archived,
    v.local_path AS vendor_local_path,
    v.indexed_at AS vendor_indexed_at,
    v.file_count AS vendor_file_count
FROM fact_repositories r
LEFT JOIN dim_vendor v ON v.vendor_key = r.vendor_key
WHERE r.evicted_at IS NULL
ORDER BY r.stars DESC NULLS LAST;

-- npm packages with staleness signal
CREATE OR REPLACE VIEW v_packages_freshness AS
SELECT
    package_key,
    name,
    version_latest,
    last_updated_at,
    NOW() - last_updated_at AS age,
    CASE
        WHEN last_updated_at IS NULL          THEN 'unknown'
        WHEN last_updated_at > NOW() - INTERVAL '30 days'  THEN 'fresh'
        WHEN last_updated_at > NOW() - INTERVAL '180 days' THEN 'stale'
        ELSE 'abandoned'
    END AS freshness,
    is_deprecated,
    is_archived
FROM dim_packages
WHERE evicted_at IS NULL
ORDER BY last_updated_at DESC NULLS LAST;
