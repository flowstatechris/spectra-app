import Foundation

/// One tool/turn activity across any profile — the Tasks feed (spec §8).
/// Keyed on the server's tool_id so tool.start → tool.complete flips in place.
public struct ActivityItem: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable {
        case inProgress   // tool.start seen, not yet complete
        case inReview     // blocked on an approval/clarify
        case success      // tool.complete
        case failed       // turn.error while running
    }

    public let id: String            // tool_id
    public let profileName: String
    public let toolName: String
    public var context: String       // human summary line from the server
    public var status: Status
    public let startedAt: Date
    public var duration: Double?

    public init(id: String, profileName: String, toolName: String,
                context: String, status: Status, startedAt: Date = Date(), duration: Double? = nil) {
        self.id = id
        self.profileName = profileName
        self.toolName = toolName
        self.context = context
        self.status = status
        self.startedAt = startedAt
        self.duration = duration
    }
}
