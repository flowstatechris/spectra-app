import SwiftUI
import SpectraCore

@main
struct SpectraApp: App {
    @State private var appState = AppState()
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
    }
}
