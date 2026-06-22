// swift-tools-version: 6.0
// Requires: Swift 6.0+ on Linux (Ubuntu 22.04 aarch64 or x86_64)
// Install:  swift.org/install/linux
//
// No Apple FoundationModels dependency — ClaudeAPI is copied from
// vendors/anthropics/ClaudeForFoundationModels/Sources/ClaudeAPI (Apache 2.0)
// and uses only Foundation/URLSession which ship with Swift on Linux.

import PackageDescription

let package = Package(
  name: "coworkers-desktop-buddy",
  platforms: [
    // Linux has no platform constraint in SPM — these are fallbacks for macOS dev.
    .macOS(.v13),
  ],
  products: [
    .executable(name: "buddy", targets: ["BuddyCLI"]),
  ],
  targets: [
    // Copied from vendors/anthropics/ClaudeForFoundationModels/Sources/ClaudeAPI
    // (Apache 2.0). access levels patched package→public for cross-target use.
    .target(
      name: "ClaudeAPI",
      path: "Sources/ClaudeAPI"
    ),

    // Core buddy logic — session polling, state modelling, Claude calls.
    .target(
      name: "BuddyCore",
      dependencies: ["ClaudeAPI"],
      path: "Sources/BuddyCore"
    ),

    // CLI entry point — terminal display, argument parsing.
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
