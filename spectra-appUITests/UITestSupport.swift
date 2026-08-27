import XCTest

/// Shared onboarding→login→profile-picker driver for the UI suite.
///
/// The login flow is an `ASWebAuthenticationSession` (see `AuthPresenter`), NOT
/// external Safari, so three things differ from the old per-file helpers:
///   1. The web form renders in `com.apple.SafariViewService`, not
///      `com.apple.mobilesafari`.
///   2. The first "Continue with browser" tap raises a SpringBoard consent
///      alert ("… Wants to Use … to Sign In") that must be tapped Continue.
///   3. On callback the sheet JS-bounces `spectra://auth-done` and
///      auto-dismisses — the app is already foreground, so gate completion on
///      the profile picker, not the flash "returning to Spectra" page.
///
/// Every stage is conditional so reruns (already past the gate, or SSO-skipped
/// because `prefersEphemeralWebBrowserSession = false`) pass straight through.
extension XCTestCase {
    // ponytail: UNVERIFIED against the live login — retargeted to
    // SafariViewService + SpringBoard consent, but never got a green
    // end-to-end run. Element queries (consent "Continue", webViews
    // textFields, save-password "Not Now") are contract-derived guesses.
    // Verify on the sim + LAN backend before trusting UI coverage.
    static let backendURL = "http://10.0.0.182:9119"

    func signIn(_ app: XCUIApplication) {
        app.launch()

        // --- Backend entry
        let urlField = app.textFields.firstMatch
        if urlField.waitForExistence(timeout: 5) {
            urlField.tap()
            urlField.typeText(Self.backendURL)
            app.buttons["Connect"].tap()
        }

        // --- Login (skip if already authenticated from a prior run)
        let signInButton = app.buttons["Continue with browser"]
        if signInButton.waitForExistence(timeout: 5) {
            signInButton.tap()

            // ASWebAuth consent alert lives in SpringBoard, first run only.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let consent = springboard.buttons["Continue"]
            if consent.waitForExistence(timeout: 5) { consent.tap() }

            let web = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
            XCTAssertTrue(web.wait(for: .runningForeground, timeout: 15),
                          "in-app auth browser (SafariViewService) never foregrounded")

            // Fill the Hermes /login form only if it actually appears — SSO
            // reuse can land straight on the callback. A literal Tab keystroke
            // navigates the WebKit form (tapping between fields refuses focus),
            // so type username⇥password⏎ as one uninterrupted sequence.
            let username = web.webViews.textFields.firstMatch
            if username.waitForExistence(timeout: 10) {
                var keyboardUp = false
                for _ in 0..<5 {
                    username.tap()
                    if web.keyboards.firstMatch.waitForExistence(timeout: 2) { keyboardUp = true; break }
                }
                XCTAssertTrue(keyboardUp, "login form keyboard didn't appear")
                web.typeText("spectra\tTest123!\n")
            }

            // Save-password sheet (SafariViewService), if offered.
            let notNow = web.buttons["Not Now"]
            if notNow.waitForExistence(timeout: 5) { notNow.tap() }

            // Sheet auto-dismisses on the spectra://auth-done bounce; the app
            // returns to foreground on its own.
        }

        // --- Profile picker → land in the tab UI
        let addButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Add '")).firstMatch
        if addButton.waitForExistence(timeout: 15) {
            let defaultRow = app.staticTexts["default"]
            XCTAssertTrue(defaultRow.waitForExistence(timeout: 10), "profiles didn't load")
            defaultRow.tap()
            addButton.tap()
        }
    }
}
