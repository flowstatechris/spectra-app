import XCTest
@testable import SpectraCore

@MainActor
final class InteractionEventTests: XCTestCase {
    private func makeSession() -> ProfileSession {
        let backend = BackendConfig(baseURL: URL(string: "http://example.test")!)
        let rpc = HermesRPCConnection(auth: HermesAuthClient(backend: backend))
        return ProfileSession(profile: ProfileInfo(dict: ["name": "default"])!, rpc: rpc)
    }

    func testApprovalIsHardBlockingTimelineEventAndExpiresInPlace() {
        let session = makeSession()
        session.handle(.init(type: "approval.request", sessionID: "s", payload: [
            "request_id": "a1", "command": "rm scratch.txt",
            "choices": ["once", "deny"],
        ]))

        XCTAssertFalse(session.canSend)
        XCTAssertEqual(session.pendingApproval?.id, "a1")
        XCTAssertEqual(session.messages.count, 1)
        guard case .approval(let pending) = session.messages[0].kind else {
            return XCTFail("approval should be a timeline event")
        }
        XCTAssertEqual(pending.state, .pending)

        // Replay after reconnect updates the same row instead of duplicating it.
        session.handle(.init(type: "approval.request", sessionID: "s", payload: [
            "request_id": "a1", "command": "rm scratch.txt",
            "choices": ["once", "deny"],
        ]))
        XCTAssertEqual(session.messages.count, 1)

        session.handle(.init(type: "approval.expire", sessionID: "s",
                             payload: ["request_id": "a1"]))
        XCTAssertTrue(session.canSend)
        XCTAssertNil(session.pendingApproval)
        guard case .approval(let expired) = session.messages[0].kind else {
            return XCTFail("approval row should remain in history")
        }
        XCTAssertEqual(expired.state, .expired)
    }

    func testClarificationIsNonBlockingAndPreservesSeededAnswersOnExpiry() {
        let session = makeSession()
        session.handle(.init(type: "clarify.request", sessionID: "s", payload: [
            "request_id": "c1",
            "questions": [
                ["qid": "q1", "question": "Environment?", "choices": ["Staging", "Prod"]],
                ["qid": "q2", "question": "Region?", "choices": ["US", "EU"]],
            ],
            "answers": ["q1": "Staging"],
        ]))

        XCTAssertTrue(session.canSend)
        XCTAssertEqual(session.pendingClarify?.id, "c1")
        guard case .clarification(let pending) = session.messages.first?.kind else {
            return XCTFail("clarification should be a timeline event")
        }
        XCTAssertEqual(pending.answers, ["q1": "Staging"])

        session.handle(.init(type: "clarify.expire", sessionID: "s",
                             payload: ["request_id": "c1"]))
        XCTAssertNil(session.pendingClarify)
        guard case .clarification(let expired) = session.messages.first?.kind else {
            return XCTFail("clarification row should remain in history")
        }
        XCTAssertEqual(expired.state, .expired)
        XCTAssertEqual(expired.answers, ["q1": "Staging"])
    }

    func testTurnErrorIsVisibleAndFailsRunningTool() {
        let session = makeSession()
        session.handle(.init(type: "tool.start", sessionID: "s", payload: [
            "tool_id": "t1", "name": "terminal",
        ]))
        session.handle(.init(type: "turn.error", sessionID: "s",
                             payload: ["text": "Command timed out"]))

        guard case .toolActivity(let tool) = session.messages[0].kind else {
            return XCTFail("first row should be the tool")
        }
        XCTAssertEqual(tool.status, .failed)
        guard case .error(let error) = session.messages[1].kind else {
            return XCTFail("turn error should be visible in history")
        }
        XCTAssertEqual(error.text, "Command timed out")
        XCTAssertEqual(session.lastError, "Command timed out")
        XCTAssertEqual(session.status, .alert)
    }
}
