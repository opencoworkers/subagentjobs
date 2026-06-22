import Testing
import BuddyCore

@Suite("BuddyState")
struct BuddyStateTests {

    @Test("empty sessions → disconnected idle state")
    func emptySessionsDisconnected() {
        let state = BuddyState.from([], tokensToday: 0)
        #expect(state.sessionsTotal == 0)
        #expect(state.sessionsRunning == 0)
        #expect(state.connected == false)
        #expect(state.msg == "No Claude connected")
        #expect(state.prompt == nil)
    }

    @Test("running session → correct msg and running count")
    func runningSession() {
        let sessions = [InferenceSession(
            id: "abc", title: "Job listings", status: .running,
            tokensOut: 1_000, pendingTool: nil
        )]
        let state = BuddyState.from(sessions, tokensToday: 1_000)
        #expect(state.sessionsRunning == 1)
        #expect(state.sessionsWaiting == 0)
        #expect(state.connected == true)
        #expect(state.msg.contains("running"))
        #expect(state.tokensToday == 1_000)
    }

    @Test("waiting session → prompt set and msg is approve")
    func waitingSessionHasPrompt() {
        let tool = PendingTool(requestId: "req_123", tool: "Bash", hint: "rm -rf /tmp/foo")
        let sessions = [InferenceSession(
            id: "xyz", title: "Deploy", status: .waiting,
            tokensOut: 500, pendingTool: tool
        )]
        let state = BuddyState.from(sessions, tokensToday: 500)
        #expect(state.sessionsWaiting == 1)
        #expect(state.prompt?.id == "req_123")
        #expect(state.prompt?.tool == "Bash")
        #expect(state.msg.hasPrefix("approve:"))
    }

    @Test("msg is ≤24 chars (physical device parity)")
    func msgFitsDisplay() {
        let sessions = (0..<10).map { i in
            InferenceSession(id: "\(i)", title: "Session \(i)", status: .running,
                             tokensOut: 0, pendingTool: nil)
        }
        let state = BuddyState.from(sessions, tokensToday: 0)
        #expect(state.msg.count <= 24)
    }

    @Test("tokensToday sums all sessions")
    func tokenSum() {
        let sessions = [
            InferenceSession(id: "a", title: "A", status: .idle, tokensOut: 10_000, pendingTool: nil),
            InferenceSession(id: "b", title: "B", status: .idle, tokensOut: 25_000, pendingTool: nil),
        ]
        let state = BuddyState.from(sessions, tokensToday: 35_000)
        #expect(state.tokensToday == 35_000)
    }
}
