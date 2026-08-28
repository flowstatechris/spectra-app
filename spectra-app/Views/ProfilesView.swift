import SwiftUI
import SpectraCore

/// Profiles tab (spec §8): added profiles, status dot, attention badge,
/// read-only rich detail. Cockpit, not a garage.
struct ProfilesView: View {
    @Environment(AppState.self) private var app
    @State private var addingProfile = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.row) {
                    Eyebrow("Connected")
                        .padding(.horizontal, Space.gutter).padding(.top, 8)
                    ForEach(app.sessions.keys.sorted(), id: \.self) { name in
                        if let session = app.sessions[name] {
                            NavigationLink { ProfileDetailView(session: session) } label: {
                                row(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                }
                .padding(.bottom, 20)
            }
            .paper()
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { addingProfile = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add profile")
                }
            }
            .sheet(isPresented: $addingProfile) { AddProfileSheet() }
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
        let attention = session.attention
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
            if let attention {
                HStack(spacing: 5) {
                    Circle().fill(Theme.danger).frame(width: 8, height: 8)
                    Eyebrow(attention.label, color: Theme.danger)
                }
            } else if app.activeProfileName == session.profile.name {
                Eyebrow("Active", color: Theme.accent)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted).accessibilityHidden(true)
        }
        .padding(16)
        .card(border: attention != nil ? Theme.danger.opacity(0.4) : Theme.hairline)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            app.activeProfileName = session.profile.name
        })
    }
}

struct ProfileDetailView: View {
    @Environment(AppState.self) private var app
    let session: ProfileSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(session.profile.name)
                    .font(Theme.serif(40))
                    .foregroundStyle(Theme.ink)

                Button("Open Chat") { app.routeToChat(profile: session.profile.name) }
                    .buttonStyle(PrimaryButton())

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
            .padding(Space.gutter)
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

/// Add profiles after onboarding. Lists backend profiles not already added;
/// tap to select, Add to create their sessions. (Profiles were previously only
/// choosable during onboarding.)
struct AddProfileSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var loading = true

    private var addable: [ProfileInfo] {
        app.availableProfiles
            .filter { app.sessions[$0.name] == nil }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                } else if addable.isEmpty {
                    Text("All profiles are already added.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(addable) { profile in
                        Button {
                            if selected.contains(profile.name) { selected.remove(profile.name) }
                            else { selected.insert(profile.name) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).font(Theme.serif(20)).foregroundStyle(Theme.ink)
                                    if !profile.model.isEmpty {
                                        Text(profile.model).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                                    }
                                }
                                Spacer()
                                Image(systemName: selected.contains(profile.name)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(profile.name) ? Theme.accent : Theme.hairline)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Add Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { app.addProfiles(Array(selected)); dismiss() }
                        .disabled(selected.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await app.refreshAvailableProfiles()
            loading = false
        }
    }
}
