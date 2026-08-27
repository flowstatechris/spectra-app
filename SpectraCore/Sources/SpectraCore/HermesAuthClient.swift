import Foundation

// MARK: - Wire types (verified against hermes_cli/dashboard_auth/routes.py)

public struct TokenSet: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Int      // unix seconds
    public let provider: String
    public let userID: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case provider
        case userID = "user_id"
    }
}

/// `GET /api/status` — public, no auth (spec §2.2).
public struct BackendStatus: Codable, Sendable {
    public let profiles: [String]
    public let gatewayMode: String
    public let authRequired: Bool
    public let authFlows: [String]

    enum CodingKeys: String, CodingKey {
        case profiles
        case gatewayMode = "gateway_mode"
        case authRequired = "auth_required"
        case authFlows = "auth_flows"
    }
}

public enum HermesAuthError: Error, Equatable {
    case loopbackListenFailed
    case loopbackCallbackMalformed
    case stateMismatch
    case authorizationDenied(String)   // server error param or missing code
    case httpError(Int, String)        // status code + body detail
    case sessionExpired                // 401 on refresh — must re-login
    case providerUnreachable           // 503 — retry later
    case notLoggedIn
}

// MARK: - Client

/// RFC 8252 native-app auth against one Hermes backend (spec §2.1/§4).
///
/// Owns the token state for a backend: access token in memory only,
/// refresh token in the Keychain. All REST goes through `authorizedRequest`,
/// which transparently refreshes with a 60s expiry skew.
public actor HermesAuthClient {
    public let backend: BackendConfig
    private var tokens: TokenSet?
    private let session: URLSession

    public init(backend: BackendConfig, session: URLSession = .shared) {
        self.backend = backend
        self.session = session
    }

    // MARK: Public status (pre-auth)

    public static func fetchStatus(baseURL: URL, session: URLSession = .shared) async throws -> BackendStatus {
        let (data, resp) = try await session.data(from: baseURL.appending(path: "api/status"))
        try Self.checkOK(resp, data)
        return try JSONDecoder().decode(BackendStatus.self, from: data)
    }

    // MARK: Login flow

    /// Build the authorize URL and loopback server; the caller presents
    /// `authorizeURL` in the system browser (ASWebAuthenticationSession) and
    /// then awaits `finishLogin`.
    public struct PendingLogin {
        public let authorizeURL: URL
        let pkce: PKCE
        let state: String
        let server: LoopbackCallbackServer
        public func cancel() { server.cancel() }
    }

    public func beginLogin() throws -> PendingLogin {
        let pkce = PKCE()
        var stateBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        let state = Data(stateBytes).base64URLEncoded
        let server = try LoopbackCallbackServer()

        var comps = URLComponents(url: backend.baseURL.appending(path: "auth/native/authorize"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "provider", value: ""),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "redirect_uri", value: server.redirectURI),
            .init(name: "state", value: state),
        ]
        return PendingLogin(authorizeURL: comps.url!, pkce: pkce, state: state, server: server)
    }

    /// Await the loopback redirect, verify state, exchange the code.
    public func finishLogin(_ pending: PendingLogin) async throws -> TokenSet {
        let params = try await pending.server.waitForCallback()
        guard let code = params["code"] else {
            throw HermesAuthError.authorizationDenied(params["error"] ?? "no code in callback")
        }
        guard params["state"] == pending.state else { throw HermesAuthError.stateMismatch }
        let tok = try await Self.exchangeCode(baseURL: backend.baseURL, code: code,
                                              verifier: pending.pkce.verifier, session: session)
        adopt(tok)
        return tok
    }

    /// `POST /auth/native/token` (spec §2.1).
    public static func exchangeCode(baseURL: URL, code: String, verifier: String,
                                    session: URLSession = .shared) async throws -> TokenSet {
        try await postJSON(baseURL.appending(path: "auth/native/token"),
                           body: ["code": code, "code_verifier": verifier], session: session)
    }

    // MARK: Session restore / refresh

    /// Restore from Keychain on launch. Throws `.notLoggedIn` if no stored token.
    public func restore() async throws -> TokenSet {
        guard let rt = Keychain.loadRefreshToken(backendID: backend.id) else {
            throw HermesAuthError.notLoggedIn
        }
        let tok = try await Self.refresh(baseURL: backend.baseURL, refreshToken: rt,
                                         provider: "", session: session)
        adopt(tok)
        return tok
    }

    /// `POST /auth/native/refresh` — 401 `session_expired` means re-login,
    /// 503 means provider unreachable (retry later). Spec §2.1.
    public static func refresh(baseURL: URL, refreshToken: String, provider: String,
                               session: URLSession = .shared) async throws -> TokenSet {
        try await postJSON(baseURL.appending(path: "auth/native/refresh"),
                           body: ["refresh_token": refreshToken, "provider": provider],
                           session: session)
    }

    // MARK: Authorized calls

    /// Valid access token, refreshing with 60s skew (spec §4).
    public func validAccessToken() async throws -> String {
        guard let tok = tokens else { throw HermesAuthError.notLoggedIn }
        if Date(timeIntervalSince1970: TimeInterval(tok.expiresAt)) > Date().addingTimeInterval(60) {
            return tok.accessToken
        }
        let fresh = try await Self.refresh(baseURL: backend.baseURL,
                                           refreshToken: tok.refreshToken,
                                           provider: tok.provider, session: session)
        adopt(fresh)
        return fresh.accessToken
    }

    /// Mint a fresh single-use WS ticket (spec §2.7: immediately before each
    /// connect, never cached, interchangeable across endpoints).
    public func mintTicket() async throws -> String {
        struct Ticket: Codable { let ticket: String }
        let token = try await validAccessToken()
        var req = URLRequest(url: backend.baseURL.appending(path: "api/auth/ws-ticket"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        try Self.checkOK(resp, data)
        return try JSONDecoder().decode(Ticket.self, from: data).ticket
    }

    public var isLoggedIn: Bool { tokens != nil }

    public func logout() {
        tokens = nil
        Keychain.deleteRefreshToken(backendID: backend.id)
    }

    /// Adopt an externally-obtained token set (also used by integration tests).
    public func adopt(_ tok: TokenSet) {
        tokens = tok
        Keychain.saveRefreshToken(tok.refreshToken, backendID: backend.id)
    }

    // MARK: Plumbing

    private static func postJSON<T: Decodable>(_ url: URL, body: [String: String],
                                               session: URLSession) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        try checkOK(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func checkOK(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401: throw HermesAuthError.sessionExpired
        case 503: throw HermesAuthError.providerUnreachable
        default:
            throw HermesAuthError.httpError(http.statusCode,
                                            String(data: data, encoding: .utf8) ?? "")
        }
    }
}
