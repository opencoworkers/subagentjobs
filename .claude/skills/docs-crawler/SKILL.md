---
name: docs-crawler
description: >
  Crawl Claude documentation sources (llms.txt + sitemap.xml), download .md pages
  with SHA256 change-detection via Redis/Postgres (durable-store CDC pattern), and
  organise them under docs/{host}/{path}.md.  In-process LRU cache (512 entries,
  pre-warmed from .cache/mdx-lru.json) avoids re-parsing unchanged MDX pages.
  Trigger on: "crawl docs", "refresh claude docs", "update docs/", "re-index docs".
---

# docs-crawler skill

Rust binary (`crates/docs-crawler`) that walks Claude documentation sources,
deduplicates via Redis SHA256 CDC, and writes converted GFM files to `docs/`.

## Default targets

| Source | Type |
|---|---|
| `https://code.claude.com/docs/llms.txt` | llms.txt (markdown link list) |
| `https://code.claude.com/sitemap.xml` | XML sitemap |
| `https://platform.claude.com/llms.txt` | llms.txt |
| `https://platform.claude.com/sitemap.xml` | XML sitemap |
| `https://support.claude.com/sitemap.xml` | XML sitemap |
| `https://claude.com/sitemap.xml` | XML sitemap |
| `https://claude.com/docs/llms.txt` | llms.txt |

## Run

```bash
# Requires DATABASE_URL + REDIS_URL (localhost:6379 default)
make crawl-docs

# or directly:
DATABASE_URL=postgres://... cargo run -p docs-crawler

# Single target override:
DATABASE_URL=... cargo run -p docs-crawler -- \
  --targets https://code.claude.com/docs/llms.txt
```

## Cache architecture

```
L1  LruCache<url, HarvestResult>   in-process, 512 entries, pre-warmed from L3
L2  Redis localhost:6379            snap:doc:{sha256(url)}, doc:{sha256(url)}
L3  crates/docs-crawler/.cache/mdx-lru.json  version-controlled, git-shared
```

First crawl: all pages are new → all fetched.
Subsequent crawls: only changed pages re-fetched (Redis CDC gate).

## MDX admonitions converted

| MDX tag | GFM output |
|---|---|
| `<Tip>…</Tip>` | `> [!TIP]\n> …` |
| `<Note>…</Note>` | `> [!NOTE]\n> …` |
| `<Warning>…</Warning>` | `> [!WARNING]\n> …` |
| `<Caution>…</Caution>` | `> [!CAUTION]\n> …` |
| `<Step title="T">…</Step>` | `**T**\n\n…` |
| `<Tab title="T">…</Tab>` | `#### T\n\n…` |

## Output layout

```
docs/
  code.claude.com/
    docs/
      en/
        vs-code.md
        setup.md
        …
  support.claude.com/
    hc/en-us/articles/…
  claude.com/
    docs/
      …
```

## Post-crawl: index docs for MCP search

After crawling, index the downloaded files into `fact_filesystem + dim_file_ast`:

```bash
make index-docs
# expands to: cargo run -p indexer -- --path docs/
```

This makes docs searchable via the MCP server's `search_jobs`-style queries.

## State files

| File | Tracked? | Purpose |
|---|---|---|
| `crates/docs-crawler/.cache/mdx-lru.json` | ✅ git-tracked | Pre-warm LRU on git pull |
| Redis `snap:doc:*` / `doc:*` | ❌ session-local | CDC gate + page cache |
| `fact_doc_pages` (Postgres) | ❌ DB | Durable page store + FTS |

## Key env vars

| Var | Default | Description |
|---|---|---|
| `DATABASE_URL` | — | Postgres connection string (required) |
| `REDIS_URL` | `redis://localhost:6379` | Redis URL |
| `LRU_CAPACITY` | `512` | In-process cache entries |
| `MDX_CACHE_FILE` | `crates/docs-crawler/.cache/mdx-lru.json` | LRU persist path |

## Tests

```bash
cargo test -p docs-crawler     # unit tests in each src module
cargo test -p durable-store    # includes new doc CDC tests
```
