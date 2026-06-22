# Plan: docs-crawler Rust (ACTIVE)

Crawl Claude doc sources (llms.txt + sitemap.xml), download .md pages,
deduplicate via Redis SHA256 CDC (durable-store pattern), store in Postgres
`fact_doc_pages`, organize under `docs/{host}/{path}.md`.

## Workspace deps reused (zero new cost)
scraper, reqwest, sha2, hex, redis, sqlx, serde, serde_json, tokio, clap, regex,
once_cell, anyhow, tracing, futures

## New workspace deps added
- `quick-xml = "0.37"` — sitemap XML parsing
- `pulldown-cmark = "0.12"` — CommonMark processing
- `lru = "0.12"` — in-process LRU harvest cache
- `url = "2"` — URL parsing in organizer + downloader

## Targets
- https://code.claude.com/docs/llms.txt
- https://code.claude.com/sitemap.xml
- https://platform.claude.com/llms.txt
- https://platform.claude.com/sitemap.xml
- https://support.claude.com/sitemap.xml
- https://claude.com/sitemap.xml
- https://claude.com/docs/llms.txt

## Architecture
```
crawl(targets)
  → parse llms.txt (regex link extraction)
  → parse sitemap.xml (quick-xml, recursive sitemapindex)
  → for each URL (buffer_unordered 5):
      downloader.fetch(url, store)
        → reqwest .md URL
        → DurableStore.check_and_record_doc_snapshot (Redis CDC)
        → skip if unchanged
        → return DocPage
  → Harvester.harvest(url, content, sha256)
        → LruCache hit → skip regex parse
        → extract_admonitions (regex: Tip/Note/Warning/Caution/Step/Tab)
        → convert_to_gfm (> [!TIP] etc.)
        → write docs/{host}/{path}.md
  → DurableStore.upsert_doc_pages (batch, transaction)
  → harvester.save_cache(.cache/mdx-lru.json)
```

## Files created/modified
### New
- `crates/docs-crawler/Cargo.toml`
- `crates/docs-crawler/src/main.rs` — clap CLI
- `crates/docs-crawler/src/crawler.rs` — orchestrator
- `crates/docs-crawler/src/sitemap.rs` — quick-xml parser
- `crates/docs-crawler/src/llms_txt.rs` — regex link extractor
- `crates/docs-crawler/src/organizer.rs` — URL→docs/path mapping
- `crates/docs-crawler/src/downloader.rs` — reqwest fetch + CDC
- `crates/docs-crawler/src/harvest.rs` — MDX extraction + LRU cache
- `crates/docs-crawler/.cache/mdx-lru.json` — version-controlled pre-warm
- `crates/durable-store/migrations/postgres/007_doc_pages.sql`
- `.claude/skills/docs-crawler/SKILL.md`

### Modified
- `crates/durable-store/src/types.rs` — DocPage, Admonition, HarvestResult, CachedLru
- `crates/durable-store/src/lib.rs` — check_and_record_doc_snapshot, get_doc_page, upsert_doc_pages
- `Cargo.toml` (root) — add workspace member + 4 new deps
- `Makefile` — crawl-docs, index-docs targets
- `scripts/agents/agents.ts` — docs-crawler agent

## Redis key patterns (follows durable-store conventions)
- `snap:doc:{sha256(url)}` → content SHA256, TTL 3600s (CDC gate)
- `doc:{sha256(url)}` → serialized DocPage JSON, TTL 3600s (L2 cache)

## LRU cache (.cache/mdx-lru.json)
Version-controlled pre-warm. Capacity 512 (env LRU_CAPACITY). Serde format:
```json
{ "version": 1, "capacity": 512, "entries": [["url", {...}], ...] }
```
New devs get pre-warmed cache on git pull.

## Run
```bash
DATABASE_URL=... REDIS_URL=redis://localhost:6379 cargo run -p docs-crawler
# or
make crawl-docs
```

## Test
```bash
cargo test -p docs-crawler
cargo test -p durable-store  # includes new doc tests
```
