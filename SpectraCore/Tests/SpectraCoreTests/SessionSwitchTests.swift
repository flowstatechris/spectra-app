import XCTest
@testable import SpectraCore

/// Resuming a picked session maps Hermes history into the Spectra timeline.
/// v1 keeps only user/assistant text rows (handoff §2b) — tool/system/empty
/// rows are dropped, not reconstructed.
final class SessionSwitchTests: XCTestCase {
    func testMapHistoryKeepsOnlyUserAndAssistantText() {
        let raw: [[String: Any]] = [
            ["role": "user", "text": "hello"],
            ["role": "assistant", "text": "hi there"],
            ["role": "tool", "name": "bash", "context": "ls"],   // dropped
            ["role": "assistant", "text": "   "],                 // dropped (blank)
            ["role": "system", "text": "boot"],                   // dropped
            ["role": "user", "text": "bye"],
        ]
        let msgs = ProfileSession.mapHistory(raw)
        XCTAssertEqual(msgs.map(\.role), [.user, .agent, .user])
        XCTAssertEqual(msgs.map(\.text), ["hello", "hi there", "bye"])
    }

    func testMapHistoryHandlesGarbage() {
        XCTAssertTrue(ProfileSession.mapHistory(nil).isEmpty)
        XCTAssertTrue(ProfileSession.mapHistory("not an array").isEmpty)
    }

    // MARK: reconcile (handoff §3 — rich-history reconciliation)

    private func rich() -> [Message] {
        [Message(role: .user, text: "run ls"),
         Message(id: "tool:1", role: .agent, text: "",
                 kind: .toolActivity(ToolActivity(id: "1", toolName: "bash"))),
         Message(role: .agent, text: "done")]
    }

    /// Server hasn't advanced (same user-turn count) → keep the richer cache,
    /// so the tool row survives a switch-away-and-back.
    func testReconcileKeepsCacheWhenServerNotAhead() {
        let server = ProfileSession.mapHistory([
            ["role": "user", "text": "run ls"],
            ["role": "assistant", "text": "done"],
        ])
        let out = ProfileSession.reconcile(cached: rich(), server: server)
        XCTAssertEqual(out.count, 3)
        guard case .toolActivity = out[1].kind else { return XCTFail("tool row lost") }
    }

    /// Session continued elsewhere (more user turns on the server) → trust the
    /// authoritative server text instead of the stale rich cache.
    func testReconcilePrefersServerWhenAhead() {
        let server = ProfileSession.mapHistory([
            ["role": "user", "text": "run ls"],
            ["role": "assistant", "text": "done"],
            ["role": "user", "text": "now pwd"],
            ["role": "assistant", "text": "/tmp"],
        ])
        let out = ProfileSession.reconcile(cached: rich(), server: server)
        XCTAssertEqual(out.map(\.text), ["run ls", "done", "now pwd", "/tmp"])
    }

    /// No cache (first visit / post-relaunch) → server history.
    func testReconcileFallsBackToServerWithoutCache() {
        let server = ProfileSession.mapHistory([["role": "user", "text": "hi"]])
        XCTAssertEqual(ProfileSession.reconcile(cached: nil, server: server), server)
        XCTAssertEqual(ProfileSession.reconcile(cached: [], server: server), server)
    }
}
