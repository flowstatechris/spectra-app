import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import SpectraCore
import ThinkingOrbsKit

/// Chat tab (spec §8): orb header, editorial thread, approval/clarify cards,
/// pinned input bar.
struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPhotoLibrary = false
    @State private var showingCamera = false
    @State private var showingFileImporter = false
    @State private var stopping = false
    @State private var scrolledIntoConversation = false
    @State private var showingInitialHeader = true
    @State private var showingStatusTransition = false
    @State private var collapsedApprovalID: String?
    @State private var showingSessions = false
    @State private var highlightedMessageID: String?   // brief deep-link flash

    var body: some View {
        VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture { if app.activeSession != nil { showingSessions = true } }
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Switch or start a chat")
            Hairline()
            if let error = app.connectionError {
                offlineBanner(error)
            }
            if let session = app.activeSession {
                thread(session)
                if let approval = session.pendingApproval,
                   collapsedApprovalID == approval.id {
                    approvalChip(approval)
                }
                inputBar(session)
            } else {
                emptyState
            }
        }
        .paper()
        .sheet(isPresented: $showingSessions) {
            if let session = app.activeSession {
                SessionSwitcherView(session: session)
            }
        }
        .animation(.snappy, value: compactHeader)
        .animation(.snappy, value: app.activeSession?.pendingApproval)
        .animation(.snappy, value: app.activeSession?.pendingClarify)
        .task(id: app.activeProfileName) {
            scrolledIntoConversation = false
            showingInitialHeader = true
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            showingInitialHeader = false
        }
        .task(id: app.activeSession?.status) {
            showingStatusTransition = false
            guard scrolledIntoConversation else { return }
            showingStatusTransition = true
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            showingStatusTransition = false
        }
        .onChange(of: app.activeSession?.pendingApproval?.id) {
            collapsedApprovalID = nil
        }
    }

    /// Explicit, tappable offline state — never an infinite spinner (§12).
    private func offlineBanner(_ text: String) -> some View {
        Button { Task { await app.retryConnection() } } label: {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").accessibilityHidden(true)
                Text(text).font(Theme.mono(12, .medium))
                Spacer()
                Text("RETRY").font(Theme.mono(11, .semibold, relativeTo: .caption2)).tracking(1.5)
            }
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Theme.danger.opacity(0.08))
        }
        .accessibilityLabel("Connection lost. \(text) Tap to retry.")
    }

    private var header: some View {
        Group {
            if compactHeader {
                HStack(spacing: 10) {
                    OrbView(status: app.activeSession?.status ?? .idle,
                            connectionState: app.connectionState,
                            size: .px20, showsLabel: false)
                    Text("\(app.activeProfileName ?? "") · \(statusLabel)")
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(Theme.muted)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(app.activeProfileName ?? "Profile"), \(statusLabel)")
            } else {
                VStack(spacing: 6) {
                    // Half-size orb: px64 is the only calibrated preset besides
                    // px20, so scale it 0.5 and collapse the reserved box to 32.
                    OrbView(status: app.activeSession?.status ?? .idle,
                            connectionState: app.connectionState,
                            size: .px64, showsLabel: false)
                        .scaleEffect(0.5)
                        .frame(width: 32, height: 32)
                    Text("\(app.activeProfileName ?? "") · \(statusLabel)")
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var compactHeader: Bool {
        scrolledIntoConversation && !showingInitialHeader && !showingStatusTransition
    }

    private var statusLabel: String {
        OrbView.label(for: app.activeSession?.status ?? .idle,
                      connectionState: app.connectionState)
    }

    @ViewBuilder
    private func thread(_ session: ProfileSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.messages) { message in
                        MessageRow(message: message, session: session,
                                   collapsedApprovalID: $collapsedApprovalID)
                            .id(message.id)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Theme.accent.opacity(
                                        highlightedMessageID == message.id ? 0.14 : 0))
                                    .padding(.horizontal, -8)
                            )
                            .animation(.easeInOut(duration: 0.3), value: highlightedMessageID)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 20)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.immediately)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 48
            } action: { _, scrolled in
                scrolledIntoConversation = scrolled
            }
            .onChange(of: session.messages.last) {
                if let last = session.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onAppear { scrollToActivity(in: session, proxy: proxy) }
            .onChange(of: app.chatScrollTargetID) {
                scrollToActivity(in: session, proxy: proxy)
            }
        }
    }

    private func scrollToActivity(in session: ProfileSession, proxy: ScrollViewProxy) {
        guard let target = app.chatScrollTargetID,
              session.messages.contains(where: { $0.id == target }) else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(target, anchor: .center)
        }
        app.clearChatScrollTarget()
        // Brief flash so the eye lands on the deep-linked row (handoff §5).
        highlightedMessageID = target
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if highlightedMessageID == target { highlightedMessageID = nil }
        }
    }

    private func approvalChip(_ approval: ApprovalRequest) -> some View {
        Button { collapsedApprovalID = nil } label: {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.shield.fill")
                Text("Hermes needs permission").font(Theme.mono(12, .medium))
                Spacer()
                Image(systemName: "chevron.up").font(.caption)
            }
            .foregroundStyle(Theme.danger)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(Theme.danger.opacity(0.08))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Restores the permission request")
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
            if !session.pendingAttachments.isEmpty {
                pendingStrip(session)
            }
            HStack(spacing: 12) {
                Menu {
                    Button { showingPhotoLibrary = true } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    Button { showingCamera = true } label: {
                        Label("Camera", systemImage: "camera")
                    }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                    Button { showingFileImporter = true } label: {
                        Label("File", systemImage: "doc")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Add attachment")
                .disabled(!session.canSend)

                TextField("", text: $draft, prompt:
                    Text(session.canSend
                         ? "Message \(session.profile.name)…"
                         : "Resolve permission request above")
                        .foregroundStyle(Theme.muted),
                    axis: .vertical)
                    .font(Theme.mono(15))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...6)
                    .disabled(!session.canSend)
                    .padding(.vertical, 10).padding(.horizontal, 16)
                    .background(Theme.plate,
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                if session.isRunning {
                    Button {
                        stopping = true
                        Task {
                            _ = await session.interrupt()
                            stopping = false
                        }
                    } label: {
                        Group {
                            if stopping { ProgressView().tint(Theme.paper) }
                            else { Image(systemName: "stop.fill") }
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.paper)
                        .frame(width: 40, height: 40)
                        .background(Theme.danger, in: Circle())
                    }
                    .accessibilityLabel("Stop Hermes")
                    .accessibilityIdentifier("stopButton")
                    .disabled(stopping)
                } else {
                    Button {
                        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard canSend(session) else { return }
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
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                defer { pickerItems = [] }
                for item in items {
                    guard let raw = try? await item.loadTransferable(type: Data.self),
                          let ui = UIImage(data: raw) else { continue }
                    await app.attachImage(profileName: session.profile.name,
                                          imageData: ui.jpeg(maxDim: 1600, quality: 0.8),
                                          thumbnail: ui.jpeg(maxDim: 240, quality: 0.7))
                }
            }
        }
        .photosPicker(isPresented: $showingPhotoLibrary, selection: $pickerItems,
                      maxSelectionCount: 4, matching: .images)
        .sheet(isPresented: $showingCamera) {
            CameraPicker { image in
                Task {
                    await app.attachImage(profileName: session.profile.name,
                                          imageData: image.jpeg(maxDim: 1600, quality: 0.8),
                                          thumbnail: image.jpeg(maxDim: 240, quality: 0.7),
                                          filename: "camera.jpg")
                }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.data]) { result in
            importFile(result, session: session)
        }
    }

    private func pendingStrip(_ session: ProfileSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(session.pendingAttachments) { a in
                    HStack(spacing: 8) {
                        if a.kind == .image, let img = UIImage(data: a.thumbnailJPEG) {
                            Image(uiImage: img).resizable().scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: "doc.fill")
                                .font(.title3).foregroundStyle(Theme.accent)
                                .frame(width: 40, height: 40)
                                .background(Theme.plate, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        Text(a.name).font(Theme.mono(11)).foregroundStyle(Theme.ink)
                            .lineLimit(1).frame(maxWidth: 120)
                        Button { session.removePendingAttachment(id: a.id) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                        }.accessibilityLabel("Remove \(a.name)")
                    }
                    .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
                    .background(Theme.plate.opacity(0.5), in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    private func importFile(_ result: Result<URL, Error>, session: ProfileSession) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { session.noteError("Couldn't open file: \(error)") }
            return
        }
        Task {
            do {
                let file = try await Task.detached {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                    return (try Data(contentsOf: url), url.lastPathComponent,
                            type?.preferredMIMEType ?? "application/octet-stream")
                }.value
                await app.attachFile(profileName: session.profile.name, data: file.0,
                                     filename: file.1, mime: file.2)
            } catch {
                session.noteError("Couldn't open \(url.lastPathComponent): \(error)")
            }
        }
    }

    private func canSend(_ session: ProfileSession) -> Bool {
        session.canSend &&
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
         || !session.pendingAttachments.isEmpty)   // attachment-only send allowed
    }
}

/// One attachment on a sent user message. Its own full-screen state so several
/// images in one message each open independently (§4 multi-attachment).
private struct UserAttachmentBubble: View {
    let attachment: Message.Attachment
    @State private var showFull = false

    var body: some View {
        if attachment.kind == .image, let img = UIImage(data: attachment.thumbnailJPEG) {
            Image(uiImage: img).resizable().scaledToFill()
                .frame(maxWidth: 200, maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onTapGesture { showFull = true }
                .accessibilityLabel("Attached image \(attachment.name). Tap to view full screen.")
                .fullScreenCover(isPresented: $showFull) {
                    ImageViewer(data: attachment.thumbnailJPEG)
                }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let count = attachment.byteCount {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file))
                            .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(12)
            .background(Theme.plate, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct MessageRow: View {
    let message: SpectraCore.Message
    let session: ProfileSession
    @Binding var collapsedApprovalID: String?

    var body: some View {
        switch message.kind {
        case .toolActivity(let activity):
            ToolActivityRow(activity: activity)

        case .status:
            HStack(spacing: 8) {
                Rectangle().fill(Theme.hairline).frame(width: 2)
                Text(message.text)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .approval(let event):
            approvalRow(event)

        case .clarification(let event):
            clarificationRow(event)

        case .error(let error):
            EventReceipt(icon: "xmark.octagon.fill", title: "Error", detail: error.text,
                         tint: Theme.danger, timestamp: error.at)

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
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(message.attachments) { a in
                        UserAttachmentBubble(attachment: a)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(Theme.mono(14))
                            .foregroundStyle(Theme.paper)
                            .padding(.vertical, 10).padding(.horizontal, 14)
                            .background(Theme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                // Agent: plain mono (spec §9), thin accent rule for identity.
                HStack(alignment: .top, spacing: 12) {
                    Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 10) {
                        if !message.text.isEmpty {
                            if message.id == session.streamingMessageID {
                                // Live stream: plain text, no per-token markdown reparse.
                                Text(message.text)
                                    .font(Theme.mono(14))
                                    .foregroundStyle(Theme.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                MarkdownText(text: message.text)   // §9: rendered markdown
                            }
                        }
                        ForEach(message.media) { m in     // §9 receive-side
                            AgentMediaView(media: m)
                        }
                    }
                    Spacer(minLength: 24)
                }
            }
        }
    }

    @ViewBuilder private func approvalRow(_ event: ApprovalEvent) -> some View {
        switch event.state {
        case .pending:
            if session.pendingApproval?.id == event.id,
               collapsedApprovalID != event.id {
                ApprovalCard(approval: event.request, session: session) {
                    collapsedApprovalID = event.id
                }
            } else if session.pendingApproval?.id != event.id {
                EventReceipt(icon: "clock.badge.exclamationmark", title: "Permission expired",
                             detail: event.request.command, tint: Theme.muted)
            }
        case .resolved(let choice, let at):
            if choice == "deny" {
                EventReceipt(icon: "xmark.seal.fill", title: "Permission denied",
                             detail: event.request.command, tint: Theme.danger, timestamp: at)
            } else {
                EventReceipt(icon: "checkmark.seal.fill",
                             title: "Permission granted · \(choiceLabel(choice))",
                             detail: event.request.command, tint: Theme.ok, timestamp: at)
            }
        case .expired:
            EventReceipt(icon: "clock.badge.exclamationmark", title: "Permission expired",
                         detail: event.request.command, tint: Theme.muted)
        }
    }

    @ViewBuilder private func clarificationRow(_ event: ClarificationEvent) -> some View {
        switch event.state {
        case .pending:
            if session.pendingClarify?.id == event.id {
                ClarifyCard(event: event, session: session)
            } else {
                EventReceipt(icon: "clock.badge.exclamationmark", title: "Clarification expired",
                             detail: event.request.questions.first?.question ?? "",
                             tint: Theme.muted)
            }
        case .answered(let at):
            EventReceipt(icon: "checkmark.circle.fill", title: "Answered · \(answerSummary(event))",
                         detail: event.request.questions.first?.question ?? "",
                         tint: Theme.ok, timestamp: at)
        case .expired:
            EventReceipt(icon: "clock.badge.exclamationmark", title: "Clarification expired",
                         detail: event.request.questions.first?.question ?? "",
                         tint: Theme.muted)
        }
    }

    private func choiceLabel(_ choice: String) -> String {
        switch choice {
        case "once": return "Once"
        case "session": return "This session"
        case "always": return "Always"
        case "deny": return "Denied"
        default: return choice.capitalized
        }
    }

    private func answerSummary(_ event: ClarificationEvent) -> String {
        if event.answers.count == 1, let answer = event.answers.values.first, !answer.isEmpty {
            return answer
        }
        return "\(event.answers.count) answers"
    }
}

private struct EventReceipt: View {
    let icon: String
    let title: String
    let detail: String
    let tint: Color
    var timestamp: Date?

    init(icon: String, title: String, detail: String, tint: Color,
         timestamp: Date? = nil) {
        self.icon = icon; self.title = title; self.detail = detail
        self.tint = tint; self.timestamp = timestamp
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Eyebrow(title, color: tint)
                    Spacer()
                    if let timestamp {
                        Text(timestamp.formatted(date: .omitted, time: .shortened))
                            .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    }
                }
                if !detail.isEmpty {
                    Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(3)
                }
            }
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }
}

/// Quiet, expandable activity derived from structured tool lifecycle events.
struct ToolActivityRow: View {
    let activity: ToolActivity
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 12 : 0) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color)
                        .frame(width: 14)
                    Text(title)
                        .font(Theme.mono(12, .medium))
                        .foregroundStyle(Theme.muted)
                    if !activity.context.isEmpty {
                        Text("· \(activity.context)")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.muted.opacity(0.8))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.muted.opacity(0.65))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)\(activity.context.isEmpty ? "" : ", \(activity.context)")")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double tap to \(expanded ? "collapse" : "show details")")

            if expanded { details }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let input = activity.input {
                detailText(input)
            }
            if activity.duration != nil || activity.exitCode != nil {
                HStack(spacing: 24) {
                    if let duration = activity.duration {
                        metric("Duration", String(format: "%.1fs", duration))
                    }
                    if let exitCode = activity.exitCode {
                        metric("Exit code", "\(exitCode)")
                    }
                }
            }
            if let output = activity.output {
                detailText(output)
            }
            if let risk = activity.risk {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow("\(risk) output risk", color: Theme.danger)
                    ForEach(activity.findings, id: \.self) { finding in
                        Text(finding).font(Theme.mono(11)).foregroundStyle(Theme.danger)
                    }
                }
            }
        }
        .padding(.leading, 23)
    }

    private func detailText(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .padding(10)
        .background(Theme.plate, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow(label)
            Text(value).font(Theme.mono(11)).foregroundStyle(Theme.ink)
        }
    }

    private var title: String {
        let name = activity.toolName.lowercased()
        if name.contains("web_search") || name == "search" || name.contains("browse") {
            return phrase(running: "Searching the web", success: "Searched the web", failed: "Web search failed")
        }
        if name.contains("read") {
            let file = activity.input.map { ($0 as NSString).lastPathComponent }
            return phrase(running: "Reading\(file.map { " \($0)" } ?? "")",
                          success: "Read\(file.map { " \($0)" } ?? "")",
                          failed: "Read failed")
        }
        if name.contains("edit") || name.contains("write") || name.contains("patch") {
            let file = activity.input.flatMap { input in
                input.contains("\n") || input.hasPrefix("{") ? nil : (input as NSString).lastPathComponent
            }
            return phrase(running: "Editing\(file.map { " \($0)" } ?? " files")",
                          success: "Edited\(file.map { " \($0)" } ?? " files")",
                          failed: "Edit failed")
        }
        if name.contains("terminal") || name.contains("command") || name.contains("exec") {
            return phrase(running: "Running command", success: "Ran command", failed: "Command failed")
        }
        if name.contains("test") {
            return phrase(running: "Running tests", success: "Tests passed", failed: "Tests failed")
        }
        let readable = activity.toolName.replacingOccurrences(of: "_", with: " ")
        return phrase(running: "Running \(readable)", success: "Ran \(readable)",
                      failed: "\(readable.capitalized) failed")
    }

    private func phrase(running: String, success: String, failed: String) -> String {
        switch activity.status {
        case .running: return running
        case .succeeded: return success
        case .failed: return failed
        }
    }

    private var icon: String {
        switch activity.status {
        case .running: return "chevron.right"
        case .succeeded: return "checkmark"
        case .failed: return "xmark"
        }
    }

    private var color: Color {
        switch activity.status {
        case .running: return Theme.muted
        case .succeeded: return Theme.ok
        case .failed: return Theme.danger
        }
    }
}

