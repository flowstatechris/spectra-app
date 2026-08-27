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
public struct ProfileInfo: Identifiable, Sendable, Hashable, Codable {
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

public struct Message: Identifiable, Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case user, agent }
    public enum Kind: Equatable, Sendable, Codable {
        case plain
        case status                 // lifecycle/status lines, quieter render
        case toolActivity(ToolActivity)
        case approval(ApprovalEvent)
        case clarification(ClarificationEvent)
        case error(ErrorEvent)
        case approvalResolved(choice: String)  // green receipt (spec §8)
    }

    /// A sent image (§9). The uploaded file lives at a server-local path we
    /// can't fetch, so we keep a small downscaled JPEG to render inline. `name`
    /// is the server filename for reference.
    public struct Attachment: Sendable, Equatable, Codable {
        public enum Kind: String, Sendable, Equatable, Codable { case image, file }

        public let name: String
        public let thumbnailJPEG: Data
        public let kind: Kind
        public let byteCount: Int?
        public let contentType: String?
        /// Hermes workspace reference returned by `file.attach`. Hidden from
        /// the displayed user message, but prepended to the submitted prompt.
        public let reference: String?

        public init(name: String, thumbnailJPEG: Data = Data(), kind: Kind = .image,
                    byteCount: Int? = nil, contentType: String? = nil,
                    reference: String? = nil) {
            self.name = name
            self.thumbnailJPEG = thumbnailJPEG
            self.kind = kind
            self.byteCount = byteCount
            self.contentType = contentType
            self.reference = reference
        }

        enum CodingKeys: String, CodingKey {
            case name, thumbnailJPEG, kind, byteCount, contentType, reference
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            thumbnailJPEG = try c.decode(Data.self, forKey: .thumbnailJPEG)
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .image
            byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount)
            contentType = try c.decodeIfPresent(String.self, forKey: .contentType)
            reference = try c.decodeIfPresent(String.self, forKey: .reference)
        }
    }

    /// Media the agent sent back inline (§9 receive-side). Parsed out of the
    /// agent's message text at `message.complete` (see `AgentMedia`), so `text`
    /// holds the clean prose and these render as inline images / file cards.
    public struct ReceivedMedia: Sendable, Equatable, Codable, Identifiable {
        public enum Slot: Sendable, Equatable, Codable {
            case remoteURL(URL)        // markdown ![](http…) — fetch directly
            case serverImage(String)   // MEDIA:<img path> — GET /api/media?path=
            case serverFile(String)    // MEDIA:<other path> — GET /api/files/download?path=
        }
        public let id: String
        public let slot: Slot
        public let name: String        // basename, or markdown alt text
        public let caption: String?
        public var isImage: Bool { if case .serverFile = slot { return false }; return true }
        public init(id: String = UUID().uuidString, slot: Slot, name: String, caption: String? = nil) {
            self.id = id; self.slot = slot; self.name = name; self.caption = caption
        }
    }

    public let id: String
    public let role: Role
    public var text: String
    public var kind: Kind
    public var attachment: Attachment?
    public var media: [ReceivedMedia]

    public init(id: String = UUID().uuidString, role: Role, text: String,
                kind: Kind = .plain, attachment: Attachment? = nil,
                media: [ReceivedMedia] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.kind = kind
        self.attachment = attachment
        self.media = media
    }

    // Hand-rolled Codable so a cached thread written before `media` existed
    // still decodes (keeps §10 instant cold-launch across app upgrades).
    enum CodingKeys: String, CodingKey { case id, role, text, kind, attachment, media }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        kind = try c.decode(Kind.self, forKey: .kind)
        attachment = try c.decodeIfPresent(Attachment.self, forKey: .attachment)
        media = try c.decodeIfPresent([ReceivedMedia].self, forKey: .media) ?? []
    }
}

/// One structured Hermes tool call embedded at its chronological position in Chat.
/// Strings are captured from the wire instead of retaining untyped JSON so rows
/// remain Codable for the existing lightweight thread cache.
public struct ToolActivity: Identifiable, Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Equatable, Codable {
        case running, succeeded, failed
    }

    public let id: String
    public let toolName: String
    public var context: String
    public var status: Status
    public var input: String?
    public var output: String?
    public var duration: Double?
    public var exitCode: Int?
    public var risk: String?
    public var findings: [String]

    public init(id: String, toolName: String, context: String = "",
                status: Status = .running, input: String? = nil,
                output: String? = nil, duration: Double? = nil,
                exitCode: Int? = nil, risk: String? = nil,
                findings: [String] = []) {
        self.id = id
        self.toolName = toolName
        self.context = context
        self.status = status
        self.input = input
        self.output = output
        self.duration = duration
        self.exitCode = exitCode
        self.risk = risk
        self.findings = findings
    }
}

/// `approval.request` payload (verified: tui_gateway/server.py
/// _approval_request_payload). `choices` is dynamic 2–4 options — render
/// exactly what the server sent.
public struct ApprovalRequest: Identifiable, Sendable, Equatable, Codable {
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

/// Durable state for an approval card at its chronological position in Chat.
public struct ApprovalEvent: Identifiable, Sendable, Equatable, Codable {
    public enum State: Sendable, Equatable, Codable {
        case pending
        case resolved(choice: String, at: Date)
        case expired
    }

    public let request: ApprovalRequest
    public var state: State
    public var id: String { request.id }

    public init(request: ApprovalRequest, state: State = .pending) {
        self.request = request
        self.state = state
    }
}

/// `clarify.request` payload (verified: _clarify_block). Single-question
/// form: {question, choices, multi_select?}. Batch form: {questions: [...]}.
public struct ClarifyRequest: Identifiable, Sendable, Equatable, Codable {
    public struct Question: Identifiable, Sendable, Equatable, Codable {
        public let id: String       // qid ("" for single-question form)
        public let question: String
        public let choices: [String]
        public let multiSelect: Bool
    }

    public let id: String           // request_id
    public let sessionID: String
    public let questions: [Question]
    public let answers: [String: String]
    public var isBatch: Bool { questions.first?.id.isEmpty == false }

    public init?(sessionID: String, payload: [String: Any]) {
        guard let rid = payload["request_id"] as? String else { return nil }
        self.id = rid
        self.sessionID = sessionID
        answers = payload["answers"] as? [String: String] ?? [:]
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

/// Durable state for a clarification card and its progressively locked answers.
public struct ClarificationEvent: Identifiable, Sendable, Equatable, Codable {
    public enum State: Sendable, Equatable, Codable {
        case pending
        case answered(at: Date)
        case expired
    }

    public let request: ClarifyRequest
    public var answers: [String: String]
    public var state: State
    public var id: String { request.id }

    public init(request: ClarifyRequest, answers: [String: String]? = nil,
                state: State = .pending) {
        self.request = request
        self.answers = answers ?? request.answers
        self.state = state
    }
}

/// A user-visible failure tied to the conversation rather than a transient toast.
public struct ErrorEvent: Identifiable, Sendable, Equatable, Codable {
    public let id: String
    public let text: String
    public let at: Date

    public init(id: String = UUID().uuidString, text: String, at: Date = Date()) {
        self.id = id
        self.text = text
        self.at = at
    }
}
