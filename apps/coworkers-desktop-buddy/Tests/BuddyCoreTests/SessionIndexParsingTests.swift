// SessionIndexParsingTests.swift
// Tests the SessionPoller.poll() → [InferenceSession] pipeline.
// These verify the exact JSON contract session-index.json must follow,
// and that THIS cowork session appears as .running once the file is seeded.

import Foundation
import Testing
@testable import BuddyCore

@Suite("SessionPoller — session-index.json parsing")
struct SessionIndexParsingTests {

    // MARK: - JSON parsing

    @Test("parses minimal valid array")
    func parsesMinimalArray() throws {
        let json = """
        [
          {"id":"s1","title":"Job listings","status":"running","tokens_out":1500}
        ]
        """.data(using: .utf8)!

        let dir = makeTempDir()
        try json.write(to: dir.appendingPathComponent("session-index.json"))
        let poller = SessionPoller(sessionsDir: dir)
        let sessions = try poller.poll()

        #expect(sessions.count == 1)
        #expect(sessions[0].id == "s1")
        #expect(sessions[0].title == "Job listings")
        #expect(sessions[0].status == .running)
        #expect(sessions[0].tokensOut == 1500)
        #expect(sessions[0].pendingTool == nil)
    }

    @Test("maps status strings correctly")
    func statusMapping() throws {
        let json = """
        [
          {"id":"a","title":"A","status":"running","tokens_out":0},
          {"id":"b","title":"B","status":"waiting","tokens_out":0},
          {"id":"c","title":"C","status":"idle","tokens_out":0},
          {"id":"d","title":"D","tokens_out":0}
        ]
        """.data(using: .utf8)!

        let dir = makeTempDir()
        try json.write(to: dir.appendingPathComponent("session-index.json"))
        let sessions = try SessionPoller(sessionsDir: dir).poll()

        #expect(sessions[0].status == .running)
        #expect(sessions[1].status == .waiting)
        #expect(sessions[2].status == .idle)
        #expect(sessions[3].status == .idle) // missing field → idle
    }

    @Test("parses pending_tool block")
    func parsesPendingTool() throws {
        let json = """
        [
          {
            "id":"x","title":"Deploy","status":"waiting","tokens_out":200,
            "pending_tool":{"request_id":"req_abc","tool":"Bash","hint":"wrangler deploy"}
          }
        ]
        """.data(using: .utf8)!

        let dir = makeTempDir()
        try json.write(to: dir.appendingPathComponent("session-index.json"))
        let sessions = try SessionPoller(sessionsDir: dir).poll()

        let pt = sessions[0].pendingTool
        #expect(pt?.requestId == "req_abc")
        #expect(pt?.tool == "Bash")
        #expect(pt?.hint == "wrangler deploy")
    }

    @Test("missing file → empty array (no throw)")
    func missingFileIsEmpty() throws {
        let dir = URL(fileURLWithPath: "/tmp/nonexistent-buddy-\(UUID().uuidString)")
        let sessions = try SessionPoller(sessionsDir: dir).poll()
        #expect(sessions.isEmpty)
    }

    @Test("malformed JSON → empty array (no throw)")
    func malformedJsonIsEmpty() throws {
        let json = "{ not valid json ]".data(using: .utf8)!
        let dir = makeTempDir()
        try json.write(to: dir.appendingPathComponent("session-index.json"))
        let sessions = try SessionPoller(sessionsDir: dir).poll()
        #expect(sessions.isEmpty)
    }

    @Test("empty array → zero sessions")
    func emptyArrayProducesZeroSessions() throws {
        let json = "[]".data(using: .utf8)!
        let dir = makeTempDir()
        try json.write(to: dir.appendingPathComponent("session-index.json"))
        let sessions = try SessionPoller(sessionsDir: dir).poll()
        #expect(sessions.isEmpty)
    }

    // MARK: - Live session contract
    // This test will PASS once sessions/session-index.json is seeded with
    // the running session for the current cowork conversation.

    // MARK: - Scaffold format (sessions/session-index.json written by Cowork)

    @Test("parses scaffold object format")
    func parsesScaffoldFormat() throws {
        let json = """
        {
          "schema_version": "0.1.0",
          "workspace_session_id": "ws-1",
          "conversation_id": "conv-1",
          "sessions": [
            {
              "instance_id": "local_abc",
              "summary": "Ecosystem wiring session",
              "last_active_at": "2026-06-21T17:12:00Z",
              "transcript_bytes": 400000,
              "status": "idle"
            },
            {
              "instance_id": "local_def",
              "summary": "Coworkers Buddy session",
              "last_active_at": "2099-01-01T00:00:00Z",
              "transcript_bytes": 8000,
              "status": "running"
            }
          ]
        }
        """.data(using: .utf8)!

        let dir = makeTempDir()
        try json.write(to: dir.appendingPathComponent("session-index.json"))
        let sessions = try SessionPoller(sessionsDir: dir).poll()

        #expect(sessions.count == 2)
        #expect(sessions[0].id == "local_abc")
        #expect(sessions[0].title.contains("Ecosystem"))
        #expect(sessions[0].status == .idle)
        #expect(sessions[1].id == "local_def")
        #expect(sessions[1].status == .running)
        // tokensOut ≈ transcript_bytes / 4
        #expect(sessions[1].tokensOut == 2000)
    }

    @Test("scaffold without explicit status infers running from recency")
    func scaffoldInfersRunningFromRecency() throws {
        // A session active within 30 minutes should be inferred as running
        let recent = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -600))
        let json = """
        {
          "schema_version": "0.1.0",
          "sessions": [
            {
              "instance_id": "local_recent",
              "summary": "Active session",
              "last_active_at": "\(recent)",
              "transcript_bytes": 0
            }
          ]
        }
        """.data(using: .utf8)!

        let dir = makeTempDir()
        try json.write(to: dir.appendingPathComponent("session-index.json"))
        let sessions = try SessionPoller(sessionsDir: dir).poll()

        #expect(sessions[0].status == .running)
    }

    @Test("live session-index.json contains THIS session as running",
          .disabled("Enabled once COWORK_SESSIONS_DIR is set and session-index.json is seeded"))
    func thisSessionIsRunning() throws {
        // Uses COWORK_SESSIONS_DIR env var (same as the app) so the test
        // exercises the exact same path the buddy reads.
        let poller = SessionPoller()
        let sessions = try poller.poll()
        let running = sessions.filter { $0.status == .running }
        #expect(!running.isEmpty, "Expected at least one running session")
        let thisSession = sessions.first { $0.id.contains("2613553e") }
        #expect(thisSession != nil, "THIS cowork session (2613553e) should appear")
        #expect(thisSession?.status == .running)
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("buddy-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
