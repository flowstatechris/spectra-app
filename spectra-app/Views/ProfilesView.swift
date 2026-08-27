import SwiftUI
import SpectraCore

/// Profiles tab (spec §8): added profiles, status dot, attention badge,
/// read-only rich detail. Cockpit, not a garage.
struct ProfilesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow("Connected")
                        .padding(.horizontal, 24).padding(.top, 8)
                    ForEach(app.sessions.keys.sorted(), id: \.self) { name in
                        if let session = app.sessions[name] {
                            NavigationLink { ProfileDetailView(session: session) } label: {
                                row(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 20)
            }
            .paper()
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if app.sessions.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "person.2").font(.largeTitle).foregroundStyle(Theme.hairline)
                        Eyebrow("No profiles added")
                    }
                }
            }
        }
    }

    private func row(_ session: ProfileSession) -> some View {
        let attention = session.pendingApproval != nil || session.pendingClarify != nil
        return HStack(spacing: 14) {
            Circle()
                .fill(app.connectionState == .connected ? Theme.ok : Theme.muted)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.profile.name)
                    .font(Theme.serif(22))
                    .foregroundStyle(Theme.ink)
                if !session.profile.model.isEmpty {
                    Text(session.profile.model)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if attention {
                Circle().fill(Theme.danger).frame(width: 8, height: 8)
            }
            if app.activeProfileName == session.profile.name {
                Eyebrow("Active", color: Theme.accent)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .card(border: attention ? Theme.danger.opacity(0.4) : Theme.hairline)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            app.activeProfileName = session.profile.name
        })
    }
}

struct ProfileDetailView: View {
    let session: ProfileSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(session.profile.name)
                    .font(Theme.serif(40))
                    .foregroundStyle(Theme.ink)

                field("Model", session.profile.model)
                field("Provider", session.profile.provider)
                if session.profile.skillCount > 0 {
                    field("Skills", "\(session.profile.skillCount)")
                }
                if session.profile.isDefault { field("Default", "Yes") }
                if !session.profile.profileDescription.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow("Description")
                        Text(session.profile.profileDescription)
                            .font(Theme.serif(17))
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .paper()
        .navigationTitle(session.profile.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(label)
                Text(value).font(Theme.mono(15)).foregroundStyle(Theme.ink)
            }
        }
    }
}
