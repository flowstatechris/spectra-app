import XCTest
@testable import SpectraCore

@MainActor
final class ReconnectTests: XCTestCase {
    private func makeSession(messages: [Message], storedSessionID: String? = nil) -> ProfileSession {
        let cfg = BackendConfig(baseURL: URL(string: "http://10.0.0.182:9119")!)
        let rpc = HermesRPCConnection(auth: HermesAuthClient(backend: cfg))  // never connected
        let profile = ProfileInfo(dict: ["name": "trading"])!
        return ProfileSession(profile: profile, rpc: rpc, restoring: messages,
                              storedSessionID: storedSessionID)
    }

    /// The core §12 invariant: a reconnect drops the dead server session but the
    /// on-screen thread must survive (cache = view continuity).
    func testResetForReconnectKeepsMessagesDropsSession() {
        let msgs = [Message(role: .user, text: "hi"), Message(role: .agent, text: "yo")]
        let s = makeSession(messages: msgs)
        s.resetForReconnect()
        XCTAssertEqual(s.messages, msgs, "reconnect must not wipe the cached thread")
        XCTAssertNil(s.serverSessionID)
        XCTAssertNil(s.pendingApproval)
        XCTAssertNil(s.pendingClarify)
        XCTAssertEqual(s.status, .idle)
    }

    /// Continuity backbone (handoff §2): a reconnect drops the dead *runtime*
    /// id but must keep the durable `storedSessionID`, so the next ensureSession
    /// resumes the same server conversation instead of forking a fresh one.
    func testResetForReconnectKeepsDurableSessionID() {
        let s = makeSession(messages: [Message(role: .user, text: "hi")],
                            storedSessionID: "durable-abc123")
        s.resetForReconnect()
        XCTAssertNil(s.serverSessionID, "dead runtime id must be cleared")
        XCTAssertEqual(s.storedSessionID, "durable-abc123", "durable id must survive reconnect")
    }

    /// A server-side reclaim (session.reclaimed) while the socket stays up must
    /// behave like a reconnect: keep the thread + durable id so the next send
    /// resumes, rather than stranding the user on a forgotten runtime id.
    func testSessionReclaimedKeepsThreadAndDurableID() {
        let msgs = [Message(role: .user, text: "hi"), Message(role: .agent, text: "yo")]
        let s = makeSession(messages: msgs, storedSessionID: "durable-xyz")
        s.handle(.init(type: "session.reclaimed", sessionID: "runtime-dead", payload: nil))
        XCTAssertEqual(s.messages, msgs, "reclaim must not wipe the cached thread")
        XCTAssertEqual(s.storedSessionID, "durable-xyz", "durable id must survive reclaim")
        XCTAssertNil(s.serverSessionID)
        XCTAssertEqual(s.status, .idle)
    }
}
