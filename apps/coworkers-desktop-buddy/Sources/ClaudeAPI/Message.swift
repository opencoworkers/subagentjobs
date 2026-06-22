// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct Message: Sendable, Hashable, Codable {
  public enum Role: String, Sendable, Codable { case user, assistant }

  public var role: Role
  public var content: [ContentBlock]

  public init(role: Role, content: [ContentBlock]) {
    self.role = role
    self.content = content
  }

  public static func user(_ text: String) -> Message {
    .init(role: .user, content: [.text(text)])
  }

  public static func assistant(_ text: String) -> Message {
    .init(role: .assistant, content: [.text(text)])
  }
}
