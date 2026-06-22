// main.swift — coworkers-desktop-buddy CLI
//
// Runs on Linux (Ubuntu 22.04+, Swift 6+). No physical device needed.
// Polls session state, calls Claude for a smart summary, renders to terminal.
//
// Usage:
//   export ANTHROPIC_API_KEY=sk-ant-...
//   export COWORK_SESSIONS_DIR=/path/to/sessions   # optional
//   swift run buddy [--watch] [--interval 10] [--no-claude]
//
// --watch      Poll every N seconds (default: run once)
// --interval   Seconds between polls in watch mode (default: 10)
// --no-claude  Skip Claude summarisation (raw state only, faster)

import Foundation
import BuddyCore

// ── Argument parsing ──────────────────────────────────────────────────────────

var watchMode   = false
var intervalSec = 10
var noClaude    = false

var args = CommandLine.arguments.dropFirst()
while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--watch":    watchMode = true
    case "--no-claude": noClaude = true
    case "--interval":
        if let s = args.first, let n = Int(s) { intervalSec = n; args = args.dropFirst() }
    default: break
    }
}

let apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
if apiKey.isEmpty && !noClaude {
    fputs("Warning: ANTHROPIC_API_KEY not set — running with --no-claude\n", stderr)
    noClaude = true
}

// ── Render ────────────────────────────────────────────────────────────────────

func render(_ state: BuddyState, summary: BuddySummary?) {
    let reset  = "\u{001B}[0m"
    let bold   = "\u{001B}[1m"
    let dim    = "\u{001B}[2m"
    let green  = "\u{001B}[32m"
    let yellow = "\u{001B}[33m"
    let red    = "\u{001B}[31m"
    let cyan   = "\u{001B}[36m"

    let statusColor = state.sessionsWaiting > 0 ? yellow :
                      state.sessionsRunning > 0 ? green  : dim
    let dot = state.connected ? "\(green)●\(reset)" : "\(dim)○\(reset)"

    print("\n\(bold)╔══ Coworkers Desktop Buddy ══╗\(reset)")
    print("\(bold)║\(reset) \(dot) \(statusColor)\(state.msg)\(reset)")
    print("\(bold)║\(reset) \(dim)sessions: \(state.sessionsTotal)  running: \(state.sessionsRunning)  waiting: \(state.sessionsWaiting)\(reset)")
    print("\(bold)║\(reset) \(dim)tokens today: \(state.tokensToday.formatted())\(reset)")

    if let p = state.prompt {
        print("\(bold)║\(reset) \(yellow)⚠ approve: \(p.tool) — \(p.hint.prefix(44))\(reset)")
    }

    if !state.lines.isEmpty {
        print("\(bold)║\(reset) \(dim)recent:\(reset)")
        for line in state.lines.prefix(5) {
            print("\(bold)║\(reset)   \(dim)\(line.prefix(72))\(reset)")
        }
    }

    if let s = summary {
        let moodEmoji: String = switch s.moodHint {
        case .happy:   "😊"
        case .busy:    "⚡"
        case .waiting: "⏳"
        case .tired:   "😴"
        case .idle:    "💤"
        }
        print("\(bold)║\(reset) \(cyan)\(moodEmoji) \(s.oneLiner)\(reset)")
        if s.needsAttention {
            print("\(bold)║\(reset) \(red)→ needs your attention\(reset)")
        }
    }
    print("\(bold)╚═════════════════════════════╝\(reset)")
}

// ── Main loop ─────────────────────────────────────────────────────────────────

let poller     = SessionPoller()
let summariser = noClaude ? nil : ClaudeSummariser(apiKey: apiKey)

func tick() async {
    let sessions: [InferenceSession]
    do { sessions = try poller.poll() }
    catch { fputs("SessionPoller error: \(error)\n", stderr); return }

    let tokensToday = sessions.reduce(0) { $0 + $1.tokensOut }
    var state = BuddyState.from(sessions, tokensToday: tokensToday)

    var summary: BuddySummary? = nil
    if let summariser, state.connected {
        do { summary = try await summariser.summarise(state) }
        catch { fputs("Claude summariser error: \(error)\n", stderr) }
        state.claudeSummary = summary?.oneLiner
    }

    render(state, summary: summary)
}

if watchMode {
    print("Watching every \(intervalSec)s — Ctrl-C to stop")
    while true {
        await tick()
        try? await Task.sleep(nanoseconds: UInt64(intervalSec) * 1_000_000_000)
    }
} else {
    await tick()
}
