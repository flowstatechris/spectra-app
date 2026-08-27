import Foundation
import Observation

/// One Profile's live chat state (see CONTEXT.md). Wire traffic flows through
/// the Backend's shared HermesRPCConnection; this object owns the server
/// Session for its profile and folds that session's events into UI state.
@Observable
@MainActor
public final class ProfileSession: Identifiable {
    public let profile: ProfileInfo
    public nonisolated var id: String { profile.name }

    public private(set) var messages: [Message] = []
    public private(set) var status: SessionStatus = .idle
    public private(set) var pendingApproval: ApprovalRequest?   // hard block on send()
    public private(set) var pendingClarify: ClarifyRequest?     // soft — thread stays live
    public private(set) var serverSessionID: String?
    /// Durable Hermes session key (`stored_session_id`). Unlike the runtime
    /// `serverSessionID` (reaped on ws disconnect), this survives reconnects and
    /// relaunches, so ensureSession() resumes it instead of forking a new server
    /// conversation. See handoff §2.
    public private(set) var storedSessionID: String?
    public private(set) var lastError: String?
    /// Image staged on the server (via image.attach) waiting to ride the next
    /// send() as an inline thumbnail on the user's message (§9).
    public private(set) var pendingAttachment: Message.Attachment?

    private let rpc: HermesRPCConnection
    private var streamingMessageID: String?

    public init(profile: ProfileInfo, rpc: HermesRPCConnection,
                restoring messages: [Message] = [],
                storedSessionID: String? = nil) {
        self.profile = profile
        self.rpc = rpc
        self.messages = messages
        self.storedSessionID = storedSessionID
        // serverSessionID stays nil on restore: the runtime session is gone.
        // But a restored storedSessionID lets the first send() resume the same
        // durable Hermes conversation instead of forking. (see Persistence.swift)
    }

    // MARK: Session lifecycle

    /// Bind a live runtime session for this profile. Resumes the durable
    /// conversation when we have one (reconnect / relaunch continuity), else
    /// creates a fresh one. Any resume failure — reaped, too large, db error —
    /// falls back to create so a send is never stranded.
    public func ensureSession() async throws {
        guard serverSessionID == nil else { return }
        status = .connecting
        defer { status = .idle }
        if let stored = storedSessionID {
            // omit_messages: Spectra keeps its own richer local timeline (folded
            // ToolActivity/Approval/Clarify rows Hermes history doesn't carry);
            // we only need a runtime id rebound to the same server conversation.
            if let r = try? await rpc.call("session.resume",
                                           params: ["session_id": stored,
                                                    "profile": profile.name,
                                                    "omit_messages": true]),
               let sid = r["session_id"] as? String {
                serverSessionID = sid
                storedSessionID = (r["stored_session_id"] as? String) ?? stored
                return
            }
        }
        let result = try await rpc.call("session.create",
                                        params: ["profile": profile.name,
                                                 "title": "Spectra — \(profile.name)"])
        serverSessionID = result["session_id"] as? String
        storedSessionID = result["stored_session_id"] as? String
    }

    /// After a socket drop + reconnect: the server reaped the *runtime* session,
    /// so drop the dead runtime id and any in-flight prompts. Cached messages
    /// stay on screen. storedSessionID is deliberately kept so the next send()
    /// resumes the same durable conversation rather than forking a new one.
    public func resetForReconnect() {
        if let id = pendingApproval?.id { updateApproval(id: id, state: .expired) }
        if let id = pendingClarify?.id { updateClarification(id: id, state: .expired) }
        serverSessionID = nil
        streamingMessageID = nil
        pendingApproval = nil
        pendingClarify = nil
        pendingAttachment = nil     // staging died with the session
        status = .idle
    }

    // MARK: Session switching (handoff §2b)

    /// One row in the recent-sessions picker.
    public struct SessionSummary: Identifiable, Sendable, Equatable {
        public let id: String        // durable stored id — pass to switchTo()
        public let title: String
        public let preview: String
        public let startedAt: Double
        public let messageCount: Int
        public var isCurrent: Bool
    }

