import XCTest
@testable import SpectraCore

@MainActor
final class ActivityNavigationTests: XCTestCase {
    func testOpeningActivitySelectsProfileAndConversationEvent() {
        let app = AppState()
        let item = ActivityItem(id: "tool-7", profileName: "research",
                                toolName: "web_search", context: "Sources",
                                status: .success,
                                targetMessageID: "clarify:question-2")

        app.openActivity(item)

        XCTAssertEqual(app.activeProfileName, "research")
        XCTAssertEqual(app.chatScrollTargetID, "clarify:question-2")
        app.clearChatScrollTarget()
        XCTAssertNil(app.chatScrollTargetID)
    }

    func testToolActivityDefaultsToToolTimelineRow() {
        let item = ActivityItem(id: "tool-7", profileName: "default",
                                toolName: "terminal", context: "swift test",
                                status: .inProgress)
        XCTAssertEqual(item.targetMessageID, "tool:tool-7")
    }

    /// handoff §5: an approval with no preceding tool row still gets a standalone
    /// feed row (Waiting), deep-linked to the approval card.
    func testApprovalWithoutToolInsertsStandaloneRow() {
        let app = AppState()
        app.recordActivity(profileName: "default", event: .init(
            type: "approval.request", sessionID: "s1",
            payload: ["request_id": "req-9", "command": "rm -rf build"]))
        XCTAssertEqual(app.activityFeed.count, 1)
        let row = app.activityFeed[0]
        XCTAssertEqual(row.status, .inReview)
        XCTAssertEqual(row.context, "rm -rf build")
        XCTAssertEqual(row.targetMessageID, "approval:req-9")
    }

    /// handoff §5: an interruption with no running tool still gets a row.
    func testInterruptedTurnWithoutToolInsertsStandaloneRow() {
        let app = AppState()
        app.recordActivity(profileName: "default", event: .init(
            type: "turn.end", sessionID: "s1", payload: ["interrupted": true]))
        XCTAssertEqual(app.activityFeed.count, 1)
        XCTAssertEqual(app.activityFeed[0].status, .interrupted)
    }
}
