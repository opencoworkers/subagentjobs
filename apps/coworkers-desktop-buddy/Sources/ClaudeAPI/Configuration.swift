// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct Configuration: Sendable {
  public enum Auth: Sendable, Hashable {
    case apiKey(String)
    /// No credential. Use when the caller injects auth per-request via
    /// ``ClaudeClient/send(_:headers:)`` / ``ClaudeClient/stream(_:headers:)``
    /// (rotating bearer tokens), or when `baseURL` is a proxy that adds
    /// authentication server-side.
    case none
  }

  public var auth: Auth
  public var baseURL: URL
  public var version: String

  public init(
    auth: Auth,
    baseURL: URL = URL(string: "https://api.anthropic.com")!,
    version: String = "2023-06-01"
  ) {
    self.auth = auth
    self.baseURL = baseURL
    self.version = version
  }
}
