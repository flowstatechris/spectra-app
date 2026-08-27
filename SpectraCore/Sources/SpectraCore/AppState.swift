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
    public private(set) var connectionError: String?            // set when reconnect retries exhaust (§12)
    public private(set) var activityFeed: [ActivityItem] = []   // cross-profile, newest first

    private var reconnecting = false
    private var intentionalDisconnect = false

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

    /// Instant cold-launch (spec §10): paint cached backend + profiles +
    /// message history synchronously, then reconnect in the background. If the
    /// keychain restore fails (tokens revoked), fall back to re-login.
    public func restoreOnLaunch() async {
        hydrateFromCache()                  // synchronous: may set phase=.ready
        guard let auth else { phase = .needsBackend; return }
        do {
            _ = try await auth.restore()
            try await connectRPC()          // connects the hydrated rpc (or a fresh one)
            try await loadProfiles()        // refresh live metadata
            if sessions.isEmpty { phase = .pickingProfiles }
            // else: keep the .ready we already painted from cache
        } catch {
            phase = .needsLogin             // can't reach backend; re-auth
        }
    }

    /// Rebuild backend, connection, and ProfileSessions from disk — no network.
    /// Runs before any await so the first frame shows the last session.
    private func hydrateFromCache() {
        guard let snap = Persistence.load() else { return }
        let config = BackendConfig(baseURL: snap.backendURL)
        backend = config
        let auth = HermesAuthClient(backend: config)
        self.auth = auth
        let connection = HermesRPCConnection(auth: auth)
        rpc = connection
        availableProfiles = snap.sessions.map(\.profile)
        for name in snap.order {
            guard let cached = snap.sessions.first(where: { $0.profile.name == name }) else { continue }
            sessions[name] = ProfileSession(profile: cached.profile, rpc: connection,
                                            restoring: cached.messages)
        }
        activeProfileName = snap.activeProfileName ?? sessions.keys.sorted().first
        if !sessions.isEmpty { phase = .ready }
    }

    /// Begin interactive login. Returns the URL to open in the system browser;
    /// completes when the loopback callback lands.
    /// `present` opens the auth URL; its second arg cancels the pending loopback
    /// (call it if the user dismisses the browser sheet, so finishLogin doesn't hang).
    public func login(present: (URL, @escaping () -> Void) -> Void) async {
        guard let auth else { return }
        phase = .loggingIn
        do {
            let pending = try await auth.beginLogin()
            present(pending.authorizeURL, { pending.cancel() })
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
        intentionalDisconnect = false
        let connection = rpc ?? HermesRPCConnection(auth: auth)  // reuse hydrated one
        rpc = connection
        try await connection.connect()
        connectionError = nil
        startEventRouter(connection)
        startStateWatcher(connection)
    }

    // MARK: Reconnect / offline (spec §12)

    /// Bounded backoff — the orb shows `.connecting` between attempts; on
    /// exhaustion we surface an explicit error (never an infinite spinner).
    private func reconnectWithBackoff() async {
        guard let rpc, !reconnecting else { return }
        reconnecting = true
        defer { reconnecting = false }
        for delaySec in [UInt64(1), 2, 4, 8, 15] {
            try? await Task.sleep(nanoseconds: delaySec * 1_000_000_000)
            if intentionalDisconnect { return }
            do {
                try await rpc.connect()
                // Server reaped our sessions on the drop — restart each fresh
                // (cached messages stay for continuity; next send re-creates).
                for s in sessions.values { s.resetForReconnect() }
                try? await loadProfiles()
                connectionError = nil
                return
            } catch let e as HermesAuthError where e == .sessionExpired {
                await forceRelogin()          // tokens gone — don't silently fail sends
                return
            } catch {
                continue                       // unreachable / ticket-mint failure: keep trying
            }
        }
        connectionError = "Can't reach \(backend?.displayName ?? "your backend")."
    }

    /// Manual retry from the offline banner.
    public func retryConnection() async {
        connectionError = nil
        await reconnectWithBackoff()
    }

    private func forceRelogin() async {
        await auth?.logout()
        sessions = [:]
        availableProfiles = []
        activeProfileName = nil
        connectionError = nil
        phase = .needsLogin
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
        persist()
    }

    public func removeProfile(_ name: String) {
        sessions.removeValue(forKey: name)
        if activeProfileName == name { activeProfileName = sessions.keys.sorted().first }
        persist()
    }

    // MARK: Persistence (spec §10)

    /// Snapshot backend + added profiles + message history to disk. Cheap
    /// enough to call on save-worthy events; NOT called per message.delta.
    public func persist() {
        guard let backend else { return }
        // Active profile first so it re-opens on top; rest alphabetical.
        // ponytail: no add-order tracking — dict loses it; deterministic is enough.
        var order = sessions.keys.sorted()
        if let active = activeProfileName, let i = order.firstIndex(of: active) {
            order.remove(at: i); order.insert(active, at: 0)
        }
        let snap = PersistedState(
            backendURL: backend.baseURL,
            activeProfileName: activeProfileName,
            order: order,
            sessions: order.compactMap { name in
                sessions[name].map { PersistedState.Session(profile: $0.profile, messages: $0.messages) }
            })
        Persistence.save(snap)
    }

    // MARK: Attachments (spec §9 / §2.6)

    /// Upload an image, stage it on the session via image.attach, and hold a
    /// thumbnail for the next send(). `imageData` is the full JPEG for upload;
    /// `thumbnail` is a small JPEG for inline display.
    public func attachImage(profileName: String, imageData: Data, thumbnail: Data,
                            mime: String = "image/jpeg", filename: String = "photo.jpg") async {
        guard let session = sessions[profileName], let auth, let rpc, let backend else { return }
        do {
            try await session.ensureSession()
            guard let sid = session.serverSessionID else { return }
            let token = try await auth.validAccessToken()
            let path = try await Attachments.upload(baseURL: backend.baseURL, token: token,
                        profile: profileName, data: imageData, filename: filename, mime: mime)
            _ = try await rpc.call("image.attach", params: ["session_id": sid, "path": path])
            session.setPendingAttachment(.init(name: (path as NSString).lastPathComponent,
                                               thumbnailJPEG: thumbnail))
        } catch {
            session.noteError("Couldn't attach image")
        }
    }

    /// Fetch agent-sent media bytes (§9 receive-side), cached so scrolling
    /// doesn't refetch. Returns nil if not logged in / fetch fails — the view
    /// falls back to a placeholder card.
    private var mediaCache: [String: Data] = [:]
    public func fetchAgentMedia(_ media: Message.ReceivedMedia) async -> Data? {
        if let hit = mediaCache[media.id] { return hit }
        guard let auth, let backend else { return nil }
        do {
            let token = try await auth.validAccessToken()
            let data = try await MediaFetch.data(for: media, baseURL: backend.baseURL, token: token)
            mediaCache[media.id] = data
            return data
        } catch { return nil }
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
                    // Persist on turn boundaries only — not per message.delta.
                    if Self.persistTriggers.contains(event.type) { persist() }
                }
            }
        }
    }

    private func startStateWatcher(_ connection: HermesRPCConnection) {
        stateWatcher?.cancel()
        stateWatcher = Task {
            for await s in await connection.stateChanges() {
                connectionState = s
                if s == .connected { connectionError = nil }
                // Unexpected drop while live → auto-reconnect (not on logout).
                if s == .disconnected, !intentionalDisconnect, !reconnecting, phase == .ready {
                    await reconnectWithBackoff()
                }
            }
        }
    }

    // MARK: Activity feed (Tasks tab)

    private static let feedCap = 200
    private static let persistTriggers: Set<String> =
        ["message.complete", "approval.request", "clarify.request", "turn.error"]

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
        intentionalDisconnect = true    // suppress auto-reconnect on this drop
        await rpc?.disconnect()
        await auth?.logout()
        Persistence.clear()
        eventRouter?.cancel()
        stateWatcher?.cancel()
        sessions = [:]
        availableProfiles = []
        activityFeed = []
        activeProfileName = nil
        phase = .needsLogin
    }
}
