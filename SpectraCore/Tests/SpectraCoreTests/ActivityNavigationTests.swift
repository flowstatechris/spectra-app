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
}
