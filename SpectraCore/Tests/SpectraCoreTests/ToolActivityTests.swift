import XCTest
@testable import SpectraCore

@MainActor
final class ToolActivityTests: XCTestCase {
    private func makeSession() -> ProfileSession {
        let backend = BackendConfig(baseURL: URL(string: "http://example.test")!)
        let rpc = HermesRPCConnection(auth: HermesAuthClient(backend: backend))
        return ProfileSession(profile: ProfileInfo(dict: ["name": "default"])!, rpc: rpc)
    }

    func testToolLifecycleProducesOneChronologicalExpandableRow() {
        let session = makeSession()
        session.handle(.init(type: "message.start", sessionID: "s", payload: nil))
        session.handle(.init(type: "tool.start", sessionID: "s", payload: [
            "tool_id": "t1", "name": "terminal", "context": "swift test",
            "args": ["command": "swift test"],
        ]))
        session.handle(.init(type: "tool.complete", sessionID: "s", payload: [
            "tool_id": "t1", "name": "terminal", "duration_s": 4.8,
            "result": ["output": "42 tests passed", "exit_code": 0],
        ]))
        session.handle(.init(type: "message.delta", sessionID: "s", payload: ["text": "Done."]))

        XCTAssertEqual(session.messages.count, 2)
        guard case .toolActivity(let tool) = session.messages[0].kind else {
            return XCTFail("first timeline item should be the tool row")
        }
        XCTAssertEqual(tool.id, "t1")
        XCTAssertEqual(tool.status, .succeeded)
        XCTAssertEqual(tool.input, "swift test")
        XCTAssertEqual(tool.exitCode, 0)
        XCTAssertEqual(tool.duration, 4.8)
        XCTAssertTrue(tool.output?.contains("42 tests passed") == true)
        XCTAssertEqual(session.messages[1].text, "Done.")
    }

    func testFailedCommandAndRiskUpdateExistingRow() {
        let session = makeSession()
        session.handle(.init(type: "tool.start", sessionID: "s", payload: [
            "tool_id": "t2", "name": "terminal", "args": ["command": "false"],
        ]))
        session.handle(.init(type: "tool.output_risk", sessionID: "s", payload: [
            "tool_id": "t2", "risk": "high", "findings": ["Potential credential output"],
        ]))
        session.handle(.init(type: "tool.complete", sessionID: "s", payload: [
            "tool_id": "t2", "name": "terminal",
            "result": ["output": "", "exit_code": 1],
        ]))

        XCTAssertEqual(session.messages.count, 1)
        guard case .toolActivity(let tool) = session.messages[0].kind else {
            return XCTFail("timeline item should remain a tool row")
        }
        XCTAssertEqual(tool.status, .failed)
        XCTAssertEqual(tool.exitCode, 1)
        XCTAssertEqual(tool.risk, "high")
        XCTAssertEqual(tool.findings, ["Potential credential output"])
    }
}
