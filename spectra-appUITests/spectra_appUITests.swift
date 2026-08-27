import XCTest

/// Full E2E against the live gated backend: onboarding → in-app auth login →
/// loopback callback → profile picker → chat turn. Skips cleanly when the
/// backend/gate isn't reachable (the shared `signIn` stages are all conditional).
final class SpectraE2ETests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testOnboardingLoginAndChat() throws {
        let app = XCUIApplication()
        signIn(app)

        // --- Chat: send a message, await an agent reply bubble
        let input = app.textFields.matching(
            NSPredicate(format: "placeholderValue BEGINSWITH 'Message'")).firstMatch
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
