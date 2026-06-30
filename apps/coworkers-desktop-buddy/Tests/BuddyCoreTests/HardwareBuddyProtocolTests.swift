import Testing
import Foundation
@testable import BuddyCore

@Suite("HardwareBuddyProtocol")
struct HardwareBuddyProtocolTests {

    // MARK: - HeartbeatSnapshot wire shape (must match src/protocol.rs serde keys)

    @Test("snapshot encodes tokens_today (snake_case) and omits nil prompt")
    func snapshotEncoding() throws {
        let snap = HeartbeatSnapshot(total: 2, running: 1, waiting: 0,
                                     msg: "1 session running", tokens: 100, tokensToday: 50)
        let json = try HardwareBuddyCodec().frameString(snap)
        #expect(json.contains("\"tokens_today\":50"))
        #expect(!json.contains("\"prompt\"")) // skip_serializing_if = None
        #expect(json.hasSuffix("\n"))          // newline-delimited framing
    }

    @Test("snapshot round-trips through JSON")
    func snapshotRoundTrip() throws {
        let prompt = WirePermissionPrompt(id: "req_9", tool: "Bash", hint: "rm -rf /tmp")
        let snap = HeartbeatSnapshot(total: 3, running: 2, waiting: 1, msg: "approve: Bash",
                                     entries: ["[busy] a", "[waiting] b"],
                                     tokens: 9_000, tokensToday: 4_000, prompt: prompt)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(HeartbeatSnapshot.self, from: data)
        #expect(back == snap)
    }

    @Test("snapshot decodes a Rust-emitted frame with defaults")
    func snapshotDecodesRustFrame() throws {
        // Minimal frame a Rust bridge could emit (entries/tokens defaulted).
        let frame = #"{"total":1,"running":1,"waiting":0,"msg":"x","tokens":0,"tokens_today":0}"#
        let snap = try JSONDecoder().decode(HeartbeatSnapshot.self, from: Data(frame.utf8))
        #expect(snap.total == 1)
        #expect(snap.entries.isEmpty)
        #expect(snap.prompt == nil)
    }

    // MARK: - BuddyState bridge

    @Test("BuddyState maps into a HeartbeatSnapshot")
    func fromBuddyState() {
        let sessions = [InferenceSession(id: "x", title: "Deploy", status: .waiting,
                                         tokensOut: 500,
                                         pendingTool: PendingTool(requestId: "r1", tool: "Bash", hint: "h"))]
        let state = BuddyState.from(sessions, tokensToday: 500)
        let snap = HeartbeatSnapshot.from(state, tokens: 1_200)
        #expect(snap.waiting == 1)
        #expect(snap.tokens == 1_200)
        #expect(snap.tokensToday == 500)
        #expect(snap.prompt?.tool == "Bash")
    }

    // MARK: - DesktopCommand tagged encoding

    @Test("commands encode with cmd tag + snake_case variants")
    func commandEncoding() throws {
        let codec = HardwareBuddyCodec()
        #expect(try codec.frameString(DesktopCommand.status).contains("\"cmd\":\"status\""))
        #expect(try codec.frameString(DesktopCommand.charBegin(name: "bufo", total: 9))
            .contains("\"cmd\":\"char_begin\""))
        #expect(try codec.frameString(DesktopCommand.fileEnd).contains("\"cmd\":\"file_end\""))
        let chunk = try codec.frameString(DesktopCommand.chunk(d: "AAA="))
        #expect(chunk.contains("\"cmd\":\"chunk\"") && chunk.contains("\"d\":\"AAA=\""))
    }

    @Test("command round-trips")
    func commandRoundTrip() throws {
        let cmd = DesktopCommand.file(path: "manifest.json", size: 42)
        let data = try JSONEncoder().encode(cmd)
        #expect(try JSONDecoder().decode(DesktopCommand.self, from: data) == cmd)
    }

    // MARK: - Device → Desktop frames

    @Test("permission decision decodes from device frame")
    func permissionDecisionDecode() throws {
        let frame = #"{"cmd":"permission","id":"req_7","decision":"once"}"#
        let d = try JSONDecoder().decode(PermissionDecision.self, from: Data(frame.utf8))
        #expect(d.id == "req_7")
        #expect(d.decision == .once)
    }

    @Test("status ack decodes battery with mV/mA keys")
    func statusAckDecode() throws {
        let frame = """
        {"ack":"status","ok":true,"data":{"name":"Claude-7F","sec":true,\
        "bat":{"pct":82,"mV":4011,"mA":-120,"usb":true}}}
        """
        let ack = try JSONDecoder().decode(CommandAck.self, from: Data(frame.utf8))
        #expect(ack.ok)
        #expect(ack.data?.name == "Claude-7F")
        #expect(ack.data?.bat?.pct == 82)
        #expect(ack.data?.bat?.ma == -120) // negative = charging
    }

    // MARK: - TimeSync

    @Test("time sync carries [epoch, tzOffset]")
    func timeSync() throws {
        let ts = TimeSync(epochSeconds: 1_700_000_000, tzOffsetSeconds: -28_800)
        let json = try HardwareBuddyCodec().frameString(ts)
        #expect(json.contains("\"time\":[1700000000,-28800]"))
    }

    // MARK: - LineBuffer framing

    @Test("LineBuffer splits fragmented frames on newlines")
    func lineBufferFragments() {
        let buf = LineBuffer()
        #expect(buf.append(Data("{\"a\":1}".utf8)).isEmpty)      // no newline yet
        let lines = buf.append(Data("}\n{\"b\":2}\n".utf8))
        // First completed line is "{\"a\":1}}" then "{\"b\":2}"
        #expect(lines.count == 2)
        #expect(String(decoding: lines[1], as: UTF8.self) == "{\"b\":2}")
    }

    // MARK: - FolderPush

    @Test("FolderPush emits char_begin … chunks … char_end")
    func folderPush() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("buddy-push-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(repeating: 0x41, count: 400) // > chunkSize, forces multiple chunks
            .write(to: tmp.appendingPathComponent("data.bin"))

        let cmds = try FolderPush.commands(for: tmp, name: "pack")
        guard case .charBegin(let name, _) = cmds.first else {
            Issue.record("expected char_begin first"); return
        }
        #expect(name == "pack")
        guard case .charEnd = cmds.last else {
            Issue.record("expected char_end last"); return
        }
        let chunkCount = cmds.filter { if case .chunk = $0 { return true } else { return false } }.count
        #expect(chunkCount == 3) // ceil(400 / 180)
    }
}
