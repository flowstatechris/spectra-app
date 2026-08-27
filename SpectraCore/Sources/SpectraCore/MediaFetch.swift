import Foundation

/// Fetches agent-sent media bytes (§9). Verified endpoints:
///   - server image: GET /api/media?path=<p>  → { data_url: "data:<mime>;base64,…" }
///   - server file:  GET /api/files/download?path=<p> → raw bytes
///   - remote image: the markdown URL, fetched directly (no auth)
/// All /api routes are Bearer-auth-gated like the rest of the REST surface.
public enum MediaFetch {
    public static func data(for media: Message.ReceivedMedia,
                            baseURL: URL, token: String,
                            session: URLSession = .shared) async throws -> Data {
        switch media.slot {
        case .remoteURL(let url):
            let (d, resp) = try await session.data(from: url)
            try ok(resp)
            return d

        case .serverImage(let path):
            let req = authed(baseURL.appending(path: "api/media"),
                             query: path, token: token)
            let (d, resp) = try await session.data(for: req)
            try ok(resp)
            struct Wrapper: Decodable { let data_url: String }
            let w = try JSONDecoder().decode(Wrapper.self, from: d)
            guard let comma = w.data_url.firstIndex(of: ","),
                  let bytes = Data(base64Encoded: String(w.data_url[w.data_url.index(after: comma)...]))
            else { throw HermesAuthError.httpError(-1, "bad data_url") }
            return bytes

        case .serverFile(let path):
            let req = authed(baseURL.appending(path: "api/files/download"),
                             query: path, token: token)
            let (d, resp) = try await session.data(for: req)
            try ok(resp)
            return d
        }
    }

    private static func authed(_ url: URL, query path: String, token: String) -> URLRequest {
        let u = url.appending(queryItems: [.init(name: "path", value: path)])
        var req = URLRequest(url: u)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func ok(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401 { throw HermesAuthError.sessionExpired }
            throw HermesAuthError.httpError(http.statusCode, "media fetch failed")
        }
    }
}
