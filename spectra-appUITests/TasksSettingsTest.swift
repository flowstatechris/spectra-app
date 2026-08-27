import XCTest

/// Verifies Activity populates from a live tool call, deep-links to Chat, and
/// Settings renders. Also captures screenshots.
final class TasksSettingsTest: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func dismissKeyboard(_ app: XCUIApplication) {
        // Drag WITHIN the message thread (mid-screen, above the keyboard) so
        // scrollDismissesKeyboard fires — a full-screen swipe lands on the
        // keyboard's QuickPath and types garbage instead.
        for _ in 0..<4 {
            if !app.keyboards.firstMatch.exists { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
            start.press(forDuration: 0.05, thenDragTo: end)
            usleep(500_000)
        }
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let att = XCTAttachment(screenshot: app.screenshot())
        att.name = name; att.lifetime = .keepAlways; add(att)
    }

    func testActivityDeepLinkAndSettings() throws {
        let app = XCUIApplication()
        signIn(app)
        let input = app.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText("Use the web_search tool to look up the current time in Tokyo, then tell me.")
        app.buttons["sendButton"].tap()
        sleep(14)   // let the web_search tool.start fire
        dismissKeyboard(app)

        let chatActivity = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH[c] 'Searching the web' OR label BEGINSWITH[c] 'Searched the web' OR label BEGINSWITH[c] 'Web search failed'"
        )).firstMatch
        XCTAssertTrue(chatActivity.waitForExistence(timeout: 15), "Chat had no structured tool activity row")
        shot(app, "chat-tool-activity")

        // Activity tab must switch and show at least one activity row.
        XCTAssertTrue(app.tabBars.buttons["Activity"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Activity"].tap()
        let pill = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] 'WORKING' OR label CONTAINS[c] 'SUCCESS' OR label CONTAINS[c] 'WAITING'")).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "Activity feed had no activity row")
        shot(app, "activity")

        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'activity:'")).firstMatch.tap()
        XCTAssertTrue(app.tabBars.buttons["Chat"].isSelected)
        XCTAssertTrue(chatActivity.waitForExistence(timeout: 5), "Activity did not deep-link to Chat")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["BACKEND"].waitForExistence(timeout: 5))
        shot(app, "settings")
    }
}
