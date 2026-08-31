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

    // MARK: missingTail (§11 — catching up after a backgrounded socket drop)

    /// The reply that raised the push landed while the socket was dead: the
    /// server has one assistant turn we never saw. Append only that, keeping
    /// the local tool row above it.
    func testMissingTailAppendsReplyMissedWhileBackgrounded() {
        let server = ProfileSession.mapHistory([
            ["role": "user", "text": "run ls"],
            ["role": "assistant", "text": "done"],
            ["role": "assistant", "text": "and here's the summary"],
        ])
        let tail = ProfileSession.missingTail(local: rich(), server: server)
        XCTAssertEqual(tail.map(\.text), ["and here's the summary"])
    }

    /// Nothing was missed — the tail must be empty, never a re-append of rows
    /// already on screen.
    func testMissingTailEmptyWhenCaughtUp() {
        let server = ProfileSession.mapHistory([
            ["role": "user", "text": "run ls"],
            ["role": "assistant", "text": "done"],
        ])
        XCTAssertTrue(ProfileSession.missingTail(local: rich(), server: server).isEmpty)
    }

    /// Non-plain rows (tool/status/approval) aren't in server history, so they
    /// must not count against it — otherwise a thread with tool rows would
    /// look ahead of the server and never catch up.
    func testMissingTailIgnoresNonPlainRows() {
        let server = ProfileSession.mapHistory([["role": "user", "text": "run ls"]])
        XCTAssertTrue(ProfileSession.missingTail(local: rich(), server: server).isEmpty)
        XCTAssertEqual(
            ProfileSession.missingTail(local: [], server: server).map(\.text), ["run ls"])
    }
}