    /// Switching adopts a new runtime session; block it mid-turn / mid-approval
    /// so we never abandon a supervised runtime (handoff §2b).
    public var canSwitchSessions: Bool { !isRunning && pendingApproval == nil }

    /// Recent sessions for this profile, newest first (`session.list`).
    public func listSessions() async throws -> [SessionSummary] {
        let r = try await rpc.call("session.list", params: ["profile": profile.name])
        let rows = r["sessions"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return SessionSummary(
                id: id,
                title: (row["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled",
                preview: row["preview"] as? String ?? "",
                startedAt: Self.double(row["started_at"]) ?? 0,
                messageCount: (row["message_count"] as? NSNumber)?.intValue ?? 0,
                isCurrent: id == storedSessionID)
        }
    }

    /// Start a fresh server conversation, clearing the visible timeline.
    public func newSession() async {
        guard canSwitchSessions else { return }
        do {
            let r = try await rpc.call("session.create",
                                       params: ["profile": profile.name,
                                                "title": "Spectra — \(profile.name)"])
            adopt(runtimeID: r["session_id"] as? String,
                  storedID: r["stored_session_id"] as? String,
                  messages: [])
        } catch { recordError("Couldn't start a new chat.") }
    }

    /// Open an existing durable session: adopt its new runtime id and replace
    /// the visible timeline with Hermes history. Unlike a reconnect-resume this
    /// pulls messages, because the user is deliberately changing conversations.
    public func switchTo(_ storedID: String) async {
        guard canSwitchSessions, storedID != storedSessionID else { return }
        status = .connecting
        do {
            let r = try await rpc.call("session.resume",
                                       params: ["session_id": storedID,
                                                "profile": profile.name])
            adopt(runtimeID: r["session_id"] as? String,
                  storedID: (r["stored_session_id"] as? String) ?? storedID,
                  messages: Self.mapHistory(r["messages"]))
        } catch {
            status = .idle
            recordError("Couldn't open that chat.")
        }
    }

    private func adopt(runtimeID: String?, storedID: String?, messages: [Message]) {
        serverSessionID = runtimeID
        storedSessionID = storedID
        self.messages = messages
        pendingClarify = nil
        streamingMessageID = nil
        lastError = nil
        status = .idle
    }

    /// Hermes history → Spectra timeline. v1 keeps only user/assistant text
    /// rows; tool/system rows are skipped rather than reconstructed into
    /// ToolActivity/Approval objects (handoff: don't reproduce the whole
    /// surface — reconcile richer local state in a later slice).
    nonisolated static func mapHistory(_ raw: Any?) -> [Message] {
        guard let rows = raw as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let role = row["role"] as? String,
                  let text = row["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            switch role {
            case "user": return Message(role: .user, text: text)
            case "assistant": return Message(role: .agent, text: text)
            default: return nil
            }
        }
    }

    // MARK: Sending

    public var canSend: Bool { pendingApproval == nil }
    public var isRunning: Bool {
        switch status {
        case .thinking, .speaking: true
        default: false
        }
    }

    public func setPendingAttachment(_ a: Message.Attachment?) { pendingAttachment = a }
    public func noteError(_ text: String) { recordError(text) }

    public func send(_ text: String) async {
        guard pendingApproval == nil else { return }  // hard block at model layer
        // Image already staged server-side via image.attach; ride it on this message.
        let attach = pendingAttachment
        guard !text.isEmpty || attach != nil else { return }
        do {
            try await ensureSession()
            guard let sid = serverSessionID else { return }
            messages.append(Message(role: .user, text: text, attachment: attach))
            pendingAttachment = nil
            let submittedText = [attach?.reference, text.isEmpty ? nil : text]
                .compactMap { $0 }.joined(separator: "\n\n")
            _ = try await rpc.call("prompt.submit", params: ["session_id": sid,
                                                              "text": submittedText])
            status = .thinking(search: false)
        } catch {
            recordError("Couldn't send message: \(error)")
        }
    }

    @discardableResult
    public func interrupt() async -> Bool {
        guard let sid = serverSessionID else { return false }
        do {
            _ = try await rpc.call("session.interrupt", params: ["session_id": sid])
            return true
        } catch {
            recordError("Couldn't stop Hermes: \(error)")
            return false
        }
    }

    // MARK: Approval / clarify responses

    @discardableResult
    public func resolveApproval(choice: String) async -> Bool {
        guard let approval = pendingApproval, let sid = serverSessionID else { return false }
        do {
            let result = try await rpc.call("approval.respond", params: [
                "session_id": sid,
                "choice": choice,
                "all": false,
                "request_id": approval.id,
            ])
            guard (result["resolved"] as? NSNumber)?.intValue ?? 0 > 0 else {
                updateApproval(id: approval.id, state: .expired)
                pendingApproval = nil
                lastError = "That permission request is no longer active."
                status = .alert
                return false
            }
            updateApproval(id: approval.id,
                           state: .resolved(choice: choice, at: Date()))
            pendingApproval = nil
            status = .thinking(search: false)
            return true
        } catch {
            recordError("Couldn't answer permission request: \(error)")
            return false
        }
    }

    /// Single-question form: qid is "". Batch form: one call per locked answer.
    @discardableResult
    public func answerClarify(questionID: String, answer: String) async -> Bool {
        guard let clarify = pendingClarify else { return false }
        do {
            var params: [String: Any] = ["request_id": clarify.id, "answer": answer]
            if !questionID.isEmpty { params["question_id"] = questionID }
            let result = try await rpc.call("clarify.respond", params: params)
            if result["status"] as? String == "expired" {
                updateClarification(id: clarify.id, state: .expired)
                pendingClarify = nil
                lastError = "That clarification request expired before the answer arrived."
                status = .alert
                return false
            }
            updateClarificationAnswer(id: clarify.id, questionID: questionID, answer: answer)
            let remaining = result["remaining"] as? [String] ?? []
            if remaining.isEmpty {
                updateClarification(id: clarify.id, state: .answered(at: Date()))
                pendingClarify = nil
                status = .thinking(search: false)
            }
            return true
        } catch {
            recordError("Couldn't send clarification: \(error)")
            return false
        }
    }

    // MARK: Event folding

    /// Fold one event scoped to this session. Called by AppState's router.
    public func handle(_ event: HermesRPCConnection.Event) {
        switch event.type {
        case "message.start":
            // Wait for the first token before inserting the message. Tool rows
            // emitted between message.start and message.delta then stay in their
            // true chronological position.
            streamingMessageID = nil
            status = .speaking

        case "message.delta":
            guard let text = event.payload?["text"] as? String else { return }
            appendToStreamingMessage(text)
            status = .speaking

        case "message.complete":
            let finalText = event.payload?["text"] as? String
            if let id = streamingMessageID, let idx = messages.firstIndex(where: { $0.id == id }) {
                let (clean, media) = AgentMedia.parse(finalText ?? messages[idx].text)
                messages[idx].text = clean
                messages[idx].media = media
                if clean.isEmpty && media.isEmpty { messages.remove(at: idx) }
            } else if let finalText, !finalText.isEmpty {
                let (clean, media) = AgentMedia.parse(finalText)
                if !clean.isEmpty || !media.isEmpty {
                    messages.append(Message(role: .agent, text: clean, media: media))
                }
            }
            streamingMessageID = nil
            if pendingApproval == nil { status = .idle }

        case "tool.start", "tool.started":
            let name = (event.payload?["name"] as? String ?? "").lowercased()
            let isSearch = name.contains("search") || name.contains("web") || name.contains("browse")
            status = .thinking(search: isSearch)
            startTool(event)

        case "tool.generating":
            let name = (event.payload?["name"] as? String ?? "").lowercased()
            let isSearch = name.contains("search") || name.contains("web") || name.contains("browse")
            status = .thinking(search: isSearch)

        case "tool.complete":
            completeTool(event)
            if streamingMessageID == nil, pendingApproval == nil { status = .thinking(search: false) }

        case "tool.output_risk":
            updateToolRisk(event)

        case "approval.request":
            if let payload = event.payload,
               let approval = ApprovalRequest(sessionID: event.sessionID, payload: payload) {
                pendingApproval = approval
                upsertApproval(approval)
                status = .alert
            }

        case "approval.expire":
            if let id = event.payload?["request_id"] as? String,
               id == pendingApproval?.id {
                updateApproval(id: id, state: .expired)
                pendingApproval = nil
                if streamingMessageID == nil { status = .idle }
            }

        case "clarify.request":
            if let payload = event.payload,
               let clarify = ClarifyRequest(sessionID: event.sessionID, payload: payload) {
                pendingClarify = clarify
                upsertClarification(clarify)
            }

        case "clarify.expire":
            if let id = event.payload?["request_id"] as? String,
               id == pendingClarify?.id {
                updateClarification(id: id, state: .expired)
                pendingClarify = nil
            }

        case "status.update":
            guard let payload = event.payload,
                  let text = payload["text"] as? String else { return }
            let kind = payload["kind"] as? String ?? ""
            if kind == "lifecycle" || kind == "warn" {
                messages.append(Message(role: .agent, text: text, kind: .status))
            }

        case "turn.error":
            let error = event.payload?["text"] as? String ?? "turn error"
            failCurrentTool(error)
            recordError(error)

        case "turn.end":
            if streamingMessageID == nil, pendingApproval == nil { status = .idle }

        default:
            break
        }
    }

    private func appendToStreamingMessage(_ text: String) {
        if let id = streamingMessageID, let idx = messages.firstIndex(where: { $0.id == id }) {
            messages[idx].text += text
        } else {
            let msg = Message(role: .agent, text: text)
            streamingMessageID = msg.id
            messages.append(msg)
        }
    }

    private func upsertApproval(_ request: ApprovalRequest) {
        if let idx = messages.firstIndex(where: {
            if case .approval(let event) = $0.kind { return event.id == request.id }
            return false
        }) {
            messages[idx].kind = .approval(ApprovalEvent(request: request))
        } else {
            messages.append(Message(id: "approval:\(request.id)", role: .agent, text: "",
                                    kind: .approval(ApprovalEvent(request: request))))
        }
    }

    private func updateApproval(id: String, state: ApprovalEvent.State) {
        guard let idx = messages.firstIndex(where: {
            if case .approval(let event) = $0.kind { return event.id == id }
            return false
        }), case .approval(var event) = messages[idx].kind else { return }
        event.state = state
        messages[idx].kind = .approval(event)
    }

    private func upsertClarification(_ request: ClarifyRequest) {
        if let idx = messages.firstIndex(where: {
            if case .clarification(let event) = $0.kind { return event.id == request.id }
            return false
        }) {
            messages[idx].kind = .clarification(ClarificationEvent(request: request))
        } else {
            messages.append(Message(id: "clarify:\(request.id)", role: .agent, text: "",
                                    kind: .clarification(ClarificationEvent(request: request))))
        }
    }

    private func updateClarification(id: String, state: ClarificationEvent.State) {
        guard let idx = messages.firstIndex(where: {
            if case .clarification(let event) = $0.kind { return event.id == id }
            return false
        }), case .clarification(var event) = messages[idx].kind else { return }
        event.state = state
        messages[idx].kind = .clarification(event)
    }

    private func updateClarificationAnswer(id: String, questionID: String, answer: String) {
        guard let idx = messages.firstIndex(where: {
            if case .clarification(let event) = $0.kind { return event.id == id }
            return false
        }), case .clarification(var event) = messages[idx].kind else { return }
        event.answers[questionID] = answer
        messages[idx].kind = .clarification(event)
    }

    private func recordError(_ text: String) {
        lastError = text
        status = .alert
        let error = ErrorEvent(text: text)
        messages.append(Message(id: "error:\(error.id)", role: .agent, text: "",
                                kind: .error(error)))
    }

    private func startTool(_ event: HermesRPCConnection.Event) {
        guard let payload = event.payload,
              let id = payload["tool_id"] as? String, !id.isEmpty,
              !messages.contains(where: { message in
                  if case .toolActivity(let tool) = message.kind { return tool.id == id }
                  return false
              }) else { return }
        let name = payload["name"] as? String ?? "tool"
        let context = payload["context"] as? String ?? payload["preview"] as? String ?? ""
        let tool = ToolActivity(id: id, toolName: name, context: context,
                                input: Self.toolInput(payload))
        messages.append(Message(id: "tool:\(id)", role: .agent, text: "",
                                kind: .toolActivity(tool)))
    }

    private func completeTool(_ event: HermesRPCConnection.Event) {
        guard let payload = event.payload,
              let id = payload["tool_id"] as? String, !id.isEmpty else { return }

        let idx = messages.firstIndex(where: { message in
            if case .toolActivity(let tool) = message.kind { return tool.id == id }
            return false
        })
        var tool: ToolActivity
        if let idx, case .toolActivity(let existing) = messages[idx].kind {
            tool = existing
        } else {
            tool = ToolActivity(id: id, toolName: payload["name"] as? String ?? "tool")
        }

        tool.context = (payload["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? tool.context
        tool.input = Self.toolInput(payload) ?? tool.input
        tool.output = Self.toolOutput(payload)
        tool.duration = Self.double(payload["duration_s"])
        tool.exitCode = Self.exitCode(payload["result"])
        tool.status = Self.toolFailed(payload["result"], exitCode: tool.exitCode)
            ? .failed : .succeeded

        if let idx {
            messages[idx].kind = .toolActivity(tool)
        } else {
            messages.append(Message(id: "tool:\(id)", role: .agent, text: "",
                                    kind: .toolActivity(tool)))
        }
    }

    private func updateToolRisk(_ event: HermesRPCConnection.Event) {
        guard let payload = event.payload,
              let id = payload["tool_id"] as? String,
              let idx = messages.firstIndex(where: { message in
                  if case .toolActivity(let tool) = message.kind { return tool.id == id }
                  return false
              }), case .toolActivity(var tool) = messages[idx].kind else { return }
        tool.risk = payload["risk"] as? String
        tool.findings = payload["findings"] as? [String] ?? []
        messages[idx].kind = .toolActivity(tool)
    }

    private func failCurrentTool(_ error: String) {
        guard let idx = messages.lastIndex(where: { message in
            if case .toolActivity(let tool) = message.kind { return tool.status == .running }
            return false
        }), case .toolActivity(var tool) = messages[idx].kind else { return }
        tool.status = .failed
        tool.output = tool.output ?? error
        messages[idx].kind = .toolActivity(tool)
    }

    private static func toolInput(_ payload: [String: Any]) -> String? {
        if let args = payload["args"] as? [String: Any], !args.isEmpty {
            for key in ["command", "path", "file_path", "query", "url"] {
                if let value = args[key] as? String, !value.isEmpty { return value }
            }
            return jsonText(args)
        }
        if let text = payload["args_text"] as? String, !text.isEmpty { return text }
        return nil
    }

    private static func toolOutput(_ payload: [String: Any]) -> String? {
        if let text = payload["result_text"] as? String, !text.isEmpty { return text }
        guard let result = payload["result"] else { return nil }
        if let text = result as? String { return text.isEmpty ? nil : text }
        return jsonText(result)
    }

    private static func jsonText(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                      options: [.prettyPrinted, .sortedKeys])
        else { return String(describing: value) }
        return String(data: data, encoding: .utf8)
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func exitCode(_ result: Any?) -> Int? {
        guard let result = result as? [String: Any] else { return nil }
        return (result["exit_code"] as? NSNumber)?.intValue
            ?? (result["exitCode"] as? NSNumber)?.intValue
    }

    private static func toolFailed(_ result: Any?, exitCode: Int?) -> Bool {
        if let exitCode { return exitCode != 0 }
        guard let result = result as? [String: Any] else { return false }
        if result["is_error"] as? Bool == true || result["isError"] as? Bool == true { return true }
        if result["success"] as? Bool == false || result["ok"] as? Bool == false { return true }
        if let error = result["error"] as? String, !error.isEmpty { return true }
        return false
    }
}
