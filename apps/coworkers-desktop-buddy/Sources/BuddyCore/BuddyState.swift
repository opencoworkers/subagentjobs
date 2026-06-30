// BuddyState.swift — Virtual buddy state (mirrors TamaState from the ESP32 firmware
// but runs entirely in the VM at inference runtime; no physical device needed).
//
// The physical buddy renders state on an M5StickC Plus display over BLE.
// The virtual buddy renders the same state to a terminal or HTTP endpoint.
//
// Source of truth for field meanings:
//   vendors/anthropics/claude-desktop-buddy/REFERENCE.md

import Foundation

// MARK: - Session state (read from Cowork session files)

/// One inference session visible to this VM instance.
public struct InferenceSession: Codable, Sendable {
    public let id: String
    public let title: String
    public let status: SessionStatus
    public let tokensOut: UInt64
    public let pendingTool: PendingTool?

    public init(id: String, title: String, status: SessionStatus,
                tokensOut: UInt64, pendingTool: PendingTool?) {
        self.id = id; self.title = title; self.status = status
        self.tokensOut = tokensOut; self.pendingTool = pendingTool
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case running, waiting, idle
}

public struct PendingTool: Codable, Sendable {
    public let requestId: String
    public let tool: String
    public let hint: String
    /// Which coworker raised this gate (e.g. "design", "engineering"). Absent for
    /// plain session permission prompts. Mirrors `gate-<id>.json`'s `role` field and
    /// `WirePermissionPrompt.role` on the wire protocol.
    public let role: String?

    // Explicit public init required: Swift's synthesized memberwise init is
    // `internal` even when all properties are `public`, so plain `import BuddyCore`
    // in tests (without @testable) cannot call it.
    public init(requestId: String, tool: String, hint: String, role: String? = nil) {
        self.requestId = requestId
        self.tool = tool
        self.hint = hint
        self.role = role
    }
}

// MARK: - Virtual buddy display state (mirrors TamaState in data.h)

/// What the buddy displays — same schema the physical device renders,
/// but emitted to the terminal / HTTP instead of an M5StickC screen.
public struct BuddyState: Codable, Sendable {
    /// Total open sessions.
    public var sessionsTotal: UInt8
    /// Sessions actively generating.
    public var sessionsRunning: UInt8
    /// Sessions blocked on a permission prompt.
    public var sessionsWaiting: UInt8
    /// One-line summary (≤24 chars for physical device parity).
    public var msg: String
    /// Recent transcript lines, newest first (≤8).
    public var lines: [String]
    /// Cumulative output tokens today.
    public var tokensToday: UInt64
    /// Pending permission prompt, if any.
    public var prompt: PermissionPrompt?
    /// Whether a live session is connected (within 30 s of last update).
    public var connected: Bool
    /// Claude-generated enriched summary (virtual-only — physical device has no LLM).
    public var claudeSummary: String?

    public init(
        connected: Bool = false,
        sessionsTotal: UInt8 = 0, sessionsRunning: UInt8 = 0, sessionsWaiting: UInt8 = 0,
        msg: String = "No sessions", lines: [String] = [], tokensToday: UInt64 = 0,
        prompt: PermissionPrompt? = nil, claudeSummary: String? = nil
    ) {
        self.connected = connected
        self.sessionsTotal = sessionsTotal; self.sessionsRunning = sessionsRunning
        self.sessionsWaiting = sessionsWaiting; self.msg = msg; self.lines = lines
        self.tokensToday = tokensToday; self.prompt = prompt
        self.claudeSummary = claudeSummary
    }
}

public struct PermissionPrompt: Codable, Sendable {
    public let id: String
    public let tool: String
    public let hint: String
    /// Which coworker raised this gate, if any. See `PendingTool.role`.
    public let role: String?

    public init(id: String, tool: String, hint: String, role: String? = nil) {
        self.id = id
        self.tool = tool
        self.hint = hint
        self.role = role
    }
}

// MARK: - Virtual stats (mirrors Stats in stats.h, but in-memory only on Linux)

public struct VirtualStats: Codable, Sendable {
    public var approvals: UInt16 = 0
    public var denials: UInt16 = 0
    public var tokensLifetime: UInt64 = 0
    /// level = tokensLifetime / 50_000
    public var level: UInt8 { UInt8(min(tokensLifetime / 50_000, 255)) }
    /// fed bar 0..9 (pips within current level)
    public var fedProgress: UInt8 { UInt8((tokensLifetime % 50_000) / 5_000) }
}

// MARK: - Conversion from InferenceSession array → BuddyState

extension BuddyState {
    public static func from(_ sessions: [InferenceSession], tokensToday: UInt64) -> BuddyState {
        let total   = UInt8(min(sessions.count, 255))
        let running = UInt8(sessions.filter { $0.status == .running }.count)
        let waiting = UInt8(sessions.filter { $0.status == .waiting }.count)
        let prompt  = sessions.compactMap(\.pendingTool).first.map {
            PermissionPrompt(id: $0.requestId, tool: $0.tool, hint: $0.hint, role: $0.role)
        }
        let msg: String
        if waiting > 0 {
            msg = "approve: \(prompt?.tool ?? "?")"
        } else if running > 0 {
            msg = "\(running) session\(running == 1 ? "" : "s") running"
        } else if total > 0 {
            msg = "\(total) session\(total == 1 ? "" : "s") idle"
        } else {
            msg = "No Claude connected"
        }
        // Per-coworker lane prefix: "role:: " before the title when a session's
        // pending tool was raised by a named coworker (design, engineering, …),
        // so the UI can split entries into per-coworker status lines. Sessions
        // with no role behave exactly as before (no prefix).
        let lines = sessions.prefix(8).map { s -> String in
            let rolePrefix = s.pendingTool?.role.map { "\($0):: " } ?? ""
            return "[\(s.status.rawValue)] \(rolePrefix)\(s.title.prefix(80))"
        }
        return BuddyState(
            connected: !sessions.isEmpty,
            sessionsTotal: total, sessionsRunning: running, sessionsWaiting: waiting,
            msg: String(msg.prefix(24)), lines: Array(lines),
            tokensToday: tokensToday, prompt: prompt
        )
    }
}
