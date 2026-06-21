//! Postgres write layer for fact_filesystem + dim_file_ast + dim_vendor.
//!
//! All writes are CDC-gated on SHA256: if a file's hash hasn't changed
//! since the last index run, no Postgres round-trip is made.

use anyhow::Result;
use schema::vendor::{FileAst, VendorConfig};
use sqlx::PgPool;

use crate::{parser, walker::IndexFile};

// ── Vendor upsert ─────────────────────────────────────────────────────────────

pub async fn upsert_vendor(
    pg: &PgPool,
    config: &VendorConfig,
    pinned_sha: Option<&str>,
    file_count: i32,
) -> Result<()> {
    sqlx::query(
        "INSERT INTO dim_vendor (vendor_key, org, repo, remote_url, branch, local_path,
                                 pinned_sha, description, file_count, indexed_at)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,NOW())
         ON CONFLICT (vendor_key) DO UPDATE SET
           pinned_sha  = EXCLUDED.pinned_sha,
           file_count  = EXCLUDED.file_count,
           indexed_at  = NOW()",
    )
    .bind(config.vendor_key())
    .bind(&config.org)
    .bind(&config.repo)
    .bind(&config.url)
    .bind(config.branch())
    .bind(config.local_path())
    .bind(pinned_sha)
    .bind(config.description.as_deref())
    .bind(file_count)
    .execute(pg)
    .await?;
    Ok(())
}

// ── File upsert (CDC-gated) ───────────────────────────────────────────────────

/// Returns true if the file was new or changed (i.e. AST re-parse is needed).
pub async fn upsert_file(pg: &PgPool, file: &IndexFile, language: Option<&str>) -> Result<bool> {
    let result = sqlx::query_scalar::<_, bool>(
        "WITH prev AS (SELECT sha256 FROM fact_filesystem WHERE file_key=$1)
         INSERT INTO fact_filesystem
           (file_key, vendor_key, relative_path, extension, language,
            size_bytes, sha256, line_count, indexed_at, evicted_at)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,NOW(),NULL)
         ON CONFLICT (file_key) DO UPDATE SET
           sha256     = EXCLUDED.sha256,
           language   = EXCLUDED.language,
           size_bytes = EXCLUDED.size_bytes,
           line_count = EXCLUDED.line_count,
           indexed_at = NOW(),
           evicted_at = NULL
         RETURNING (SELECT sha256 IS DISTINCT FROM $7 OR sha256 IS NULL FROM prev)",
    )
    .bind(&file.file_key)
    .bind(&file.vendor_key)
    .bind(&file.relative_path)
    .bind(file.extension.as_deref())
    .bind(language)
    .bind(file.size_bytes as i64)
    .bind(&file.sha256)
    .bind(file.content.as_ref().map(|c| c.lines().count() as i32))
    .fetch_optional(pg)
    .await?;

    // None = row was skipped; Some(true) = hash changed; Some(false) = same hash
    Ok(result.unwrap_or(true))
}

/// Upsert the AST row for a file.
pub async fn upsert_ast(pg: &PgPool, ast: &FileAst) -> Result<()> {
    sqlx::query(
        "INSERT INTO dim_file_ast
           (file_key, language, symbols, imports, exports, doc_summary, parsed_at)
         VALUES ($1,$2,$3,$4,$5,$6,NOW())
         ON CONFLICT (file_key) DO UPDATE SET
           language    = EXCLUDED.language,
           symbols     = EXCLUDED.symbols,
           imports     = EXCLUDED.imports,
           exports     = EXCLUDED.exports,
           doc_summary = EXCLUDED.doc_summary,
           parsed_at   = NOW()",
    )
    .bind(&ast.file_key)
    .bind(&ast.language)
    .bind(serde_json::to_value(&ast.symbols)?)
    .bind(&ast.imports)
    .bind(&ast.exports)
    .bind(ast.doc_summary.as_deref())
    .execute(pg)
    .await?;
    Ok(())
}

/// Soft-delete files in this vendor that were NOT seen in the current walk
/// (i.e. they were deleted from the repo).
pub async fn evict_missing(pg: &PgPool, vendor_key: &str, seen_keys: &[String]) -> Result<u64> {
    let result = sqlx::query(
        "UPDATE fact_filesystem SET evicted_at = NOW()
         WHERE vendor_key = $1
           AND evicted_at IS NULL
           AND file_key != ALL($2)",
    )
    .bind(vendor_key)
    .bind(seen_keys)
    .execute(pg)
    .await?;
    Ok(result.rows_affected())
}

// ── Orchestration: index one file ────────────────────────────────────────────

/// Index a single file: upsert fact_filesystem + dim_file_ast (CDC-gated).
pub async fn index_file(pg: &PgPool, file: &IndexFile) -> Result<IndexStats> {
    let language = file.extension.as_deref()
        .and_then(parser::detect_language);

    let changed = upsert_file(pg, file, language).await?;

    if !changed {
        return Ok(IndexStats { files_skipped: 1, ..Default::default() });
    }

    // Parse and upsert AST only when content changed
    let ast = match (language, &file.content) {
        (Some(lang), Some(src)) => {
            let parsed = parser::parse(lang, src)?;
            Some(FileAst {
                file_key:    file.file_key.clone(),
                language:    lang.to_string(),
                symbols:     parsed.symbols,
                imports:     parsed.imports,
                exports:     parsed.exports,
                doc_summary: parsed.doc_summary,
            })
        }
        _ => None,
    };

    if let Some(ast) = &ast {
        upsert_ast(pg, ast).await?;
    }

    Ok(IndexStats { files_indexed: 1, symbols_extracted: ast.map(|a| a.symbols.len()).unwrap_or(0), ..Default::default() })
}

// ── Stats ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Default)]
pub struct IndexStats {
    pub files_indexed:    usize,
    pub files_skipped:    usize,
    pub symbols_extracted: usize,
    pub files_evicted:    u64,
}

impl std::ops::AddAssign for IndexStats {
    fn add_assign(&mut self, other: Self) {
        self.files_indexed     += other.files_indexed;
        self.files_skipped     += other.files_skipped;
        self.symbols_extracted += other.symbols_extracted;
        self.files_evicted     += other.files_evicted;
    }
}
