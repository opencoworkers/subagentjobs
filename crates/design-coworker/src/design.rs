//! design-coworker — pure design-system logic (no I/O except the gate file helpers).
//!
//! This is the proof-of-loop for the coworkers platform (see
//! apps/coworkers-desktop-buddy/COWORKERS-PLATFORM.md): the *design* coworker owns
//! an 8-token design system, lints proposed token sets, and turns tokens into a
//! Claude Hardware Buddy **character pack** — a real design artifact the buddy can
//! render. Publishing that artifact is **gated**: it surfaces on the buddy device
//! and only proceeds after the operator presses approve.
//!
//! Everything here is pure + unit-tested so the loop is verifiable without a Mac or
//! a physical device. The MCP server in `main.rs` is a thin wrapper over these fns.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

// ── The 8-token design system ────────────────────────────────────────────────

/// Exactly eight semantic tokens. The constraint is the point: a small, fixed
/// palette is what keeps a design system coherent (the coworkers.subagentknowledge
/// .com "8-token design system"). Field names double as the token names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DesignTokens {
    /// Window / canvas background.
    pub bg: String,
    /// Raised panel surface.
    pub surface: String,
    /// Primary brand accent (buttons, active state).
    pub accent: String,
    /// Character / illustration body fill.
    pub body: String,
    /// Primary text.
    pub text: String,
    /// Secondary / dimmed text.
    #[serde(rename = "textDim")]
    pub text_dim: String,
    /// Darkest ink (outlines, shadows).
    pub ink: String,
    /// Hairline / divider.
    pub line: String,
}

impl DesignTokens {
    /// The canonical subagentjobs palette (M5-orange on warm dark).
    pub fn canonical() -> Self {
        Self {
            bg:       "#0E0E0E".into(),
            surface:  "#1A1714".into(),
            accent:   "#D4825A".into(),
            body:     "#6B8E23".into(),
            text:     "#FFFFFF".into(),
            text_dim: "#9A9A9A".into(),
            ink:      "#000000".into(),
            line:     "#2E2A26".into(),
        }
    }

