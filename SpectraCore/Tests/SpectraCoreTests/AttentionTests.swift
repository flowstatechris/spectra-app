import XCTest
@testable import SpectraCore

@MainActor
final class AttentionTests: XCTestCase {
    private func makeSession() -> ProfileSession {
        let cfg = BackendConfig(baseURL: URL(string: "http://10.0.0.182:9119")!)
        let rpc = HermesRPCConnection(auth: HermesAuthClient(backend: cfg))
        return ProfileSession(profile: ProfileInfo(dict: ["name": "default"])!, rpc: rpc)
    }

    /// The single attention signal: none when idle, clarify when asked, and
    /// approval outranks clarify (it hard-blocks sending; clarify doesn't).
    func testAttentionPriority() {
        let s = makeSession()
        XCTAssertNil(s.attention)

        s.handle(.init(type: "clarify.request", sessionID: "s1",
                       payload: ["request_id": "c1", "question": "Which env?"]))
        XCTAssertEqual(s.attention, .clarify)

        s.handle(.init(type: "approval.request", sessionID: "s1",
                       payload: ["request_id": "a1", "command": "rm -rf build"]))
        XCTAssertEqual(s.attention, .approval, "approval must outrank an open clarify")
    }

    func testRouteToChatOnlyAdoptsKnownProfile() {
        let app = AppState()
        let before = app.chatRouteToken
        app.routeToChat(profile: "ghost")           // unknown → don't switch profile
        XCTAssertNil(app.activeProfileName)
        XCTAssertEqual(app.chatRouteToken, before + 1, "token bumps so the tab still routes")
    }
}
