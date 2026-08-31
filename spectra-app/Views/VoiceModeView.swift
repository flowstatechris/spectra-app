import SwiftUI
import SpectraCore
import ThinkingOrbsKit

/// Full-screen Voice Mode: a preparing screen while the on-device speech model
/// installs (first run only), then the live loop.
///
/// The orb is driven by `VoiceSession.Phase`, not `SessionStatus` — a voice turn
/// has states a typed turn doesn't (listening to the user, waiting on the model)
/// and `SessionStatus` has no vocabulary for them. It is state-only, with no
/// amplitude reactivity: `ThinkingOrb` takes no level input, and adding one
/// means changing a vendored submodule (out of scope).
struct VoiceModeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @State private var voice: VoiceSession
    @State private var starting = true
    private let connectionState: HermesRPCConnection.State

    /// Big. This is a full-screen surface with one subject on it.
    private static let orbSize: Double = 260

    init(session: ProfileSession, connectionState: HermesRPCConnection.State) {
        _voice = State(initialValue: VoiceSession(session: session))
        self.connectionState = connectionState
    }

    private var session: ProfileSession { voice.session }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            if starting && voice.phase == .idle { preparing } else { live }
            closeButton
        }
        .task {
            // AppState only exists in the environment, not at init time, so the
            // server-side synthesiser is injected here — before start(), so the
            // first sentence of the first turn already uses it.
            voice.remoteSynthesize = { [app] text in await app.synthesizeSpeech(text) }
            await voice.start()
            starting = false
        }
        // A call took the audio session; VoiceSession already tore itself down.
        .onChange(of: voice.didExit) { _, exited in if exited { dismiss() } }
        // Approvals and clarify questions are spoken, so the user isn't left in
        // silence wondering why the agent stopped.
        .onChange(of: session.pendingApproval?.id) { _, id in
            guard id != nil, let approval = session.pendingApproval else { return }
            voice.announce("Permission needed. \(approval.command)")
        }
        .onChange(of: session.pendingClarify?.id) { _, id in
            guard id != nil, let question = session.pendingClarify?.questions.first?.question else { return }
            voice.announce(question)
        }
        .onDisappear { Task { await voice.stop() } }
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button { Task { await voice.stop(); dismiss() } } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40)
                        .background(Theme.plate, in: Circle())
                }
                .accessibilityLabel("Exit Voice Mode")
            }
            Spacer()
        }
        .padding(.horizontal, Space.gutter)
    }

    // MARK: Preparing

    /// Shown only until the mic is live. On a first run this also covers the
    /// on-device speech model installing, which is the one thing here that can
    /// take a noticeable moment.
    private var preparing: some View {
        VStack(spacing: 22) {
            Spacer()
            ThinkingOrb(state: .connecting, size: .px64, displaySize: Self.orbSize)
                .frame(width: Self.orbSize, height: Self.orbSize)
            Eyebrow("Preparing")
            Text("Setting up on-device speech. Everything stays on this phone — only text is sent to Hermes.")
                .font(Theme.mono(13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            if let error = voice.error {
                Text(error)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, 32)
    }

    // MARK: Live

    private var live: some View {
        VStack(spacing: 24) {
            Spacer()
            ThinkingOrb(state: orbState, size: .px64, displaySize: Self.orbSize)
                .frame(width: Self.orbSize, height: Self.orbSize)
                .accessibilityLabel(statusLabel)
            Eyebrow(statusLabel, color: session.pendingApproval != nil ? Theme.danger : Theme.muted)
                .animation(.easeInOut(duration: 0.2), value: statusLabel)
            caption
            Spacer()
            if let approval = session.pendingApproval { approvalChoices(approval) }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, 32)
    }

    /// Voice phase → orb state. `.listening` is the kit's wave mode, which is
    /// the one state that visually reads as "the mic is open" rather than
    /// "something is computing".
    private var orbState: OrbState {
        if connectionState != .connected { return .connecting }
        if session.pendingApproval != nil { return .breathing }
        switch voice.phase {
        case .idle:      return .breathing
        case .listening: return .listening
        case .sending:   return .weaving
        case .thinking:  if case .thinking(let search) = session.status, search { return .searching }
                         return .working
        case .speaking:  return .composing
        }
    }

    private var statusLabel: String {
        if connectionState != .connected { return "Offline" }
        if session.pendingApproval != nil { return "Needs permission" }
        switch voice.phase {
        case .idle:      return "Starting"
        case .listening: return "Listening"
        case .sending:   return "Sending"
        case .thinking:  return "Waiting"
        case .speaking:  return "Speaking"
        }
    }

    @ViewBuilder private var caption: some View {
        let text = voice.captionText.isEmpty ? voice.partialTranscript : voice.captionText
        Text(text)
            .font(Theme.serif(19))
            .foregroundStyle(voice.captionText.isEmpty ? Theme.muted : Theme.ink)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .top)
            .animation(.easeInOut(duration: 0.15), value: text)

        if let error = voice.error {
            Text(error)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.danger)
                .multilineTextAlignment(.center)
        }
        // iOS installs only compact voices out of the box, and they sound
        // robotic. The good ones are a free download but the user has to go get
        // them, and there is no public deep link to that Settings pane — so the
        // path is spelled out rather than hidden behind a button that can't work.
        if voice.usingCompactVoice && voice.lastEngine == "on-device" {
            Text("Robotic voice? Download a better one:\nSettings → Accessibility → Spoken Content → Voices → English")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        #if DEBUG
        // Reads the live graph instead of guessing at it. "mic 0" means no audio
        // buffers are arriving at all — a dead tap, not a bad transcription.
        if !voice.diagnostics.isEmpty {
            Text(voice.diagnostics)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.muted.opacity(0.7))
        }
        #endif
    }

    /// Spoken aloud, resolved by tap — never voice-matched. "Deny" and "allow
    /// this time" are one bad endpoint apart, and this is the one place in the
    /// feature where a mis-transcription has real consequences.
    private func approvalChoices(_ approval: ApprovalRequest) -> some View {
        VStack(spacing: Space.row) {
            Text(approval.command)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.muted)
                .lineLimit(3)
            ForEach(approval.choices, id: \.self) { choice in
                Button(choiceLabel(choice)) {
                    Task { await session.resolveApproval(choice: choice) }
                }
                .buttonStyle(OutlineButton(tint: choice == "deny" ? Theme.danger : Theme.accent))
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(Theme.danger.opacity(0.45), lineWidth: 1))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func choiceLabel(_ choice: String) -> String {
        switch choice {
        case "once": "Allow once"
        case "session": "This session"
        case "always": "Always allow"
        case "deny": "Deny"
        default: choice
        }
    }
}
