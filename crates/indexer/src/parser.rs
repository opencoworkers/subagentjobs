//! Symbol extraction via regex — language-aware, tree-sitter upgrade path later.
//!
//! Supports: Rust, TypeScript/JavaScript, SQL, Python, Shell.
//! Returns a list of [`AstSymbol`]s and extracted import/use paths.

use anyhow::Result;
use once_cell::sync::Lazy;
use regex::Regex;
use schema::vendor::AstSymbol;

// ── Language detection ────────────────────────────────────────────────────────

pub fn detect_language(extension: &str) -> Option<&'static str> {
    match extension {
        "rs"             => Some("rust"),
        "ts" | "tsx"     => Some("typescript"),
        "js" | "jsx" | "mjs" | "cjs" => Some("javascript"),
        "py"             => Some("python"),
        "sql"            => Some("sql"),
        "md" | "mdx"     => Some("markdown"),
        "toml"           => Some("toml"),
        "yaml" | "yml"   => Some("yaml"),
        "json" | "jsonc" => Some("json"),
        "sh" | "bash" | "zsh" => Some("shell"),
        _                => None,
    }
}

// ── Regex patterns ────────────────────────────────────────────────────────────

static RE_RUST_PUB_FN:     Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*pub(?:\([^)]*\))?\s+(?:async\s+)?fn\s+(\w+)").unwrap());
static RE_RUST_PRIV_FN:    Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*(?:async\s+)?fn\s+(\w+)").unwrap());
static RE_RUST_STRUCT:     Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*pub(?:\([^)]*\))?\s+struct\s+(\w+)").unwrap());
static RE_RUST_TRAIT:      Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*pub(?:\([^)]*\))?\s+trait\s+(\w+)").unwrap());
static RE_RUST_ENUM:       Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*pub(?:\([^)]*\))?\s+enum\s+(\w+)").unwrap());
static RE_RUST_TYPE:       Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*pub(?:\([^)]*\))?\s+type\s+(\w+)").unwrap());
static RE_RUST_CONST:      Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*pub(?:\([^)]*\))?\s+const\s+(\w+)").unwrap());
static RE_RUST_IMPL:       Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*impl(?:<[^>]*>)?\s+(?:\w+::)*(\w+)").unwrap());
static RE_RUST_USE:        Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*(?:pub\s+)?use\s+([^;]+);").unwrap());

static RE_TS_EXPORT_FN:    Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*export\s+(?:async\s+)?function\s+(\w+)").unwrap());
static RE_TS_EXPORT_CLASS: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*export\s+(?:abstract\s+)?class\s+(\w+)").unwrap());
static RE_TS_EXPORT_IFACE: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*export\s+interface\s+(\w+)").unwrap());
static RE_TS_EXPORT_TYPE:  Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*export\s+type\s+(\w+)").unwrap());
static RE_TS_EXPORT_CONST: Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*export\s+(?:const|let|var)\s+(\w+)").unwrap());
static RE_TS_EXPORT_ENUM:  Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*export\s+(?:const\s+)?enum\s+(\w+)").unwrap());
static RE_TS_IMPORT:       Lazy<Regex> = Lazy::new(|| Regex::new(r#"^[ \t]*import\s+.*from\s+['"]([^'"]+)['"]"#).unwrap());

static RE_SQL_TABLE:       Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^CREATE\s+(?:TABLE|VIEW)\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:\w+\.)?(\w+)").unwrap());
static RE_SQL_FUNCTION:    Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:\w+\.)?(\w+)").unwrap());
static RE_SQL_INDEX:       Lazy<Regex> = Lazy::new(|| Regex::new(r"(?i)^CREATE\s+(?:UNIQUE\s+)?INDEX\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)").unwrap());

static RE_PY_DEF:          Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*(?:async\s+)?def\s+(\w+)").unwrap());
static RE_PY_CLASS:        Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*class\s+(\w+)").unwrap());
static RE_PY_IMPORT:       Lazy<Regex> = Lazy::new(|| Regex::new(r"^[ \t]*(?:from\s+(\S+)\s+import|import\s+(\S+))").unwrap());

// ── Public API ────────────────────────────────────────────────────────────────

pub struct ParseResult {
    pub symbols:     Vec<AstSymbol>,
    pub imports:     Vec<String>,
    pub exports:     Vec<String>,
    pub doc_summary: Option<String>,
    /// Retained for the AST record even though no consumer reads it yet.
    #[allow(dead_code)]
    pub line_count:  u32,
}

