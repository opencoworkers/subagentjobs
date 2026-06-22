// ClaudeSummariser.swift — uses ClaudeAPI (copied from ClaudeForFoundationModels)
// to generate an enriched one-line summary of current session state.
//
// This is the virtual-buddy-only capability: the physical ESP32 device shows
// raw msg strings. The virtual buddy can ask Claude to interpret the state and
// produce a smarter summary — e.g. "3 sessions deep in a Rust compile loop,
// 1 waiting on a Bash approval for a wrangler deploy."
//
// Mirrors the @Generable structured output pattern from ClaudeForFoundationModels
// using plain Codable instead (works on Linux without FoundationModels framework).

import Foundation
import ClaudeAPIClient

public struct BuddySummary: Codable, Sendable {
    /// ≤80 chars. What's actually happening right now, in plain language.
    public let oneLiner: String
    /// Mood signal the physical buddy would derive from velocity/approvals.
    public let moodHint: MoodHint
    /// True if the operator should look at the screen soon.
    public let needsAttention: Bool
}

public enum MoodHint: String, Codable, Sendable {
    case happy, busy, waiting, tired, idle
}

public struct ClaudeSummariser: Sendable {
    private let client: ClaudeClient
    private let model: String

    /// Initialise with a standard Anthropic API key (`sk-ant-api03-...`).
    public init(apiKey: String, model: String = "claude-haiku-4-5-20251001") {
        let config = Configuration(auth: .apiKey(apiKey))
        self.client = ClaudeClient(configuration: config)
        self.model = model
    }

    /// Initialise with a Claude Code / Claude.ai OAuth token (`sk-ant-oat01-...`).
    /// Reads `CLAUDE_CODE_OAUTH_TOKEN` env var if no explicit token is supplied.
    public init(oauthToken: String, model: String = "claude-haiku-4-5-20251001") {
        let config = Configuration(auth: .oauthToken(oauthToken))
        self.client = ClaudeClient(configuration: config)
        self.model = model
    }

    /// Convenience: reads `CLAUDE_CODE_OAUTH_TOKEN` then `ANTHROPIC_API_KEY`
    /// from the process environment. Returns nil if neither is set.
    public static func fromEnvironment(model: String = "claude-haiku-4-5-20251001") -> ClaudeSummariser? {
        let env = ProcessInfo.processInfo.environment
        if let token = env["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return ClaudeSummariser(oauthToken: token, model: model)
        }
        if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty {
            return ClaudeSummariser(apiKey: key, model: model)
        }
        return nil
    }

    /// Generate a `BuddySummary` from the current `BuddyState`.
    /// Uses structured JSON output so the result is always parseable.
    public func summarise(_ state: BuddyState) async throws -> BuddySummary {
        let stateJSON = (try? String(data: JSONEncoder().encode(state), encoding: .utf8)) ?? "{}"
        let prompt = """
        You are the virtual display of a Claude Hardware Buddy — a desk companion that shows
        what the developer's Claude sessions are doing.

        Current session state (JSON):
        \(stateJSON)

        Respond with ONLY a JSON object matching this exact schema:
        {
          "oneLiner": "<≤80 char plain-English description of what is happening>",
          "moodHint": "<one of: happy, busy, waiting, tired, idle>",
          "needsAttention": <true|false>
        }

        Rules:
        - oneLiner must be ≤80 chars and feel like a status line on a small device
        - moodHint = waiting if sessionsWaiting > 0, busy if sessionsRunning > 0 and no prompt,
          happy if recently completed, tired if tokensToday > 100000, idle otherwise
        - needsAttention = true if sessionsWaiting > 0
        - No markdown, no explanation, only the JSON object.
        """

        let request = MessagesRequest(
            model: model,
            maxTokens: 200,
            messages: [Message(role: .user, content: [.text(prompt)])]
        )
        let response = try await client.send(request)
        guard let text = response.content.compactMap({ block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }).first else {
            throw BuddyError.emptyResponse
        }
        // Strip any accidental markdown fences
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else {
            throw BuddyError.badJSON(cleaned)
        }
        return try JSONDecoder().decode(BuddySummary.self, from: data)
    }
}

public enum BuddyError: Error, CustomStringConvertible {
    case emptyResponse
    case badJSON(String)

    public var description: String {
        switch self {
        case .emptyResponse: "Claude returned no text content"
        case .badJSON(let s): "Could not decode JSON: \(s.prefix(120))"
        }
    }
}
