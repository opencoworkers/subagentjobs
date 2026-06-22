// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Request body for `POST /v1/messages`.
public struct MessagesRequest: Sendable, Codable {
  public var model: String
  public var maxTokens: Int
  public var system: String?
  public var messages: [Message]
  public var tools: [ToolDefinition]?
  public var toolChoice: ToolChoice?
  public var thinking: ThinkingConfig?
  public var temperature: Double?
  public var topP: Double?
  public var topK: Int?
  public var cacheControl: CacheControl?
  public var outputConfig: OutputConfig?
  public var stream: Bool

  public init(
    model: String,
    maxTokens: Int = 16_000,
    system: String? = nil,
    messages: [Message],
    tools: [ToolDefinition]? = nil,
    toolChoice: ToolChoice? = nil,
    thinking: ThinkingConfig? = nil,
    temperature: Double? = nil,
    topP: Double? = nil,
    topK: Int? = nil,
    cacheControl: CacheControl? = nil,
    outputConfig: OutputConfig? = nil,
    stream: Bool = false
  ) {
    self.model = model
    self.maxTokens = maxTokens
    self.system = system
    self.messages = messages
    self.tools = tools
    self.toolChoice = toolChoice
    self.thinking = thinking
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.cacheControl = cacheControl
    self.outputConfig = outputConfig
    self.stream = stream
  }

  private enum CodingKeys: String, CodingKey {
    case model, system, messages, tools, thinking, stream, temperature
    case maxTokens = "max_tokens"
    case toolChoice = "tool_choice"
    case topP = "top_p"
    case topK = "top_k"
    case cacheControl = "cache_control"
    case outputConfig = "output_config"
  }
}

/// Output shaping: structured output via constrained decoding, effort level.
public struct OutputConfig: Sendable, Hashable, Codable {
  public var format: Format?
  public var effort: Effort?

  public init(format: Format? = nil, effort: Effort? = nil) {
    self.format = format
    self.effort = effort
  }

  /// Constrained-decoding output format. The model strictly conforms to the
  /// schema — it cannot emit a token that would violate it.
  public struct Format: Sendable, Hashable, Codable {
    public var schema: JSONValue

    public init(schema: JSONValue) { self.schema = schema }

    private enum CodingKeys: String, CodingKey { case type, schema }

    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      schema = try c.decode(JSONValue.self, forKey: .schema)
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode("json_schema", forKey: .type)
      try c.encode(schema, forKey: .schema)
    }
  }

  public enum Effort: String, Sendable, Codable {
    case low, medium, high, xhigh, max
  }
}
