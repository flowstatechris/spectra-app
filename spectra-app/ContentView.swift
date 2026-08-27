import SwiftUI
import SpectraCore

struct ContentView: View {
    private enum MainTab: Hashable { case chat, profiles, activity, settings }

    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue
    @State private var selectedTab = MainTab.chat

    var body: some View {
        Group {
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
        .tint(Theme.accent)
        .preferredColorScheme(Appearance(rawValue: appearanceRaw)?.scheme)
        .task { await app.restoreOnLaunch() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await app.refreshAll() }
            case .inactive, .background: app.persist()  // flush unsent-reply state
            @unknown default: break
            }
        }
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
