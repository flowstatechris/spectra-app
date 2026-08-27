import Foundation

/// On-disk snapshot for instant cold-launch (spec §10): backend URL, added
/// profiles, and per-profile message history. NOT the server session id — the
/// gateway reaps orphaned sessions on ws disconnect (`ws_orphan_reap`), so a
/// persisted session id is guaranteed dead by next launch. Cached messages give
/// view continuity only; the first send after relaunch opens a fresh session.
public struct PersistedState: Codable, Sendable {
    public struct Session: Codable, Sendable {
        public var profile: ProfileInfo
        public var messages: [Message]
    }
    public var backendURL: URL
    public var activeProfileName: String?
    public var order: [String]          // profile add order
    public var sessions: [Session]
}

public enum Persistence {
    // Application Support/spectra-state.json — not Documents (not user-facing).
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spectra-state.json")
    }

    public static func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    public static func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
