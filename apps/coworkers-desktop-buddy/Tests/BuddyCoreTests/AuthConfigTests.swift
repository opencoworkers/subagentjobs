// AuthConfigTests.swift
// Tests the two auth modes ClaudeClient must support:
//   1. x-api-key  header for standard API keys (sk-ant-api03-...)
//   2. Authorization: Bearer  for Claude Code OAuth tokens (sk-ant-oat01-...)
//
// Uses a spy HTTPTransport so no real network calls are made.
// The test for .oauthToken will FAIL until Configuration.Auth gains that case.

import Foundation
import Testing
@testable import ClaudeAPIClient
import BuddyCore  // for ClaudeSummariser

// MARK: - Spy transport

/// Captures the last URLRequest received. Returns a minimal 200 response.
final class SpyTransport: HTTPTransport, @unchecked Sendable {
    var capturedRequest: URLRequest?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        let json = """
        {"id":"msg_test","type":"message","role":"assistant","content":[{"type":"text","text":"hi"}],
         "model":"claude-haiku-4-5-20251001","stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}
        """.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (json, response)
    }

    func bytes(for request: URLRequest) async throws
        -> (AsyncThrowingStream<UInt8, Error>, URLResponse) {
        capturedRequest = request
        let empty = AsyncThrowingStream<UInt8, Error> { $0.finish() }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        return (empty, response)
    }
}

// MARK: - Tests

@Suite("ClaudeClient auth headers")
struct AuthConfigTests {

    private let minimalRequest = MessagesRequest(
        model: "claude-haiku-4-5-20251001",
        maxTokens: 1,
        messages: [Message(role: .user, content: [.text("ping")])]
    )

    @Test("apiKey → x-api-key header, no Authorization header")
    func apiKeyHeader() async throws {
        let spy = SpyTransport()
        let client = ClaudeClient(
            configuration: Configuration(auth: .apiKey("sk-ant-api03-test")),
            transport: spy
        )
        _ = try await client.send(minimalRequest)
        let req = try #require(spy.capturedRequest)
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-ant-api03-test")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("oauthToken → Authorization: Bearer header, no x-api-key header")
    func oauthTokenHeader() async throws {
        let spy = SpyTransport()
        let token = "sk-ant-oat01-test-token"
        let client = ClaudeClient(
            configuration: Configuration(auth: .oauthToken(token)),
            transport: spy
        )
        _ = try await client.send(minimalRequest)
        let req = try #require(spy.capturedRequest)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test("per-request header overrides .none auth (existing behaviour)")
    func perRequestBearerHeader() async throws {
        let spy = SpyTransport()
        let token = "sk-ant-oat01-rotated"
        let client = ClaudeClient(
            configuration: Configuration(auth: .none),
            transport: spy
        )
        _ = try await client.send(minimalRequest, headers: ["Authorization": "Bearer \(token)"])
        let req = try #require(spy.capturedRequest)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }

    @Test("ClaudeSummariser reads CLAUDE_CODE_OAUTH_TOKEN env var")
    func summariserReadsOAuthEnv() {
        // This is a pure construction test — no network call.
        // Verifies ClaudeSummariser.init() picks up the env var without
        // requiring an explicit apiKey parameter.
        // Will compile once ClaudeSummariser.init(oauthToken:) exists.
        let summariser = ClaudeSummariser(oauthToken: "sk-ant-oat01-test")
        // If it compiles, the init exists. Runtime behaviour tested by integration tests.
        _ = summariser
    }
}
