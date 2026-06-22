// SessionPoller.swift — reads active Cowork sessions from the filesystem.
//
// Supports TWO on-disk formats so the buddy works out of the box with the
// sessions/ scaffold that Cowork writes (schema v0.1.0) AND with the flat
// array format that is easier to write from scripts / tests.
//
// FORMAT A — scaffold object (written by sessions/session-index.json scaffold):
//   {
//     "schema_version": "0.1.0",
//     "sessions": [
//       {
//         "instance_id": "local_...",
//         "summary": "What this session did",
//         "last_active_at": "2026-06-21T19:03:00Z",
//         "transcript_bytes": 12345,
//         "status": "running"          // optional — inferred from recency if absent
//       }
//     ]
//   }
//
// FORMAT B — flat buddy array (written by tests / scripts / this buddy):
//   [
//     {"id":"local_...","title":"...","status":"running","tokens_out":1500}
//   ]

import Foundation

public struct SessionPoller: Sendable {
    private let sessionsDir: URL

    // Default path mirrors the macOS Application Support layout seen in the repo.
    // Override with COWORK_SESSIONS_DIR env var.
    public init() {
        let override = ProcessInfo.processInfo.environment["COWORK_SESSIONS_DIR"]
        if let override {
            sessionsDir = URL(fileURLWithPath: override)
        } else {
            let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            sessionsDir = home.appendingPathComponent("sessions")
        }
    }

    public init(sessionsDir: URL) {
        self.sessionsDir = sessionsDir
    }

    /// Read session-index.json from sessionsDir. Understands both the scaffold
    /// object format and the flat buddy array format.
    public func poll() throws -> [InferenceSession] {
        let indexURL = sessionsDir.appendingPathComponent("session-index.json")
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        // Try flat buddy array first, then scaffold object.
        return (try? parseBuddyArray(data))
            ?? (try? parseScaffold(data))
            ?? []
    }

    // MARK: - Format B: flat buddy array

    private struct BuddyEntry: Codable {
        let id: String
        let title: String
        let status: String?
        let tokensOut: UInt64?
        let pendingTool: PendingToolEntry?

        private enum CodingKeys: String, CodingKey {
            case id, title, status
            case tokensOut = "tokens_out"
            case pendingTool = "pending_tool"
        }
    }

    private struct PendingToolEntry: Codable {
        let requestId: String
        let tool: String
        let hint: String
        private enum CodingKeys: String, CodingKey {
            case requestId = "request_id"
            case tool, hint
        }
    }

    private func parseBuddyArray(_ data: Data) throws -> [InferenceSession] {
        let entries = try JSONDecoder().decode([BuddyEntry].self, from: data)
        return entries.map { e in
            let status = sessionStatus(from: e.status)
            let pt = e.pendingTool.map { p in
                PendingTool(requestId: p.requestId, tool: p.tool, hint: p.hint)
            }
            return InferenceSession(
                id: e.id, title: e.title, status: status,
                tokensOut: e.tokensOut ?? 0, pendingTool: pt
            )
        }
    }

    // MARK: - Format A: scaffold object (schema v0.1.0)

    private struct ScaffoldFile: Codable {
        let sessions: [ScaffoldEntry]
    }

    private struct ScaffoldEntry: Codable {
        let instanceId: String
        let summary: String?
        let lastActiveAt: String?
        let transcriptBytes: UInt64?
        /// Optional explicit status. If absent, inferred from lastActiveAt recency.
        let status: String?

        private enum CodingKeys: String, CodingKey {
            case instanceId   = "instance_id"
            case summary
            case lastActiveAt = "last_active_at"
            case transcriptBytes = "transcript_bytes"
            case status
        }
    }

    private func parseScaffold(_ data: Data) throws -> [InferenceSession] {
        let file = try JSONDecoder().decode(ScaffoldFile.self, from: data)
        let now = Date()
        return file.sessions.map { e in
            // Status priority: explicit field → infer from recency → idle
            let status: SessionStatus
            if let s = e.status {
                status = sessionStatus(from: s)
            } else if let iso = e.lastActiveAt, let date = iso8601(iso) {
                // Active within last 30 minutes → running
                status = now.timeIntervalSince(date) < 1800 ? .running : .idle
            } else {
                status = .idle
            }
            // Rough token estimate: ~4 bytes per token
            let tokensOut = (e.transcriptBytes ?? 0) / 4
            let title = e.summary.map { String($0.prefix(60)) } ?? e.instanceId
            return InferenceSession(
                id: e.instanceId, title: title, status: status,
                tokensOut: tokensOut, pendingTool: nil
            )
        }
    }

    // MARK: - Helpers

    private func sessionStatus(from string: String?) -> SessionStatus {
        switch string {
        case "running":  return .running
        case "waiting":  return .waiting
        default:         return .idle
        }
    }

    private func iso8601(_ string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: string)
    }
}
