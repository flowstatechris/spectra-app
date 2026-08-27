import XCTest

/// Verifies Activity populates from a live tool call, deep-links to Chat, and
/// Settings renders. Also captures screenshots.
final class TasksSettingsTest: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func login(_ app: XCUIApplication) {
        app.launch()
        let urlField = app.textFields.firstMatch
        if urlField.waitForExistence(timeout: 5) {
            urlField.tap(); urlField.typeText("http://10.0.0.182:9119")
            app.buttons["Connect"].tap()
        }
        let signIn = app.buttons["Continue with browser"]
        if signIn.waitForExistence(timeout: 5) {
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            signIn.tap()
            _ = safari.wait(for: .runningForeground, timeout: 15)
            let username = safari.webViews.textFields.firstMatch
            _ = username.waitForExistence(timeout: 15)
            let close = safari.buttons["Close"]; if close.waitForExistence(timeout: 2) { close.tap() }
            var kb = false
            for _ in 0..<5 { username.tap(); if safari.keyboards.firstMatch.waitForExistence(timeout: 2) { kb = true; break }; if close.exists { close.tap() } }
            XCTAssertTrue(kb)
            safari.typeText("spectra\tTest123!\n")
            _ = safari.staticTexts.matching(NSPredicate(format: "label CONTAINS 'return to Spectra'")).firstMatch.waitForExistence(timeout: 15)
            let notNow = safari.buttons["Not Now"]; if notNow.waitForExistence(timeout: 3) { notNow.tap() }
            app.activate()
        }
        let addBtn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add '")).firstMatch
        if addBtn.waitForExistence(timeout: 15) { app.staticTexts["default"].tap(); addBtn.tap() }
    }

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
        login(app)
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
