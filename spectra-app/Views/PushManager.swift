import UIKit
import UserNotifications
import SpectraCore

/// APNs push registration + presentation (§11). Asks permission when the user
/// reaches the main app, forwards the device token to AppState (which registers
/// it with Hermes), and suppresses a banner for a profile already on screen.
@MainActor
final class PushManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PushManager()
    private weak var app: AppState?
    private var started = false

    // DEBUG builds sign with the `development` aps-environment → sandbox APNs.
    // Flip to production when shipping a Release/TestFlight build (see spec §11).
    #if DEBUG
    private let environment = "sandbox"
    #else
    private let environment = "production"
    #endif

    func start(app: AppState) {
        self.app = app
        UNUserNotificationCenter.current().delegate = self
        guard !started else { return }
        started = true
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await app?.registerAPNsToken(hex: hex, environment: environment) }
    }

    // Foreground delivery: drop the banner if the pushed profile is already the
    // one on screen; otherwise show it (§11: only surfaces when not foregrounded
    // for that profile).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        let profile = notification.request.content.userInfo["profile"] as? String
        if let profile, profile == app?.activeProfileName { return [] }
        return [.banner, .sound, .list]
    }
}

/// UIKit AppDelegate shim — the SwiftUI App lifecycle has no remote-token hook.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken: deviceToken) }
    }
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // best-effort — the app is fully usable without push
    }
}
