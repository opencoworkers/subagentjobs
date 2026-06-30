---
name: design-playbook
description: >-
  Design coworker playbook — work the 8-token design system and ship Claude
  Hardware Buddy character packs through the gated publish loop. Use when the user
  wants design tokens, a token lint (WCAG contrast), a buddy character pack built
  from tokens, or a pack published (which requires operator approval on the buddy
  device). Trigger on "design tokens", "lint the palette", "build a buddy pack",
  "publish the pack", or follow-up design work after /design.
---

# Design coworker playbook

The design coworker owns one thing end to end: **the 8-token design system → a
Hardware Buddy character pack → published, with a human approving the publish on
the physical buddy.** This is the proof-of-loop slice of the coworkers platform
(`apps/coworkers-desktop-buddy/COWORKERS-PLATFORM.md`).

## The 8 tokens

A coherent system is a *small* one. There are exactly eight semantic tokens:

| Token | Meaning |
|---|---|
| `bg` | Window / canvas background |
| `surface` | Raised panel surface |
| `accent` | Primary brand accent (buttons, active state) |
| `body` | Character / illustration body fill |
| `text` | Primary text |
| `textDim` | Secondary / dimmed text |
| `ink` | Darkest ink (outlines, shadows) |
| `line` | Hairline / divider |

All eight are `#RRGGBB`. The canonical palette is M5-orange on warm dark.

## Setup

```bash
cargo build -p design-coworker          # builds target/debug/design-coworker
```

The MCP server is wired by this plugin's `mcp/servers.json`. It reads/writes the
gate handshake in `$COWORK_SESSIONS_DIR` and writes artifacts to
`$DESIGN_ARTIFACTS_DIR` (defaults: `sessions/`, `artifacts/`).

## The loop

1. **Inspect / lint** — `tokens_get`, then `tokens_lint` on any proposed change.
   Lint rules: every token a valid hex; `text/bg` ≥ WCAG AA 4.5:1 (error);
   `accent/bg` and `textDim/bg` ≥ 3:1 (warn); `ink` no lighter than `text` (warn).
   Errors block building and publishing — fix the palette first.
2. **Build** — `artifact_build <name>` writes a character pack: `manifest.json`
   (byte-compatible with the buddy's `CharacterManifest`) + a `tokens.json`
   sidecar. The manifest's `colors` are derived from the tokens, so the pack
   renders on the buddy with the exact palette.
3. **Request publish** — `artifact_request_publish <name> <gate_id>` raises an
   approval gate. Nothing is published yet — the gate appears on the operator's
   buddy device as a `role = design` permission prompt.
4. **Operator decides** — the operator presses approve / deny on the hardware
   (or, in software, a `permission-<gate_id>.json` is written into the sessions
   dir, exactly as the desktop app's Approve/Deny buttons do).
5. **Finalize** — `artifact_finalize_publish <name> <gate_id>` reads the decision
   and publishes the pack **iff approved**. Report the real outcome — approved,
   denied, or still pending. Never assume approval.

## Why the gate matters

The gate is the whole thesis of the platform in miniature: a coworker's
side-effecting action surfaces on the physical buddy and is granted by a human
button press. `cwc-finance` and `cwc-legal` reuse exactly this machinery with
different playbooks; only the policy in `gates.toml` differs.