/// Hard-block approval (spec §8): elevated, danger-edged, dynamic choices.
struct ApprovalCard: View {
    let approval: ApprovalRequest
    let session: ProfileSession
    let onCollapse: () -> Void
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.danger)
                Eyebrow("Approval required", color: Theme.danger)
                Spacer()
                Button(action: onCollapse) {
                    Image(systemName: "chevron.down")
                        .font(.caption).foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse permission request")
            }
            Text(approval.command)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.ink)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Theme.plate, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                ForEach(approval.choices, id: \.self) { choice in
                    Button(choiceLabel(choice)) {
                        isSubmitting = true
                        Task {
                            let resolved = await session.resolveApproval(choice: choice)
                            if !resolved { isSubmitting = false }
                        }
                    }
                        .buttonStyle(OutlineButton(tint: choice == "deny" ? Theme.danger : Theme.accent))
                        .disabled(isSubmitting)
                }
            }
            if isSubmitting {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Sending decision…").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Theme.danger.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
    }

    private func choiceLabel(_ choice: String) -> String {
        switch choice {
        case "once": return "Allow once"
        case "session": return "This session"
        case "always": return "Always allow"
        case "deny": return "Deny"
        default: return choice
        }
    }
}

/// Soft clarify (spec §8): choice rows or free text; ignorable.
struct ClarifyCard: View {
    let event: ClarificationEvent
    let session: ProfileSession
    @State private var freeText: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var submitting: Set<String> = []

