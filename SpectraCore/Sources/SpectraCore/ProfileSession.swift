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
    public private(set) var lastError: String?

    private let rpc: HermesRPCConnection
    private var streamingMessageID: String?

    public init(profile: ProfileInfo, rpc: HermesRPCConnection,
                restoring messages: [Message] = []) {
        self.profile = profile
        self.rpc = rpc
        self.messages = messages
        // serverSessionID stays nil on restore: the cached thread is display-
        // only; first send() opens a fresh server session. (see Persistence.swift)
    }

    // MARK: Session lifecycle

    /// Create (or reuse) this profile's server session.
    public func ensureSession() async throws {
        guard serverSessionID == nil else { return }
        status = .connecting
        let result = try await rpc.call("session.create",
                                        params: ["profile": profile.name,
                                                 "title": "Spectra — \(profile.name)"])
        serverSessionID = result["session_id"] as? String
        status = .idle
    }

    // MARK: Sending

    public var canSend: Bool { pendingApproval == nil }

    public func send(_ text: String) async {
        guard pendingApproval == nil else { return }  // hard block at model layer
        do {
            try await ensureSession()
            guard let sid = serverSessionID else { return }
            messages.append(Message(role: .user, text: text))
            _ = try await rpc.call("prompt.submit", params: ["session_id": sid, "text": text])
            status = .thinking(search: false)
        } catch {
            lastError = "\(error)"
            status = .alert
        }
    }

    public func interrupt() async {
        guard let sid = serverSessionID else { return }
        _ = try? await rpc.call("session.interrupt", params: ["session_id": sid])
    }

    // MARK: Approval / clarify responses

    public func resolveApproval(choice: String) async {
        guard let approval = pendingApproval, let sid = serverSessionID else { return }
        do {
            _ = try await rpc.call("approval.respond", params: [
                "session_id": sid,
                "choice": choice,
                "all": false,
                "request_id": approval.id,
            ])
            messages.append(Message(role: .agent,
                                    text: approval.command,
                                    kind: .approvalResolved(choice: choice)))
            pendingApproval = nil
        } catch {
            lastError = "\(error)"
        }
    }

    /// Single-question form: qid is "". Batch form: one call per locked answer.
    public func answerClarify(questionID: String, answer: String) async {
        guard let clarify = pendingClarify else { return }
        do {
            var params: [String: Any] = ["request_id": clarify.id, "answer": answer]
            if !questionID.isEmpty { params["question_id"] = questionID }
            let result = try await rpc.call("clarify.respond", params: params)
            let remaining = result["remaining"] as? [String] ?? []
            if remaining.isEmpty { pendingClarify = nil }
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: Event folding

    /// Fold one event scoped to this session. Called by AppState's router.
    public func handle(_ event: HermesRPCConnection.Event) {
        switch event.type {
        case "message.start":
            let msg = Message(role: .agent, text: "")
            streamingMessageID = msg.id
            messages.append(msg)
            status = .speaking

        case "message.delta":
            guard let text = event.payload?["text"] as? String else { return }
            appendToStreamingMessage(text)
            status = .speaking

        case "message.complete":
            let finalText = event.payload?["text"] as? String
            if let id = streamingMessageID, let idx = messages.firstIndex(where: { $0.id == id }) {
                if let finalText { messages[idx].text = finalText }
                if messages[idx].text.isEmpty { messages.remove(at: idx) }
            } else if let finalText, !finalText.isEmpty {
                messages.append(Message(role: .agent, text: finalText))
            }
            streamingMessageID = nil
            if pendingApproval == nil { status = .idle }

        case "tool.start", "tool.generating":
            let name = (event.payload?["name"] as? String ?? "").lowercased()
            let isSearch = name.contains("search") || name.contains("web") || name.contains("browse")
            status = .thinking(search: isSearch)

        case "tool.complete":
            if streamingMessageID == nil, pendingApproval == nil { status = .thinking(search: false) }

        case "approval.request":
            if let payload = event.payload,
               let approval = ApprovalRequest(sessionID: event.sessionID, payload: payload) {
                pendingApproval = approval
                status = .alert
            }

        case "approval.expire":
            if event.payload?["request_id"] as? String == pendingApproval?.id {
                pendingApproval = nil
                if streamingMessageID == nil { status = .idle }
            }

        case "clarify.request":
            if let payload = event.payload {
                pendingClarify = ClarifyRequest(sessionID: event.sessionID, payload: payload)
            }

        case "clarify.expire":
            if event.payload?["request_id"] as? String == pendingClarify?.id {
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
            lastError = event.payload?["text"] as? String ?? "turn error"
            status = .alert

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
}
