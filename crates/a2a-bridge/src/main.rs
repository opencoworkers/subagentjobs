//! subagentjobs-a2a-bridge
//!
//! Exposes the subagentjobs MCP server as an A2A agent, so external A2A
//! clients (e.g. Gemini, other agents) can discover and invoke job-search
//! capabilities over the A2A protocol without knowing anything about MCP.
//!
//! ## How it works
//!
//!   External A2A client
//!       ↓  A2A JSON-RPC / HTTP+JSON
//!   [this binary]  ← a2a-server-lf (axum HTTP)
//!       ↓  MCP stdio
//!   subagentjobs-mcp-server  (crates/mcp-server)
//!
//! The bridge translates A2A `tasks/send` requests into MCP tool calls
//! (`search_jobs`, `get_job`) and streams results back as A2A task events.
//!
//! ## Transport choices
//!
//! A2A supports multiple transports; we implement two:
//!   1. HTTP+JSON  — broadest compatibility, including CF Workers front-ends
//!   2. JSON-RPC   — for direct agent-to-agent calls
//!   (gRPC is omitted: requires prost/tonic build, out of scope for now)
//!
//! ## AgentCard
//!
//! Published at GET /.well-known/agent-card.json — describes capabilities.
//! The CF Worker (workers/web) reverse-proxies this to the outside world.
//!
//! ## Running
//!
//!   A2A_ADDR=0.0.0.0:8080 \
//!   MCP_BINARY=/path/to/subagentjobs-mcp-server \
//!   DATABASE_URL=postgres://... \
//!   cargo run -p a2a-bridge
//!
//! ## Cross-platform notes
//!
//! On Windows the MCP binary must be `subagentjobs-mcp-server.exe`.
//! Set `MCP_BINARY` explicitly; auto-detection uses `which` on Unix.

use anyhow::{Context, Result};
use serde_json::{json, Value};
use std::sync::Arc;
use tracing::{error, info};

/// Runtime state shared across axum handlers.
struct AppState {
    mcp_binary: String,
}

// ── AgentCard ─────────────────────────────────────────────────────────────────

/// The AgentCard describes this agent to any A2A directory or client.
///
/// Spec: https://a2aproject.github.io/A2A/specification/#agent-card
fn agent_card() -> Value {
    json!({
        "name": "subagentjobs",
        "version": "0.1.0",
        "description": "AI job board aggregator. Discover and search 49 job boards curated for AI/agent engineers. Powered by subagentjobs.com.",
        "url": "https://subagentjobs.com",
        "defaultInputModes":  ["text/plain", "application/json"],
        "defaultOutputModes": ["text/plain", "application/json"],
        "capabilities": {
            "streaming": false,
            "pushNotifications": false,
            "stateTransitionHistory": false
        },
        "skills": [
            {
                "id": "search_jobs",
                "name": "Search Jobs",
                "description": "Full-text + filter search across 49 AI/agent job boards. Supports role, company, location, seniority, remote, salary filters.",
                "tags": ["jobs", "career", "ai", "agents"],
                "inputModes":  ["text/plain", "application/json"],
                "outputModes": ["application/json"]
            },
            {
                "id": "get_job",
                "name": "Get Job",
                "description": "Retrieve a specific job posting by its stable SHA256 URL key.",
                "tags": ["jobs", "career"],
                "inputModes":  ["application/json"],
                "outputModes": ["application/json"]
            }
        ]
    })
}

// ── MCP bridge helpers ────────────────────────────────────────────────────────

