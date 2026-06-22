# Plan: docs-crawler TypeScript (ARCHIVED)

Superseded by the Rust plan. The TypeScript/cheerio approach was replaced because
the workspace already has `scraper`, `reqwest`, `sha2`, `hex`, `redis`, `sqlx`, `serde`,
`tokio`, `clap`, and `regex` as workspace deps — the Rust crate gets all of this for free
and extends `durable-store` directly with no translation layer.

## Original scope
- `apps/cheerio-crawler/` Node.js project
- `bloom-filters` npm (replaced by Redis snap:doc:* keys)
- Custom `LRUCache<K,V>` TypeScript class (replaced by `lru` crate)
- `fast-xml-parser` npm (replaced by `quick-xml`)
- `commonmark` npm (replaced by `pulldown-cmark`)
- `DocStore` TypeScript port of DurableStore (~100 lines)

## Why Rust won
- All core deps already in workspace (zero new cost for most)
- `durable-store` can be extended directly — no translation layer
- `scraper` (Rust Cheerio) already a workspace dep
- Single `cargo test` for everything — no npm toolchain needed
- Type safety + zero-cost serde

Let me quickly check the VS Code Redis extension ecosystem and current `.vscode/extensions.json` state:  



Searched for files matching `**/.vscode/extensions.json`, no matches

Fetched https://marketplace.visualstudio.com/items?itemName=cweijan.vscode-redis-client

Good — `cweijan.vscode-redis-client` is confirmed. Now let me update the plan and present it: 

