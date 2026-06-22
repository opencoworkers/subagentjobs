// CharacterManifest.swift — parses manifest.json from a character pack.
// Handles the idle: String | [String] ambiguity in the bufo manifest.

import Foundation

public struct CharacterColors: Codable, Sendable {
    public let body: String
    public let bg: String
    public let text: String
    public let textDim: String?
    public let ink: String?
}

/// Parsed + resolved character manifest.
public struct CharacterManifest: Sendable {
    public let name: String
    public let colors: CharacterColors
    /// All GIF URLs keyed by state. Idle may have multiple variants.
    private let stateURLs: [CharacterState: [URL]]

    /// Number of idle animation variants (1 for single-file characters, 9 for bufo).
    public var idleVariantCount: Int {
        stateURLs[.idle]?.count ?? 1
    }

    /// Resolve the GIF URL for a given state and variant index.
    /// `variant` wraps around so callers can use any index.
    public func gif(for state: CharacterState, variant: Int = 0) -> URL? {
        guard let urls = stateURLs[state], !urls.isEmpty else { return nil }
        return urls[variant % urls.count]
    }

    // MARK: - Loading

    /// Load from a character pack directory (reads `manifest.json` inside).
    public static func load(from directory: URL) throws -> CharacterManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try parse(data, baseDirectory: directory)
    }

    /// Parse manifest JSON with a given base directory for resolving GIF paths.
    public static func parse(_ data: Data, baseDirectory: URL) throws -> CharacterManifest {
        let raw = try JSONDecoder().decode(RawManifest.self, from: data)
        func resolve(_ name: String) -> URL {
            baseDirectory.appendingPathComponent(name)
        }

        var urls: [CharacterState: [URL]] = [:]
        urls[.sleep]     = [resolve(raw.states.sleep)]
        urls[.idle]      = raw.states.idle.all.map(resolve)
        urls[.busy]      = [resolve(raw.states.busy)]
        urls[.attention] = [resolve(raw.states.attention)]
        urls[.celebrate] = [resolve(raw.states.celebrate)]
        urls[.dizzy]     = [resolve(raw.states.dizzy)]
        urls[.heart]     = [resolve(raw.states.heart)]

        return CharacterManifest(name: raw.name, colors: raw.colors, stateURLs: urls)
    }

    // MARK: - Raw Codable types

    private struct RawManifest: Codable {
        let name: String
        let colors: CharacterColors
        let states: RawStates
    }

    private struct RawStates: Codable {
        let sleep: String
        let idle: OneOrMany
        let busy: String
        let attention: String
        let celebrate: String
        let dizzy: String
        let heart: String
    }

    /// Handles the `idle` field which can be either `"idle.gif"` or `["idle_0.gif","idle_1.gif",...]`.
    private enum OneOrMany: Codable {
        case one(String)
        case many([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let single = try? container.decode(String.self) {
                self = .one(single)
            } else {
                self = .many(try container.decode([String].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .one(let s):   try container.encode(s)
            case .many(let ss): try container.encode(ss)
            }
        }

        var all: [String] {
            switch self {
            case .one(let s):   return [s]
            case .many(let ss): return ss
            }
        }
    }
}
