import Foundation

public struct BackendConfig: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let baseURL: URL
    public var displayName: String

    public init(baseURL: URL, displayName: String? = nil) {
        self.id = baseURL.absoluteString
        self.baseURL = baseURL
        self.displayName = displayName ?? baseURL.host() ?? baseURL.absoluteString
    }
}

/// Rich per-profile metadata from `profiles.list` over RPC (reachable over
/// /api/ws even though the REST surface only exposes names — ADR-0002).
public struct ProfileInfo: Identifiable, Sendable, Hashable {
    public let name: String
    public let isDefault: Bool
    public let model: String
    public let provider: String
    public let profileDescription: String
    public let skillCount: Int

    public var id: String { name }

    public init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String else { return nil }
        self.name = name
        isDefault = dict["is_default"] as? Bool ?? false
        model = dict["model"] as? String ?? ""
        provider = dict["provider"] as? String ?? ""
        profileDescription = dict["description"] as? String ?? ""
        skillCount = dict["skill_count"] as? Int ?? 0
    }
}

public enum SessionStatus: Equatable, Sendable {
    case idle
    case connecting
    case thinking(search: Bool)   // tool running (search-type vs general)
    case speaking                 // deltas streaming
    case alert                    // error state
}

public struct Message: Identifiable, Sendable, Equatable {
    public enum Role: String, Sendable { case user, agent }
    public enum Kind: Equatable, Sendable {
        case plain
        case status                 // lifecycle/status lines, quieter render
        case approvalResolved(choice: String)  // green receipt (spec §8)
    }

    public let id: String
    public let role: Role
    public var text: String
    public var kind: Kind

    public init(id: String = UUID().uuidString, role: Role, text: String, kind: Kind = .plain) {
        self.id = id
        self.role = role
        self.text = text
        self.kind = kind
    }
}

/// `approval.request` payload (verified: tui_gateway/server.py
/// _approval_request_payload). `choices` is dynamic 2–4 options — render
/// exactly what the server sent.
public struct ApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: String          // request_id
    public let sessionID: String
    public let command: String     // server-redacted
    public let choices: [String]   // "once"/"session"/"always"/"deny"
    public let smartDenied: Bool

    public init?(sessionID: String, payload: [String: Any]) {
        guard let rid = payload["request_id"] as? String else { return nil }
        self.id = rid
        self.sessionID = sessionID
        self.command = payload["command"] as? String ?? ""
        self.choices = payload["choices"] as? [String] ?? ["once", "deny"]
        self.smartDenied = payload["smart_denied"] as? Bool ?? false
    }
}

/// `clarify.request` payload (verified: _clarify_block). Single-question
/// form: {question, choices, multi_select?}. Batch form: {questions: [...]}.
public struct ClarifyRequest: Identifiable, Sendable, Equatable {
    public struct Question: Identifiable, Sendable, Equatable {
        public let id: String       // qid ("" for single-question form)
        public let question: String
        public let choices: [String]
        public let multiSelect: Bool
    }

    public let id: String           // request_id
    public let sessionID: String
    public let questions: [Question]
    public var isBatch: Bool { questions.first?.id.isEmpty == false }

    public init?(sessionID: String, payload: [String: Any]) {
        guard let rid = payload["request_id"] as? String else { return nil }
        self.id = rid
        self.sessionID = sessionID
        if let batch = payload["questions"] as? [[String: Any]] {
            questions = batch.compactMap { q in
                guard let text = q["question"] as? String else { return nil }
                return Question(id: q["qid"] as? String ?? "",
                                question: text,
                                choices: q["choices"] as? [String] ?? [],
                                multiSelect: q["multi_select"] as? Bool ?? false)
            }
        } else if let text = payload["question"] as? String {
            questions = [Question(id: "",
                                  question: text,
                                  choices: payload["choices"] as? [String] ?? [],
                                  multiSelect: payload["multi_select"] as? Bool ?? false)]
        } else {
            return nil
        }
        if questions.isEmpty { return nil }
    }
}
