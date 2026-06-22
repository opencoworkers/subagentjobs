// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Extended-thinking configuration. Adaptive is the only on-mode for current
/// Opus models; older models accept a fixed budget but that path is deprecated.
public enum ThinkingConfig: Sendable, Hashable, Codable {
  case adaptive
  case disabled

  private enum CodingKeys: String, CodingKey { case type }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .type) {
    case "adaptive": self = .adaptive
    case "disabled": self = .disabled
    case let other:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: c,
        debugDescription: "Unknown thinking type '\(other)'"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .adaptive: try c.encode("adaptive", forKey: .type)
    case .disabled: try c.encode("disabled", forKey: .type)
    }
  }
}

/// Prompt-cache opt-in (`cache_control`). Always `ephemeral` on the wire;
/// `ttl` selects the cache window, with the API's default when nil.
public struct CacheControl: Sendable, Hashable, Codable {
  public enum TTL: String, Sendable, Codable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
  }

  public var ttl: TTL?
  public init(ttl: TTL? = nil) { self.ttl = ttl }

  private enum CodingKeys: String, CodingKey { case type, ttl }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ttl = try c.decodeIfPresent(TTL.self, forKey: .ttl)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode("ephemeral", forKey: .type)
    try c.encodeIfPresent(ttl, forKey: .ttl)
  }
}
