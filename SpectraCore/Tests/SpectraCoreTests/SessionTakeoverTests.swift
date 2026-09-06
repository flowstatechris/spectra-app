import XCTest
@testable import SpectraCore

/// #1 (multi-device handoff): send() special-cases exactly one server refusal
/// — SESSION_NOT_OWNED — by matching the RPCError's `reason` literally in a
/// `catch` pattern (see ProfileSession.submitPrompt). Associated-value literal
/// matching against an *optional* String is easy to get subtly wrong (e.g.
/// matching `nil` or every serverError), so pin the exact matching semantics
/// this code relies on, independent of any real connection.
final class SessionTakeoverTests: XCTestCase {
    private func classify(_ error: Error) -> String {
        switch error {
        case HermesRPCConnection.RPCError.serverError(_, _, "SESSION_NOT_OWNED"):
            return "takeover"
        case HermesRPCConnection.RPCError.serverError:
            return "other server error"
        default:
            return "unknown"
        }
    }

    func testMatchesOnlyTheSessionNotOwnedReason() {
        XCTAssertEqual(
            classify(HermesRPCConnection.RPCError.serverError(code: 4090, message: "x", reason: "SESSION_NOT_OWNED")),
            "takeover")
    }

    func testDoesNotMatchAnUnrelatedReasonOnTheSameCode() {
        XCTAssertEqual(
            classify(HermesRPCConnection.RPCError.serverError(code: 4090, message: "x", reason: "MAX_CONCURRENT_SESSIONS")),
            "other server error")
    }

    func testDoesNotMatchWhenNoReasonWasSent() {
        XCTAssertEqual(
            classify(HermesRPCConnection.RPCError.serverError(code: 4090, message: "x", reason: nil)),
            "other server error")
    }

    func testMatchesRegardlessOfCode() {
        // The reason is the contract, not the code (server docs this explicitly).
        XCTAssertEqual(
            classify(HermesRPCConnection.RPCError.serverError(code: 5000, message: "x", reason: "SESSION_NOT_OWNED")),
            "takeover")
    }
}
