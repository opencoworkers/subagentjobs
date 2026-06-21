//! Filesystem walker — respects .gitignore, yields (relative_path, file_content).
//!
//! Powered by the `ignore` crate (same one used by ripgrep), so it automatically
//! skips .gitignore'd paths, node_modules, target/, .git/, etc.

use anyhow::Result;
use ignore::WalkBuilder;
use schema::vendor::VendorConfig;
use sha2::{Digest, Sha256};
use std::path::Path;

/// Max file size to read fully into memory (skip larger files — likely binary or generated).
const MAX_FILE_BYTES: u64 = 512 * 1024; // 512 KB

/// An individual file ready for indexing.
pub struct IndexFile {
    /// '{vendor_key}:{relative_path}'
    pub file_key:      String,
    pub vendor_key:    String,
    pub relative_path: String,
    pub extension:     Option<String>,
    pub size_bytes:    u64,
    pub sha256:        String,
    /// None if file is binary, too large, or unreadable
    pub content:       Option<String>,
}

/// Walk a vendor repo and yield all indexable files.
pub fn walk_vendor(repo_root: &Path, config: &VendorConfig) -> Result<Vec<IndexFile>> {
    let vendor_key = config.vendor_key();
    let mut files = Vec::new();

    let walker = WalkBuilder::new(repo_root)
        .git_ignore(true)   // respect .gitignore
        .git_global(true)   // respect global gitignore
        .hidden(true)       // skip hidden files (but still traverse hidden dirs like .github)
        .require_git(false) // don't require a git repo
        // Common non-source dirs to skip even without gitignore
        .filter_entry(|e| {
            let name = e.file_name().to_string_lossy();
            !matches!(
                name.as_ref(),
                "target" | "node_modules" | ".git" | "__pycache__"
                | "dist" | "build" | ".wrangler" | "coverage"
            )
        })
        .build();

    for entry in walker.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        // to_string_lossy() → Cow<str>, .replace() → String (owned)
        let relative: String = path.strip_prefix(repo_root)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/"); // normalise path separators on Windows

        let ext = path.extension()
            .and_then(|e| e.to_str())
            .map(str::to_lowercase);

        let metadata = std::fs::metadata(path).ok();
        let size = metadata.as_ref().map(|m| m.len()).unwrap_or(0);

        // Skip large files and likely-binary files
        if size > MAX_FILE_BYTES || is_likely_binary(ext.as_deref()) {
            continue;
        }

        let content = std::fs::read_to_string(path).ok();
        let sha256 = match &content {
            Some(s) => sha256_hex(s.as_bytes()),
            None    => sha256_hex(&std::fs::read(path).unwrap_or_default()),
        };

        files.push(IndexFile {
            file_key:      format!("{vendor_key}:{relative}"),
            vendor_key:    vendor_key.clone(),
            relative_path: relative,
            extension:     ext,
            size_bytes:    size,
            sha256,
            content,
        });
    }

    Ok(files)
}

fn sha256_hex(data: &[u8]) -> String {
    hex::encode(Sha256::digest(data))
}

/// Quick heuristic: skip file extensions that are almost always binary.
fn is_likely_binary(ext: Option<&str>) -> bool {
    matches!(
        ext,
        Some("png" | "jpg" | "jpeg" | "gif" | "webp" | "ico" | "svg" |
             "wasm" | "bin" | "exe" | "dll" | "so" | "dylib" |
             "zip" | "tar" | "gz" | "tgz" | "bz2" | "xz" |
             "pdf" | "ttf" | "woff" | "woff2" | "eot" |
             "mp4" | "mp3" | "wav" | "avi" | "mov" |
             "lock" // Cargo.lock, package-lock.json — large, generated
        )
    )
}

/// Compute the current HEAD commit SHA for a repo (requires git on PATH).
pub fn git_head_sha(repo_root: &Path) -> Option<String> {
    std::process::Command::new("git")
        .args(["-C", &repo_root.to_string_lossy(), "rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
}
