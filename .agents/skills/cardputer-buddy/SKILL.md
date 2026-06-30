---
name: cardputer-buddy
description: Iterate on the Cardputer-Adv MicroPython app bundle (Codex Buddy, Snake, Hello) after the device is already provisioned via m5-onboard. Use when the user wants to add a new app, push a single changed .py without re-flashing, watch device serial logs, or run a one-shot REPL command. Trigger on "add an app", "push to the cardputer", "tail the device", "run on the device", or follow-up work after /maker-setup.
plugin: cwc-makers@Codex-plugins-official
source: https://github.com/anthropics/Codex-plugins-official/blob/main/plugins/cwc-makers/skills/cardputer-buddy/SKILL.md
---

# Cardputer Buddy — coworkers-desktop-buddy integration

The Cardputer runs `claude_buddy.py` as a **BLE peripheral** over Nordic UART Service (NUS).
The macOS companion app `apps/coworkers-desktop-buddy` is the **BLE host** — it forwards
`sessions/session-index.json` inference state to the device and receives permission decisions.

## BLE wire protocol (NUS UUIDs)

| Role                           | UUID                                   |
|-------------------------------|----------------------------------------|
| NUS Service                   | `6e400001-b5a3-f393-e0a9-e50e24dcca9e` |
| RX — desktop→device (write)   | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` |
| TX — device→desktop (notify)  | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` |

Devices must advertise a name starting with `Codex` (e.g. `Codex-DEV2`) plus the NUS
Service UUID. The macOS bridge scans for this name prefix using `btleplug`.

Full spec: `vendors/anthropics/Codex-desktop-buddy/REFERENCE.md`

## Wire types — source of truth

**Rust** (desktop/bridge side): `apps/coworkers-desktop-buddy/src/protocol.rs`

| Type                | Direction          | Description                                         |
|--------------------|--------------------|-----------------------------------------------------|
| `HeartbeatSnapshot` | desktop → device  | Session counts, msg, token totals, optional prompt  |
| `PermissionDecision`| device → desktop  | `{cmd:"permission", id:…, decision:"once"|"deny"}`  |
| `DesktopCommand`    | desktop → device  | Status, Name, Owner, Unpair, CharBegin/File/Chunk   |
| `CommandAck`        | device → desktop  | `{ack:…, ok:bool, error?:…, data?:StatusData}`      |
| `TurnEvent`         | desktop → device  | `{evt:"turn", role:…, content:[…]}`                 |
| `TimeSync`          | desktop → device  | `{time:[epoch_seconds, tz_offset_seconds]}`         |

**Swift** (macOS app): `apps/coworkers-desktop-buddy/Sources/BuddyCore/BuddyState.swift`

Key structs: `BuddyState`, `InferenceSession`, `PendingTool`, `PermissionPrompt`

## HeartbeatSnapshot fields (sent every 1s change + keepalive every 10s)

```json
{
  "total": 3,       // all open sessions
  "running": 1,     // actively generating
  "waiting": 1,     // blocked on permission prompt
  "msg": "approve: Bash",   // ≤24 chars for device display
  "entries": ["10:42 git push"],
  "tokens": 184502,
  "tokens_today": 31200,
  "prompt": { "id": "req_abc123", "tool": "Bash", "hint": "rm -rf /tmp/foo" }
}
```

No snapshot for ~30 s → device treats link as dead.

## Device layout

```
/flash/
├── main.py              launcher menu
├── buddy_*.py           shared libs (BLE, UI, state, protocol, chars)
├── burst_frames.py      sprite frames
└── apps/
    ├── claude_buddy.py  BLE peripheral ← our protocol above
    ├── hello_cardputer.py
    └── snake.py
```

`main.py` scans `/flash/apps/` at boot. Drop a file into `buddy/device/apps/`, push it.

## Dev loop

```bash
# Push apps without re-flashing (from inside build-with-Codex/onboard/)
python3 scripts/install_apps.py --port <PORT> --src buddy

# Push single file
python3 buddy/scripts/push.py --port <PORT> --files apps/claude_buddy.py

# Tail serial logs
python3 buddy/scripts/tail_serial.py --port <PORT>

# One-shot REPL
python3 buddy/scripts/repl_run.py --port <PORT> --script "import os; print(os.listdir('/flash'))"
```

`<PORT>` from last `detect.py` run (e.g. `/dev/cu.usbmodem1101`, `/dev/ttyACM0`).

## Verifying BLE connection to macOS app

1. Build + run the macOS bridge: `cd apps/coworkers-desktop-buddy && make run-bridge`
2. In Codex for macOS: **Developer → Hardware Buddy → Connect** → pick `Codex-*` device
3. Terminal shows `RUST_LOG=info cargo run` → look for `snapshot built` log lines
4. Check `BuddyState.connected == true` in `sessions/session-index.json`

## Checking the Swift types match the Rust protocol

```bash
# List all types in the Swift BuddyState model
make lsp-symbols FILE=apps/coworkers-desktop-buddy/Sources/BuddyCore/BuddyState.swift

# List all types in the Rust protocol
make lsp-symbols FILE=apps/coworkers-desktop-buddy/src/protocol.rs
```

## Adding a new app

Crib from `buddy/device/apps/hello_cardputer.py` (smallest keyboard + font + exit example).
Then `python3 scripts/install_apps.py --port <PORT> --src buddy`.

## Character state machine (macOS side)

`Sources/BuddyCore/CharacterState.swift` maps `BuddyState` → 7 states:
`sleep | idle | busy | attention | celebrate | dizzy | heart`

- `connected=false` → `sleep`
- `sessionsWaiting > 0` → `attention` (permission needed)
- `sessionsRunning > 0` → `busy`
- Token crossing 50K boundary → `celebrate`
- Fast approval (< 5s) → `heart`

These are rendered as ASCII art frames via `CharacterManifest` → `GIFPlayerView`.
