import SwiftUI
import SpectraCore

struct ContentView: View {
    private enum MainTab: Hashable { case chat, profiles, activity, settings }

    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @State private var selectedTab = MainTab.chat
    // Held for at least 0.75s (see .task below) so restoreOnLaunch()'s async
    // token check has time to land before anything is shown. Without this,
    // a revoked token flips phase from the optimistic cache-painted .ready
    // to .needsLogin mid-frame — a flash of the sign-in screen behind chat
    // that's already on screen. A valid token never gets that far: launching
    // just clears straight into .ready.
    @State private var launching = true

    var body: some View {
        Group {
            if launching {
                LaunchScreen()
            } else {
                switch app.phase {
                case .needsBackend:
                    BackendConfigView()
                case .needsLogin, .loggingIn, .error:
                    LoginView()
                case .pickingProfiles:
                    ProfilePickerView()
                case .ready:
                    mainTabs
                        .task { PushManager.shared.start(app: app) }   // §11: ask + register
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(Appearance(rawValue: appearanceRaw)?.scheme)
        .task {
            async let restore: Void = app.restoreOnLaunch()
            try? await Task.sleep(for: .milliseconds(750))
            await restore   // no-op if restoreOnLaunch already finished
            withAnimation(.easeOut(duration: 0.25)) { launching = false }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await app.refreshAll() }
            case .inactive, .background: app.persist()  // flush unsent-reply state
            @unknown default: break
            }
        }
        .onChange(of: app.chatRouteToken) { selectedTab = .chat }  // tapped push → Chat (§6/§11)
    }

    private var mainTabs: some View {
        TabView(selection: $selectedTab) {
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: .chat) { ChatView() }
            Tab("Profiles", systemImage: "square.stack", value: .profiles) { ProfilesView() }
                .badge(app.profilesNeedingAttention.count)
            Tab("Activity", systemImage: "circle.grid.2x2", value: .activity) {
                ActivityView { item in
                    app.openActivity(item)
                    selectedTab = .chat
                }
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView() }
        }
    }
}
