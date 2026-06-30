// HardwareBuddyProtocol.swift — Swift mirror of src/protocol.rs.
//
// This is the wire protocol the physical Claude Hardware Buddy device speaks over
// Bluetooth LE / Nordic UART Service (NUS) — the same protocol Claude Desktop's
// "Hardware Buddy & Maker Devices" panel uses to pair and drive a device.
//
// Until now only the Rust bridge (src/protocol.rs) could talk to the device. The
// macOS app rendered a *virtual* pet but had no path to the physical buddy. These
// types give the Swift app a byte-compatible encoder/decoder so `HardwareBuddyLink`
// (CoreBluetooth, macOS-only) can pair with, drive, and push folders to a real device.
//
// All messages are newline-delimited JSON. Field names are kept identical to the
// serde representation in src/protocol.rs so both ends interoperate.
//
// Source of truth: apps/coworkers-desktop-buddy/src/protocol.rs
//                  vendors/anthropics/claude-desktop-buddy/REFERENCE.md

import Foundation

// MARK: - Nordic UART Service identifiers

/// BLE identifiers for the Nordic UART Service the buddy firmware advertises.
public enum NordicUART {
    /// Service UUID advertised by the device (name prefix "Claude").
    public static let serviceUUID  = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Characteristic the desktop *writes* to (device RX).
    public static let rxWriteUUID  = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Characteristic the desktop *subscribes* to for notifications (device TX).
    public static let txNotifyUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

    /// The device advertises its name with this prefix.
    public static let namePrefix = "Claude"
}

// MARK: - Desktop → Device

/// Sent whenever session state changes, plus a keepalive every 10 s.
/// If no snapshot arrives for ~30 s the device treats the link as dead.
///
/// JSON keys mirror `protocol.rs::HeartbeatSnapshot` exactly.
public struct HeartbeatSnapshot: Codable, Sendable, Equatable {
    /// Total open sessions.
    public var total: UInt32
    /// Sessions actively generating.
    public var running: UInt32
    /// Sessions blocked on a permission prompt.
    public var waiting: UInt32
    /// One-line summary for a small display.
    public var msg: String
    /// Recent transcript lines, newest first.
    public var entries: [String]
    /// Cumulative output tokens since the desktop app started.
    public var tokens: UInt64
    /// Output tokens since local midnight.
    public var tokensToday: UInt64
    /// Present only when a permission decision is needed.
    public var prompt: WirePermissionPrompt?

    public init(total: UInt32 = 0, running: UInt32 = 0, waiting: UInt32 = 0,
                msg: String = "", entries: [String] = [], tokens: UInt64 = 0,
                tokensToday: UInt64 = 0, prompt: WirePermissionPrompt? = nil) {
        self.total = total; self.running = running; self.waiting = waiting
        self.msg = msg; self.entries = entries; self.tokens = tokens
        self.tokensToday = tokensToday; self.prompt = prompt
    }

    private enum CodingKeys: String, CodingKey {
        case total, running, waiting, msg, entries, tokens
        case tokensToday = "tokens_today"
        case prompt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total       = try c.decodeIfPresent(UInt32.self, forKey: .total)   ?? 0
        running     = try c.decodeIfPresent(UInt32.self, forKey: .running) ?? 0
        waiting     = try c.decodeIfPresent(UInt32.self, forKey: .waiting) ?? 0
        msg         = try c.decodeIfPresent(String.self, forKey: .msg)     ?? ""
        entries     = try c.decodeIfPresent([String].self, forKey: .entries) ?? []
        tokens      = try c.decodeIfPresent(UInt64.self, forKey: .tokens)  ?? 0
        tokensToday = try c.decodeIfPresent(UInt64.self, forKey: .tokensToday) ?? 0
        prompt      = try c.decodeIfPresent(WirePermissionPrompt.self, forKey: .prompt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(total, forKey: .total)
        try c.encode(running, forKey: .running)
        try c.encode(waiting, forKey: .waiting)
        try c.encode(msg, forKey: .msg)
        try c.encode(entries, forKey: .entries)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(tokensToday, forKey: .tokensToday)
        // Match serde `skip_serializing_if = "Option::is_none"`.
        try c.encodeIfPresent(prompt, forKey: .prompt)
    }
}

/// Pending tool-call approval attached to a `HeartbeatSnapshot`.
/// Named `Wire…` to avoid colliding with `BuddyState.PermissionPrompt`.
public struct WirePermissionPrompt: Codable, Sendable, Equatable {
    /// Opaque ID — must be echoed back in `PermissionDecision`.
    public let id: String
    /// Tool name, e.g. `"Bash"`.
    public let tool: String
    /// Short hint shown on the device display, e.g. `"rm -rf /tmp/foo"`.
    public let hint: String
    /// Which coworker raised this gate (e.g. `"design"`, `"finance"`). Absent for
    /// plain session permission prompts. Lets the device show *who* is asking.
    public let role: String?

