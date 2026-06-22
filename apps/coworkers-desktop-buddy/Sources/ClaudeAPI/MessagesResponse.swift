// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Response body for `POST /v1/messages`. When streaming, the same shape
/// arrives as the `message_start` payload, with `content` empty and `usage`
/// carrying the prompt-side counts.
public struct MessagesResponse: Sendable, Codable {
  public var id: String
  public var model: String
  public var role: Message.Role
  public var content: [ContentBlock]
  public var stopReason: StopReason?
  public var usage: Usage

  private enum CodingKeys: String, CodingKey {
    case id, model, role, content, usage
    case stopReason = "stop_reason"
  }
}

public enum StopReason: String, Sendable, Codable {
  case endTurn = "end_turn"
  case maxTokens = "max_tokens"
  case stopSequence = "stop_sequence"
  case toolUse = "tool_use"
  case refusal
  case pauseTurn = "pause_turn"
  /// Forward-compatibility: an unrecognized stop reason must not kill the
  /// stream after content has already been delivered.
  case unknown

  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = StopReason(rawValue: raw) ?? .unknown
  }
}

/// Token counts as the API reports them: `inputTokens` covers only the
/// uncached portion of the prompt — cache reads and writes are separate
/// fields, so the full prompt size is the sum of all three.
public struct Usage: Sendable, Codable, Hashable {
  public var inputTokens: Int?
  public var outputTokens: Int
  public var cacheCreationInputTokens: Int?
  public var cacheReadInputTokens: Int?

  private enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
  }
}