    private var clarify: ClarifyRequest { event.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Clarify", color: Theme.accent)
            ForEach(clarify.questions) { q in
                VStack(alignment: .leading, spacing: 10) {
                    Text(q.question)
                        .font(Theme.serif(17))
                        .foregroundStyle(Theme.ink)
                    if let answer = event.answers[q.id] {
                        Label(answer, systemImage: "checkmark.circle.fill")
                            .font(Theme.mono(12)).foregroundStyle(Theme.ok)
                    } else if q.choices.isEmpty {
                        HStack(spacing: 10) {
                            TextField("", text: textBinding(for: q.id), prompt:
                                Text("Answer…").foregroundStyle(Theme.muted))
                                .font(Theme.mono(14))
                                .padding(.vertical, 9).padding(.horizontal, 12)
                                .background(Theme.plate, in: Capsule())
                            Button("Send") {
                                submit(q, answer: freeText[q.id, default: ""])
                            }
                            .buttonStyle(OutlineButton(tint: Theme.accent))
                            .disabled(freeText[q.id, default: ""].isEmpty || submitting.contains(q.id))
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach(q.choices, id: \.self) { choice in
                                Button {
                                    if q.multiSelect {
                                        toggle(choice, for: q.id)
                                    } else {
                                        submit(q, answer: choice)
                                    }
                                } label: {
                                    HStack {
                                        Text(choice).font(Theme.mono(13)).foregroundStyle(Theme.ink)
                                        Spacer()
                                        Image(systemName: q.multiSelect
                                              ? (selections[q.id, default: []].contains(choice)
                                                 ? "checkmark.square.fill" : "square")
                                              : "arrow.up.right")
                                            .font(.caption).foregroundStyle(q.multiSelect ? Theme.accent : Theme.muted)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(.vertical, 11).padding(.horizontal, 14)
                                    .background(Theme.plate, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(submitting.contains(q.id))
                            }
                            if q.multiSelect {
                                Button("Send selections") {
                                    let selected = q.choices.filter {
                                        selections[q.id, default: []].contains($0)
                                    }
                                    let data = try? JSONEncoder().encode(selected)
                                    submit(q, answer: data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                                }
                                .buttonStyle(OutlineButton(tint: Theme.accent))
                                .disabled(selections[q.id, default: []].isEmpty || submitting.contains(q.id))
                            }
                        }
                    }
                }
            }
            if !submitting.isEmpty {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Sending answer…").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func textBinding(for id: String) -> Binding<String> {
        Binding(get: { freeText[id, default: ""] }, set: { freeText[id] = $0 })
    }

    private func toggle(_ choice: String, for id: String) {
        if selections[id, default: []].contains(choice) {
            selections[id]?.remove(choice)
        } else {
            selections[id, default: []].insert(choice)
        }
    }

    private func submit(_ question: ClarifyRequest.Question, answer: String) {
        submitting.insert(question.id)
        Task {
            let accepted = await session.answerClarify(questionID: question.id, answer: answer)
            if !accepted { submitting.remove(question.id) }
        }
    }
}

/// Full-screen image viewer (§9: tap thumbnail → view full-screen). Renders the
/// locally-held JPEG; the server-side original isn't fetchable over the wire.
private struct ImageViewer: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFit().ignoresSafeArea()
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title).foregroundStyle(.white.opacity(0.9))
                    .padding()
            }.accessibilityLabel("Close")
        }
    }
}

