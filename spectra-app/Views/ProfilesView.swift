import SwiftUI
import SpectraCore

/// Profiles tab (spec §8): added profiles, status dot, attention badge,
/// read-only detail. Cockpit, not a garage.
struct ProfilesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationStack {
            List {
                ForEach(app.sessions.keys.sorted(), id: \.self) { name in
                    if let session = app.sessions[name] {
                        NavigationLink {
                            ProfileDetailView(session: session)
                        } label: {
                            row(session)
                        }
                    }
                }
                .onDelete { offsets in
                    let names = app.sessions.keys.sorted()
                    for i in offsets { app.removeProfile(names[i]) }
                }
            }
            .navigationTitle("Profiles")
            .overlay {
                if app.sessions.isEmpty {
                    ContentUnavailableView("No profiles added",
                                           systemImage: "person.2",
                                           description: Text("Add one from your backend."))
                }
            }
        }
    }

    private func row(_ session: ProfileSession) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(app.connectionState == .connected ? .green : .gray)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(session.profile.name)
                if !session.profile.model.isEmpty {
                    Text(session.profile.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if session.pendingApproval != nil || session.pendingClarify != nil {
                Circle().fill(.red).frame(width: 9, height: 9)
            }
            Button {
                app.activeProfileName = session.profile.name
            } label: {
                Image(systemName: app.activeProfileName == session.profile.name
                      ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
        }
    }
}

struct ProfileDetailView: View {
    let session: ProfileSession

    var body: some View {
        List {
            LabeledContent("Name", value: session.profile.name)
            if !session.profile.model.isEmpty {
                LabeledContent("Model", value: session.profile.model)
            }
            if !session.profile.provider.isEmpty {
                LabeledContent("Provider", value: session.profile.provider)
            }
            if session.profile.skillCount > 0 {
                LabeledContent("Skills", value: "\(session.profile.skillCount)")
            }
            if !session.profile.profileDescription.isEmpty {
                Section("Description") { Text(session.profile.profileDescription) }
            }
        }
        .navigationTitle(session.profile.name)
    }
}
