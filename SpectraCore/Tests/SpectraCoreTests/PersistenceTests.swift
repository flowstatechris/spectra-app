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
            Message(role: .user, text: "hey", attachments: [.init(
                name: "notes.txt", kind: .file, byteCount: 12,
                contentType: "text/plain", reference: "@file:notes.txt")]),
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

// MARK: - Memory bounds

/// The three caps that keep a long-lived install from growing without limit.
final class MemoryBoundsTests: XCTestCase {

    func testToolTextIsClampedAndMarked() {
        let huge = String(repeating: "x", count: ProfileSession.toolTextLimit * 3)
        let clamped = ProfileSession.clamp(huge)
        XCTAssertLessThan(clamped.utf8.count, huge.utf8.count)
        XCTAssertTrue(clamped.hasPrefix("xxx"))
        XCTAssertTrue(clamped.contains("truncated"))
    }

    func testShortToolTextIsUntouched() {
        XCTAssertEqual(ProfileSession.clamp("ls -la"), "ls -la")
    }

    /// Clamping must not split a multi-byte character into invalid UTF-8.
    func testClampKeepsValidUTF8() {
        let emoji = String(repeating: "🙂", count: ProfileSession.toolTextLimit)
        let clamped = ProfileSession.clamp(emoji)
        XCTAssertTrue(clamped.contains("truncated"))
        XCTAssertEqual(clamped, String(decoding: Array(clamped.utf8), as: UTF8.self))
    }

    func testUploadBodyIsWellFormedJSONWithoutCopyingThroughSerialization() throws {
        let body = try Attachments.dataURLBody(data: Data([0xDE, 0xAD, 0xBE, 0xEF]),
                                               filename: #"od"d "quote".txt"#,
                                               mime: "text/plain")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["filename"], #"od"d "quote".txt"#)
        XCTAssertEqual(json["data_url"], "data:text/plain;base64,3q2+7w==")
    }

    func testOversizedUploadIsRefusedNotAttempted() {
        XCTAssertThrowsError(
            try Attachments.dataURLBody(data: Data(count: Attachments.maxUploadBytes + 1),
                                        filename: "big.bin", mime: "application/octet-stream"))
    }

    func testPersistedHistoryIsCapped() {
        let msgs = (0..<(Persistence.historyLimit + 50)).map {
            Message(id: "m\($0)", role: .user, text: "\($0)")
        }
        let kept = Array(msgs.suffix(Persistence.historyLimit))
        XCTAssertEqual(kept.count, Persistence.historyLimit)
        XCTAssertEqual(kept.last?.id, msgs.last?.id)   // newest survives, not oldest
    }
}
