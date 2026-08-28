import Foundation

/// One tool/turn activity across any profile — the Activity feed (spec §13).
/// Keyed on the server's tool_id so tool.start → tool.complete flips in place.
public struct ActivityItem: Identifiable, Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case inProgress   // tool.start seen, not yet complete
        case inReview     // blocked on an approval/clarify
        case success      // tool.complete
        case failed       // turn.error while running
        case interrupted  // turn.end(interrupted: true)
    }

    public let id: String            // tool_id
    public let profileName: String
    public let toolName: String
    public var context: String       // human summary line from the server
    public var status: Status
    public var targetMessageID: String
    public let startedAt: Date
    public var duration: Double?

    /// Human title for the feed row. Synthetic standalone rows carry a bare
    /// `turn`/`approval`/`clarify` toolName; real tools carry a snake/kebab id.
    /// Map the former to plain language and Title-Case the latter.
    public var displayTitle: String {
        switch toolName {
        case "turn":     return "Turn update"
        case "approval": return "Approval request"
        case "clarify":  return "Question"
        default:
            let words = toolName.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " })
            guard !words.isEmpty else { return toolName }
            return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    public init(id: String, profileName: String, toolName: String,
                context: String, status: Status, targetMessageID: String? = nil,
                startedAt: Date = Date(), duration: Double? = nil) {
        self.id = id
        self.profileName = profileName
        self.toolName = toolName
        self.context = context
        self.status = status
        self.targetMessageID = targetMessageID ?? "tool:\(id)"
        self.startedAt = startedAt
        self.duration = duration
    }
}
