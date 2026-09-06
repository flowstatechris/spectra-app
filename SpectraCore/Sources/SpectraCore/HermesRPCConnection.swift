import Foundation

/// One JSON-RPC 2.0 connection to a Backend's `/api/ws` (see ADR-0002).
///
/// Wire format: line-delimited JSON-RPC over WebSocket text frames — a single
/// frame may carry several newline-joined messages (the server coalesces
/// streaming deltas). Events arrive as `method: "event"` notifications with
/// `params.type` / `params.session_id` / `params.payload`.
///
/// Payloads are dynamic per-method, so requests/responses use plain
/// JSONSerialization dictionaries; typed models live at the call sites that
/// act on them (ProfileSession).
public actor HermesRPCConnection {
    public struct Event: Sendable {
        public let type: String
        public let sessionID: String
        public let payload: [String: Any]?
    }

    public enum State: Equatable, Sendable {
        case disconnected, connecting, connected
    }

    public enum RPCError: Error {
        case notConnected
        /// `reason` is the server's machine-readable `error.data.reason` (e.g.
        /// `SESSION_NOT_OWNED`), when it sent one — the message text alone
        /// isn't safe to branch on since wording can change (see #1).
        case serverError(code: Int, message: String, reason: String? = nil)
        case malformedResponse
        case timeout
    }

    private let auth: HermesAuthClient
    private var task: URLSessionWebSocketTask?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var receiveLoop: Task<Void, Never>?

    public private(set) var state: State = .disconnected
    private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]

    public init(auth: HermesAuthClient) {
        self.auth = auth
    }

    // MARK: Streams

    public func events() -> AsyncStream<Event> {
        let id = UUID()
        return AsyncStream { cont in
            eventContinuations[id] = cont
            cont.onTermination = { _ in
                Task { await self.removeEventContinuation(id) }
            }
        }
    }

    public func stateChanges() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream { cont in
            stateContinuations[id] = cont
            cont.yield(state)
            cont.onTermination = { _ in
                Task { await self.removeStateContinuation(id) }
            }
        }
    }

    private func removeEventContinuation(_ id: UUID) { eventContinuations[id] = nil }
    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }

    private func setState(_ s: State) {
        state = s
        for cont in stateContinuations.values { cont.yield(s) }
    }

    // MARK: Connect / disconnect

    /// Connect with a freshly-minted single-use ticket (spec §2.7 discipline:
    /// mint immediately before dialing, never reuse).
    public func connect() async throws {
        guard state == .disconnected else { return }
        setState(.connecting)
        do {
            let ticket = try await auth.mintTicket()
            var comps = URLComponents(url: auth.backend.baseURL.appending(path: "api/ws"),
                                      resolvingAgainstBaseURL: false)!
            comps.scheme = comps.scheme == "https" ? "wss" : "ws"
            comps.queryItems = [.init(name: "ticket", value: ticket)]
            let t = URLSession.shared.webSocketTask(with: comps.url!)
            t.resume()
            task = t
            receiveLoop = Task { await self.runReceiveLoop(t) }
            setState(.connected)
        } catch {
            setState(.disconnected)
            throw error
        }
    }

    public func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        failAllPending(RPCError.notConnected)
        setState(.disconnected)
    }

    // MARK: Calls

    /// Send a JSON-RPC request and await its response's `result` dict.
    public func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard let task, state == .connected else { throw RPCError.notConnected }
        nextID += 1
        let id = nextID
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: frame)
        try await task.send(.string(String(data: data, encoding: .utf8)!))
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
        }
    }

    // MARK: Receive loop

    private func runReceiveLoop(_ t: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await t.receive()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: text = ""
                }
                for line in text.split(separator: "\n") {
                    handleLine(String(line))
                }
            } catch {
                if !Task.isCancelled { handleDrop() }
                return
            }
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let err = obj["error"] as? [String: Any] {
                let data = err["data"] as? [String: Any]
                cont.resume(throwing: RPCError.serverError(
                    code: err["code"] as? Int ?? -1,
                    message: err["message"] as? String ?? "unknown",
                    reason: data?["reason"] as? String))
            } else if let result = obj["result"] as? [String: Any] {
                cont.resume(returning: result)
            } else {
                // result may legitimately be non-dict (null); normalize to empty
                cont.resume(returning: [:])
            }
            return
        }

        if obj["method"] as? String == "event",
           let params = obj["params"] as? [String: Any],
           let type = params["type"] as? String {
            let event = Event(type: type,
                              sessionID: params["session_id"] as? String ?? "",
                              payload: params["payload"] as? [String: Any])
            for cont in eventContinuations.values { cont.yield(event) }
        }
    }

    private func handleDrop() {
        task = nil
        failAllPending(RPCError.notConnected)
        setState(.disconnected)
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
    }
}
