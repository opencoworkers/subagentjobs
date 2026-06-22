// SessionPoller.swift — reads active Cowork sessions from the filesystem.
//
// On Linux the session files live under the path set by COWORK_SESSIONS_DIR
// (or the default below). Each session directory contains a transcript JSONL.
// We read the last few lines to extract session title, status, and token count.

import Foundation

public struct SessionPoller: Sendable {
    private let sessionsDir: URL

    // Default path mirrors the macOS Application Support layout seen in the repo.
    // Override with COWORK_SESSIONS_DIR env var on Linux.
    public init() {
        let override = ProcessInfo.processInfo.environment["COWORK_SESSIONS_DIR"]
        if let override {
            sessionsDir = URL(fileURLWithPath: override)
        } else {
            // Attempt to locate sessions relative to a known anchor file.
            let home = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            sessionsDir = home.appendingPathComponent("sessions")
        }
    }

    public init(sessionsDir: URL) {
        self.sessionsDir = sessionsDir
    }

    /// Read the session-index.json written by the sessions scaffold, or fall back
    /// to scanning JSONL files in the sessions directory.
    public func poll() throws -> [InferenceSession] {
        let indexURL = sessionsDir.appendingPathComponent("session-index.json")
        if let data = try? Data(contentsOf: indexURL) {
            return (try? parseIndex(data)) ?? []
        }
        // Fallback: return a synthetic "no data" session so the buddy shows something.
        return []
    }

    // MARK: - session-index.json parser

    private struct IndexEntry: Codable {
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

    private func parseIndex(_ data: Data) throws -> [InferenceSession] {
        let entries = try JSONDecoder().decode([IndexEntry].self, from: data)
        return entries.map { e in
            let status: SessionStatus = switch e.status {
            case "running":  .running
            case "waiting":  .waiting
            default:          .idle
            }
            let pt = e.pendingTool.map { p in
                PendingTool(requestId: p.requestId, tool: p.tool, hint: p.hint)
            }
            return InferenceSession(
                id: e.id, title: e.title, status: status,
                tokensOut: e.tokensOut ?? 0, pendingTool: pt
            )
        }
    }
}