pub fn parse(language: &str, source: &str) -> Result<ParseResult> {
    let mut symbols  = Vec::new();
    let mut imports  = Vec::new();
    let mut exports  = Vec::new();
    let mut doc_lines = Vec::new();
    let mut in_doc   = true; // collect leading comment as doc_summary

    for (i, line) in source.lines().enumerate() {
        let lineno = i as u32 + 1;

        // Collect leading doc comment (first comment block in file)
        if in_doc {
            let trimmed = line.trim();
            if trimmed.starts_with("//!") || trimmed.starts_with("///")
                || trimmed.starts_with("--") || trimmed.starts_with("#!")
                || trimmed.starts_with("\"\"\"") || trimmed.starts_with("/*")
            {
                doc_lines.push(trimmed.trim_start_matches(['/', '-', '#', '*', '!', '"', ' ']).trim().to_string());
            } else if !trimmed.is_empty() && !trimmed.starts_with("//")
                && !trimmed.starts_with("#") {
                in_doc = false;
            }
        }

        match language {
            "rust" => extract_rust(line, lineno, &mut symbols, &mut imports),
            "typescript" | "javascript" => extract_ts(line, lineno, &mut symbols, &mut imports, &mut exports),
            "sql" => extract_sql(line, lineno, &mut symbols),
            "python" => extract_python(line, lineno, &mut symbols, &mut imports),
            _ => {}
        }
    }

    // exports = pub symbols in Rust; already populated for TS
    if language == "rust" {
        exports = symbols.iter()
            .filter(|s| s.visibility.starts_with("pub"))
            .map(|s| s.name.clone())
            .collect();
    }

    let doc_summary = if doc_lines.is_empty() { None }
        else { Some(doc_lines.iter().filter(|l| !l.is_empty()).take(5).cloned().collect::<Vec<_>>().join(" ")) };

    Ok(ParseResult {
        symbols,
        imports,
        exports,
        doc_summary,
        line_count: source.lines().count() as u32,
    })
}

// ── Language-specific extractors ──────────────────────────────────────────────

fn extract_rust(line: &str, lineno: u32, symbols: &mut Vec<AstSymbol>, imports: &mut Vec<String>) {
    // pub use → import tracking
    if let Some(cap) = RE_RUST_USE.captures(line) {
        imports.push(cap[1].trim().to_string());
        return;
    }

    let rules: &[(&Lazy<Regex>, &str, &str)] = &[
        (&RE_RUST_PUB_FN,   "fn",     "pub"),
        (&RE_RUST_PRIV_FN,  "fn",     "private"),
        (&RE_RUST_STRUCT,   "struct", "pub"),
        (&RE_RUST_TRAIT,    "trait",  "pub"),
        (&RE_RUST_ENUM,     "enum",   "pub"),
        (&RE_RUST_TYPE,     "type",   "pub"),
        (&RE_RUST_CONST,    "const",  "pub"),
        (&RE_RUST_IMPL,     "impl",   "private"),
    ];
    for (re, kind, vis) in rules {
        if let Some(cap) = re.captures(line) {
            symbols.push(AstSymbol { name: cap[1].to_string(), kind: kind.to_string(), line: lineno, visibility: vis.to_string() });
            return;
        }
    }
}

fn extract_ts(line: &str, lineno: u32, symbols: &mut Vec<AstSymbol>, imports: &mut Vec<String>, exports: &mut Vec<String>) {
    if let Some(cap) = RE_TS_IMPORT.captures(line) {
        imports.push(cap[1].to_string());
        return;
    }
    let rules: &[(&Lazy<Regex>, &str)] = &[
        (&RE_TS_EXPORT_FN,    "fn"),
        (&RE_TS_EXPORT_CLASS, "class"),
        (&RE_TS_EXPORT_IFACE, "interface"),
        (&RE_TS_EXPORT_TYPE,  "type"),
        (&RE_TS_EXPORT_CONST, "const"),
        (&RE_TS_EXPORT_ENUM,  "enum"),
    ];
    for (re, kind) in rules {
        if let Some(cap) = re.captures(line) {
            let name = cap[1].to_string();
            exports.push(name.clone());
            symbols.push(AstSymbol { name, kind: kind.to_string(), line: lineno, visibility: "export".to_string() });
            return;
        }
    }
}

fn extract_sql(line: &str, lineno: u32, symbols: &mut Vec<AstSymbol>) {
    let rules: &[(&Lazy<Regex>, &str)] = &[
        (&RE_SQL_TABLE,    "table"),
        (&RE_SQL_FUNCTION, "fn"),
        (&RE_SQL_INDEX,    "index"),
    ];
    for (re, kind) in rules {
        if let Some(cap) = re.captures(line) {
            symbols.push(AstSymbol { name: cap[1].to_string(), kind: kind.to_string(), line: lineno, visibility: "pub".to_string() });
            return;
        }
    }
}

fn extract_python(line: &str, lineno: u32, symbols: &mut Vec<AstSymbol>, imports: &mut Vec<String>) {
    if let Some(cap) = RE_PY_IMPORT.captures(line) {
        let path = cap.get(1).or_else(|| cap.get(2)).map(|m| m.as_str()).unwrap_or("");
        imports.push(path.to_string());
        return;
    }
    let vis = if line.trim_start().starts_with("_") { "private" } else { "pub" };
    if let Some(cap) = RE_PY_DEF.captures(line) {
        symbols.push(AstSymbol { name: cap[1].to_string(), kind: "fn".to_string(), line: lineno, visibility: vis.to_string() });
    } else if let Some(cap) = RE_PY_CLASS.captures(line) {
        symbols.push(AstSymbol { name: cap[1].to_string(), kind: "class".to_string(), line: lineno, visibility: vis.to_string() });
    }
}
