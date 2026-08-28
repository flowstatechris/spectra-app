import XCTest
@testable import SpectraCore

/// The freeze fix (ChatView renders the live message as plain text, skipping
/// per-token markdown reparse) hinges on streamingMessageID being set for the
/// duration of the stream and cleared at completion — independent of status
/// churn from interleaved tool events.
@MainActor
final class StreamingStateTests: XCTestCase {
    private func makeSession() -> ProfileSession {
        let backend = BackendConfig(baseURL: URL(string: "http://example.test")!)
        let rpc = HermesRPCConnection(auth: HermesAuthClient(backend: backend))
        return ProfileSession(profile: ProfileInfo(dict: ["name": "default"])!, rpc: rpc)
    }

    func testStreamingIDTracksTheLiveMessageThroughToolChurn() {
        let s = makeSession()
        XCTAssertNil(s.streamingMessageID)

        s.handle(.init(type: "message.start", sessionID: "x", payload: nil))
        s.handle(.init(type: "message.delta", sessionID: "x", payload: ["text": "Hel"]))
        let live = s.streamingMessageID
        XCTAssertEqual(s.messages.last?.id, live, "streaming id must point at the live message")

        // A tool fires mid-stream (status flips to .thinking) — the streaming id
        // must survive, so the view keeps rendering plain text.
        s.handle(.init(type: "tool.start", sessionID: "x", payload: ["tool_id": "t", "name": "bash"]))
        s.handle(.init(type: "tool.complete", sessionID: "x", payload: ["tool_id": "t"]))
        XCTAssertEqual(s.streamingMessageID, live, "tool churn must not clear the streaming id")

        s.handle(.init(type: "message.delta", sessionID: "x", payload: ["text": "lo"]))
        s.handle(.init(type: "message.complete", sessionID: "x", payload: ["text": "Hello"]))
        XCTAssertNil(s.streamingMessageID, "completion clears the streaming id → markdown render")
    }
}
