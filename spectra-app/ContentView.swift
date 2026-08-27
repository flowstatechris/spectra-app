import SwiftUI
import SpectraCore

struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue

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
        TabView {
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") { ChatView() }
            Tab("Profiles", systemImage: "square.stack") { ProfilesView() }
                .badge(app.profilesNeedingAttention.count)
            Tab("Tasks", systemImage: "circle.grid.2x2") { TasksView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
    }
}
