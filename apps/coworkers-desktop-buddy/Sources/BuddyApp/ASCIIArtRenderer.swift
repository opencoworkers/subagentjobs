// ASCIIArtRenderer.swift — pixel-brightness-to-character mapping.
//
// Inspired by chenglou/pretext variable-typographic-ascii demo
// (https://chenglou.me/pretext/variable-typographic-ascii/).
//
// The core idea: each "pixel" of the source image maps to a character
// whose visual weight (density of ink) approximates the pixel's brightness.
// Variable typographic refinement: characters are chosen for visual weight,
// not just simple luminance — e.g. '@' is heavier than '#' is heavier than '+'.
//
// This implementation works entirely in CoreGraphics / AppKit — no WebView,
// no JavaScript. It produces ASCII frames that can be stored in memory and
// displayed in SwiftUI as a monospace Text view.
//
// Grid size: 48 columns × 25 rows (roughly matches 96×100 GIF at ~2:1 aspect).

import AppKit
import CoreGraphics

public struct ASCIIArtRenderer: Sendable {
    public let cols: Int
    public let rows: Int

    // Characters ordered by visual weight (ink density), lightest → darkest.
    // Chosen to match the variable-typographic aesthetic: each char's visual
    // weight in a monospace font approximates the corresponding luminance band.
    // For a DARK background the palette is reversed (dark pixels need heavy chars).
    private let palette: [Character]

    /// cols/rows = sampling grid. darkBackground = invert palette.
    public init(cols: Int = 48, rows: Int = 25, darkBackground: Bool = true) {
        self.cols = cols
        self.rows = rows
        // Light-to-dark character set (visually weighted, not just ANSI order).
        // Mirrors the density progression used in pretext's ASCII art demo.
        let lightToDark: [Character] = [
            " ", "·", ".", "′", "´", ",", ":", ";", "!", "|",
            "i", "l", "1", "t", "f", "r", "j", "v", "x", "z",
            "c", "s", "u", "n", "e", "o", "a", "h", "k", "w",
            "b", "d", "q", "p", "g", "m", "W", "M", "N", "Q",
            "0", "8", "B", "#", "%", "@"
        ]
        // On dark background: bright pixels → heavy chars, dark pixels → space.
        palette = darkBackground ? lightToDark.reversed() : lightToDark
    }

    /// Convert an NSImage to an ASCII art string.
    /// Returns nil if the image can't be rasterised.
    public func render(_ image: NSImage) -> String? {
        guard let bitmap = rasterise(image) else { return nil }

        var lines: [String] = []
        for row in 0..<rows {
            var line = ""
            for col in 0..<cols {
                let brightness = pixelBrightness(bitmap, x: col, y: row)
                let idx = min(
                    Int(brightness * Float(palette.count)),
                    palette.count - 1
                )
                // Append char twice — monospace chars are ~2:1 aspect so
                // doubling horizontally gives square pixels.
                line.append(palette[idx])
                line.append(palette[idx])
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - CoreGraphics helpers

    private func rasterise(_ image: NSImage) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: cols,
            pixelsHigh: rows,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: cols, height: rows).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: cols, height: rows))

        return rep
    }

    /// Returns 0.0 (dark) … 1.0 (bright) for a pixel at (x, y).
    private func pixelBrightness(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Float {
        guard let color = rep.colorAt(x: x, y: y) else { return 0 }
        // Perceptual luminance weights (rec.601)
        let r = Float(color.redComponent)
        let g = Float(color.greenComponent)
        let b = Float(color.blueComponent)
        let a = Float(color.alphaComponent)
        // Premultiply alpha: transparent pixels = background (dark = 0.0)
        return (0.299 * r + 0.587 * g + 0.114 * b) * a
    }
}

// MARK: - Cached frame extractor

/// Extracts individual frames from an animated GIF file and caches them as
/// pre-rendered ASCII strings. Thread-safe, uses value-type storage.
public struct ASCIIFrameCache: Sendable {
    public let frames: [String]
    public let frameDelayMs: Int

    public static func build(gifURL: URL, renderer: ASCIIArtRenderer) -> ASCIIFrameCache? {
        guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [String] = []
        var totalDelay: Double = 0

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            if let ascii = renderer.render(nsImage) {
                frames.append(ascii)
            }
            // GIF frame delay (in 1/100s units)
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any],
               let gif = props["{GIF}"] as? [String: Any],
               let delay = gif["DelayTime"] as? Double {
                totalDelay += delay
            }
        }

        guard !frames.isEmpty else { return nil }
        let avgDelayMs = frames.isEmpty ? 100 : Int((totalDelay / Double(frames.count)) * 1000)
        return ASCIIFrameCache(frames: frames, frameDelayMs: max(avgDelayMs, 50))
    }
}
