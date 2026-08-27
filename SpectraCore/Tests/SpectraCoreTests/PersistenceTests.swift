import XCTest
@testable import SpectraCore

final class PersistenceTests: XCTestCase {
    /// The whole snapshot round-trips, including the Message.Kind case that
    /// carries an associated value (the one Codable synthesis most easily breaks).
    func testSnapshotRoundTrip() throws {
        let profile = ProfileInfo(dict: ["name": "trading", "model": "opus",
                                         "provider": "anthropic", "skill_count": 3])!
        let messages = [
            Message(role: .user, text: "hey"),
            Message(role: .agent, text: "hi", kind: .status),
            Message(role: .agent, text: "rm -rf tmp", kind: .approvalResolved(choice: "once")),
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
        if case .approvalResolved(let c) = back.sessions.first?.messages.last?.kind {
            XCTAssertEqual(c, "once")
        } else { XCTFail("approvalResolved kind lost in round-trip") }
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
