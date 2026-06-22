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
