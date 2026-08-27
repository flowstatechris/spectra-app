import XCTest
@testable import SpectraCore

final class PersistenceTests: XCTestCase {
    /// The whole snapshot round-trips, including the Message.Kind case that
    /// carries an associated value (the one Codable synthesis most easily breaks).
    func testSnapshotRoundTrip() throws {
        let profile = ProfileInfo(dict: ["name": "trading", "model": "opus",
                                         "provider": "anthropic", "skill_count": 3])!
        let approval = ApprovalRequest(sessionID: "s", payload: [
            "request_id": "a1", "command": "rm scratch.txt", "choices": ["once", "deny"],
        ])!
        let clarify = ClarifyRequest(sessionID: "s", payload: [
            "request_id": "c1", "question": "Environment?", "choices": ["Staging", "Prod"],
        ])!
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let messages = [
            Message(role: .user, text: "hey", attachment: .init(
                name: "notes.txt", kind: .file, byteCount: 12,
                contentType: "text/plain", reference: "@file:notes.txt")),
            Message(role: .agent, text: "hi", kind: .status),
            Message(role: .agent, text: "", kind: .toolActivity(
                ToolActivity(id: "t1", toolName: "terminal", context: "swift test",
                             status: .succeeded, input: "swift test",
                             output: "42 tests passed", duration: 4.8, exitCode: 0))),
            Message(role: .agent, text: "rm -rf tmp", kind: .approvalResolved(choice: "once")),
            Message(role: .agent, text: "", kind: .approval(
                ApprovalEvent(request: approval, state: .resolved(choice: "once", at: timestamp)))),
            Message(role: .agent, text: "", kind: .clarification(
                ClarificationEvent(request: clarify, answers: ["": "Staging"],
                                   state: .answered(at: timestamp)))),
            Message(role: .agent, text: "", kind: .error(
                ErrorEvent(id: "e1", text: "Command timed out", at: timestamp))),
        ]
        let state = PersistedState(
            backendURL: URL(string: "http://10.0.0.182:9119")!,
            activeProfileName: "trading",
            order: ["trading"],
            sessions: [.init(profile: profile, messages: messages)])

        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(PersistedState.self, from: data)

        XCTAssertEqual(back.backendURL, state.backendURL)
        XCTAssertEqual(back.order, ["trading"])
        XCTAssertEqual(back.sessions.first?.profile, profile)
        XCTAssertEqual(back.sessions.first?.messages, messages)  // Equatable covers Kind
        if case .approvalResolved(let c) = back.sessions.first?.messages[3].kind {
            XCTAssertEqual(c, "once")
        } else { XCTFail("approvalResolved kind lost in round-trip") }
    }

    /// The Activity feed round-trips (Codable status enum + Date), so it can
    /// survive a cold launch (handoff §5).
    func testActivityFeedRoundTrip() throws {
        let feed = [
            ActivityItem(id: "t1", profileName: "default", toolName: "terminal",
                         context: "swift test", status: .success,
                         startedAt: Date(timeIntervalSince1970: 1_800_000_000), duration: 4.8),
            ActivityItem(id: "approval:a1", profileName: "default", toolName: "approval",
                         context: "rm -rf build", status: .inReview),
        ]
        let state = PersistedState(
            backendURL: URL(string: "http://x")!, activeProfileName: nil,
            order: [], sessions: [], activity: feed)
        let back = try JSONDecoder().decode(
            PersistedState.self, from: try JSONEncoder().encode(state))
        XCTAssertEqual(back.activity, feed)
    }

    /// Invariant: the snapshot has no place to store a server session id — it's
    /// display-only continuity (gateway reaps orphaned sessions on disconnect).
    func testNoServerSessionIDPersisted() throws {
        let state = PersistedState(backendURL: URL(string: "http://x")!,
                                   activeProfileName: nil, order: [], sessions: [])
        let json = String(data: try JSONEncoder().encode(state), encoding: .utf8)!
        XCTAssertFalse(json.contains("session_id"))
        XCTAssertFalse(json.lowercased().contains("serversession"))
    }
}
