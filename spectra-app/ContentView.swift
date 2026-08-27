import SwiftUI
import SpectraCore

struct ContentView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

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
            }
        }
        .task { await app.restoreOnLaunch() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await app.refreshAll() } }
        }
    }

    private var mainTabs: some View {
        TabView {
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                ChatView()
            }
            Tab("Profiles", systemImage: "person.2") {
                ProfilesView()
            }
            .badge(app.profilesNeedingAttention.count)
        }
    }
}
