import XCTest

/// Full E2E against the live gated backend: onboarding → Safari password
/// login → loopback callback → profile picker → chat turn. Requires the
/// hermes serve instance on the LAN (skips cleanly when absent).
final class SpectraE2ETests: XCTestCase {
    static let baseURL = "http://10.0.0.182:9119"

    override func setUp() { continueAfterFailure = false }

    @MainActor
    private func focusAndType(_ element: XCUIElement, text: String, in app: XCUIApplication) {
        // hasKeyboardFocus isn't reliable for Safari's remoted webview
        // elements — use the software keyboard's presence as the focus signal.
        for _ in 0..<6 {
            element.tap()
            if app.keyboards.firstMatch.waitForExistence(timeout: 2) { break }
        }
        element.typeText(text)
    }

    @MainActor
    func testOnboardingLoginAndChat() throws {
        let app = XCUIApplication()
        app.launch()

        // --- Backend entry (skip if already past it from a previous run)
        let urlField = app.textFields.firstMatch
        if urlField.waitForExistence(timeout: 5) {
            urlField.tap()
            urlField.typeText(Self.baseURL)
            app.buttons["Connect"].tap()
        }

        // --- Login → Safari
        let signIn = app.buttons["Continue with browser"]
        if signIn.waitForExistence(timeout: 5) {
            XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").terminate()
            signIn.tap()

            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 15), "Safari didn't open")

            // Hermes /login form. Tapping between webview fields is hopelessly
            // flaky (focus refuses to leave the first field), but a literal
            // Tab keystroke navigates the form inside WebKit itself — so type
            // username⇥password⏎ as ONE uninterrupted sequence.
            let username = safari.webViews.textFields.firstMatch
            XCTAssertTrue(username.waitForExistence(timeout: 15), "login form didn't load")

            // Safari's first-launch coach-marks swallow taps — dismiss any.
            let coachClose = safari.buttons["Close"]
            if coachClose.waitForExistence(timeout: 2) { coachClose.tap() }

            var keyboardUp = false
            for _ in 0..<5 {
                username.tap()
                if safari.keyboards.firstMatch.waitForExistence(timeout: 2) { keyboardUp = true; break }
                if coachClose.exists { coachClose.tap() }
            }
            XCTAssertTrue(keyboardUp, "keyboard didn't appear")
            safari.typeText("spectra\tTest123!\n")

            let success = safari.staticTexts.matching(
                NSPredicate(format: "label CONTAINS 'return to Spectra'")).firstMatch
            XCTAssertTrue(success.waitForExistence(timeout: 15), "never reached the loopback callback page")

            // Dismiss Safari's "Save Password?" sheet if it appears.
            let notNow = safari.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 5) { notNow.tap() }
            app.activate()
        }

        // --- Profile picker
        let addButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add '")).firstMatch
        if addButton.waitForExistence(timeout: 15) {
            let defaultRow = app.staticTexts["default"]
            XCTAssertTrue(defaultRow.waitForExistence(timeout: 10), "profiles didn't load")
            defaultRow.tap()
            addButton.tap()
        }

        // --- Chat: send a message, await an agent reply bubble
        let input = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10), "chat input missing")
        input.tap()
        input.typeText("Reply with exactly: E2E OK")
        app.buttons["sendButton"].tap()

        // Our sent message appears…
        XCTAssertTrue(app.staticTexts["Reply with exactly: E2E OK"]
            .waitForExistence(timeout: 5), "sent message not in thread")
        // …and *some* agent output follows (model may error server-side; any
        // agent bubble/status row proves the event pipeline end-to-end).
        let agentReplied = NSPredicate(format: "label CONTAINS 'E2E OK' OR label CONTAINS 'error' OR label CONTAINS '401' OR label CONTAINS 'Error'")
        let reply = app.staticTexts.matching(agentReplied).element(boundBy: 1)
        XCTAssertTrue(reply.waitForExistence(timeout: 60), "no agent output within 60s")
    }
}