    /// All (name, value) pairs in declaration order.
    pub fn pairs(&self) -> [(&'static str, &str); 8] {
        [
            ("bg", &self.bg),
            ("surface", &self.surface),
            ("accent", &self.accent),
            ("body", &self.body),
            ("text", &self.text),
            ("textDim", &self.text_dim),
            ("ink", &self.ink),
            ("line", &self.line),
        ]
    }
}

// ── Colour maths (WCAG) ───────────────────────────────────────────────────────

/// Parse `#RRGGBB` into linear-ish sRGB components 0..=255. Returns None on bad input.
pub fn parse_hex(s: &str) -> Option<(u8, u8, u8)> {
    let h = s.strip_prefix('#')?;
    if h.len() != 6 || !h.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let r = u8::from_str_radix(&h[0..2], 16).ok()?;
    let g = u8::from_str_radix(&h[2..4], 16).ok()?;
    let b = u8::from_str_radix(&h[4..6], 16).ok()?;
    Some((r, g, b))
}

/// WCAG relative luminance of an `#RRGGBB` colour (0.0..=1.0).
pub fn relative_luminance(hex: &str) -> Option<f64> {
    let (r, g, b) = parse_hex(hex)?;
    fn chan(c: u8) -> f64 {
        let s = c as f64 / 255.0;
        if s <= 0.03928 { s / 12.92 } else { ((s + 0.055) / 1.055).powf(2.4) }
    }
    Some(0.2126 * chan(r) + 0.7152 * chan(g) + 0.0722 * chan(b))
}

/// WCAG contrast ratio between two colours (1.0..=21.0). None on bad input.
pub fn contrast_ratio(a: &str, b: &str) -> Option<f64> {
    let la = relative_luminance(a)?;
    let lb = relative_luminance(b)?;
    let (hi, lo) = if la >= lb { (la, lb) } else { (lb, la) };
    Some((hi + 0.05) / (lo + 0.05))
}

// ── Lint ──────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity { Error, Warn }

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LintFinding {
    pub severity: Severity,
    pub token: String,
    pub message: String,
}

/// Validate a token set. Errors block publishing; warnings are advisory.
pub fn lint(tokens: &DesignTokens) -> Vec<LintFinding> {
    let mut out = Vec::new();

    // 1. Every token must be a valid #RRGGBB hex.
    for (name, value) in tokens.pairs() {
        if parse_hex(value).is_none() {
            out.push(LintFinding {
                severity: Severity::Error,
                token: name.into(),
                message: format!("`{value}` is not a valid #RRGGBB colour"),
            });
        }
    }
    // Stop here if any colour is unparseable — contrast maths would be meaningless.
    if out.iter().any(|f| f.severity == Severity::Error) {
        return out;
    }

    // 2. Primary text must hit WCAG AA (4.5:1) against the background.
    if let Some(c) = contrast_ratio(&tokens.text, &tokens.bg) {
        if c < 4.5 {
            out.push(LintFinding {
                severity: Severity::Error,
                token: "text".into(),
                message: format!("text/bg contrast {c:.2}:1 below WCAG AA 4.5:1"),
            });
        }
    }
    // 3. Accent must be distinguishable against the background (3:1).
    if let Some(c) = contrast_ratio(&tokens.accent, &tokens.bg) {
        if c < 3.0 {
            out.push(LintFinding {
                severity: Severity::Warn,
                token: "accent".into(),
                message: format!("accent/bg contrast {c:.2}:1 below 3:1 (may look muddy)"),
            });
        }
    }
    // 4. Dimmed text should still be legible (3:1) but is allowed to be soft.
    if let Some(c) = contrast_ratio(&tokens.text_dim, &tokens.bg) {
        if c < 3.0 {
            out.push(LintFinding {
                severity: Severity::Warn,
                token: "textDim".into(),
                message: format!("textDim/bg contrast {c:.2}:1 below 3:1"),
            });
        }
    }
    // 5. ink should be the darkest token (it's used for outlines).
    if let (Some(ink), Some(text)) =
        (relative_luminance(&tokens.ink), relative_luminance(&tokens.text))
    {
        if ink > text {
            out.push(LintFinding {
                severity: Severity::Warn,
                token: "ink".into(),
                message: "ink is lighter than text — outlines may disappear".into(),
            });
        }
    }
    out
}

/// True if a token set has no blocking errors and may be built/published.
pub fn is_publishable(tokens: &DesignTokens) -> bool {
    !lint(tokens).iter().any(|f| f.severity == Severity::Error)
}

// ── Artifact: token set → Hardware Buddy character pack ───────────────────────

/// The seven buddy states each map to a GIF filename inside the pack.
const STATE_FILES: [(&str, &str); 7] = [
    ("sleep", "sleep.gif"),
    ("busy", "busy.gif"),
    ("attention", "attention.gif"),
    ("celebrate", "celebrate.gif"),
    ("dizzy", "dizzy.gif"),
    ("heart", "heart.gif"),
    ("idle", "idle.gif"), // handled specially as an array below
];

/// Build a `manifest.json` for a Hardware Buddy character pack from tokens.
///
/// The output is byte-shape-compatible with `BuddyCore/CharacterManifest.swift`
/// (`name`, `colors{body,bg,text,textDim,ink}`, `states{...}`), so the artifact a
/// designer produces here renders directly on the buddy.
pub fn build_manifest(name: &str, tokens: &DesignTokens) -> serde_json::Value {
    let mut states = serde_json::Map::new();
    for (state, file) in STATE_FILES {
        if state == "idle" {
            // Idle supports a carousel; emit a 3-frame array to exercise that path.
            states.insert(
                "idle".into(),
                serde_json::json!(["idle_0.gif", "idle_1.gif", "idle_2.gif"]),
            );
        } else {
            states.insert(state.into(), serde_json::json!(file));
        }
    }
    serde_json::json!({
        "name": name,
        "colors": {
            "body":    tokens.body,
            "bg":      tokens.bg,
            "text":    tokens.text,
            "textDim": tokens.text_dim,
            "ink":     tokens.ink,
        },
        "states": states,
    })
}

/// Write a pack directory containing `manifest.json` and a `tokens.json` sidecar.
/// Returns the manifest path. (GIF frames are produced by the designer separately;
/// the manifest + tokens are the reviewable design artifact.)
pub fn write_pack(dir: &Path, name: &str, tokens: &DesignTokens) -> std::io::Result<PathBuf> {
    let name = sanitize_component(name).map_err(io_invalid)?;
    let pack = dir.join(name);
    std::fs::create_dir_all(&pack)?;
    let manifest = build_manifest(name, tokens);
    let manifest_path = pack.join("manifest.json");
    std::fs::write(&manifest_path, serde_json::to_vec_pretty(&manifest).unwrap())?;
    std::fs::write(
        pack.join("tokens.json"),
        serde_json::to_vec_pretty(tokens).unwrap(),
    )?;
    Ok(manifest_path)
}

// ── Approval gate (the human-in-the-loop loop) ────────────────────────────────

/// Reject names that could escape a directory or collide with control chars.
/// Used for both pack names and gate ids before they are interpolated into a
/// filesystem path. Returns the validated component unchanged.
pub fn sanitize_component(name: &str) -> Result<&str, String> {
    if name.is_empty() {
        return Err("name must not be empty".into());
    }
    if name.len() > 128 {
        return Err("name too long (max 128 chars)".into());
    }
    if name.starts_with('.') {
        return Err(format!("invalid name '{name}': must not start with '.'"));
    }
    if name.contains("..") {
        return Err(format!("invalid name '{name}': must not contain '..'"));
    }
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.') {
        return Err(format!(
            "invalid name '{name}': only [A-Za-z0-9._-] allowed (no path separators)"
        ));
    }
    Ok(name)
}

