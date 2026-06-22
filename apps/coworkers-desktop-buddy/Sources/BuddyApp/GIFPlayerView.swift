// GIFPlayerView.swift — macOS NSImageView-backed animated GIF player.
// NSImageView with animates = true handles GIF frame decoding and looping natively.

import SwiftUI
import AppKit

struct GIFPlayerView: NSViewRepresentable {
    let gifURL: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        // Only reload if the URL changed
        if view.image == nil || context.coordinator.lastURL != gifURL {
            context.coordinator.lastURL = gifURL
            if let image = NSImage(contentsOf: gifURL) {
                view.image = image
                view.animates = true
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastURL: URL? = nil
    }
}
