// CharacterManifestTests.swift
// Tests CharacterManifest JSON parsing including the idle: String | [String] ambiguity.

import Foundation
import Testing
@testable import BuddyCore

@Suite("CharacterManifest — manifest.json parsing")
struct CharacterManifestTests {

    // Minimal manifest with idle as a single string
    static let singleIdleJSON = """
    {
      "name": "test-char",
      "colors": {"body":"#FF0000","bg":"#000000","text":"#FFFFFF"},
      "states": {
        "sleep": "sleep.gif",
        "idle": "idle.gif",
        "busy": "busy.gif",
        "attention": "attention.gif",
        "celebrate": "celebrate.gif",
        "dizzy": "dizzy.gif",
        "heart": "heart.gif"
      }
    }
    """.data(using: .utf8)!

    // Manifest with idle as array (bufo's actual format)
    static let arrayIdleJSON = """
    {
      "name": "bufo",
      "colors": {"body":"#6B8E23","bg":"#000000","text":"#FFFFFF","textDim":"#808080","ink":"#000000"},
      "states": {
        "sleep": "sleep.gif",
        "idle": ["idle_0.gif","idle_1.gif","idle_2.gif"],
        "busy": "busy.gif",
        "attention": "attention.gif",
        "celebrate": "celebrate.gif",
        "dizzy": "dizzy.gif",
        "heart": "heart.gif"
      }
    }
    """.data(using: .utf8)!

    @Test("parses manifest with idle as single string")
    func singleIdleGIF() throws {
        let dir = URL(fileURLWithPath: "/tmp/test-char")
        let manifest = try CharacterManifest.parse(Self.singleIdleJSON, baseDirectory: dir)
        #expect(manifest.name == "test-char")
        #expect(manifest.gif(for: .idle, variant: 0)?.lastPathComponent == "idle.gif")
        #expect(manifest.gif(for: .sleep, variant: 0)?.lastPathComponent == "sleep.gif")
        #expect(manifest.gif(for: .busy, variant: 0)?.lastPathComponent == "busy.gif")
    }

    @Test("parses manifest with idle as array (bufo format)")
    func arrayIdleGIFs() throws {
        let dir = URL(fileURLWithPath: "/tmp/bufo")
        let manifest = try CharacterManifest.parse(Self.arrayIdleJSON, baseDirectory: dir)
        #expect(manifest.name == "bufo")
        #expect(manifest.idleVariantCount == 3)
        #expect(manifest.gif(for: .idle, variant: 0)?.lastPathComponent == "idle_0.gif")
        #expect(manifest.gif(for: .idle, variant: 1)?.lastPathComponent == "idle_1.gif")
        #expect(manifest.gif(for: .idle, variant: 2)?.lastPathComponent == "idle_2.gif")
        // Variant wraps around
        #expect(manifest.gif(for: .idle, variant: 3)?.lastPathComponent == "idle_0.gif")
    }

    @Test("colors decode correctly")
    func colorsDecoded() throws {
        let dir = URL(fileURLWithPath: "/tmp/bufo")
        let manifest = try CharacterManifest.parse(Self.arrayIdleJSON, baseDirectory: dir)
        #expect(manifest.colors.body == "#6B8E23")
        #expect(manifest.colors.bg == "#000000")
        #expect(manifest.colors.textDim == "#808080")
    }

    @Test("non-idle states resolve to single URL")
    func nonIdleStateURLs() throws {
        let dir = URL(fileURLWithPath: "/tmp/bufo")
        let manifest = try CharacterManifest.parse(Self.arrayIdleJSON, baseDirectory: dir)
        for state in [CharacterState.sleep, .busy, .attention, .celebrate, .dizzy, .heart] {
            let url = manifest.gif(for: state)
            #expect(url != nil, "Expected URL for state \(state.rawValue)")
            #expect(url?.lastPathComponent.hasSuffix(".gif") == true)
        }
    }

    @Test("load from actual bufo directory (live test)",
          .disabled("Requires BUDDY_CHARACTER_DIR env var or vendors path"))
    func loadsLiveBufoManifest() throws {
        let bufoDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BUDDY_CHARACTER_DIR"]
            ?? "/Users/alex-opensubagents/opencoworkers/subagentjobs/vendors/anthropics/claude-desktop-buddy/characters/bufo")
        let manifest = try CharacterManifest.load(from: bufoDir)
        #expect(manifest.name == "bufo")
        #expect(manifest.idleVariantCount == 9)
        // Verify all GIF files actually exist
        for state in CharacterState.allCases {
            let url = manifest.gif(for: state)
            #expect(url != nil)
            if let url {
                #expect(FileManager.default.fileExists(atPath: url.path),
                        "Missing: \(url.lastPathComponent) for state \(state.rawValue)")
            }
        }
    }
}