/// One piece of agent-sent media (§9 receive-side): images render inline
/// (tap → full screen), non-image files as a share card. Bytes are fetched
/// lazily via AppState (cached) — see MediaFetch for the endpoints.
private struct AgentMediaView: View {
    let media: SpectraCore.Message.ReceivedMedia
    @Environment(AppState.self) private var app
    @State private var data: Data?
    @State private var failed = false
    @State private var showFull = false
    @State private var shareURL: URL?

    var body: some View {
        if media.isImage {
            imageBody
                .task(id: media.id) {
                    data = await app.fetchAgentMedia(media)
                    failed = data == nil
                }
        } else {
            fileCard
        }
    }

    @ViewBuilder private var imageBody: some View {
        if let data, let img = UIImage(data: data) {
            VStack(alignment: .leading, spacing: 4) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture { showFull = true }
                    .accessibilityLabel("Image \(media.name). Tap to view full screen.")
                    .fullScreenCover(isPresented: $showFull) { ImageViewer(data: data) }
                if let cap = media.caption {
                    Text(cap).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
        } else if failed {
            placeholder(icon: "photo", text: media.name)
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.hairline.opacity(0.4))
                .frame(width: 160, height: 120)
                .overlay(ProgressView())
                .accessibilityLabel("Loading image \(media.name)")
        }
    }

