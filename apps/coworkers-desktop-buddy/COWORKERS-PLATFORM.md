# Coworkers Platform — design

> Status: design / RFC. This document thinks through turning
> `coworkers-desktop-buddy` from a single virtual pet into the **ambient surface
> of a role-based coworker platform** — Design, Engineering, Product, Data, Legal,
> Finance — packaged as installable Claude plugins.

## 1. Where the idea comes from

Three existing things, each contributing one layer:

| Source | Layer it contributes | What we borrow |
|---|---|---|
| [coworkers.subagentknowledge.com](https://coworkers.subagentknowledge.com/) | **Behaviour** — protocol-native *peer* coworkers | Role taxonomy, peer messaging over a2a/acp/mcp, **approval gates** (Legal/Finance never act without operator approval) |
| [`cwc-makers`](https://github.com/anthropics/claude-plugins-official/tree/main/plugins/cwc-makers) | **Packaging** — a Claude plugin | `.claude-plugin/` manifest + `commands/` + `skills/` + `agents/`, installable from a marketplace |
| [`claude-desktop-buddy`](https://github.com/anthropics/claude-desktop-buddy) | **Surface** — ambient hardware/visual presence | BLE wire protocol, 7-state pet, permission prompt → physical approve/deny |

The key realisation: **these are orthogonal axes, not competing designs.** A coworker
is *behaviour* (a role + tools + gates), *shipped as* a plugin, and *made visible
through* the buddy surface. Today the repo only has one coworker (`engineering`) and
one surface (the virtual pet). This design generalises both.

## 2. What already exists in this repo (build on, don't rebuild)

- **Type-safe agent system** — `crates/schema/src/agent.rs` (`AgentConfig`, `AgentModel`,
  `AgentTool`, least-privilege tool lists) → `crates/agent-gen` → `.claude/agents/*.yaml`.
  This is already the right primitive for *defining a coworker's agent*.
- **`engineering-coworker` MCP server** (`crates/engineering-coworker`) — exposes
  cargo/wrangler/git/d1 tools. This is the template for a **per-role MCP server**.
- **a2a-bridge** (`crates/a2a-bridge`) — wraps an MCP server as an A2A agent. This is
  the **peer-to-peer transport** the coworkers site describes.
- **Naming ontology** — `{device_surface}__{client_surface}__{coworker_enum}`. The
  `coworker_enum` slot is *exactly* the role axis; today it only has
  `engineering_coworker`. We extend the enum.
- **Desktop buddy** — `apps/coworkers-desktop-buddy`. The BLE link + permission
  approve/deny path (now wired to real hardware) is the **approval-gate surface**.

## 3. Core model

```
                       ┌──────────────────────────────────────────┐
                       │            Coworker (a role)              │
                       │                                           │
  plugin packaging  →  │  .claude-plugin/   commands/   skills/    │
                       │  agents/  (generated from schema)         │
                       │  mcp/      (per-role MCP server)          │
                       │  gates.toml (approval policy)             │
                       └───────────────┬───────────────────────────┘
                                       │ a2a / mcp (peer messaging)
            ┌──────────────────────────┼──────────────────────────┐
            ▼                          ▼                          ▼
   product-management          engineering                    legal
   (orchestrator)              (TS/Rust + MCP)                (review + gate)
            │                          │                          │
            └──────────────► CoworkerBus (a2a-bridge) ◄───────────┘
                                       │
                                       ▼  HeartbeatSnapshot + gate prompts
                          ┌─────────────────────────────┐
                          │  coworkers-desktop-buddy    │  ← ambient surface
                          │  (macOS app + BLE device)   │     • per-coworker lanes
                          └─────────────────────────────┘     • approval gates → buttons
```

A **coworker** = `RoleConfig { role, agent: AgentConfig, mcp: McpServerSpec, gates: GatePolicy }`.
The plugin is the distributable wrapper; the buddy is the shared window onto all of them.

## 4. Role taxonomy → coworker_enum

Extend the ontology enum and ship one plugin per role. Mapping the requested roles to
the coworkers.subagentknowledge.com behaviours and to repo assets:

| Plugin | `coworker_enum` | Owns | Approval gate | Reuses |
|---|---|---|---|---|
| `cwc-engineering` | `engineering_coworker` | TS/Rust, MCP framework, templates | OAuth-only writes | **exists**: `engineering-coworker` MCP |
| `cwc-design`      | `design_coworker` | Design tokens, HTML artifacts (8-token system) | — | new MCP: token lint, artifact preview |
| `cwc-product`     | `product_coworker` | Routing/priority across peers (orchestrator) | — | a2a-bridge as the bus |
| `cwc-data`        | `data_coworker` | Warehouse (D1/AlloyDB, Kimball facts) | read-only by default | **exists**: D1 tools, `crates/indexer` |
| `cwc-legal`       | `legal_coworker` | Contract/compliance review | **never sends without operator approval** | buddy approve/deny |
| `cwc-finance`     | `finance_coworker` | Cost/vendor spend tracking | **spend gate before any cost** | buddy approve/deny + `dim_packages` spend |

The two roles with hard gates (Legal, Finance) are the reason the buddy matters: a gate
is just a `WirePermissionPrompt` whose decision must come from a human — exactly the
mechanism the device already renders and the BLE link already round-trips.

## 5. Plugin anatomy (one per role, mirrors cwc-makers)

```
plugins/cwc-<role>/
├── .claude-plugin/
│   └── plugin.json          # name, version, description, marketplace metadata
├── commands/
│   └── <role>.md            # /cwc-<role> entry point (slash command)
├── skills/
│   └── <role>-playbook/     # the role's how-to (SKILL.md + scripts)
├── agents/
│   └── <role>.yaml          # GENERATED from crates/agent-gen (least-privilege tools)
├── mcp/
│   └── server.toml          # points at the per-role MCP binary + transport
├── gates.toml               # approval policy (which tools/actions require operator OK)
├── LICENSE
└── README.md
```

`agents/*.yaml` are **generated**, never hand-edited — extend `crates/agent-gen` with a
`RoleConfig` table so adding a coworker is a typed code change that fails the build on a
bad tool name, not a hand-rolled YAML.

### `gates.toml` (new — the approval-gate contract)

```toml
# cwc-finance/gates.toml
[gate.spend]
match  = { tool = "*", action = "purchase|subscribe|deploy_paid" }
require = "operator"          # must be approved by a human
surface = "buddy"            # render on the desktop buddy device
hint    = "{{vendor}} ${{amount}}"
```

The coworker runtime reads `gates.toml`; when a gated action is attempted it emits a
`WirePermissionPrompt` (already defined in `HardwareBuddyProtocol.swift` /
`src/protocol.rs`) tagged with the originating role. The buddy shows it; the operator
presses approve/deny on the device; the decision flows back through the existing path.

## 6. The buddy surface, generalised

Today `BuddyState` aggregates *sessions*. For the platform it aggregates *coworkers*:

- `HeartbeatSnapshot.entries` becomes per-coworker status lines
  (`[engineering] compiling`, `[legal] ⏸ awaiting approval: NDA v3`).
- A pending gate carries a `role` so the device can show *who* is asking.
- The 7-state pet maps cleanly: `attention` fires for any open gate, `busy` when ≥1
  coworker is working, `celebrate` on a shipped deliverable rather than raw tokens.

This is an additive change to the wire protocol: add an optional `role: String?` to
`WirePermissionPrompt` and an optional per-entry role tag. Both sides already tolerate
unknown/defaulted fields (serde `default` + Swift `decodeIfPresent`).

## 7. Communication: peers, not a tree

Per the coworkers site, coworkers "can initiate work — not just receive it." Concretely:

- **Transport**: `crates/a2a-bridge` exposes each role's MCP server as an A2A agent; the
  set of bridges is the **CoworkerBus**. Product-management is the default router but any
  peer may message any peer (a2a `tasks/send`).
- **Discovery**: each role publishes `/.well-known/agent-card.json` (the bridge already
  does this) listing its skills + gates so peers know what it can do and what needs
  approval.
- **No new protocol invented** — a2a for peer tasks, mcp for tool calls, the buddy wire
  protocol for the human-in-the-loop gate.

## 8. Staged roadmap

1. **✅ Proof-of-loop: `cwc-design`** *(implemented)* — the design coworker is the
   first vertical slice and the only one that needed building to prove the thesis. It
   ships:
   - `crates/design-coworker` — MCP server: 8-token design system, WCAG lint,
     token-set → buddy character-pack artifact builder, and a two-phase approval gate
     (`artifact_request_publish` → operator decides on the buddy →
     `artifact_finalize_publish`). Pure logic is unit-tested (9 tests) so the loop is
     verifiable without a Mac or device.
   - `plugins/cwc-design/` — plugin packaging (`.claude-plugin/plugin.json`,
     `commands/design.md`, `skills/design-playbook/`, generated
     `agents/design-coworker.yaml`, `mcp/servers.json`, `gates.toml`).
   - Additive wire-protocol change — optional `role` on `PermissionPrompt` /
     `WirePermissionPrompt` (Rust `src/protocol.rs` + Swift) so the device can show
     *who* is asking. Backward compatible (serde `default` / `decodeIfPresent`).
   - `.claude-plugin/marketplace.json` — `claude plugin install cwc-design@subagentjobs`.

   The publish step is the thesis in miniature: a coworker's side-effecting action
   surfaces on the buddy as a `role = design` prompt and only proceeds on a physical
   approve. The gate handshake reuses the exact `permission-<id>.json` decision file the
   desktop app's Approve/Deny buttons already write.
2. **Per-coworker lanes in `BuddyWindow`** — render the `role` tag in the prompt card
   and split `entries` into per-coworker status lines. (Surface polish; protocol already
   carries `role`.)
3. **`cwc-finance` / `cwc-legal`** — the other gated roles; reuse the slice-1 machinery
   (gate emit/decide/finalize), only the MCP tools + `gates.toml` policy + playbook
   differ. Finance adds a spend gate over `dim_packages`; Legal a send/publish gate.
4. **Non-gated roles** — `cwc-data`, `cwc-engineering` (wrap the existing MCP),
   `cwc-product` (router) once the gate path is proven.

`cwc-design` was chosen as the proof-of-loop because its artifact — a Hardware Buddy
character pack — *is* a design deliverable that the buddy renders, so the role, the
artifact, and the surface are one coherent story end to end.

## 9. Open questions for the operator

- **Marketplace home** — publish `cwc-*` under this repo's own marketplace, or contribute
  upstream to `claude-plugins-official` alongside `cwc-makers`?
- **Per-role MCP isolation** — one MCP binary per role (clean least-privilege, more
  processes) vs. one multiplexed server with role-scoped tool namespaces?
- **Gate persistence** — should approved gates be remembered (allow-once vs. allow-always
  per vendor/counterparty), and where (Redis L2 / Postgres L3 via `durable-store`)?
```
