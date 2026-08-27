import Foundation
import Observation

/// Root app state: one Backend, its shared RPC connection, and the
/// ProfileSessions the user has added. (Multi-backend deferred — spec §15.)
@Observable
@MainActor
public final class AppState {
    public enum Phase: Equatable {
        case needsBackend          // no backend configured
        case needsLogin            // backend set, not authenticated
        case loggingIn
        case pickingProfiles       // authenticated, choosing which profiles to add
        case ready                 // sessions live
        case error(String)
    }

    public private(set) var phase: Phase = .needsBackend
    public private(set) var backend: BackendConfig?
    public private(set) var availableProfiles: [ProfileInfo] = []
    public private(set) var sessions: [String: ProfileSession] = [:]  // key = profile name
    public var activeProfileName: String?
    public private(set) var connectionState: HermesRPCConnection.State = .disconnected
    public private(set) var activityFeed: [ActivityItem] = []   // cross-profile, newest first

    public private(set) var auth: HermesAuthClient?
    private var rpc: HermesRPCConnection?
    private var eventRouter: Task<Void, Never>?
    private var stateWatcher: Task<Void, Never>?

    public init() {}

    public var activeSession: ProfileSession? {
        activeProfileName.flatMap { sessions[$0] }
    }

    public var profilesNeedingAttention: Set<String> {
        Set(sessions.values.filter { $0.pendingApproval != nil || $0.pendingClarify != nil }
            .map(\.profile.name))
    }

    // MARK: Backend + auth

    public func setBackend(_ url: URL) {
        let config = BackendConfig(baseURL: url)
        backend = config
        auth = HermesAuthClient(backend: config)
        phase = .needsLogin
    }

    /// Try silent restore from Keychain; falls back to `.needsLogin`.
    public func restoreOnLaunch() async {
        guard let auth else { return }
        phase = .loggingIn
        do {
            _ = try await auth.restore()
            try await connectRPC()
            try await loadProfiles()
            phase = sessions.isEmpty ? .pickingProfiles : .ready
        } catch {
            phase = .needsLogin
        }
    }

    /// Begin interactive login. Returns the URL to open in the system browser;
    /// completes when the loopback callback lands.
    public func login(present: (URL) -> Void) async {
        guard let auth else { return }
        phase = .loggingIn
        do {
            let pending = try await auth.beginLogin()
            present(pending.authorizeURL)
            _ = try await auth.finishLogin(pending)
            try await connectRPC()
            try await loadProfiles()
            phase = .pickingProfiles
        } catch {
            phase = .error("Login failed: \(error)")
        }
    }

    private func connectRPC() async throws {
        guard let auth else { return }
        let connection = HermesRPCConnection(auth: auth)
        rpc = connection
        try await connection.connect()
        startEventRouter(connection)
        startStateWatcher(connection)
    }

    private func loadProfiles() async throws {
        guard let rpc else { return }
        let result = try await rpc.call("profiles.list")
        let raw = result["profiles"] as? [[String: Any]] ?? []
        availableProfiles = raw.compactMap(ProfileInfo.init(dict:))
    }

    // MARK: Profiles

    public func addProfiles(_ names: [String]) {
        guard let rpc else { return }
        for name in names {
            guard sessions[name] == nil,
                  let info = availableProfiles.first(where: { $0.name == name }) else { continue }
            sessions[name] = ProfileSession(profile: info, rpc: rpc)
        }
        if activeProfileName == nil { activeProfileName = names.first }
        if !sessions.isEmpty { phase = .ready }
    }

    public func removeProfile(_ name: String) {
        sessions.removeValue(forKey: name)
        if activeProfileName == name { activeProfileName = sessions.keys.sorted().first }
    }

    // MARK: Refresh (spec §6: one shared refresh path)

    public func refreshAll() async {
        guard let rpc else { return }
        if await rpc.state == .disconnected {
            try? await rpc.connect()
        }
        try? await loadProfiles()   // additive re-sync; never removes added profiles
    }

    // MARK: Event routing

    private func startEventRouter(_ connection: HermesRPCConnection) {
        eventRouter?.cancel()
        eventRouter = Task {
            for await event in await connection.events() {
                guard !event.sessionID.isEmpty else { continue }
                // Route by server session id → owning ProfileSession.
                if let session = sessions.values.first(where: { $0.serverSessionID == event.sessionID }) {
                    session.handle(event)
                    recordActivity(profileName: session.profile.name, event: event)
                }
            }
        }
    }

    private func startStateWatcher(_ connection: HermesRPCConnection) {
        stateWatcher?.cancel()
        stateWatcher = Task {
            for await s in await connection.stateChanges() {
                connectionState = s
            }
        }
    }

    // MARK: Activity feed (Tasks tab)

    private static let feedCap = 200

    /// Fold tool/turn events into the cross-profile feed. Linear scan on
    /// completion (feed is capped at 200 — swap for a tool_id index only if
    /// that ever shows up in a profile). ponytail: O(n) flip, n<=200.
    private func recordActivity(profileName: String, event: HermesRPCConnection.Event) {
        switch event.type {
        case "tool.start":
            guard let toolID = event.payload?["tool_id"] as? String else { return }
            let name = event.payload?["name"] as? String ?? "tool"
            let context = event.payload?["context"] as? String ?? name
            activityFeed.insert(ActivityItem(id: toolID, profileName: profileName,
                                             toolName: name, context: context,
                                             status: .inProgress), at: 0)
            if activityFeed.count > Self.feedCap { activityFeed.removeLast() }

        case "tool.complete":
            guard let toolID = event.payload?["tool_id"] as? String,
                  let idx = activityFeed.firstIndex(where: { $0.id == toolID }) else { return }
            activityFeed[idx].status = .success
            activityFeed[idx].duration = event.payload?["duration_s"] as? Double
            if let summary = event.payload?["summary"] as? String, !summary.isEmpty {
                activityFeed[idx].context = summary
            }

        case "approval.request", "clarify.request":
            if let idx = activityFeed.firstIndex(where: {
                $0.profileName == profileName && $0.status == .inProgress }) {
                activityFeed[idx].status = .inReview
            }

        case "turn.error":
            if let idx = activityFeed.firstIndex(where: {
                $0.profileName == profileName &&
                ($0.status == .inProgress || $0.status == .inReview) }) {
                activityFeed[idx].status = .failed
            }

        default:
            break
        }
    }

    public func logout() async {
        await rpc?.disconnect()
        await auth?.logout()
        eventRouter?.cancel()
        stateWatcher?.cancel()
        sessions = [:]
        availableProfiles = []
        activityFeed = []
        activeProfileName = nil
        phase = .needsLogin
    }
}
