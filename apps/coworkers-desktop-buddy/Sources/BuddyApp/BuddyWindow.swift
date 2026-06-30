// BuddyWindow.swift — Coworkers Buddy main display.
//
// Design reference:
//   hardware-buddy-window.png — macOS companion app (warm native materials)
//   device.jpg — M5StickC Plus OLED layout (character → pips → stats)
//
// macOS 27 Liquid Glass design language:
//   • .glassEffect() panels, system material window background
//   • Warm neutral palette with M5-orange (#D4825A) accent
//   • Tamagotchi stat row mirrors device.jpg: mood ♥, energy ██, Lv
//   • Approve / Deny buttons wired to session permission prompt

import SwiftUI
import UniformTypeIdentifiers
import BuddyCore

// MARK: - ViewModel

@MainActor
@Observable
final class BuddyViewModel {
    var state: BuddyState = BuddyState()
    var summary: String = "Connecting…"
    var needsAttention: Bool = false
    var isPolling: Bool = false
    var error: String? = nil
    var manifest: CharacterManifest? = nil

    let characterController = CharacterController()

    /// BLE link to the physical Claude Hardware Buddy device (CoreBluetooth).
    /// This is what connects the app to Claude Desktop's "Hardware Buddy & Maker
    /// Devices" panel — the device speaks the same Nordic UART Service protocol.
    let hardwareLink = HardwareBuddyLink()

    private let poller = SessionPoller()
    private var pollTask: Task<Void, Never>? = nil
    /// Cumulative output tokens streamed to the device since app start.
    private var cumulativeTokens: UInt64 = 0

    func startPolling() {
        guard pollTask == nil else { return }
        loadManifest()
        // A permission decision pressed on the *physical* device forwards straight
        // into the same file-drop path the on-screen Approve/Deny buttons use.
        hardwareLink.onPermissionDecision = { decision in
            BuddyViewModel.writeDecision(id: decision.id,
                                         decision: decision.decision.rawValue)
        }
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    private func loadManifest() {
        let dir = characterDir()
        manifest = try? CharacterManifest.load(from: dir)
        if let m = manifest {
            characterController.setIdleVariantCount(m.idleVariantCount)
        }
    }

    private func characterDir() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["BUDDY_CHARACTER_DIR"] { return URL(fileURLWithPath: path) }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return cwd
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vendors/anthropics/claude-desktop-buddy/characters/bufo")
    }

