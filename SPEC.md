# subagentjobs — Refactor Spec
## Decision: Rust-first, Redis/Postgres cache, D1 edge read-through

---

## What EXISTS now (all in Cloudflare inline JS Workers)

| Worker | Language | Verdict |
|---|---|---|
| subagentjobs-web | inline JS | **REPLACE** → Hono TS (thin edge, reads from D1 cache) |
| subagentjobs-etl | inline JS | **REPLACE** → Rust binary (compiled MCP tool) |
| subagentjobs-enrich | inline JS | **REPLACE** → Rust binary (taxonomy matcher + future LLM) |

**Python removed entirely.** There was no Python that made sense here — the
ETL is network-bound I/O that belongs in Rust async (tokio + reqwest), not
a scripting language.

---

## Target architecture

```
┌─────────────────────────────────────────┐
│  subagentjobs.com  (Cloudflare Worker)   │
│  Hono TS — thin router only              │
│  reads: D1 (edge) → KV (hot cache)       │
└────────────┬────────────────────────────┘
             │ API calls (low latency, cached)
┌────────────▼────────────────────────────┐
│  Rust MCP Server  (subagentjobs-mcp)     │
│  crate: mcp-server  (rmcp 1.x)           │
│  tools: search_jobs, get_skill_graph,    │
│         crawl_board, get_job             │
│  cache: L1 process HashMap               │
│         L2 Redis (redis-rs 1.x, 60s TTL)│
│         L3 Postgres (pg_durable, source) │
└────────────┬────────────────────────────┘
             │ sqlx pool
┌────────────▼────────────────────────────┐
│  Postgres  (pg_durable schema)           │
│  tables: fact_job_posting (TEXT PK)      │
│           dim_board, dim_skill           │
│           bridge_job_skill               │
│           crawl_log, streams_job_change  │
└─────────────────────────────────────────┘
```

---

## Tests to write BEFORE code (TDD)

### 1. SHA256 CDC (crate: durable-store)
```rust
// OUTCOME: second crawl of same board → changed=false, 0 DB writes
#[tokio::test]
async fn test_sha256_cdc_no_change() {
    let store = DurableStore::test().await;
    let snapshot = b"stable-payload";
    store.record_snapshot("anthropic", snapshot).await.unwrap();
    let result = store.check_changed("anthropic", snapshot).await.unwrap();
    assert_eq!(result.changed, false);
    assert_eq!(result.writes, 0);
}

// OUTCOME: mutated payload → changed=true, upsert runs
#[tokio::test]
async fn test_sha256_cdc_detects_change() {
    let store = DurableStore::test().await;
    store.record_snapshot("anthropic", b"v1").await.unwrap();
    let result = store.check_changed("anthropic", b"v2").await.unwrap();
    assert_eq!(result.changed, true);
}
```

### 2. Redis L2 cache (crate: durable-store)
```rust
// OUTCOME: cache hit → 0 Postgres queries, response < 5ms
#[tokio::test]
async fn test_redis_cache_hit_skips_pg() {
    let store = DurableStore::test().await;
    store.warm_cache("board:anthropic", &sample_jobs()).await.unwrap();
    let (jobs, source) = store.get_board("anthropic").await.unwrap();
    assert_eq!(source, CacheSource::Redis);
    assert!(!jobs.is_empty());
}

// OUTCOME: cache miss → falls through to Postgres
#[tokio::test]
async fn test_redis_miss_falls_through_to_pg() {
    let store = DurableStore::test_cold().await; // no redis data
    let (jobs, source) = store.get_board("anthropic").await.unwrap();
    assert_eq!(source, CacheSource::Postgres);
}
```

### 3. MCP tool: search_jobs (crate: mcp-server)
```rust
// OUTCOME: search "python data engineer" → ranked results, < 50ms cached
#[tokio::test]
async fn test_search_jobs_returns_ranked() {
    let server = McpServer::test().await;
    let result = server.call_tool("search_jobs", json!({"query": "python data engineer"})).await.unwrap();
    let jobs: Vec<JobResult> = serde_json::from_value(result).unwrap();
    assert!(!jobs.is_empty());
    // top result must match at least one query term
    assert!(jobs[0].title.to_lowercase().contains("data") || jobs[0].skills.contains("Python"));
}

// OUTCOME: search with skill filter → only jobs with that skill
#[tokio::test]
async fn test_search_jobs_skill_filter() {
    let server = McpServer::test().await;
    let result = server.call_tool("search_jobs", json!({"skills": ["Rust"]})).await.unwrap();
    let jobs: Vec<JobResult> = serde_json::from_value(result).unwrap();
    assert!(jobs.iter().all(|j| j.skills.contains("Rust")));
}
```

