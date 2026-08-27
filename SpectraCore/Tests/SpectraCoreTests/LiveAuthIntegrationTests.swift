import XCTest
@testable import SpectraCore

/// Integration tests against the real gated Hermes instance on the LAN.
/// The "system browser" leg (authorize redirect → /login form → password
/// POST) is simulated headlessly with a cookie-carrying URLSession; every
/// other step exercises HermesAuthClient's actual wire code.
final class LiveAuthIntegrationTests: XCTestCase {
    static let base = URL(string: ProcessInfo.processInfo.environment["HERMES_BASE_URL"]
                          ?? "http://10.0.0.182:9119")!
    static let username = "spectra"
    static let password = "Test123!"

    private func requireServer() async throws -> BackendStatus {
        do {
            return try await HermesAuthClient.fetchStatus(baseURL: Self.base)
        } catch {
            throw XCTSkip("Hermes backend not reachable at \(Self.base): \(error)")
        }
    }

    func testStatusIsPublicAndAdvertisesNativePKCE() async throws {
        let status = try await requireServer()
        XCTAssertTrue(status.authRequired)
        XCTAssertTrue(status.authFlows.contains("native_pkce"))
        XCTAssertFalse(status.profiles.isEmpty)
    }

    func testFullLoginTokenTicketRefreshFlow() async throws {
        _ = try await requireServer()
        let backend = BackendConfig(baseURL: Self.base)
        let client = HermesAuthClient(backend: backend)

        // beginLogin builds the authorize URL + loopback server.
        let pending = try await client.beginLogin()
        defer { pending.cancel() }
        XCTAssertTrue(pending.authorizeURL.absoluteString.contains("code_challenge_method=S256"))

        // --- Simulated browser: follow authorize → /login, then POST the
        // password form exactly as web/login does (fetch + cookie).
        let browser = URLSession(configuration: .ephemeral) // cookie jar included
        let (_, authResp) = try await browser.data(from: pending.authorizeURL)
        XCTAssertEqual((authResp as? HTTPURLResponse)?.statusCode, 200) // followed 302 → /login

        var loginReq = URLRequest(url: Self.base.appending(path: "auth/password-login"))
        loginReq.httpMethod = "POST"
        loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginReq.httpBody = try JSONEncoder().encode(
            ["provider": "basic", "username": Self.username, "password": Self.password])
        let (loginData, loginResp) = try await browser.data(for: loginReq)
        XCTAssertEqual((loginResp as? HTTPURLResponse)?.statusCode, 200)
        struct LoginOK: Codable { let ok: Bool; let next: String }
        let next = try JSONDecoder().decode(LoginOK.self, from: loginData).next

        // Browser "redirects" to the loopback URI — hit it for real so the
        // client's NWListener path is exercised, not bypassed.
        async let callbackHit: Void = { _ = try await browser.data(from: URL(string: next)!) }()

        // --- Client side: catch callback, verify state, exchange code.
        let tokens = try await client.finishLogin(pending)
        _ = try await callbackHit
        XCTAssertEqual(tokens.provider, "basic")
        XCTAssertEqual(tokens.userID, Self.username)
        XCTAssertGreaterThan(tokens.expiresAt, Int(Date().timeIntervalSince1970))

        // Ticket minting (Bearer REST) — twice, to prove fresh mint per call.
        let t1 = try await client.mintTicket()
        let t2 = try await client.mintTicket()
        XCTAssertFalse(t1.isEmpty)
        XCTAssertNotEqual(t1, t2)

        // Refresh rotation via the client.
        let refreshed = try await HermesAuthClient.refresh(
            baseURL: Self.base, refreshToken: tokens.refreshToken, provider: tokens.provider)
        XCTAssertGreaterThanOrEqual(refreshed.expiresAt, tokens.expiresAt)

        // Restore-from-keychain path. Hostless test bundles have no Keychain
        // entitlement (SecItemAdd → -34018), so only assert when storage works;
        // the real persistence path is exercised in the app target.
        if Keychain.loadRefreshToken(backendID: backend.id) != nil {
            let restored = try await client.restore()
            XCTAssertEqual(restored.userID, Self.username)
        }

        await client.logout()
        let loggedIn = await client.isLoggedIn
        XCTAssertFalse(loggedIn)
    }

    func testBadCodeRejected() async throws {
        _ = try await requireServer()
        do {
            _ = try await HermesAuthClient.exchangeCode(
                baseURL: Self.base, code: "bogus", verifier: "bogus-verifier")
            XCTFail("expected rejection")
        } catch let e as HermesAuthError {
            guard case .httpError(400, _) = e else { return XCTFail("wrong error: \(e)") }
        }
    }
}
