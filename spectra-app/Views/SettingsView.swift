import SwiftUI
import SpectraCore

/// Settings tab (spec §8): flat sectioned list. Only surfaces that back a
/// real behavior today — Backend, Appearance, About. Notifications and
/// per-profile Face ID are deferred with their infrastructure (§11, §15),
/// so no dead toggles here.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @AppStorage("appearance") private var appearanceRaw = Appearance.system.rawValue

    private var appearance: Binding<Appearance> {
        Binding(get: { Appearance(rawValue: appearanceRaw) ?? .system },
                set: { appearanceRaw = $0.rawValue })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    backendSection
                    appearanceSection
                    aboutSection
                }
                .padding(Space.gutter)
            }
            .paper()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Backend")
            if let backend = app.backend {
                Text(backend.baseURL.absoluteString)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.ink)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.plate, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            }
            Button("Change server") { app.editBackend() }
                .buttonStyle(OutlineButton())
            Button("Sign out") { Task { await app.logout() } }
                .buttonStyle(OutlineButton(tint: Theme.danger))
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Appearance")
            Picker("", selection: appearance) {
                ForEach(Appearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("About")
            row("Version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            Link(destination: URL(string: "https://github.com/flowstatechris/spectra-app")!) {
                HStack {
                    Text("GitHub").font(Theme.mono(13)).foregroundStyle(Theme.accent)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.accent)
                }
            }
            row("License", "MIT")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.mono(13)).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).font(Theme.mono(13)).foregroundStyle(Theme.ink)
        }
    }
}