### 4. MCP tool: get_skill_graph (crate: mcp-server)
```rust
// OUTCOME: returns nodes + edges, no skills with 0 count
#[tokio::test]
async fn test_skill_graph_no_zero_count_nodes() {
    let server = McpServer::test().await;
    let result = server.call_tool("get_skill_graph", json!({})).await.unwrap();
    let graph: SkillGraph = serde_json::from_value(result).unwrap();
    assert!(graph.nodes.iter().all(|n| n.job_count > 0));
    assert!(graph.edges.iter().all(|e| e.weight >= 5));
}
```

### 5. Taxonomy entity extraction (crate: mcp-server)
```rust
// OUTCOME: Greenhouse HTML → extracted skills match known content
#[tokio::test]
async fn test_taxonomy_extracts_known_skills() {
    let html = include_str!("fixtures/anthropic_research_eng.html");
    let skills = extract_skills(html, &TAXONOMY);
    assert!(skills.contains("Python"));
    assert!(skills.contains("Machine Learning"));
    // must NOT contain false positives from overly-broad aliases
    assert!(!skills.contains("R")); // single-char alias must not fire on "infrastructure"
}
```

### 6. Crawl idempotency (integration)
```rust
// OUTCOME: crawl N times → crawl_log.changed=false after first, board.job_count stable
#[tokio::test]
async fn test_crawl_idempotent() {
    let crawler = Crawler::test().await;
    crawler.crawl_board("figma").await.unwrap();
    let initial_count = crawler.job_count("figma").await;
    crawler.crawl_board("figma").await.unwrap();
    assert_eq!(crawler.job_count("figma").await, initial_count);
    let log = crawler.last_crawl_log("figma").await;
    assert_eq!(log.changed, false);
}
```

---

## Code to REMOVE

| File / Worker | Why |
|---|---|
| `subagentjobs-etl` (inline JS Worker) | Replaced by compiled Rust `crawler` binary + scheduled invocation |
| `subagentjobs-enrich` (inline JS Worker) | Replaced by `enrich` tool in Rust MCP server |
| Any Python script (`*.py`, pip deps) | Never needed; tokio/reqwest handles all async I/O |
| Hand-rolled SHA256 in JS (`crypto.subtle` inline) | Replaced by `sha2` crate, tested, single impl |
| Inline HTML template strings in JS workers | Replaced by Hono TS router returning JSON; frontend is separate |

---

## Code to ADD

```
crates/
  schema/           ← NormalizedJob, LeverJob, Board, Skill, GraphNode/Edge (DONE, compile-checks)
  durable-store/    ← Redis L2 + Postgres L3 pool, CDC check, crawl_log writes
  mcp-server/       ← rmcp 1.x, 4 tools: search_jobs, get_job, get_skill_graph, crawl_board
  task-state-machine/ ← pg_durable FSM: PENDING→CRAWLING→ENRICHED→ACTIVE
  acp-bridge/       ← ACP envelope wrap for MCP tools (for Cowork plugin)
  a2a-node/         ← A2A protocol node, forwards to mcp-server

workers/
  web/              ← Hono TS, reads D1 + KV, no business logic
  scheduled/        ← tiny JS shim that calls /crawl on the Rust MCP server
```

---

## Dependency pinning (workspace.dependencies)

```toml
rmcp = { version = "1", features = ["server", "client", "transport-io", "schemars"] }
redis = { version = "1", features = ["tokio-comp", "connection-manager", "json"] }
sqlx = { version = "0.8", features = ["runtime-tokio", "tls-rustls", "postgres", "uuid", "json", "chrono", "migrate"] }
sha2 = "0.10"           # replaces hand-rolled crypto.subtle in JS
reqwest = { version = "0.12", features = ["json", "rustls-tls"], default-features = false }
scraper = "0.22"        # HTML parse for Greenhouse content field (replaces js regex)
tokio = { version = "1", features = ["full"] }
```

---

## Token budget rules (enforced going forward)

1. Write Rust, compile-check, push to git — no inline code in chat prose
2. Use Redis as L2: any query that ran once must be cached; chat never re-fetches
3. MCP tools are the API surface — no new Cloudflare Worker JS unless it's a 5-line shim
4. No Python anywhere in this repo
5. All D1 writes go through the Rust MCP server; the JS worker is read-only