    public init(id: String, tool: String, hint: String = "", role: String? = nil) {
        self.id = id; self.tool = tool; self.hint = hint; self.role = role
    }

    private enum CodingKeys: String, CodingKey { case id, tool, hint, role }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id   = try c.decode(String.self, forKey: .id)
        tool = try c.decode(String.self, forKey: .tool)
        hint = try c.decodeIfPresent(String.self, forKey: .hint) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role)
    }
}

/// One-shot time sync sent on connect: `[epoch_seconds, tz_offset_seconds]`.
public struct TimeSync: Codable, Sendable, Equatable {
    public let time: [Int64]

    public init(epochSeconds: Int64, tzOffsetSeconds: Int64) {
        self.time = [epochSeconds, tzOffsetSeconds]
    }

    /// Build a `TimeSync` for the current wall clock and local time zone.
    public static func now(_ date: Date = Date(),
                           timeZone: TimeZone = .current) -> TimeSync {
        TimeSync(epochSeconds: Int64(date.timeIntervalSince1970),
                 tzOffsetSeconds: Int64(timeZone.secondsFromGMT(for: date)))
    }
}

// MARK: - Desktop commands (expect an ack from the device)

/// Commands the desktop sends; each elicits a `CommandAck` from the device.
/// Mirrors `protocol.rs::DesktopCommand` (`#[serde(tag = "cmd", rename_all = "snake_case")]`).
public enum DesktopCommand: Sendable, Equatable {
    case status
    case name(String)
    case owner(String)
    case unpair
    // Folder-push transport (the "Send to Device" / "Drop a data folder" flow).
    case charBegin(name: String, total: UInt64)
    case file(path: String, size: UInt64)
    case chunk(d: String)   // base64-encoded bytes
    case fileEnd
    case charEnd
}

extension DesktopCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case cmd, name, total, path, size, d
    }
    private enum Tag: String, Codable {
        case status, name, owner, unpair
        case charBegin = "char_begin"
        case file
        case chunk
        case fileEnd = "file_end"
        case charEnd = "char_end"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status:
            try c.encode(Tag.status, forKey: .cmd)
        case .name(let n):
            try c.encode(Tag.name, forKey: .cmd)
            try c.encode(n, forKey: .name)
        case .owner(let n):
            try c.encode(Tag.owner, forKey: .cmd)
            try c.encode(n, forKey: .name)
        case .unpair:
            try c.encode(Tag.unpair, forKey: .cmd)
        case .charBegin(let name, let total):
            try c.encode(Tag.charBegin, forKey: .cmd)
            try c.encode(name, forKey: .name)
            try c.encode(total, forKey: .total)
        case .file(let path, let size):
            try c.encode(Tag.file, forKey: .cmd)
            try c.encode(path, forKey: .path)
            try c.encode(size, forKey: .size)
        case .chunk(let d):
            try c.encode(Tag.chunk, forKey: .cmd)
            try c.encode(d, forKey: .d)
        case .fileEnd:
            try c.encode(Tag.fileEnd, forKey: .cmd)
        case .charEnd:
            try c.encode(Tag.charEnd, forKey: .cmd)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .cmd) {
        case .status: self = .status
        case .name:   self = .name(try c.decode(String.self, forKey: .name))
        case .owner:  self = .owner(try c.decode(String.self, forKey: .name))
        case .unpair: self = .unpair
        case .charBegin:
            self = .charBegin(name: try c.decode(String.self, forKey: .name),
                              total: try c.decode(UInt64.self, forKey: .total))
        case .file:
            self = .file(path: try c.decode(String.self, forKey: .path),
                         size: try c.decode(UInt64.self, forKey: .size))
        case .chunk:  self = .chunk(d: try c.decode(String.self, forKey: .d))
        case .fileEnd: self = .fileEnd
        case .charEnd: self = .charEnd
        }
    }
}

