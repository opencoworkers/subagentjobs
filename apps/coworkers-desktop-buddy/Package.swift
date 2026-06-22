// swift-tools-version: 6.2
// macOS 27 + Xcode beta required (FoundationModels is OS 27+ only)
// Build:
//   DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
//   CLAUDE_CODE_OAUTH_TOKEN=$(cat ~/.claude/.credentials.json | python3 -c \
//     "import sys,json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])") \
//   COWORK_SESSIONS_DIR=/Users/alex-opensubagents/opencoworkers/subagentjobs/sessions \
//   swift run BuddyApp

import PackageDescription

let package = Package(
  name: "coworkers-desktop-buddy",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "BuddyApp", targets: ["BuddyApp"]),
    // CLI fallback (--no-claude, Linux-compatible)
    .executable(name: "buddy", targets: ["BuddyCLI"]),
  ],
  dependencies: [
    // Real ClaudeForFoundationModels — uses FoundationModels on macOS 27
    .package(path: "../../vendors/anthropics/ClaudeForFoundationModels"),
  ],
  targets: [
    // HTTP client copied from ClaudeForFoundationModels for Linux CLI path
    .target(name: "ClaudeAPIClient", path: "Sources/ClaudeAPI"),

    // Shared state + logic (no UI dependency)
    .target(
      name: "BuddyCore",
      dependencies: ["ClaudeAPIClient"],
      path: "Sources/BuddyCore"
    ),

    // SwiftUI visual app — macOS 27, uses real FoundationModels
    .executableTarget(
      name: "BuddyApp",
      dependencies: [
        "BuddyCore",
        .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
      ],
      path: "Sources/BuddyApp"
    ),

    // Terminal CLI (Linux + macOS, no FoundationModels)
    .executableTarget(
      name: "BuddyCLI",
      dependencies: ["BuddyCore"],
      path: "Sources/BuddyCLI"
    ),

    .testTarget(
      name: "BuddyCoreTests",
      dependencies: ["BuddyCore"],
      path: "Tests/BuddyCoreTests"
    ),
  ]
)
