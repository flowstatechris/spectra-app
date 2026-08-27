import SwiftUI
import SpectraCore

/// Chat tab (spec §8): orb header, message thread, approval/clarify cards,
/// pinned input bar.
struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session = app.activeSession {
                thread(session)
                if let approval = session.pendingApproval {
                    ApprovalCard(approval: approval, session: session)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                if let clarify = session.pendingClarify {
                    ClarifyCard(clarify: clarify, session: session)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
                inputBar(session)
            } else {
                emptyState
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            OrbView(status: app.activeSession?.status ?? .idle,
                    connectionState: app.connectionState)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func thread(_ session: ProfileSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.messages.last?.text) {
                if let last = session.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image("LogoMark")
                .resizable().scaledToFit()
                .frame(width: 56, height: 56)
            Text("No profile selected")
                .font(.headline)
            Text("Pick a profile in the Profiles tab.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func inputBar(_ session: ProfileSession) -> some View {
        HStack(spacing: 10) {
            TextField("Message \(session.profile.name)", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .disabled(!session.canSend)
            Button {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                draft = ""
                Task { await session.send(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .accessibilityIdentifier("sendButton")
            .disabled(!session.canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

struct MessageRow: View {
    let message: SpectraCore.Message

    var body: some View {
        switch message.kind {
        case .status:
            Text(message.text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .approvalResolved(let choice):
            Label {
                Text("\(choice.capitalized) — \(message.text)")
                    .font(.caption.monospaced())
                    .lineLimit(2)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
            .padding(8)
            .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .plain:
            // Plain monospace for all text/code (spec §9) — no styling in v1.
            Text(message.text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(10)
                .background(message.role == .user ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity,
                       alignment: message.role == .user ? .trailing : .leading)
        }
    }
}

/// Hard-block approval card (spec §8): renders exactly the server's choices.
struct ApprovalCard: View {
    let approval: ApprovalRequest
    let session: ProfileSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval required", systemImage: "exclamationmark.shield")
                .font(.headline)
            Text(approval.command)
                .font(.caption.monospaced())
                .lineLimit(4)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                ForEach(approval.choices, id: \.self) { choice in
                    Button(choice.capitalized) {
                        Task { await session.resolveApproval(choice: choice) }
                    }
                    .buttonStyle(.bordered)
                    .tint(choice == "deny" ? .red : .accentColor)
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.red.opacity(0.4)))
    }
}

/// Soft clarify card (spec §8): choice rows or free-text; ignorable.
struct ClarifyCard: View {
    let clarify: ClarifyRequest
    let session: ProfileSession
    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(clarify.questions) { q in
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.question).font(.subheadline)
                    if q.choices.isEmpty {
                        HStack {
                            TextField("Answer", text: $freeText)
                                .textFieldStyle(.roundedBorder)
                            Button("Send") {
                                let t = freeText; freeText = ""
                                Task { await session.answerClarify(questionID: q.id, answer: t) }
                            }
                            .disabled(freeText.isEmpty)
                        }
                    } else {
                        ForEach(q.choices, id: \.self) { choice in
                            Button {
                                Task { await session.answerClarify(questionID: q.id, answer: choice) }
                            } label: {
                                Text(choice)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