// MARK: - Device → Desktop

/// Permission decision the physical device sends back after the operator
/// presses a button on the device.
public struct PermissionDecision: Codable, Sendable, Equatable {
    public let cmd: String   // always "permission"
    public let id: String
    public let decision: PermissionDecisionKind

    public init(id: String, decision: PermissionDecisionKind) {
        self.cmd = "permission"; self.id = id; self.decision = decision
    }
}

public enum PermissionDecisionKind: String, Codable, Sendable, Equatable {
    case once, deny
}

/// Generic ack the device sends for every `cmd` it receives.
public struct CommandAck: Codable, Sendable, Equatable {
    public let ack: String
    public let ok: Bool
    public let n: UInt64?
    public let error: String?
    public let data: StatusData?

    public init(ack: String, ok: Bool, n: UInt64? = nil,
                error: String? = nil, data: StatusData? = nil) {
        self.ack = ack; self.ok = ok; self.n = n; self.error = error; self.data = data
    }
}

/// Payload inside a `status` ack.
public struct StatusData: Codable, Sendable, Equatable {
    public let name: String
    public let sec: Bool
    public let bat: BatteryStatus?
    public let sys: SysInfo?
    public let stats: DeviceStats?

    public init(name: String, sec: Bool = false, bat: BatteryStatus? = nil,
                sys: SysInfo? = nil, stats: DeviceStats? = nil) {
        self.name = name; self.sec = sec; self.bat = bat; self.sys = sys; self.stats = stats
    }

    private enum CodingKeys: String, CodingKey { case name, sec, bat, sys, stats }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name  = try c.decode(String.self, forKey: .name)
        sec   = try c.decodeIfPresent(Bool.self, forKey: .sec) ?? false
        bat   = try c.decodeIfPresent(BatteryStatus.self, forKey: .bat)
        sys   = try c.decodeIfPresent(SysInfo.self, forKey: .sys)
        stats = try c.decodeIfPresent(DeviceStats.self, forKey: .stats)
    }
}

public struct BatteryStatus: Codable, Sendable, Equatable {
    public let pct: UInt8
    public let mv: UInt16
    public let ma: Int16    // negative = charging
    public let usb: Bool

    public init(pct: UInt8, mv: UInt16, ma: Int16, usb: Bool) {
        self.pct = pct; self.mv = mv; self.ma = ma; self.usb = usb
    }

    private enum CodingKeys: String, CodingKey {
        case pct
        case mv = "mV"
        case ma = "mA"
        case usb
    }
}

public struct SysInfo: Codable, Sendable, Equatable {
    public let up: UInt32     // uptime seconds
    public let heap: UInt32   // free heap bytes
    public init(up: UInt32, heap: UInt32) { self.up = up; self.heap = heap }
}

public struct DeviceStats: Codable, Sendable, Equatable {
    public let appr: UInt16   // lifetime approvals
    public let deny: UInt16   // lifetime denials
    public let vel: UInt16    // median seconds-to-respond
    public let nap: UInt32    // cumulative nap seconds
    public let lvl: UInt8     // current level (tokens / 50_000)

    public init(appr: UInt16, deny: UInt16, vel: UInt16, nap: UInt32, lvl: UInt8) {
        self.appr = appr; self.deny = deny; self.vel = vel; self.nap = nap; self.lvl = lvl
    }
}

// MARK: - BuddyState → HeartbeatSnapshot

