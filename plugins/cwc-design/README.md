# cwc-design

The **design coworker**, packaged as a Claude plugin — the proof-of-loop slice of
the [coworkers platform](../../apps/coworkers-desktop-buddy/COWORKERS-PLATFORM.md).

It owns an **8-token design system**, lints token sets (WCAG contrast), builds
**Claude Hardware Buddy character packs** from tokens, and **gates publishing**
behind operator approval surfaced on the buddy device.

## What's in the box

| Path | Type | Purpose |
|---|---|---|
| `commands/design.md` | Slash command | `/design [get\|lint\|build <name>\|publish <name>]` |
| `skills/design-playbook/` | Skill | The role's how-to (tokens → pack → gated publish) |
| `agents/design-coworker.yaml` | Agent | Generated from `crates/agent-gen` (least-privilege) |
| `mcp/servers.json` | MCP config | Wires the `design-coworker` MCP binary |
| `gates.toml` | Gate policy | `artifact_publish` requires operator approval on the buddy |

The MCP server itself lives in `crates/design-coworker` (Rust, rmcp/stdio).

## Install

```
/plugin install cwc-design@subagentjobs
```

## Build the server

```bash
cargo build -p design-coworker      # → target/debug/design-coworker
cargo test  -p design-coworker      # token engine, lint, artifact, gate roundtrip
```

## The loop

```
tokens_get / tokens_lint
   → artifact_build <name>                 # token set → buddy character pack
   → artifact_request_publish <name> <id>  # raises a gate on the buddy (role=design)
   → operator approves/denies on the device
   → artifact_finalize_publish <name> <id> # publishes iff approved
```

Publishing is the only side-effecting action, so it is the only gated one. The
gate is rendered as a buddy permission prompt and resolved by a physical button
press — the same human-in-the-loop path the desktop buddy already uses for session
permission prompts.

## License

MIT (see `LICENSE`).
