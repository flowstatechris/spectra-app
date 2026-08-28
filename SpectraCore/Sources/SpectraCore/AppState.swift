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
    public private(set) var chatScrollTargetID: String?

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
        Set(sessions.values.filter { $0.attention != nil }.map(\.profile.name))
    }

    public func openActivity(_ item: ActivityItem) {
        activeProfileName = item.profileName
        chatScrollTargetID = item.targetMessageID
    }

    /// A tapped notification (or any request to jump to a profile's chat) bumps
    /// this token; ContentView observes it to switch to the Chat tab. (§6/§11)
    public private(set) var chatRouteToken = 0
    public func routeToChat(profile: String?) {
        if let profile, sessions[profile] != nil { activeProfileName = profile }
        chatRouteToken &+= 1
    }

    public func clearChatScrollTarget() { chatScrollTargetID = nil }

    // MARK: Backend + auth

    public func setBackend(_ url: URL) {
        let config = BackendConfig(baseURL: url)
        // A new backend means a new auth client. Any hydrated/previous `rpc` is
        // bound to the OLD auth client (stale/nil tokens), so connectRPC must
        // NOT reuse it — else mintTicket runs on the old client → notLoggedIn.
        if let old = rpc { Task { await old.disconnect() } }
        rpc = nil
        eventRouter?.cancel(); eventRouter = nil
        stateWatcher?.cancel(); stateWatcher = nil
        backend = config
        auth = HermesAuthClient(backend: config)
        phase = .needsLogin
    }

    /// Re-open the backend URL box (e.g. moved networks → new LAN IP). Pointing
    /// at a new address drops the auth client, so `setBackend` forces re-login.
    /// ponytail: re-auth on server change; token migration across baseURLs isn't
    /// worth the complexity for a LAN move.
    public func editBackend() { phase = .needsBackend }

    /// Instant cold-launch (spec §10): paint cached backend + profiles +
    /// message history synchronously, then reconnect in the background. If the
    /// keychain restore fails (tokens revoked), fall back to re-login.
    public func restoreOnLaunch() async {
        hydrateFromCache()                  // synchronous: may set phase=.ready
        guard let auth else { phase = .needsBackend; return }
        do {
            _ = try await auth.restore()
            await postAPNsToken()           // flush any token that raced ahead of auth (§11)
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
                                            restoring: cached.messages,
                                            storedSessionID: cached.storedSessionID)
        }
        activeProfileName = snap.activeProfileName ?? sessions.keys.sorted().first
        // Restore the Activity feed. Any row still non-terminal belongs to a
        // session that died with the last launch — resolve it to interrupted so
        // we never show a stale "Working"/"Waiting" (handoff §5).
        activityFeed = (snap.activity ?? []).map {
            var item = $0
            if item.status == .inProgress || item.status == .inReview {
                item.status = .interrupted
            }
            return item
        }
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
            Cuelume.shared.play(.success)   // interactive login only — not silent restore
        } catch {
            phase = .error("Login failed: \(error)")
            Cuelume.shared.play(.error)
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
                // Server reaped the runtime sessions on the drop. Clear the dead
                // runtime ids (cached messages + durable ids stay); the next send
                // resumes each durable conversation rather than forking a new one.
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
        Cuelume.shared.play(.error)   // reconnect backoff exhausted (§12)
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

    /// Refresh the full profile list from the backend so the Profiles tab can
    /// offer profiles not yet added (after relaunch, availableProfiles holds
    /// only the added ones). Best-effort; keeps the current list on error.
    public func refreshAvailableProfiles() async {
        try? await loadProfiles()
    }

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
                sessions[name].map { PersistedState.Session(profile: $0.profile, messages: $0.messages,
                                                             storedSessionID: $0.storedSessionID) }
            },
            activity: activityFeed)   // already bounded to feedCap
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
            session.addPendingAttachment(.init(name: (path as NSString).lastPathComponent,
                                               thumbnailJPEG: thumbnail))
        } catch {
            session.noteError("Couldn't attach image")
        }
    }

    /// Stage a non-image file with Hermes and retain its rewritten `@file:`
    /// reference for the next prompt. One pending attachment matches the
    /// existing image composer model; multiple may be staged and ride together.
    public func attachFile(profileName: String, data: Data, filename: String,
                           mime: String) async {
        guard let session = sessions[profileName], let rpc else { return }
        do {
            try await session.ensureSession()
            guard let sid = session.serverSessionID else { return }
            let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
            let result = try await rpc.call("file.attach", params: [
                "session_id": sid,
                "name": filename,
                "data_url": dataURL,
            ])
            guard result["attached"] as? Bool == true,
                  let reference = result["ref_text"] as? String else {
                session.noteError("Couldn't attach \(filename)")
                return
            }
            session.addPendingAttachment(.init(name: filename, kind: .file,
                                                byteCount: data.count, contentType: mime,
                                                reference: reference))
        } catch {
            session.noteError("Couldn't attach \(filename): \(error)")
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

    /// Register this device's APNs token with Hermes (§11). Best-effort — the
    /// token is cached so we can re-post after login or on refresh. Server keys
    /// pushes to the authed user, so only the token + environment are needed.
    private var apnsToken: (hex: String, environment: String)?
    public func registerAPNsToken(hex: String, environment: String) async {
        apnsToken = (hex, environment)
        await postAPNsToken()
    }
    func postAPNsToken() async {
        guard let (hex, env) = apnsToken, let auth, let backend else { return }
        do {
            let token = try await auth.validAccessToken()
            var req = URLRequest(url: backend.baseURL.appending(path: "api/apns/register"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(
                withJSONObject: ["device_token": hex, "environment": env])
            _ = try await URLSession.shared.data(for: req)
        } catch { /* best-effort; retried on next launch/foreground */ }
    }

    // MARK: Refresh (spec §6: one shared refresh path)

    public func refreshAll() async {
        guard let rpc else { return }
        if await rpc.state == .disconnected {
            try? await rpc.connect()
        }
        try? await loadProfiles()   // additive re-sync; never removes added profiles
        await postAPNsToken()       // re-register device token on foreground (§11)
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

    // MARK: Activity feed

    private static let feedCap = 200
    private static let persistTriggers: Set<String> =
        ["message.complete", "approval.request", "clarify.request", "turn.error", "turn.end"]

    /// Fold tool/turn events into the cross-profile feed. Linear scan on
    /// completion (feed is capped at 200 — swap for a tool_id index only if
    /// that ever shows up in a profile). ponytail: O(n) flip, n<=200.
    private func recordActivity(profileName: String, event: HermesRPCConnection.Event) {
        switch event.type {
        case "tool.start":
            guard let toolID = event.payload?["tool_id"] as? String else { return }
            let name = event.payload?["name"] as? String ?? "tool"
            let context = event.payload?["context"] as? String ?? name
            insertActivity(ActivityItem(id: toolID, profileName: profileName,
                                        toolName: name, context: context,
                                        status: .inProgress))

        case "tool.complete":
            guard let toolID = event.payload?["tool_id"] as? String,
                  let idx = activityFeed.firstIndex(where: { $0.id == toolID }) else { return }
            activityFeed[idx].status = .success
            activityFeed[idx].duration = event.payload?["duration_s"] as? Double
            if let summary = event.payload?["summary"] as? String, !summary.isEmpty {
                activityFeed[idx].context = summary
            }

        case "approval.request", "clarify.request":
            let isApproval = event.type == "approval.request"
            let prefix = isApproval ? "approval" : "clarify"
            let requestID = event.payload?["request_id"] as? String
            let target = requestID.map { "\(prefix):\($0)" }
            if let idx = activityFeed.firstIndex(where: {
                $0.profileName == profileName && $0.status == .inProgress }) {
                activityFeed[idx].status = .inReview
                if let target { activityFeed[idx].targetMessageID = target }
            } else {
                // No tool row to attach to — surface the attention item on its
                // own so approvals/clarifies with no preceding tool still show.
                let context = isApproval
                    ? (event.payload?["command"] as? String ?? "Needs permission")
                    : (event.payload?["question"] as? String ?? "Needs clarification")
                insertActivity(ActivityItem(
                    id: target ?? "\(prefix):\(UUID().uuidString)",
                    profileName: profileName, toolName: prefix,
                    context: context, status: .inReview, targetMessageID: target))
            }

        case "turn.error":
            let text = event.payload?["text"] as? String ?? "Turn error"
            if let idx = activityFeed.firstIndex(where: {
                $0.profileName == profileName &&
                ($0.status == .inProgress || $0.status == .inReview) }) {
                activityFeed[idx].status = .failed
                if let messageID = sessions[profileName]?.messages.last?.id {
                    activityFeed[idx].targetMessageID = messageID
                }
            } else {
                insertActivity(turnActivity(profileName, context: text, status: .failed))
            }

        case "turn.end":
            guard event.payload?["interrupted"] as? Bool == true else { return }
            if let idx = activityFeed.firstIndex(where: {
                $0.profileName == profileName &&
                ($0.status == .inProgress || $0.status == .inReview) }) {
                activityFeed[idx].status = .interrupted
            } else {
                // Interruption with no running tool (e.g. a stopped text turn)
                // still deserves a feed row (handoff §5).
                insertActivity(turnActivity(profileName, context: "Turn interrupted",
                                            status: .interrupted))
            }

        default:
            break
        }
    }

    #if DEBUG
    /// Test-only entry point; recordActivity itself stays private.
    func recordActivityForTest(profileName: String, event: HermesRPCConnection.Event) {
        recordActivity(profileName: profileName, event: event)
    }
    #endif

    private func insertActivity(_ item: ActivityItem) {
        activityFeed.insert(item, at: 0)
        if activityFeed.count > Self.feedCap { activityFeed.removeLast() }
    }

    /// Standalone (non-tool) feed row for a turn-level event, deep-linked to the
    /// profile's latest message.
    private func turnActivity(_ profileName: String, context: String,
                              status: ActivityItem.Status) -> ActivityItem {
        ActivityItem(id: "turn:\(profileName):\(Date().timeIntervalSince1970)",
                     profileName: profileName, toolName: "turn", context: context,
                     status: status,
                     targetMessageID: sessions[profileName]?.messages.last?.id)
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
