import Foundation

/// RFC 8252 loopback redirect catcher: listens on 127.0.0.1:<ephemeral>,
/// waits for `GET /callback?code=...&state=...`, replies with a tiny HTML
/// page, and hands back the query parameters.
///
/// POSIX sockets, not Network.framework: NWListener fails with EINVAL for
/// unentitled listeners on current iOS runtimes (verified in-simulator on
/// iOS 26), while plain BSD listening sockets on loopback work everywhere.
public final class LoopbackCallbackServer: @unchecked Sendable {
    private let fd: Int32
    public let port: UInt16

    public init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HermesAuthError.loopbackListenFailed }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")      // loopback only
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw HermesAuthError.loopbackListenFailed
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        let port = UInt16(bigEndian: out.sin_port)
        guard port > 0 else {
            close(fd)
            throw HermesAuthError.loopbackListenFailed
        }
        self.fd = fd
        self.port = port
    }

    public var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    /// Block (off the cooperative pool) until the callback request arrives.
    /// Accepts and drains non-callback connections (browser preconnects).
    public func waitForCallback() async throws -> [String: String] {
        let fd = self.fd
        return try await withUnsafeThrowingContinuation { cont in
            Thread.detachNewThread {
                do {
                    cont.resume(returning: try Self.acceptLoop(listenFD: fd))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func cancel() { close(fd) }

    // MARK: - Blocking internals (dedicated thread)

    private static func acceptLoop(listenFD: Int32) throws -> [String: String] {
        while true {
            let conn = accept(listenFD, nil, nil)
            guard conn >= 0 else { throw HermesAuthError.loopbackListenFailed } // fd closed = cancelled
            defer { close(conn) }
            // Per-connection receive timeout: Safari opens speculative preconnect
            // sockets that send nothing. Without this the blocking read() below
            // wedges the single accept loop on a silent connection and the real
            // ?code= callback never gets accepted (login hangs forever).
            // ponytail: 5s head-of-line delay per silent preconnect; thread-per-
            // connection only if that ever bites.
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            guard let target = readRequestTarget(conn) else { continue }
            guard let components = URLComponents(string: target),
                  components.path == "/callback",
                  let items = components.queryItems, !items.isEmpty
            else {
                respond(conn, status: "404 Not Found", body: "")
                continue
            }
            // 200 + HTML with a JS bounce to the app's custom scheme. In an
            // ASWebAuthenticationSession the bounce is caught by callbackURLScheme
            // and the sheet auto-dismisses back to the app; in a plain browser it
            // just shows the message. (Plain 200 keeps the live auth test happy —
            // it reads this body over URLSession, which won't run the script.)
            respond(conn, status: "200 OK",
                    body: "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:48px;color:#111\">"
                        + "<p>Signed in — returning to Spectra…</p>"
                        + "<script>location.replace('spectra://auth-done')</script>"
                        + "</body></html>")
            var params: [String: String] = [:]
            for item in items { params[item.name] = item.value }
            return params
        }
    }

    private static func readRequestTarget(_ conn: Int32) -> String? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(Data("\r\n\r\n".utf8)) {
            let n = read(conn, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 65536 { return nil }
        }
        guard let requestLine = String(data: buffer, encoding: .utf8)?
                .components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private static func respond(_ conn: Int32, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = response.withCString { write(conn, $0, strlen($0)) }
    }
}