extension HeartbeatSnapshot {
    /// Build the wire snapshot the device renders from the app's `BuddyState`.
    /// `tokens` is the cumulative session total since app start; `BuddyState.tokensToday`
    /// supplies the daily counter.
    public static func from(_ state: BuddyState, tokens: UInt64? = nil) -> HeartbeatSnapshot {
        // NOTE: previously dropped `role` here even when `state.prompt.role` was
        // set, so the physical device never learned which coworker raised the
        // gate. `WirePermissionPrompt` always carried a `role` field — it just
        // wasn't being populated from app state.
        let prompt = state.prompt.map {
            WirePermissionPrompt(id: $0.id, tool: $0.tool, hint: $0.hint, role: $0.role)
        }
        return HeartbeatSnapshot(
            total: UInt32(state.sessionsTotal),
            running: UInt32(state.sessionsRunning),
            waiting: UInt32(state.sessionsWaiting),
            msg: state.msg,
            entries: state.lines,
            tokens: tokens ?? state.tokensToday,
            tokensToday: state.tokensToday,
            prompt: prompt
        )
    }
}

// MARK: - Newline-delimited JSON framing

/// Encodes/decodes the newline-delimited JSON frames carried over NUS.
///
/// The device firmware splits its RX stream on `\n`, so every desktop→device
/// message is one compact JSON object followed by a single newline. Incoming
/// notifications are buffered until a newline completes a frame.
public struct HardwareBuddyCodec: Sendable {
    public init() {}

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Compact, stable key order keeps frames small and diffable.
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    /// Encode any `Encodable` wire message into a single `\n`-terminated frame.
    public func frame<T: Encodable>(_ value: T) throws -> Data {
        var data = try Self.encoder.encode(value)
        data.append(0x0A) // '\n'
        return data
    }

    /// Convenience: frame and return as UTF-8 `String` (used in tests/logging).
    public func frameString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try frame(value), as: UTF8.self)
    }
}

/// Buffers an incoming notification stream and yields complete JSON lines.
/// CoreBluetooth delivers arbitrary fragments, so callers feed every chunk in
/// and drain whatever complete frames have accumulated.
public final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()

    public init() {}

    /// Append a fragment and return any complete (newline-terminated) lines,
    /// each with the trailing newline stripped. Empty lines are skipped.
    public func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }
}

// MARK: - Folder push ("Send to Device")

/// Splits a directory tree into the ordered `DesktopCommand` sequence the device
/// expects for a character/data push: `char_begin`, then per file
/// `file` → N×`chunk` → `file_end`, finally `char_end`.
///
/// This is the typed equivalent of the "Drop a data folder here → Send to Device"
/// action in Claude Desktop's Hardware Buddy panel.
public enum FolderPush {
    /// Max raw bytes per chunk before base64 (keeps each NUS frame within MTU bounds).
    public static let chunkSize = 180

    public enum PushError: Error, CustomStringConvertible {
        case notADirectory(URL)
        public var description: String {
            switch self {
            case .notADirectory(let u): "Not a directory: \(u.path)"
            }
        }
    }

    /// Build the full command sequence for pushing `directory` under logical
    /// name `name` (defaults to the directory's own name).
    public static func commands(for directory: URL,
                                name: String? = nil,
                                fileManager: FileManager = .default) throws -> [DesktopCommand] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw PushError.notADirectory(directory)
        }
        let charName = name ?? directory.lastPathComponent
        let files = try regularFiles(under: directory, fileManager: fileManager)
        let totalBytes = files.reduce(UInt64(0)) { $0 + (fileSize($1) ?? 0) }

        var cmds: [DesktopCommand] = [.charBegin(name: charName, total: totalBytes)]
        for file in files {
            let rel = relativePath(of: file, base: directory)
            let data = (try? Data(contentsOf: file)) ?? Data()
            cmds.append(.file(path: rel, size: UInt64(data.count)))
            for start in stride(from: 0, to: data.count, by: chunkSize) {
                let end = min(start + chunkSize, data.count)
                let slice = data.subdata(in: start..<end)
                cmds.append(.chunk(d: slice.base64EncodedString()))
            }
            cmds.append(.fileEnd)
        }
        cmds.append(.charEnd)
        return cmds
    }

    private static func regularFiles(under directory: URL,
                                     fileManager: FileManager) throws -> [URL] {
        guard let en = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if vals?.isRegularFile == true { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func relativePath(of file: URL, base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath.hasPrefix(basePath + "/") {
            return String(filePath.dropFirst(basePath.count + 1))
        }
        return file.lastPathComponent
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(UInt64.init)
    }
}
