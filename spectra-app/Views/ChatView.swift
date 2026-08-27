import SwiftUI
import SpectraCore
import ThinkingOrbsKit

/// Chat tab (spec §8): orb header, editorial thread, approval/clarify cards,
/// pinned input bar.
struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let session = app.activeSession {
                thread(session)
                if let approval = session.pendingApproval {
                    ApprovalCard(approval: approval, session: session)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let clarify = session.pendingClarify {
                    ClarifyCard(clarify: clarify, session: session)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                inputBar(session)
            } else {
                emptyState
            }
        }
        .paper()
        .animation(.snappy, value: app.activeSession?.pendingApproval)
        .animation(.snappy, value: app.activeSession?.pendingClarify)
    }

    private var header: some View {
        VStack(spacing: 10) {
            if let name = app.activeProfileName {
                Eyebrow(name)
            }
            OrbView(status: app.activeSession?.status ?? .idle,
                    connectionState: app.connectionState, size: .px64)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func thread(_ session: ProfileSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 20)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: session.messages.last?.text) {
                if let last = session.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image("LogoMark").resizable().scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.hairline)
            Eyebrow("No profile selected")
            Text("Pick a profile in the Profiles tab.")
                .font(Theme.serif(20))
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func inputBar(_ session: ProfileSession) -> some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 12) {
                TextField("", text: $draft, prompt:
                    Text("Message \(session.profile.name)…").foregroundStyle(Theme.muted),
                    axis: .vertical)
                    .font(Theme.mono(15))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...5)
                    .disabled(!session.canSend)
                    .padding(.vertical, 10).padding(.horizontal, 16)
                    .background(Theme.plate, in: Capsule())

                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    Task { await session.send(text) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.paper)
                        .frame(width: 40, height: 40)
                        .background(canSend(session) ? Theme.accent : Theme.hairline, in: Circle())
                }
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("sendButton")
                .disabled(!canSend(session))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private func canSend(_ session: ProfileSession) -> Bool {
        session.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct MessageRow: View {
    let message: SpectraCore.Message

    var body: some View {
        switch message.kind {
        case .status:
            HStack(spacing: 8) {
                Rectangle().fill(Theme.hairline).frame(width: 2)
                Text(message.text)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .approvalResolved(let choice):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(choice, color: Theme.ok)
                    Text(message.text)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(12)
            .background(Theme.ok.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.ok.opacity(0.3), lineWidth: 1))

        case .plain:
            if message.role == .user {
                Text(message.text)
                    .font(Theme.mono(14))
                    .foregroundStyle(Theme.paper)
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                // Agent: plain mono (spec §9), thin accent rule for identity.
                HStack(alignment: .top, spacing: 12) {
                    Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 2)
                    Text(message.text)
                        .font(Theme.mono(14))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                    Spacer(minLength: 24)
                }
            }
        }
    }
}

/// Hard-block approval (spec §8): elevated, danger-edged, dynamic choices.
struct ApprovalCard: View {
    let approval: ApprovalRequest
    let session: ProfileSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.danger)
                Eyebrow("Approval required", color: Theme.danger)
            }
            Text(approval.command)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.ink)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.plate, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 10) {
                ForEach(approval.choices, id: \.self) { choice in
                    Button(choice) { Task { await session.resolveApproval(choice: choice) } }
                        .buttonStyle(OutlineButton(tint: choice == "deny" ? Theme.danger : Theme.accent))
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Theme.danger.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
    }
}

/// Soft clarify (spec §8): choice rows or free text; ignorable.
struct ClarifyCard: View {
    let clarify: ClarifyRequest
    let session: ProfileSession
    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Clarify", color: Theme.accent)
            ForEach(clarify.questions) { q in
                VStack(alignment: .leading, spacing: 10) {
                    Text(q.question)
                        .font(Theme.serif(17))
                        .foregroundStyle(Theme.ink)
                    if q.choices.isEmpty {
                        HStack(spacing: 10) {
                            TextField("", text: $freeText, prompt:
                                Text("Answer…").foregroundStyle(Theme.muted))
                                .font(Theme.mono(14))
                                .padding(.vertical, 9).padding(.horizontal, 12)
                                .background(Theme.plate, in: Capsule())
                            Button("Send") {
                                let t = freeText; freeText = ""
                                Task { await session.answerClarify(questionID: q.id, answer: t) }
                            }
                            .buttonStyle(OutlineButton(tint: Theme.accent))
                            .disabled(freeText.isEmpty)
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(q.choices, id: \.self) { choice in
                                Button {
                                    Task { await session.answerClarify(questionID: q.id, answer: choice) }
                                } label: {
                                    HStack {
                                        Text(choice).font(Theme.mono(13)).foregroundStyle(Theme.ink)
                                        Spacer()
                                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.muted).accessibilityHidden(true)
                                    }
                                    .padding(.vertical, 11).padding(.horizontal, 14)
                                    .background(Theme.plate, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