    private var fileCard: some View {
        Button {
            Task {
                if data == nil { data = await app.fetchAgentMedia(media) }
                guard let data else { failed = true; return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(media.name)
                try? data.write(to: url)
                shareURL = url
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.name).font(Theme.mono(13)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let cap = media.caption {
                        Text(cap).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.muted)
            }
            .padding(12)
            .background(Theme.hairline.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("File \(media.name). Tap to open or share.")
        .sheet(item: $shareURL) { url in ShareSheet(url: url) }
    }

    private func placeholder(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Theme.muted)
            Text(text).font(Theme.mono(11)).foregroundStyle(Theme.muted)
        }
        .padding(10)
        .background(Theme.hairline.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Minimal UIKit share sheet bridge for file media (§9). ponytail: SwiftUI has
/// no native activity-sheet, so one small representable.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Native camera bridge; SwiftUI still has no camera equivalent to PhotosPicker.
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onImage(image) }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

private extension UIImage {
    /// Downscale so the longest side ≤ maxDim, then JPEG-encode. Keeps uploads
    /// and persisted thumbnails small. ponytail: nearest-neighbour-free UIKit resize.
    func jpeg(maxDim: CGFloat, quality: CGFloat) -> Data {
        let longest = max(size.width, size.height)
        let scale = longest > maxDim ? maxDim / longest : 1
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let out = UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return out.jpegData(compressionQuality: quality) ?? Data()
    }
}