fn io_invalid(e: String) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::InvalidInput, e)
}

/// A pending gate the design coworker raises before a side-effecting action.
/// Shape matches the buddy's `WirePermissionPrompt` plus a `role`, so the device
/// can show *who* is asking. Written as `gate-<id>.json` into the sessions dir.
///
/// `name` records the artifact the operator is approving — finalize binds the
/// decision to this so an approval for one pack cannot publish another.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Gate {
    pub role: String,
    pub id: String,
    pub tool: String,
    /// The artifact (pack) name this gate authorizes.
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub hint: String,
}

impl Gate {
    pub fn new(
        id: impl Into<String>,
        tool: impl Into<String>,
        name: impl Into<String>,
        hint: impl Into<String>,
    ) -> Self {
        Self {
            role: "design".into(),
            id: id.into(),
            tool: tool.into(),
            name: name.into(),
            hint: hint.into(),
        }
    }
}

/// The operator's decision, as written back by the buddy (`permission-<id>.json`).
/// Mirrors `PermissionDecision` in src/protocol.rs / HardwareBuddyProtocol.swift.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Decision { Once, Deny }

#[derive(Debug, Deserialize)]
struct DecisionFile {
    #[allow(dead_code)]
    cmd: String,
    id: String,
    decision: Decision,
}

/// Emit a gate request into `sessions_dir` for the buddy to surface.
pub fn emit_gate(sessions_dir: &Path, gate: &Gate) -> std::io::Result<PathBuf> {
    sanitize_component(&gate.id).map_err(io_invalid)?;
    std::fs::create_dir_all(sessions_dir)?;
    let path = sessions_dir.join(format!("gate-{}.json", gate.id));
    std::fs::write(&path, serde_json::to_vec(gate).unwrap())?;
    Ok(path)
}

