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
      path: "Sources/BuddyApp",
      exclude: ["Info.plist"],
      // `swift build`/`swift run` produce a bare Mach-O binary, not an .app bundle, so
      // there's no Info.plist to read NSBluetoothAlwaysUsageDescription from. Embed one
      // directly into the __TEXT,__info_plist section — the standard SPM technique for
      // command-line-built executables that need a TCC usage-description prompt
      // (Bluetooth, camera, mic, etc.) instead of crashing with
      // "This app has crashed because it attempted to access privacy-sensitive data
      // without a usage description."
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/BuddyApp/Info.plist",
        ])
      ]
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
