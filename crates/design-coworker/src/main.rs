//! design-coworker — MCP server for the design coworker.
//!
//! # Purpose
//! The proof-of-loop slice of the coworkers platform
//! (apps/coworkers-desktop-buddy/COWORKERS-PLATFORM.md). The design coworker owns an
//! 8-token design system, lints proposed token sets, builds Claude Hardware Buddy
//! character-pack artifacts from tokens, and **gates publishing** behind operator
//! approval surfaced on the buddy device.
//!
//! # The loop
//!   tokens_get / tokens_lint → artifact_build (token set → buddy character pack)
//!     → artifact_request_publish (raises a gate on the buddy)
//!     → operator presses approve/deny on the device
//!     → artifact_finalize_publish (publishes iff approved)
//!
//! # Naming ontology
//!   {device_surface}__{client_surface}__{coworker_enum}
//!   macos__desktop_cowork__design_coworker
//!
//! # Transport
//! stdio (Docker MCP gateway or a claude_desktop_config.json entry).
//!
//! # Usage
//!   cargo run -p design-coworker -- --sessions-dir ./sessions --artifacts-dir ./artifacts

use anyhow::Result;
use clap::Parser;
use design_coworker::{
    self as design, Decision, DesignTokens, Gate,
};
use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    tool, tool_handler, tool_router,
};
use schemars::JsonSchema;
use serde::Deserialize;
use std::path::PathBuf;

// ── CLI ────────────────────────────────────────────────────────────────────────

#[derive(Parser, Debug, Clone)]
#[command(name = "design-coworker")]
struct Cli {
    /// Directory the buddy reads gate prompts from and writes decisions to.
    #[arg(env = "COWORK_SESSIONS_DIR", long, default_value = "sessions")]
    sessions_dir: PathBuf,

    /// Directory built character-pack artifacts are written to.
    #[arg(env = "DESIGN_ARTIFACTS_DIR", long, default_value = "artifacts")]
    artifacts_dir: PathBuf,
}

