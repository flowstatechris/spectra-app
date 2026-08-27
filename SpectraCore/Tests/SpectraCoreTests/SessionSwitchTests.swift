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
}
