//! Vendor filesystem index types — mirrors postgres/004_vendor_filesystem.sql.
//!
//! These types are used by `crates/indexer` to populate and query the
//! fact_filesystem / dim_file_ast / dim_vendor tables, and by the MCP server
//! to expose `search_code` and `list_symbols` tools.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

// ── Vendor ────────────────────────────────────────────────────────────────────

/// A vendor repository registered in `.vendors.toml`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct VendorRow {
    /// '{org}/{repo}' — primary key
    pub vendor_key:  String,
    pub org:         String,
    pub repo:        String,
    pub remote_url:  Option<String>,
    pub branch:      String,
    /// Relative path on disk: 'vendors/{org}/{repo}'
    pub local_path:  String,
    /// Git commit SHA at last successful index run
    pub pinned_sha:  Option<String>,
    pub description: Option<String>,
    pub file_count:  i32,
}

// ── File record ───────────────────────────────────────────────────────────────

/// One row in fact_filesystem — a single indexed file.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct FileRecord {
    /// '{vendor_key}:{relative/path}' — primary key
    pub file_key:      String,
    pub vendor_key:    String,
    pub relative_path: String,
    pub extension:     Option<String>,
    pub language:      Option<String>,
    pub size_bytes:    Option<i64>,
    pub sha256:        Option<String>,
    pub line_count:    Option<i32>,
}

// ── Symbol ────────────────────────────────────────────────────────────────────

/// A single named symbol extracted from a source file.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct AstSymbol {
    /// Symbol name: function, type, struct, class, constant, etc.
    pub name:       String,
    /// 'fn' | 'struct' | 'trait' | 'enum' | 'type' | 'class' | 'const' | 'interface'
    pub kind:       String,
    /// 1-based source line number
    pub line:       u32,
    /// 'pub' | 'pub(crate)' | 'export' | 'private' | 'unknown'
    pub visibility: String,
}

// ── AST row ───────────────────────────────────────────────────────────────────

/// One row in dim_file_ast — the parsed symbol index for a file.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct FileAst {
    pub file_key:    String,
    pub language:    String,
    /// Extracted symbols (serialised to JSONB in Postgres)
    pub symbols:     Vec<AstSymbol>,
    /// Import / use paths
    pub imports:     Vec<String>,
    /// Public export names
    pub exports:     Vec<String>,
    /// First module-level doc comment or file header
    pub doc_summary: Option<String>,
}

// ── Vendor config (parsed from .vendors.toml) ────────────────────────────────

/// One `[[vendor]]` stanza from `.vendors.toml`.
/// Parsed by `crates/indexer` using the `toml` crate.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VendorConfig {
    pub org:         String,
    pub repo:        String,
    pub url:         String,
    pub branch:      Option<String>,
    pub description: Option<String>,
}

impl VendorConfig {
    pub fn vendor_key(&self) -> String {
        format!("{}/{}", self.org, self.repo)
    }
    pub fn local_path(&self) -> String {
        format!("vendors/{}/{}", self.org, self.repo)
    }
    pub fn branch(&self) -> &str {
        self.branch.as_deref().unwrap_or("main")
    }
}

/// Top-level `.vendors.toml` structure.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VendorsConfig {
    pub vendor: Vec<VendorConfig>,
}
