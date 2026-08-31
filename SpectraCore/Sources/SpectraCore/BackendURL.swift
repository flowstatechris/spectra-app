import Foundation

/// Turns whatever someone types in the backend box into a URL.
///
/// The scheme is the whole problem here. Typing a bare host used to get
/// `http://` unconditionally, which meant a real hostname was silently
/// downgraded to plaintext and then refused by App Transport Security — and
/// switching the server to HTTPS didn't help, because the app never asked for
/// HTTPS. So: an explicit scheme is always honoured, and a bare host defaults
/// to `https` unless it looks like something on the local network, where
/// plaintext is the norm and ATS permits it.
public enum BackendURL {

    public static func normalize(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            s = (isLocal(host(of: s)) ? "http://" : "https://") + s
        }
        // Force a scheme BEFORE parsing: URLComponents reads a bare
        // "10.0.0.182:9119" with the host as the scheme, so a scheme==nil
        // check never fires and the URL comes out malformed.
        guard let url = URLComponents(string: s)?.url, url.host != nil else { return nil }
        return url
    }

    /// Host portion of a scheme-less string: strip any path, then any port.
    private static func host(of s: String) -> String {
        let noPath = s.split(separator: "/", maxSplits: 1).first.map(String.init) ?? s
        // rsplit on ":" so an IPv6 literal isn't cut at its first colon.
        guard let colon = noPath.lastIndex(of: ":"),
              noPath[noPath.index(after: colon)...].allSatisfy(\.isNumber)
        else { return noPath }
        return String(noPath[..<colon])
    }

    /// Hosts where plaintext is normal: loopback, Bonjour, a bare name with no
    /// dots, and the private IPv4 ranges a home LAN uses.
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") { return true }
        if !h.contains(".") { return true }                  // bare hostname
        let parts = h.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let a = Int(parts[0]), let b = Int(parts[1])
        else { return false }                                // a real domain
        switch a {
        case 10, 127: return true
        case 192: return b == 168
        case 172: return (16...31).contains(b)
        case 169: return b == 254                            // link-local
        default: return false                                // public IP → https
        }
    }
}
