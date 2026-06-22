// CharacterDisplayView.swift — shows bufo (or any character pack) in the buddy window.
//
// Defaults to animated GIF mode. Tap the character to toggle ASCII art mode —
// the variable-typographic aesthetic from chenglou/pretext, rendered natively
// in Swift via ASCIIArtRenderer.
//
// STATE LABEL: shows the current CharacterState name below the character.
// ASCII toggle: one tap switches between GIF and ASCII art rendering.

import SwiftUI
import BuddyCore

struct CharacterDisplayView: View {
    let manifest: CharacterManifest
    let state: CharacterState
    let idleVariant: Int
    @State private var showASCII: Bool = false
    @State private var asciiCache: [CharacterState: [String]] = [:]
    @State private var asciiFrameIndex: Int = 0
    @State private var asciiTimer: Timer? = nil

    private let renderer = ASCIIArtRenderer(cols: 38, rows: 20, darkBackground: true)
    // Character display size (2× the 96×100 GIF)
    private let charWidth: CGFloat  = 192
    private let charHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if showASCII {
                    asciiView
                } else {
                    gifView
                }
            }
            .frame(width: charWidth, height: charHeight)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onTapGesture { toggleASCII() }
            .overlay(
                // Subtle hint to tap
                Text(showASCII ? "GIF" : "ASCII")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(4),
                alignment: .bottomTrailing
            )

            stateLabel
        }
        .onChange(of: state) { _, _ in resetASCIIAnimation() }
        .onChange(of: idleVariant) { _, _ in resetASCIIAnimation() }
    }

    // MARK: - GIF view

    private var gifView: some View {
        Group {
            if let url = manifest.gif(for: state, variant: idleVariant) {
                GIFPlayerView(gifURL: url)
            } else {
                // Fallback: coloured placeholder matching bufo body color
                Rectangle()
                    .fill(Color(hex: manifest.colors.body) ?? .green)
                    .overlay(
                        Text(state.rawValue.uppercased())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.black)
                    )
            }
        }
    }

    // MARK: - ASCII art view

    private var asciiView: some View {
        let frames = asciiCache[state] ?? []
        let frame = frames.isEmpty ? "loading..." : (frames[asciiFrameIndex % frames.count])
        return ScrollView([]) {
            Text(frame)
                .font(.system(size: 5, weight: .regular, design: .monospaced))
                .foregroundStyle(Color(hex: manifest.colors.body) ?? .green)
                .lineSpacing(0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .disabled(true)
        .onAppear { ensureASCIICached(state: state) }
    }

    // MARK: - State label

    private var stateLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            Text(state.rawValue.uppercased())
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(stateColor)
        }
    }

    private var stateColor: Color {
        switch state {
        case .sleep:     return .gray
        case .idle:      return .green
        case .busy:      return .cyan
        case .attention: return .yellow
        case .celebrate: return .orange
        case .dizzy:     return .purple
        case .heart:     return .pink
        }
    }

    // MARK: - ASCII toggle

    private func toggleASCII() {
        showASCII.toggle()
        if showASCII {
            ensureASCIICached(state: state)
            startASCIIAnimation()
        } else {
            stopASCIIAnimation()
        }
    }

    private func ensureASCIICached(state: CharacterState) {
        guard asciiCache[state] == nil,
              let url = manifest.gif(for: state, variant: idleVariant) else { return }
        Task.detached(priority: .utility) {
            if let cache = ASCIIFrameCache.build(gifURL: url, renderer: renderer) {
                await MainActor.run {
                    asciiCache[state] = cache.frames
                    // Start animation now that cache is ready
                    if showASCII { startASCIIAnimation() }
                }
            }
        }
    }

    private func startASCIIAnimation() {
        stopASCIIAnimation()
        asciiFrameIndex = 0
        let frames = asciiCache[state] ?? []
        guard frames.count > 1 else { return }
        // Use Task to avoid Sendable closure mutation warning
        asciiTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                asciiFrameIndex = (asciiFrameIndex + 1) % frames.count
            }
        }
    }

    private func stopASCIIAnimation() {
        asciiTimer?.invalidate()
        asciiTimer = nil
    }

    private func resetASCIIAnimation() {
        asciiFrameIndex = 0
        if showASCII {
            ensureASCIICached(state: state)
            startASCIIAnimation()
        }
    }
}

// MARK: - Hex color helper

extension Color {
    /// Parse a CSS hex color string like `"#6B8E23"`.
    init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let value = UInt64(h, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >>  8) & 0xFF) / 255,
            blue:  Double( value        & 0xFF) / 255
        )
    }
}
