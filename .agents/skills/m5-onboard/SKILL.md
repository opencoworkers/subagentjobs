---
name: m5-onboard
description: End-to-end onboarding for a freshly-plugged-in M5Stack ESP32 device (Cardputer, Cardputer-Adv, Core, CoreS3, Stick) — detect on USB, flash UIFlow 2.0 firmware, and install the Codex Buddy MicroPython app bundle. Use whenever the user plugs in or wants to flash/provision/reset an M5Stack or ESP32 board, or says "m5-onboard go".
plugin: cwc-makers@Codex-plugins-official
source: https://github.com/anthropics/Codex-plugins-official/blob/main/plugins/cwc-makers/skills/m5-onboard/SKILL.md
---

# M5Stack Onboarding → coworkers-desktop-buddy

Automates cold-start for an M5Stack ESP32 device: detect on USB, identify model, flash
UIFlow 2.0, and push the Codex Buddy MicroPython app bundle onto `/flash/`.

The provisioned device becomes a **BLE peripheral** that pairs with the macOS
`apps/coworkers-desktop-buddy` app (built with `make run-bridge` in that directory).
The macOS app is the BLE host; the device is the BLE peripheral.

Run every `scripts/*.py` invocation from inside the `build-with-Codex/onboard/` directory
(created by `/maker-setup`).

## When to use

- **Fresh/unknown device** → `onboard.py --apps buddy` (detect → identify → flash → install apps)
- **Already-flashed, just refresh apps** → `install_apps.py --src buddy`
- **Something feels broken** → `smoke_test.py` (I2C + LCD + speaker + button check)
- **Multiple devices plugged in** → ask which port; don't guess

Default variant is **Cardputer-Adv**. If user says "Cardputer" (no "Adv"), ask — wrong
firmware boot-loops the device.

## Default provisioning command

```bash
# From inside build-with-Codex/onboard/
python3 scripts/onboard.py --apps buddy
```

**IMPORTANT — run in background and tail the log** (command takes 2–3 min; silent Bash
output looks like a hang):

```bash
python3 scripts/onboard.py --apps buddy 2>&1 | tee /tmp/m5-onboard.log &
tail -f /tmp/m5-onboard.log | grep -E --line-buffered \
  "^====|heartbeat|Heads up|Enter download mode|download mode!|rebooted into UIFlow|Manual reset|DONE|ERROR|Error|Traceback|FAIL|failed|No USB|not detected|Attempt [0-9]"
```

## Physical button prompt (REQUIRED — cannot be automated)

When the log shows `Enter download mode`, **stop and tell the user** to do this on the
**back of the Cardputer**:

1. Press and **hold** the **G0** button
2. While holding G0, briefly press and release **RST**
3. Keep holding G0 for ~1 more second, then release
4. Screen goes fully dark → download mode active

If the device reboots into UIFlow instead, G0 was released too early — retry holding longer.
Do NOT proceed, retry the script, or attempt software workarounds until screen is dark.

## Stages

1. **Detect** (`detect.py`) — enumerate ports, filter to USB-UART bridges or ESP32-S3 native USB
2. **Identify** (`detect.py`) — cross-reference `references/hardware_signatures.md`
3. **Fetch firmware** (`fetch_firmware.py`) — M5Burner manifest API, cached at `~/.cache/m5-onboard/`
4. **Flash** (`flash.py`) — esptool at 460800 baud (UART) or 115200 `--no-stub` (native USB)
5. **Install apps** (`install_apps.py`) — paste-mode REPL upload into `/flash/`, sets NVS `boot_option=2`
6. **Smoke test** (optional, `smoke_test.py`)

## Critical gotchas (scripts handle these — don't override)

- **Native-USB ESP32-S3 (Cardputer, Cardputer-Adv, CoreS3) needs the G0+RST dance** — no software path exists
- **Do not unplug during FLASH** — mask ROM survives but re-run is needed
- **Baud: 460800 UART, 115200 `--no-stub` native USB** — 921600 fails on CH9102
- **NVS writes must use `set_str`, not `set_blob`** — UIFlow reads with `get_str()`
- **REPL multi-line → paste mode** (Ctrl-E / Ctrl-D) — line-by-line accumulates indentation
- **Hard reset via DTR/RTS is a no-op on native USB** — use `mpy_repl.repl_reset()` instead
- **BLE on ESP32-S3 requires `boot_option=2` + custom `main.py`** — UIFlow's default wedges NimBLE

## After provisioning

- Power: slide switch on right edge
- Boot: short log → launcher menu (lists every `/flash/apps/*.py`)
- Navigation: arrow keys scroll, Enter launches, ESC returns
- Codex Buddy app: select `claude_buddy` from launcher

## Connecting to the macOS companion app

The device advertises over BLE as `Codex-<suffix>` with Nordic UART Service (NUS):

| NUS UUID                               | Role                          |
|---------------------------------------|-------------------------------|
| `6e400001-b5a3-f393-e0a9-e50e24dcca9e`| Service                       |
| `6e400002-b5a3-f393-e0a9-e50e24dcca9e`| RX — desktop writes here      |
| `6e400003-b5a3-f393-e0a9-e50e24dcca9e`| TX — device notifies here     |

To pair with our macOS app:
1. Start the bridge: `cd apps/coworkers-desktop-buddy && make run-bridge`
2. In Codex for macOS: **Help → Troubleshooting → Enable Developer Mode**
3. **Developer → Hardware Buddy → Connect** → pick `Codex-*` from scan list
4. The bridge logs `snapshot built` when sessions are forwarded to the device

The Rust bridge (`src/main.rs`) uses `btleplug` to scan for `Codex` name prefix and
connects to `6e400001-…` service. Wire types are in `src/protocol.rs`.
On the Swift side, session state flows through `BuddyState` → `CharacterController`
→ ASCII art renderer → `GIFPlayerView`.

## Dependencies

- `pyserial` — vendored at `scripts/vendor/` (BSD-3-Clause)
- `esptool` — pip dep, auto-installed on first run (`python -m pip install --user esptool`)
- Python 3.10+ required; `git` optional (tarball fallback in `/maker-setup`)

## Key files

- `scripts/onboard.py` — main orchestrator
- `scripts/detect.py` — port discovery + chip ID
- `scripts/fetch_firmware.py` — firmware download + cache
- `scripts/flash.py` — esptool wrapper
- `scripts/install_apps.py` — push `.py` files into `/flash/` via paste-mode REPL
- `scripts/smoke_test.py` — I2C + LCD + speaker + buttons
- `scripts/mpy_repl.py` — serial/REPL helpers
- `references/hardware_signatures.md` — chip + I2C fingerprints → model → firmware
- `references/uiflow2_nvs.md` — NVS key reference

## LSP queries for this codebase

Use the `make lsp-*` targets to navigate the coworkers-desktop-buddy source:

```bash
# See all BLE protocol types
make lsp-symbols FILE=apps/coworkers-desktop-buddy/src/protocol.rs

# See all Swift state types
make lsp-symbols FILE=apps/coworkers-desktop-buddy/Sources/BuddyCore/BuddyState.swift

# Find all callers of HeartbeatSnapshot
make lsp-refs FILE=apps/coworkers-desktop-buddy/src/protocol.rs LINE=12 COL=11
```
