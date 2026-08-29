import Foundation

/// On-disk snapshot for instant cold-launch (spec §10): backend URL, added
/// profiles, per-profile message history, and the durable Hermes session key.
/// The *runtime* session id is never persisted — the gateway reaps orphaned
/// sessions on ws disconnect (`ws_orphan_reap`), so it's dead by next launch.
/// The durable `stored_session_id` survives, letting the first send after
/// relaunch resume the same conversation instead of forking a new one.
public struct PersistedState: Codable, Sendable {
    public struct Session: Codable, Sendable {
        public var profile: ProfileInfo
        public var messages: [Message]
        public var storedSessionID: String?   // optional: old snapshots decode fine
    }
    public var backendURL: URL
    public var activeProfileName: String?
    public var order: [String]          // profile add order
    public var sessions: [Session]
    public var activity: [ActivityItem]?   // optional: old snapshots decode fine
}

public enum Persistence {
    /// Newest messages kept per session in the snapshot. The file is fully
    /// decoded into memory on every cold launch and rewritten on every turn
    /// boundary, so an uncapped history meant both costs grew for the life of
    /// the install — with sent-image thumbnails riding along inside it. Older
    /// turns still live server-side and come back via session.resume.
    public static let historyLimit = 200

    // Application Support/spectra-state.json — not Documents (not user-facing).
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spectra-state.json")
    }

    public static func load() -> PersistedState? {
        // Mapped: the decoder reads through the file instead of us holding the
        // whole snapshot as bytes *and* as objects at the same time.
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
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