/// Read back a previously emitted gate, if one exists for `id`. Returns
/// `Ok(None)` when no gate was raised — used by finalize to refuse honouring a
/// decision file unless a gate actually preceded it.
pub fn read_gate(sessions_dir: &Path, id: &str) -> std::io::Result<Option<Gate>> {
    sanitize_component(id).map_err(io_invalid)?;
    let path = sessions_dir.join(format!("gate-{id}.json"));
    match std::fs::read(&path) {
        Ok(bytes) => {
            let gate: Gate = serde_json::from_slice(&bytes)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            Ok(Some(gate))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// Read the operator's decision for a gate, if one has been written yet.
/// Returns `Ok(None)` while the gate is still pending. The decision file's own
/// `id` must match the requested `id` — a decision written for a different gate
/// is rejected rather than silently honoured.
pub fn read_decision(sessions_dir: &Path, id: &str) -> std::io::Result<Option<Decision>> {
    sanitize_component(id).map_err(io_invalid)?;
    let path = sessions_dir.join(format!("permission-{id}.json"));
    match std::fs::read(&path) {
        Ok(bytes) => {
            let parsed: DecisionFile = serde_json::from_slice(&bytes)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            if parsed.id != id {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    format!("decision file id '{}' does not match gate id '{id}'", parsed.id),
                ));
            }
            Ok(Some(parsed.decision))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_palette_is_publishable() {
        let t = DesignTokens::canonical();
        let findings = lint(&t);
        assert!(is_publishable(&t), "canonical palette must pass: {findings:?}");
    }

    #[test]
    fn exactly_eight_tokens() {
        assert_eq!(DesignTokens::canonical().pairs().len(), 8);
    }

    #[test]
    fn rejects_bad_hex() {
        let mut t = DesignTokens::canonical();
        t.accent = "not-a-color".into();
        let f = lint(&t);
        assert!(f.iter().any(|x| x.token == "accent" && x.severity == Severity::Error));
        assert!(!is_publishable(&t));
    }

    #[test]
    fn flags_low_text_contrast() {
        let mut t = DesignTokens::canonical();
        t.text = "#111111".into(); // near-black text on near-black bg
        let f = lint(&t);
        assert!(
            f.iter().any(|x| x.token == "text" && x.severity == Severity::Error),
            "expected AA contrast error, got {f:?}"
        );
        assert!(!is_publishable(&t));
    }

    #[test]
    fn contrast_extremes() {
        let c = contrast_ratio("#FFFFFF", "#000000").unwrap();
        assert!((c - 21.0).abs() < 0.01, "white/black should be 21:1, got {c}");
        assert!((contrast_ratio("#777777", "#777777").unwrap() - 1.0).abs() < 0.01);
    }

    #[test]
    fn manifest_matches_buddy_schema() {
        let t = DesignTokens::canonical();
        let m = build_manifest("bufo", &t);
        assert_eq!(m["name"], "bufo");
        assert_eq!(m["colors"]["bg"], t.bg);
        assert_eq!(m["colors"]["textDim"], t.text_dim); // buddy uses textDim key
        assert!(m["states"]["idle"].is_array(), "idle must be a carousel array");
        assert_eq!(m["states"]["sleep"], "sleep.gif");
    }

    #[test]
    fn write_pack_roundtrips() {
        let dir = std::env::temp_dir().join(format!("design-pack-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let t = DesignTokens::canonical();
        let mpath = write_pack(&dir, "bufo", &t).unwrap();
        assert!(mpath.exists());
        let back: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&mpath).unwrap()).unwrap();
        assert_eq!(back["name"], "bufo");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn gate_roundtrip_approve_and_deny() {
        let dir = std::env::temp_dir().join(format!("design-gate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let gate = Gate::new("g1", "artifact_publish", "bufo", "publish pack bufo");
        emit_gate(&dir, &gate).unwrap();
        // The gate is now readable and records the pack it authorizes.
        assert_eq!(read_gate(&dir, "g1").unwrap().unwrap().name, "bufo");

        // Pending until the buddy writes a decision.
        assert_eq!(read_decision(&dir, "g1").unwrap(), None);

        // Operator approves on the device (buddy writes permission-g1.json).
        std::fs::write(
            dir.join("permission-g1.json"),
            br#"{"cmd":"permission","id":"g1","decision":"once"}"#,
        ).unwrap();
        assert_eq!(read_decision(&dir, "g1").unwrap(), Some(Decision::Once));

        // A denial flows through the same path.
        std::fs::write(
            dir.join("permission-g2.json"),
            br#"{"cmd":"permission","id":"g2","decision":"deny"}"#,
        ).unwrap();
        assert_eq!(read_decision(&dir, "g2").unwrap(), Some(Decision::Deny));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn gate_json_carries_role_and_name() {
        let gate = Gate::new("g9", "artifact_publish", "bufo", "h");
        let v: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&gate).unwrap()).unwrap();
        assert_eq!(v["role"], "design");
        assert_eq!(v["tool"], "artifact_publish");
        assert_eq!(v["name"], "bufo");
    }

    #[test]
    fn sanitize_rejects_traversal() {
        assert!(sanitize_component("bufo").is_ok());
        assert!(sanitize_component("bufo-2_v1.0").is_ok());
        for bad in ["../evil", "a/b", "a\\b", "..", ".hidden", "", "a..b", "name with space"] {
            assert!(sanitize_component(bad).is_err(), "should reject {bad:?}");
        }
    }

    #[test]
    fn write_pack_rejects_unsafe_name() {
        let dir = std::env::temp_dir().join(format!("design-unsafe-{}", std::process::id()));
        let err = write_pack(&dir, "../escape", &DesignTokens::canonical()).unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_decision_rejects_id_mismatch() {
        let dir = std::env::temp_dir().join(format!("design-mismatch-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // Decision file named for gA but whose internal id says gB — must be rejected,
        // not silently accepted (defends against stale/colliding decision files).
        std::fs::write(
            dir.join("permission-gA.json"),
            br#"{"cmd":"permission","id":"gB","decision":"once"}"#,
        ).unwrap();
        assert!(read_decision(&dir, "gA").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_gate_absent_is_none() {
        let dir = std::env::temp_dir().join(format!("design-nogate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(read_gate(&dir, "never").unwrap(), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