/// Spawn the MCP server binary as a child process over stdio and call a tool.
///
/// This is a simple synchronous spawn-and-read approach. For production use,
/// consider keeping the process alive and multiplexing calls with rmcp's
/// `ClientSession`. The current approach is stateless and easier to reason about.
async fn call_mcp_tool(
    mcp_binary: &str,
    tool_name: &str,
    tool_args: Value,
) -> Result<Value> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::process::Command;

    let mut child = Command::new(mcp_binary)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .with_context(|| format!("spawning MCP binary: {mcp_binary}"))?;

    let stdin  = child.stdin.take().expect("stdin");
    let stdout = child.stdout.take().expect("stdout");

    // MCP initialize request (JSON-RPC 2.0)
    let init_req = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": { "name": "a2a-bridge", "version": "0.1.0" }
        }
    });

    // Tool call request
    let call_req = json!({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": {
            "name": tool_name,
            "arguments": tool_args
        }
    });

    let init_line = serde_json::to_string(&init_req)? + "\n";
    let call_line = serde_json::to_string(&call_req)? + "\n";

    // Write both requests
    let mut stdin = stdin;
    stdin.write_all(init_line.as_bytes()).await?;
    stdin.write_all(call_line.as_bytes()).await?;
    drop(stdin);

    // Read stdout line by line, find the response to id=2
    let mut reader = BufReader::new(stdout).lines();
    let mut result: Option<Value> = None;

    while let Ok(Some(line)) = reader.next_line().await {
        if line.is_empty() { continue; }
        let v: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
        if v.get("id") == Some(&json!(2)) {
            result = Some(v);
            break;
        }
    }

    child.kill().await.ok();

    let resp = result.context("no response from MCP server")?;

    if let Some(err) = resp.get("error") {
        anyhow::bail!("MCP error: {err}");
    }

    Ok(resp["result"].clone())
}

// ── axum routes ───────────────────────────────────────────────────────────────

// These are placeholder handlers — the real a2a-server-lf framework wires
// routing via its `AgentExecutor` trait. Implement that trait here and call
// `a2a_server::serve(executor, addr)`.
//
// For now: an AgentCard endpoint + a stub tasks/send so the binary compiles
// and the architecture is clear. Replace stubs with `impl AgentExecutor` once
// a2a-server-lf API stabilises (it's still pre-release).

async fn handle_agent_card() -> axum::Json<Value> {
    axum::Json(agent_card())
}

async fn handle_tasks_send(
    axum::extract::State(state): axum::extract::State<Arc<AppState>>,
    axum::Json(body): axum::Json<Value>,
) -> axum::Json<Value> {
    // Extract the user's message text from the A2A tasks/send body.
    // A2A message format: body.params.message.parts[0].text
    let text = body
        .pointer("/params/message/parts/0/text")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    info!("tasks/send: {text}");

    // Interpret the request as a job search query.
    // A production implementation would parse skill IDs and structured args.
    let result = call_mcp_tool(
        &state.mcp_binary,
        "search_jobs",
        json!({ "query": text, "limit": 10 }),
    )
    .await;

    match result {
        Ok(data) => axum::Json(json!({
            "jsonrpc": "2.0",
            "id": body["id"],
            "result": {
                "id": uuid::Uuid::new_v4().to_string(),
                "status": { "state": "completed" },
                "artifacts": [{
                    "parts": [{ "type": "data", "data": data }]
                }]
            }
        })),
        Err(e) => {
            error!("MCP call failed: {e:#}");
            axum::Json(json!({
                "jsonrpc": "2.0",
                "id": body["id"],
                "error": { "code": -32000, "message": e.to_string() }
            }))
        }
    }
}

// ── main ──────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_default_env()
                .add_directive("a2a_bridge=info".parse()?),
        )
        .init();

    let addr = std::env::var("A2A_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into());
    let mcp_binary = std::env::var("MCP_BINARY")
        .unwrap_or_else(|_| "subagentjobs-mcp-server".into());

    let state = Arc::new(AppState { mcp_binary });

    use axum::routing::{get, post};
    let app = axum::Router::new()
        .route("/.well-known/agent-card.json", get(handle_agent_card))
        .route("/", post(handle_tasks_send))
        .with_state(state);

    info!("A2A bridge listening on {addr}");
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    axum::serve(listener, app).await?;
    Ok(())
}
