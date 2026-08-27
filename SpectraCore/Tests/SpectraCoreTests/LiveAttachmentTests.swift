import XCTest
@testable import SpectraCore

/// Live §2.6/§9 attachment path against the gated backend. Model-independent
/// (upload + image.attach don't invoke the model). Skips if backend is down.
final class LiveAttachmentTests: XCTestCase {
    static let base = URL(string: ProcessInfo.processInfo.environment["HERMES_BASE_URL"]
                          ?? "http://10.0.0.182:9119")!
    static let pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="

    private func loggedIn() async throws -> HermesAuthClient {
        do { _ = try await HermesAuthClient.fetchStatus(baseURL: Self.base) }
        catch { throw XCTSkip("backend unreachable: \(error)") }
        let client = HermesAuthClient(backend: BackendConfig(baseURL: Self.base))
        let pending = try await client.beginLogin()
        let browser = URLSession(configuration: .ephemeral)
        _ = try await browser.data(from: pending.authorizeURL)
        var req = URLRequest(url: Self.base.appending(path: "auth/password-login"))
        req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["provider": "basic", "username": "spectra", "password": "Test123!"])
        let (d, _) = try await browser.data(for: req)
        struct LoginOK: Codable { let next: String }
        let next = try JSONDecoder().decode(LoginOK.self, from: d).next
        async let hit: Void = { _ = try await browser.data(from: URL(string: next)!) }()
        _ = try await client.finishLogin(pending)
        _ = try await hit
        return client
    }

    func testUploadThenImageAttach() async throws {
        let auth = try await loggedIn()
        let token = try await auth.validAccessToken()
        let png = Data(base64Encoded: Self.pngB64)!

        // Step 1: REST upload → server path
        let path = try await Attachments.upload(
            baseURL: Self.base, token: token, profile: "default",
            data: png, filename: "test.png", mime: "image/png")
        XCTAssertTrue(path.contains("/images/"), "unexpected upload path: \(path)")

        // Step 2: stage on a session via image.attach
        let rpc = HermesRPCConnection(auth: auth)
        try await rpc.connect()
        let sid = try await rpc.call("session.create", params: ["profile": "default"])["session_id"] as? String ?? ""
        XCTAssertFalse(sid.isEmpty)
        let attached = try await rpc.call("image.attach", params: ["session_id": sid, "path": path])
        XCTAssertEqual(attached["attached"] as? Int, 1)
        await rpc.disconnect()
    }
}
