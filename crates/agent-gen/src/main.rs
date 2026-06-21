//! agent-gen — generate `.claude/agents/*.yaml` from typed Rust definitions.
//!
//! ## Usage
//!
//!   cargo run -p agent-gen              # writes to .claude/agents/
//!   cargo run -p agent-gen -- --check   # validate only, no write (CI mode)
//!   cargo run -p agent-gen -- --print   # print YAML to stdout, no write
//!   cargo run -p agent-gen -- --out <dir>  # write to custom directory
//!
//! ## Why Rust over markdown?
//!
//! Plain markdown agent files have no schema — a typo in `tool` or an invalid
//! model name fails silently at runtime. By defining agents as Rust structs:
//!   - Invalid tool names are caught at compile time (exhaustive enum)
//!   - Description length is validated before writing
//!   - The YAML is always in sync with the typed source of truth
//!   - Diffs are meaningful: model/tool changes show up in `crates/agent-gen/`
//!
//! ## TypeScript alternative
//!
//! `scripts/agents/generate.ts` provides the same functionality using Zod for
//! projects that prefer a Node.js toolchain. Both generate identical YAML.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

mod agents;

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let check_only = args.iter().any(|a| a == "--check");
    let print_only = args.iter().any(|a| a == "--print");
    let out_dir: PathBuf = args
        .iter()
        .position(|a| a == "--out")
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(".claude/agents"));

    let agent_list = agents::all_agents();

    // Validate all agents first — fail fast before touching the filesystem.
    for agent in &agent_list {
        agent.validate();
    }

    println!("✓ validated {} agents", agent_list.len());

    if print_only {
        for agent in &agent_list {
            println!("\n# ─── {} ─────────────────────────", agent.name);
            print!("{}", agent.to_yaml());
        }
        return Ok(());
    }

    if check_only {
        println!("✓ check passed — all agent configs are valid (no files written)");
        return Ok(());
    }

    // Write to .claude/agents/
    std::fs::create_dir_all(&out_dir)
        .with_context(|| format!("creating {}", out_dir.display()))?;

    for agent in &agent_list {
        let path = out_dir.join(format!("{}.yaml", agent.name));
        write_if_changed(&path, &agent.to_yaml())?;
    }

    println!("✓ wrote {} agent files to {}", agent_list.len(), out_dir.display());
    Ok(())
}

/// Write `content` to `path` only if the file doesn't already have that content.
/// Avoids touching mtimes on unchanged files (keeps git status clean).
fn write_if_changed(path: &Path, content: &str) -> Result<()> {
    if let Ok(existing) = std::fs::read_to_string(path) {
        if existing == content {
            println!("  ─ unchanged: {}", path.display());
            return Ok(());
        }
    }
    std::fs::write(path, content)
        .with_context(|| format!("writing {}", path.display()))?;
    println!("  ✓ wrote:     {}", path.display());
    Ok(())
}