// ── Tool inputs ────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize, JsonSchema)]
struct TokensLintInput {
    /// A JSON object with all eight tokens: bg, surface, accent, body, text, textDim,
    /// ink, line. Omit to lint the canonical palette.
    tokens: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct ArtifactBuildInput {
    /// Pack name (becomes the character pack directory + manifest `name`).
    name: String,
    /// Optional token override (same shape as tokens_lint). Defaults to canonical.
    tokens: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct PublishRequestInput {
    /// Name of a previously built pack to publish.
    name: String,
    /// Opaque gate id the operator's decision will be keyed on.
    gate_id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
struct PublishFinalizeInput {
    /// Pack name passed to artifact_request_publish.
    name: String,
    /// Same gate id passed to artifact_request_publish.
    gate_id: String,
}

/// Empty params for no-argument tools. `Parameters<()>` fails to deserialize the
/// `arguments: {}` that standard MCP clients send for no-arg tool calls (serde's
/// unit-type `Deserialize` impl rejects a JSON object), surfacing as a -32602
/// "expected unit" error. An empty struct deserializes from `{}` cleanly.
#[derive(Debug, Deserialize, JsonSchema)]
struct NoArgs {}

// ── Server ─────────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct DesignCoworker {
    sessions_dir: PathBuf,
    artifacts_dir: PathBuf,
    tool_router: ToolRouter<Self>,
}

impl DesignCoworker {
    fn new(sessions_dir: PathBuf, artifacts_dir: PathBuf) -> Self {
        Self { sessions_dir, artifacts_dir, tool_router: Self::tool_router() }
    }

    /// Parse a token JSON value, falling back to the canonical palette.
    fn tokens_from(value: Option<serde_json::Value>) -> Result<DesignTokens, String> {
        match value {
            None => Ok(DesignTokens::canonical()),
            Some(v) => serde_json::from_value(v).map_err(|e| format!("bad tokens: {e}")),
        }
    }
}

#[tool_router(router = tool_router)]
impl DesignCoworker {
    /// Return the canonical 8-token design system as JSON.
    #[tool(description = "Get the canonical 8-token design system (bg, surface, accent, body, text, textDim, ink, line) as JSON.")]
    async fn tokens_get(&self, _input: Parameters<NoArgs>) -> String {
        serde_json::to_string_pretty(&DesignTokens::canonical()).unwrap()
    }

    /// Lint a token set against the 8-token rules and WCAG contrast.
    #[tool(description = "Lint a token set: validates all 8 hex tokens + WCAG contrast (text 4.5:1, accent/textDim 3:1). Returns findings; errors block publishing.")]
    async fn tokens_lint(&self, input: Parameters<TokensLintInput>) -> String {
        let tokens = match Self::tokens_from(input.0.tokens) {
            Ok(t) => t,
            Err(e) => return format!("error: {e}"),
        };
        let findings = design::lint(&tokens);
        serde_json::json!({
            "publishable": design::is_publishable(&tokens),
            "findings": findings,
        }).to_string()
    }

    /// Build a Hardware Buddy character pack from tokens and write it to disk.
    #[tool(description = "Build a buddy character pack (manifest.json + tokens.json) from a token set and write it under the artifacts dir. Refuses to build if linting has errors.")]
    async fn artifact_build(&self, input: Parameters<ArtifactBuildInput>) -> String {
        let tokens = match Self::tokens_from(input.0.tokens) {
            Ok(t) => t,
            Err(e) => return format!("error: {e}"),
        };
        if !design::is_publishable(&tokens) {
            return format!(
                "error: token set has blocking lint errors; fix before building:\n{}",
                serde_json::to_string_pretty(&design::lint(&tokens)).unwrap()
            );
        }
        match design::write_pack(&self.artifacts_dir, &input.0.name, &tokens) {
            Ok(path) => format!("built pack at {}", path.display()),
            Err(e) => format!("error: {e}"),
        }
    }

    /// Raise an approval gate on the buddy for publishing a built pack.
    /// This does NOT publish — it surfaces a prompt the operator must approve on
    /// the physical device. Poll artifact_finalize_publish for the outcome.
    #[tool(description = "Request to publish a built pack. Raises an approval gate on the buddy device (role=design). Does NOT publish yet — call artifact_finalize_publish after the operator decides.")]
    async fn artifact_request_publish(&self, input: Parameters<PublishRequestInput>) -> String {
        let name = match design::sanitize_component(&input.0.name) {
            Ok(n) => n.to_string(),
            Err(e) => return format!("error: {e}"),
        };
        let gate_id = match design::sanitize_component(&input.0.gate_id) {
            Ok(g) => g.to_string(),
            Err(e) => return format!("error: {e}"),
        };
        let pack = self.artifacts_dir.join(&name);
        if !pack.join("manifest.json").exists() {
            return format!("error: no built pack named '{name}' — run artifact_build first");
        }
        // Record the pack name in the gate so the approval is bound to *this* artifact.
        let gate = Gate::new(
            gate_id.clone(),
            "artifact_publish",
            name.clone(),
            format!("publish pack {name}"),
        );
        match design::emit_gate(&self.sessions_dir, &gate) {
            Ok(path) => format!(
                "gate raised on buddy: {} (id={gate_id}, pack={name}). Awaiting operator approval.",
                path.display()
            ),
            Err(e) => format!("error: {e}"),
        }
    }

    /// Finalize a publish: if the operator approved on the buddy, mark the pack
    /// published; if denied, abort; if no decision yet, report pending.
    #[tool(description = "Finalize a publish after the operator decides on the buddy. Publishes the pack iff approved (once); aborts on deny; reports pending otherwise.")]
    async fn artifact_finalize_publish(&self, input: Parameters<PublishFinalizeInput>) -> String {
        let name = match design::sanitize_component(&input.0.name) {
            Ok(n) => n.to_string(),
            Err(e) => return format!("error: {e}"),
        };
        let gate_id = match design::sanitize_component(&input.0.gate_id) {
            Ok(g) => g.to_string(),
            Err(e) => return format!("error: {e}"),
        };

        // 1. A gate must actually have been raised for this id — otherwise a stale or
        //    colliding permission-<id>.json could approve a publish nobody requested.
        let gate = match design::read_gate(&self.sessions_dir, &gate_id) {
            Ok(Some(g)) => g,
            Ok(None) => return format!(
                "error: no gate '{gate_id}' was raised — call artifact_request_publish first"
            ),
            Err(e) => return format!("error: {e}"),
        };
        // 2. The approval must be for the pack actually being published (no laundering
        //    one pack's approval into publishing another).
        if gate.name != name {
            return format!(
                "error: gate '{gate_id}' authorizes pack '{}', not '{name}' — refusing to publish",
                gate.name
            );
        }

        // 3. Honour the operator's decision.
        match design::read_decision(&self.sessions_dir, &gate_id) {
            Ok(None) => format!("pending: gate '{gate_id}' awaiting operator approval on the buddy"),
            Ok(Some(Decision::Deny)) => format!("denied: publish of '{name}' aborted by operator"),
            Ok(Some(Decision::Once)) => {
                let src = self.artifacts_dir.join(&name);
                if !src.join("manifest.json").exists() {
                    return format!("error: pack '{name}' no longer exists — rebuild before publishing");
                }
                let published = self.artifacts_dir.join("published");
                if let Err(e) = std::fs::create_dir_all(&published) {
                    return format!("error: {e}");
                }
                let marker = published.join(format!("{name}.published"));
                match std::fs::write(&marker, src.join("manifest.json").to_string_lossy().as_bytes()) {
                    Ok(_) => format!("approved: published '{name}' → {}", marker.display()),
                    Err(e) => format!("error: {e}"),
                }
            }
            Err(e) => format!("error: {e}"),
        }
    }
}

// ── rmcp glue ──────────────────────────────────────────────────────────────────

#[tool_handler(router = self.tool_router,
               name    = "design-coworker",
               version = "0.1.0",
               instructions = "The design coworker. Own an 8-token design system, lint token \
                               sets (WCAG contrast), build Claude Hardware Buddy character-pack \
                               artifacts from tokens, and gate publishing behind operator approval \
                               surfaced on the buddy device. Profile: \
                               macos__desktop_cowork__design_coworker.")]
impl ServerHandler for DesignCoworker {}

// ── main ───────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    use tracing_subscriber::{fmt, prelude::*, EnvFilter};
    tracing_subscriber::registry()
        .with(fmt::layer().with_writer(std::io::stderr))
        .with(EnvFilter::from_default_env())
        .init();

    let cli = Cli::parse();
    tracing::info!(
        sessions_dir = %cli.sessions_dir.display(),
        artifacts_dir = %cli.artifacts_dir.display(),
        profile = "macos__desktop_cowork__design_coworker",
        "design-coworker MCP server starting"
    );

    let server = DesignCoworker::new(cli.sessions_dir, cli.artifacts_dir);
    let service = server.serve(rmcp::transport::io::stdio()).await
        .map_err(|e| anyhow::anyhow!("server error: {e}"))?;
    service.waiting().await?;
    Ok(())
}
