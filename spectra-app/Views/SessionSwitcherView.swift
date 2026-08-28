import SwiftUI
import SpectraCore

/// Recent-sessions picker for the active Profile (handoff §2b). Tapping the Chat
/// header opens this; it lists Hermes sessions, offers New Chat, and resumes the
/// picked one. Switching is blocked mid-turn / mid-approval so we never abandon a
/// supervised runtime — listing stays available, only the actions disable.
struct SessionSwitcherView: View {
    @Environment(AppState.self) private var app
    let session: ProfileSession
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [ProfileSession.SessionSummary] = []
    @State private var loading = true
    @State private var loadError: String?

    private var canSwitch: Bool { session.canSwitchSessions }

    var body: some View {
        NavigationStack {
            List {
                if app.sessions.count > 1 {
                    Section("Switch profile") {
                        ForEach(app.sessions.keys.sorted(), id: \.self) { name in
                            Button { app.activeProfileName = name; dismiss() } label: {
                                HStack {
                                    Text(name).font(Theme.mono(14, .medium)).foregroundStyle(Theme.ink)
                                    if let a = app.sessions[name]?.attention {
                                        Text(a.label).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.danger)
                                    }
                                    Spacer()
                                    if name == app.activeProfileName {
                                        Text("active").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .disabled(name == app.activeProfileName)
                        }
                    }
                }
                if !canSwitch {
                    Text("Finish the current turn before switching chats.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                }

                Section {
                    Button { Task { await session.newSession(); dismiss() } } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                            .font(Theme.mono(14, .semibold))
                    }
                    .disabled(!canSwitch)
                }

                Section("Recent") {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                            .listRowBackground(Color.clear)
                    } else if let loadError {
                        Text(loadError).font(Theme.mono(12)).foregroundStyle(Theme.danger)
                    } else if sessions.isEmpty {
                        Text("No other chats yet.")
                            .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    } else {
                        ForEach(sessions) { row in
                            Button { Task { await session.switchTo(row.id); dismiss() } } label: {
                                sessionRow(row)
                            }
                            .disabled(!canSwitch || row.isCurrent)
                        }
                    }
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            do { sessions = try await session.listSessions() }
            catch { loadError = "Couldn't load chats." }
            loading = false
        }
    }

    @ViewBuilder
    private func sessionRow(_ row: ProfileSession.SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.title).font(Theme.mono(14, .medium)).foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if row.isCurrent {
                    Text("current").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.accent)
                }
            }
            if !row.preview.isEmpty {
                Text(row.preview).font(Theme.serif(13)).foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Text(subtitle(row)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ row: ProfileSession.SessionSummary) -> String {
        let count = "\(row.messageCount) message\(row.messageCount == 1 ? "" : "s")"
        guard row.startedAt > 0 else { return count }
        let when = Date(timeIntervalSince1970: row.startedAt)
            .formatted(.relative(presentation: .named))
        return "\(when) · \(count)"
    }
}