    private func tick() async {
        do {
            let sessions = try poller.poll()
            let tokensToday = sessions.reduce(0) { $0 + $1.tokensOut }
            state = BuddyState.from(sessions, tokensToday: tokensToday)
            characterController.update(state)
            cumulativeTokens = max(cumulativeTokens, tokensToday)
            // Stream the same state to the physical buddy if one is paired.
            hardwareLink.send(HeartbeatSnapshot.from(state, tokens: cumulativeTokens))
            await summarise(state)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Drop a permission decision JSON into the sessions directory. The Cowork
    /// session runner polls for these and forwards the decision. Shared by the
    /// on-screen Approve/Deny buttons and the physical device's buttons.
    static func writeDecision(id: String, decision: String) {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["COWORK_SESSIONS_DIR"] else { return }
        let url = URL(fileURLWithPath: dir)
            .appendingPathComponent("permission-\(id).json")
        let payload = #"{"cmd":"permission","id":"\#(id)","decision":"\#(decision)"}"#
        try? payload.write(to: url, atomically: true, encoding: .utf8)
    }

    private func summarise(_ state: BuddyState) async {
        guard let summariser = ClaudeSummariser.fromEnvironment() else {
            summary = state.msg
            return
        }
        do {
            let result = try await summariser.summarise(state)
            summary = result.oneLiner
            needsAttention = result.needsAttention
        } catch {
            summary = state.msg
        }
    }
}

// MARK: - Design tokens (M5StickC Plus colour palette)

private extension Color {
    /// Warm orange — M5StickC Plus silicone case
    static let m5Orange  = Color(red: 0.83, green: 0.51, blue: 0.35)
    /// Level badge green — matches device.jpg "Lv 0" badge
    static let lvGreen   = Color(red: 0.18, green: 0.52, blue: 0.28)
    /// Attention amber — waiting / prompt
    static let warnAmber = Color(red: 0.90, green: 0.65, blue: 0.15)
}

// MARK: - Root view

struct BuddyWindow: View {
    @State private var vm = BuddyViewModel()
    @State private var showFolderImporter = false

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            hardwarePairingCard
            characterPanel
            tamagotchiRow
            Divider()
            sessionList
            Spacer(minLength: 0)
            if let p = vm.state.prompt { promptCard(p) }
            footerBar
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .onAppear  { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
        .fileImporter(isPresented: $showFolderImporter,
                      allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                vm.hardwareLink.sendFolder(url)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    // MARK: - Hardware Buddy pairing card

    /// Mirrors Claude Desktop's "Hardware Buddy & Maker Devices" panel: pair over
    /// BLE, see battery, and push a data folder to the device.
    private var hardwarePairingCard: some View {
        let link = vm.hardwareLink
        return HStack(spacing: 10) {
            Image(systemName: link.state.isPaired ? "cpu.fill" : "cpu")
                .font(.system(size: 14))
                .foregroundStyle(link.state.isPaired ? Color.m5Orange : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(link.state.label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if let bat = link.battery {
                    Text("\(bat.usb ? "⚡︎ " : "")\(bat.pct)%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let p = link.pushProgress {
                Text("\(p.sent)/\(p.total)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if link.state.isPaired {
                Button { showFolderImporter = true } label: {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Send a data folder to the device")

                Button { link.disconnect(unpairDevice: false) } label: {
                    Text("Unpair").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if case .scanning = link.state {
                // No physical device on hand is the common case (e.g. a pure
                // FoundationModels/macOS setup with no Hardware Buddy at all) — give
                // the user a way to cancel instead of "Searching…" with no recourse
                // but quitting. The link itself also times out on its own after 15s.
                Button { link.disconnect(unpairDevice: false) } label: {
                    Text("Stop").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button { link.connect() } label: {
                    Text("Connect").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.m5Orange)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack {
            Text("buddy")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            Spacer()

            HStack(spacing: 4) {
                Circle()
                    .fill(vm.state.connected ? Color.green : Color.secondary)
                    .frame(width: 5, height: 5)
                Text(vm.state.connected ? "live" : "idle")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(vm.state.connected ? .green : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .glassEffect(in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Character panel — OLED screen inside M5 device frame

    private var characterPanel: some View {
        ZStack {
            // Outer warm tinted frame (M5 case)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.m5Orange.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.m5Orange.opacity(0.30), lineWidth: 1.5)
                )

            // Dark OLED screen inset
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.black.opacity(0.90))
                .glassEffect(in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .padding(9)

            // ASCII pet + state label — no manifest needed, matches device.jpg
            VStack(spacing: 4) {
                AsciiPetView(state: vm.characterController.currentState)
                    .onTapGesture(count: 2) { vm.characterController.triggerDizzy() }

                stateChip
            }
            .padding(10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var stateChip: some View {
        let s = vm.characterController.currentState
        let (label, color): (String, Color) = switch s {
        case .sleep:     ("sleep",     .gray)
        case .idle:      ("idle",      .green)
        case .busy:      ("busy",      .cyan)
        case .attention: ("attention", .warnAmber)
        case .celebrate: ("celebrate", .m5Orange)
        case .dizzy:     ("dizzy",     .purple)
        case .heart:     ("heart",     .pink)
        }
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    // MARK: - Tamagotchi row (mirrors M5 OLED: mood / energy / level)

    private var tamagotchiRow: some View {
        HStack(alignment: .center, spacing: 0) {
            levelBadge.padding(.leading, 16)
            Spacer()
            moodPips
            Spacer()
            energyPips.padding(.trailing, 16)
        }
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.03))
    }

    private var levelBadge: some View {
        let lv = min(Int(vm.state.tokensToday / 50_000), 99)
        return Text("Lv \(lv)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.lvGreen, in: RoundedRectangle(cornerRadius: 4))
    }

    /// mood ♥ — one pip per running session (max 5)
    private var moodPips: some View {
        let filled = min(Int(vm.state.sessionsRunning), 5)
        return HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < filled ? "heart.fill" : "heart")
                    .font(.system(size: 9))
                    .foregroundStyle(i < filled ? Color.m5Orange : Color.secondary.opacity(0.35))
            }
        }
    }

    /// energy ██ — 8 pips scaled to tokens_today / 100K
    private var energyPips: some View {
        let fraction = min(Double(vm.state.tokensToday) / 100_000.0, 1.0)
        let filled   = Int(fraction * 8)
        return HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < filled ? Color.m5Orange.opacity(0.85) : Color.secondary.opacity(0.18))
                    .frame(width: 8, height: 11)
            }
        }
    }

    // MARK: - Session list

    private var sessionList: some View {
        VStack(spacing: 0) {
            if vm.state.lines.isEmpty {
                Text("No sessions")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else {
                let rows = Array(vm.state.lines.prefix(4).enumerated())
                ForEach(rows, id: \.offset) { idx, line in
                    sessionRow(line)
                    if idx < rows.count - 1 {
                        Divider().padding(.leading, 30)
                    }
                }
            }
        }
    }

    /// Per-coworker lane colour, keyed off the role name so each coworker reads
    /// as a consistent colour across the session list and the prompt card.
    private static func laneColor(for role: String) -> Color {
        let palette: [Color] = [.m5Orange, .lvGreen, .cyan, .purple, .pink, .warnAmber]
        let idx = abs(role.hashValue) % palette.count
        return palette[idx]
    }

    private func sessionRow(_ line: String) -> some View {
        let isRunning = line.contains("running")
        let isWaiting = line.contains("waiting")
        let dotColor: Color = isRunning ? .green : isWaiting ? .warnAmber : Color.secondary.opacity(0.4)

        // Strip the "[status] " prefix BuddyState.from emits, then peel off an
        // optional "role:: " lane prefix so each row can be split into its
        // owning coworker's lane instead of one flat undifferentiated list.
        var display = line
        if let r = line.range(of: #"^\[(running|waiting|idle)\] "#, options: .regularExpression) {
            display = String(line[r.upperBound...])
        }
        var role: String? = nil
        if let r = display.range(of: #"^[\w-]+:: "#, options: .regularExpression) {
            role = String(display[display.startIndex..<r.upperBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            display = String(display[r.upperBound...])
        }

        return HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            if let role {
                Text(role)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Self.laneColor(for: role), in: RoundedRectangle(cornerRadius: 3))
            }
            Text(display)
                .font(.system(size: 12))
                .foregroundStyle(isRunning ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // MARK: - Permission prompt card with Approve / Deny

    private func promptCard(_ prompt: PermissionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.warnAmber)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(prompt.tool)
                            .font(.system(size: 13, weight: .semibold))
                        // Which coworker raised this gate (WirePermissionPrompt.role),
                        // so "approve" doesn't read as one undifferentiated session.
                        if let role = prompt.role {
                            Text(role)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Self.laneColor(for: role), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text(prompt.hint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    writeDecision(id: prompt.id, decision: "once")
                } label: {
                    Label("Allow", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.m5Orange)
                .controlSize(.small)

                Button {
                    writeDecision(id: prompt.id, decision: "deny")
                } label: {
                    Label("Deny", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.warnAmber.opacity(0.5), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Drop a permission decision JSON into the sessions directory.
    /// The Cowork session runner polls for these and forwards the decision.
    private func writeDecision(id: String, decision: String) {
        BuddyViewModel.writeDecision(id: id, decision: decision)
    }

    // MARK: - Footer

    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(vm.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(shortTokens(vm.state.tokensToday))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private func shortTokens(_ t: UInt64) -> String {
        switch t {
        case 0..<1_000:         return "\(t)"
        case 1_000..<1_000_000: return String(format: "%.0fK", Double(t) / 1_000)
        default:                return String(format: "%.1fM", Double(t) / 1_000_000)
        }
    }
}
