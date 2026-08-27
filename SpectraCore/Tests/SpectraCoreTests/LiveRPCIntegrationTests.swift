import XCTest
@testable import SpectraCore

/// Drives HermesRPCConnection + ProfileSession against the live gated backend.
/// The agent's model call may fail server-side (bad API key) — that's fine:
/// the transport contract (RPC round trips + event folding) is what's under test.
final class LiveRPCIntegrationTests: XCTestCase {
    static let base = URL(string: ProcessInfo.processInfo.environment["HERMES_BASE_URL"]
                          ?? "http://10.0.0.182:9119")!

    private func loggedInAuth() async throws -> HermesAuthClient {
        do {
            _ = try await HermesAuthClient.fetchStatus(baseURL: Self.base)
        } catch {
            throw XCTSkip("Hermes backend not reachable: \(error)")
        }
        let backend = BackendConfig(baseURL: Self.base)
        let client = HermesAuthClient(backend: backend)

        // Headless "browser": authorize → password form → loopback redirect.
        let pending = try await client.beginLogin()
        let browser = URLSession(configuration: .ephemeral)
        _ = try await browser.data(from: pending.authorizeURL)
        var loginReq = URLRequest(url: Self.base.appending(path: "auth/password-login"))
        loginReq.httpMethod = "POST"
        loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginReq.httpBody = try JSONEncoder().encode(
            ["provider": "basic", "username": "spectra", "password": "Test123!"])
        let (loginData, _) = try await browser.data(for: loginReq)
        struct LoginOK: Codable { let next: String }
        let next = try JSONDecoder().decode(LoginOK.self, from: loginData).next
        async let hit: Void = { _ = try await browser.data(from: URL(string: next)!) }()
        _ = try await client.finishLogin(pending)
        _ = try await hit
        return client
    }

    func testRPCConnectListProfilesAndChatTurn() async throws {
        let auth = try await loggedInAuth()
        let rpc = HermesRPCConnection(auth: auth)
        try await rpc.connect()

        var sawReady = false
        let eventsStream = await rpc.events()

        // profiles.list — rich metadata (ADR-0002).
        let result = try await rpc.call("profiles.list")
        let profiles = (result["profiles"] as? [[String: Any]] ?? []).compactMap(ProfileInfo.init(dict:))
        XCTAssertFalse(profiles.isEmpty)
        XCTAssertTrue(profiles.contains { $0.name == "default" })
        let def = profiles.first { $0.name == "default" }!
        XCTAssertFalse(def.model.isEmpty)  // metadata really is rich here

        // ProfileSession: create session + submit prompt, fold events.
        let session = await MainActor.run { ProfileSession(profile: def, rpc: rpc) }
        await session.send("Reply with exactly: WIRE OK")
        let sid = await MainActor.run { session.serverSessionID }
        XCTAssertNotNil(sid)
        let userMsgCount = await MainActor.run { session.messages.count }
        XCTAssertEqual(userMsgCount, 1)  // our user message

        let deadline = Date().addingTimeInterval(30)
        var sawComplete = false
        for await event in eventsStream {
            if event.type == "gateway.ready" { sawReady = true }
            if event.sessionID == sid {
                await MainActor.run { session.handle(event) }
                if event.type == "message.complete" { sawComplete = true; break }
            }
            if Date() > deadline { break }
        }
        XCTAssertTrue(sawReady)
        XCTAssertTrue(sawComplete, "no message.complete within 30s")

        let messages = await MainActor.run { session.messages }
        XCTAssertGreaterThan(messages.count, 1)
        let status = await MainActor.run { session.status }
        XCTAssertEqual(status, .idle)

        // session.history round-trips our prompt.
        let hist = try await rpc.call("session.history", params: ["session_id": sid!])
        let rows = hist["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(rows.contains { ($0["text"] as? String)?.contains("WIRE OK") == true })

        await rpc.disconnect()
        let state = await rpc.state
        XCTAssertEqual(state, .disconnected)
    }

    func testServerErrorSurfacesAsRPCError() async throws {
        let auth = try await loggedInAuth()
        let rpc = HermesRPCConnection(auth: auth)
        try await rpc.connect()
        do {
            _ = try await rpc.call("prompt.submit", params: ["session_id": "nonexistent", "text": "x"])
            XCTFail("expected server error")
        } catch let e as HermesRPCConnection.RPCError {
            guard case .serverError = e else { return XCTFail("wrong error: \(e)") }
        }
        await rpc.disconnect()
    }
}