Updated memory file [](file:///Users/alex-opensubagents/Library/Application%20Support/Code/User/workspaceStorage/e21a826d625aa5821b8a06d5c65f8ea2/GitHub.copilot-chat/memory-tool/memories/YzliNjBjZTMtNDE5MS00OTk4LWE4MTAtOTg5MDQwYWJhYWQ4/plan.md)

---

## Plan: `apps/cheerio-crawler/` — Redis + LRU Cache + MDX Harvest

This extends the previous plan with 3 new concerns. Here's the full updated picture:

---

### Cache Architecture

Three-layer hierarchy for the MDX harvest pipeline:

```
L1  LRUCache<url, HarvestResult>   in-process, fixed 512 entries, O(1), pre-warmed from L3
L2  Redis localhost:6379            session-scoped, network, fast eviction
L3  .cache/mdx-lru.json            on-disk, version-controlled, team pre-warm
```

**Read path:** L1 hit → return. L1 miss → L2 hit → promote to L1 → return. L2 miss → L3 hit → promote to L1+L2 → return. L3 miss → fetch network → write L1+L2+L3.

**Why version-controlled L3?** Every team member (and agent session) gets a pre-warmed cache on `git pull`. No cold-start fetches. Capacity is bounded by the `LRUCache` eviction policy — the JSON file never grows beyond `capacity` entries.

---

### New Source Files (additions to previous plan)

**`src/lru-cache.ts`** — `LRUCache<K, V>` class
- Doubly-linked list + `Map` for O(1) `get`/`set`
- `get(key)` promotes to MRU position
- `set(key, value)` evicts LRU when at capacity
- `serialize(): SerializedLRU<K,V>` → `{ version: 1, capacity, entries: [K,V][] }` ordered LRU→MRU
- `static deserialize<K,V>(data, capacity): LRUCache<K,V>` → inserts in order to restore recency
- `async save(path: string)` → writes JSON to disk
- `static async load<K,V>(path, capacity): Promise<LRUCache<K,V>>` → reads + deserializes

**`src/redis-client.ts`** — `RedisCache` class wrapping `redis` (npmjs v4)
- `connect(url = 'redis://localhost:6379')`
- `get<T>(key): Promise<T | null>` — JSON.parse on hit
- `set<T>(key, value, options?)` — JSON.stringify
- `del(key)` / `flush(pattern)` for cleanup
- Graceful `isConnected` flag — if Redis is down, silently skip L2 (crawler still works)

**`src/mdx-harvest.ts`** — `MdxHarvester` class
- Constructor takes `LRUCache` + `RedisCache` + `docsRoot`
- `harvest(url): Promise<HarvestResult>` — full L1→L2→L3→network lookup chain
- Parses MDX components: `<Tip>`, `<Note>`, `<Warning>`, `<Caution>`, `<Steps>/<Step>`, `<Tabs>/<Tab>`
- Returns `HarvestResult: { url, raw, admonitions: Admonition[], gfm, sha256 }`
- `Admonition: { type, content, gfm }` where `gfm` is the `> [!TIP]` block

**`apps/cheerio-crawler/.cache/mdx-lru.json`** — initial empty serialized LRU:
```json
{ "version": 1, "capacity": 512, "entries": [] }
```
This file is committed, grows with crawls, bounded to 512 entries.

**`apps/cheerio-crawler/.gitignore`**
- Gitignore `.state/` (Bloom + SHA256 hashes — machine-local)
- Track `.cache/` (LRU disk cache — shared via git)

---

### New Tests (Phase 1 additions — all RED first)

**`tests/lru-cache.test.ts`** — 6 cases:
- `get` on empty → `undefined`
- `set` then `get` → returns value
- At capacity+1, LRU entry is evicted
- `get` on existing key promotes it (not evicted next)
- `serialize()` → `{ version:1, capacity, entries }` in LRU→MRU order
- `deserialize(serialize())` round-trip → same get/eviction behavior

**`tests/mdx-harvest.test.ts`** — 5 cases (mocked fetch + Redis):
- `<Tip>content</Tip>` → `Admonition { type:'tip', gfm:'> [!TIP]\n> content' }`
- `<Note>…</Note>` → type `note`
- `<Steps><Step title="T">body</Step></Steps>` → numbered list GFM
- L1 cache hit → fetch NOT called
- L2 Redis hit → fetch NOT called, entry promoted to L1

**`tests/redis-client.test.ts`** — 4 cases (using `redis` mock):
- `get` on missing key → `null`
- `set` then `get` → returns deserialized value
- `del` removes key
- Redis connection failure → `isConnected = false`, `get` returns `null` silently

---

### VS Code Wiring

**`.vscode/extensions.json`** (new file, created as part of VS Code docs plan):
```json
{
  "recommendations": [
    "anthropic.claude-code",
    "cweijan.vscode-redis-client"
  ]
}
```

**`.vscode/settings.json`** (new):
```json
{
  "claudeCode.initialPermissionMode": "plan",
  "claudeCode.autosave": true,
  "database-client.telemetry.usesOnlineServices": false
}
```

---

### New Skill: `.claude/skills/mdx-harvest/SKILL.md`

Frontmatter pattern (same as existing skills):
```yaml
name: mdx-harvest
description: Extract and cache MDX admonitions (Tip, Note, Steps, Tabs) from Claude docs pages...
```

Body covers:
- When to trigger ("harvest admonitions", "extract MDX", "convert docs page")
- `MdxHarvester` class usage pattern
- Cache hierarchy (L1 LRU → L2 Redis → L3 `.cache/mdx-lru.json`)
- How to warm the cache: `make crawl` populates L3, Redis auto-warms from there
- `.cache/mdx-lru.json` is version-controlled — `git pull` gives you team's cache

---

### Updated Makefile Targets

Add alongside `crawl`:
```
crawl         → cd apps/cheerio-crawler && npm ci && npm run crawl
crawl-test    → cd apps/cheerio-crawler && npm test
redis-start   → docker run -d --name subagentjobs-redis -p 6379:6379 redis:7-alpine
redis-stop    → docker stop subagentjobs-redis && docker rm subagentjobs-redis
```

---

### Full File List (complete picture)

| File | Status |
|---|---|
| `apps/cheerio-crawler/package.json` | new |
| `apps/cheerio-crawler/tsconfig.json` | new |
| `apps/cheerio-crawler/vitest.config.ts` | new |
| `apps/cheerio-crawler/src/index.ts` | new |
| `apps/cheerio-crawler/src/crawler.ts` | new |
| `apps/cheerio-crawler/src/organizer.ts` | new |
| `apps/cheerio-crawler/src/bloom.ts` | new |
| `apps/cheerio-crawler/src/sitemap.ts` | new |
| `apps/cheerio-crawler/src/llms-txt.ts` | new |
| `apps/cheerio-crawler/src/downloader.ts` | new |
| `apps/cheerio-crawler/src/lru-cache.ts` | new |
| `apps/cheerio-crawler/src/redis-client.ts` | new |
| `apps/cheerio-crawler/src/mdx-harvest.ts` | new |
| `apps/cheerio-crawler/.cache/mdx-lru.json` | new, **tracked** |
| `apps/cheerio-crawler/.gitignore` | new |
| `apps/cheerio-crawler/tests/*.test.ts` | new |
| `.claude/skills/cheerio-crawler/SKILL.md` | new |
| `.claude/skills/mdx-harvest/SKILL.md` | new |
| `.vscode/extensions.json` | new |
| `.vscode/settings.json` | new |
| Makefile | modify |

---

**Decisions**
- `redis` (npmjs official v4, not `ioredis`) — as requested; it's Promise-native
- Redis is optional at runtime — `RedisCache.isConnected` gates L2; crawler works without Redis running
- `docker run redis:7-alpine` for local Redis via `make redis-start` — zero setup
- LRU capacity = 512 entries, configurable via `LRU_CAPACITY` env var
- `.cache/mdx-lru.json` is NOT gitignored — it's the pre-warmed team cache, bounded to 512 entries
- `.state/` (Bloom filter + SHA256) IS gitignored — machine-local crawl state
- `database-client.telemetry.usesOnlineServices: false` disables VS Code extension telemetry per their docs

**Out of scope**
- Redis persistence/AOF config (default in-memory is fine for L2 session cache)
- Redis auth/TLS (localhost only)
- Converting HTML pages that don't have `.md` URLs (all target sites serve `.md` directly)

---

Ready to hand off to implementation. Any adjustments?

Let me check the workspace Cargo deps and the sessions/ directory to know exactly what's available before finalizing the Rust plan.  

Read [](file:///Users/alex-opensubagents/opencoworkers/subagentjobs/Cargo.toml)

Read [](file:///Users/alex-opensubagents/opencoworkers/subagentjobs/sessions)

The workspace already has `scraper`, `reqwest`, `sha2`, `hex`, `redis`, `sqlx`, `clap`, `regex`, `serde` — almost the entire stack. Only 3 new deps needed. Let me write both plans. 

Updated memory file [](file:///Users/alex-opensubagents/Library/Application%20Support/Code/User/workspaceStorage/e21a826d625aa5821b8a06d5c65f8ea2/GitHub.copilot-chat/memory-tool/memories/YzliNjBjZTMtNDE5MS00OTk4LWE4MTAtOTg5MDQwYWJhYWQ4/plan.md)

---

## Plan: Rust `crates/docs-crawler/` — Dogfood-First

**TL;DR:** The root Cargo.toml already has `scraper`, `reqwest`, `sha2`, `hex`, `redis`, `sqlx`, `serde`, `tokio`, `clap`, and `regex` as workspace deps. The TypeScript port is now unnecessary — a Rust crate gets all of this free and extends `durable-store` directly with no translation layer. Only 3 new workspace deps needed.

---

### Step 0 — Save & commit both plans *(blocks nothing else)*

1. Create `sessions/plans/docs-crawler-ts.md` — the TypeScript plan (archived)
2. Create `sessions/plans/docs-crawler-rust.md` — this Rust plan (active)
3. `git add sessions/plans/ && git commit -m "docs(plans): add docs-crawler plans TS + Rust"`

---

### Phase 1 — Tests (RED) *(parallel)*

All tests are `#[cfg(test)]` modules inside each `src/*.rs` file, run with `cargo test -p docs-crawler`.

4. **`src/sitemap.rs` tests** — 3 inline XML fixture cases:
   - `<urlset>` → `Vec<String>` of `<loc>` values
   - `<sitemapindex>` → `Vec<String>` of nested sitemap URLs
   - Empty doc → `[]`

5. **`src/llms_txt.rs` tests** — 3 inline text fixture cases:
   - `[Title](https://…/page.md)` lines → URL extracted
   - H1/blockquote lines → ignored
   - Mixed content → only URLs

6. **`src/organizer.rs` tests** — 5 URL→path cases (same as TypeScript plan)

7. **`src/harvest.rs` tests** — 5 cases using `mockito` or inline string fixtures:
   - `<Tip>content</Tip>` → `Admonition::Tip { content }` + `"> [!TIP]\n> content"` GFM
   - `<Note>…</Note>` → `Admonition::Note`
   - `<Steps><Step title="T">body</Step></Steps>` → numbered list GFM
   - LRU hit (`lru::LruCache`) → fetch NOT called
   - `CachedLru` serde round-trip → `entries` deserialized restores recency order

8. **durable-store tests** — extend existing test module:
   - `check_and_record_doc_snapshot` with same hash → `CdcResult { changed: false }`
   - `check_and_record_doc_snapshot` with new hash → `CdcResult { changed: true }`, Redis updated

Run `cargo test -p docs-crawler` → **all fail** (no `src/` logic yet).

---

### Phase 2 — Extend `durable-store` *(blocks Phase 3)*

9. **types.rs** — add:

   ```
   DocPage { url, host, path, sha256, content_md, admonitions: Vec<Admonition>, gfm, crawled_at }
   Admonition — serde enum: Tip/Note/Warning/Caution/Step/Tab  
   HarvestResult { url, sha256, admonitions, gfm }
   CachedLru { version: u8, capacity: usize, entries: Vec<(String, HarvestResult)> }
   ```
   All derive `Serialize, Deserialize, Clone, Debug`.

10. **lib.rs** — add 3 doc methods following `get_jobs_for_board` / `check_and_record_snapshot` patterns exactly:
    - `check_and_record_doc_snapshot(url, hash) -> CdcResult` — Redis key `snap:doc:{sha256(url)}`
    - `get_doc_page(url) -> Option<DocPage>` — Redis L2 (`doc:{sha256(url)}`) → Postgres L3
    - `upsert_doc_pages(pages: &[DocPage]) -> u64` — `UNNEST` batch INSERT following `upsert_jobs`

11. **`crates/durable-store/migrations/postgres/007_doc_pages.sql`** — following `004_vendor_filesystem.sql`:
    ```sql
    CREATE TABLE IF NOT EXISTS fact_doc_pages (
      url TEXT PRIMARY KEY,  host TEXT NOT NULL,  path TEXT NOT NULL,
      sha256 TEXT NOT NULL,  content_md TEXT,
      admonitions JSONB,     gfm TEXT,
      crawled_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE INDEX idx_doc_pages_host ON fact_doc_pages(host);
    CREATE INDEX idx_doc_pages_fts  ON fact_doc_pages
      USING gin(to_tsvector('english', coalesce(content_md,'')));
    ```

---

### Phase 3 — Build `crates/docs-crawler/` *(depends on Phase 2)*

12. **Cargo.toml** (workspace member + Cargo.toml root update):
    ```toml
    [dependencies]
    durable-store = { path = "../durable-store" }
    scraper.workspace = true      # already present
    reqwest.workspace = true      # already present
    sha2.workspace = true         # already present
    hex.workspace = true          # already present
    quick-xml = "0.37"            # new
    pulldown-cmark = "0.12"       # new
    lru = "0.13"                  # new
    # + serde, serde_json, tokio, clap, regex, anyhow — all workspace
    ```

13. **`src/sitemap.rs`** — `parse_sitemap(xml: &str) -> (Vec<String>, Vec<String>)` using `quick-xml`; handles `<urlset>` + `<sitemapindex>` recursion

14. **`src/llms_txt.rs`** — `parse_llms_txt(text: &str) -> Vec<String>` via `regex` (already workspace); extracts `[…](url)` links

15. **`src/organizer.rs`** — `url_to_path(url: &str) -> PathBuf`; uses `url::Url` (already via reqwest); `docs/{host}/{path}.md`

16. **`src/harvest.rs`** — `Harvester` struct holding `LruCache<String, HarvestResult>` + `DurableStore` ref:
    - `harvest(url) -> HarvestResult` — checks LRU → Redis (`get_doc_page`) → fetches
    - MDX parser: `scraper::Html::parse_document` + CSS selector `tip, note, warning, steps` for custom elements; `pulldown-cmark` for the surrounding CommonMark
    - `save_cache(&self, path: &Path)` / `load_cache(path, capacity) -> Self` — serde to `.cache/mdx-lru.json`

17. **`src/downloader.rs`** — `download(url, store: &DurableStore) -> Option<DocPage>`:
    - `reqwest::get(url)` — try `.md` URL, if 404 append `.md`
    - `store.check_and_record_doc_snapshot(url, sha256)` → skip if `!changed`
    - Returns `None` if unchanged, `Some(DocPage)` if new/updated

18. **`src/crawler.rs`** — `crawl(targets: &[&str], store: &DurableStore)`:
    - Per target: detect type (`llms.txt` or `sitemap.xml`) → parse → collect URLs
    - `futures::stream::iter(urls).buffer_unordered(5)` for concurrent fetching
    - Calls `store.upsert_doc_pages` at end in one batch

19. **`src/main.rs`** — `clap` CLI:
    ```
    docs-crawler [--targets <url>...] [--docs-root <path>] [--lru-capacity <n>]
    ```
    Calls `DurableStore::connect()` → `crawl()` → saves LRU cache

---

### Phase 4 — Wire *(parallel)*

20. **Root Cargo.toml** — add `"crates/docs-crawler"` to `[workspace.members]`; add `quick-xml`, `pulldown-cmark`, `lru` to `[workspace.dependencies]`

21. **Makefile** — add targets:
    ```
    crawl-docs    → cargo run -p docs-crawler
    index-docs    → cargo run -p indexer -- --path docs/
    ```
    Add both to `.PHONY` and help text.

22. **`.claude/skills/docs-crawler/SKILL.md`** — following `cardputer-buddy` SKILL.md format (YAML frontmatter + body); trigger phrases: "crawl docs", "refresh claude docs", "update docs/"

23. **agents.ts** — add entry #9:
    `{ name: 'docs-crawler', tool: AgentTool.Bash, prompt: 'cargo run -p docs-crawler' }`

---

### Phase 5 — Verify

24. `cargo check -p docs-crawler` → compiles
25. `cargo test -p docs-crawler` → all tests pass
26. `cargo test -p durable-store` → existing + new doc tests pass
27. `cargo run -p docs-crawler -- --targets https://code.claude.com/docs/llms.txt` → `docs/code.claude.com/docs/en/*.md` files appear

---

**Relevant files**

| File | Action |
|---|---|
| `crates/docs-crawler/` | new crate |
| types.rs | extend: `DocPage`, `Admonition`, `HarvestResult`, `CachedLru` |
| lib.rs | extend: 3 doc methods |
| `crates/durable-store/migrations/postgres/007_doc_pages.sql` | new |
| Cargo.toml (root) | add workspace member + 3 new deps |
| Makefile | add `crawl-docs`, `index-docs` |
| agents.ts | add `docs-crawler` agent |
| `.claude/skills/docs-crawler/SKILL.md` | new skill |
| `sessions/plans/docs-crawler-ts.md` | archived TS plan |
| `sessions/plans/docs-crawler-rust.md` | this plan |

**New workspace deps (only 3)**

| Dep | Version | Replaces |
|---|---|---|
| `quick-xml` | `0.37` | `fast-xml-parser` npm |
| `pulldown-cmark` | `0.12` | `commonmark` npm (ref impl) |
| `lru` | `0.13` | custom `LRUCache<K,V>` TS class |

**Everything else** (`scraper`, `reqwest`, `sha2`, `hex`, `redis`, `sqlx`, `serde`, `tokio`, `clap`, `regex`) — **already in the workspace**. The TypeScript plan would have needed 8+ npm packages from scratch.

**Decisions**
- `scraper` over `select` — already in workspace, CSS selector API mirrors Cheerio
- `pulldown-cmark` — this is the reference CommonMark impl (used by GitHub, rustdoc); the user mentioned cmark spec specifically
- `lru` crate replaces the custom TypeScript `LRUCache<K,V>` — battle-tested, O(1) get/set/evict
- `.cache/mdx-lru.json` stays version-controlled — `CachedLru { entries: Vec<(String, HarvestResult)> }` serializes identically to the TypeScript format
- `crates/docs-crawler/` over extending indexer — indexer is file-system only by design; clean separation
- `sessions/plans/` for plan files — consistent with existing sessions operational docs pattern

---

Ready to commit the TS plan as archived and hand this Rust plan off to the implementing agent?