import SwiftUI
import PhotosUI
import SpectraCore
import ThinkingOrbsKit

/// Chat tab (spec §8): orb header, editorial thread, approval/clarify cards,
/// pinned input bar.
struct ChatView: View {
    @Environment(AppState.self) private var app
    @State private var draft = ""
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let error = app.connectionError {
                offlineBanner(error)
            }
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
            if let a = session.pendingAttachment {
                pendingStrip(a, session)
            }
            HStack(spacing: 12) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Attach image")
                .disabled(!session.canSend)

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
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                defer { pickerItem = nil }
                guard let raw = try? await item.loadTransferable(type: Data.self),
                      let ui = UIImage(data: raw) else { return }
                await app.attachImage(profileName: session.profile.name,
                                      imageData: ui.jpeg(maxDim: 1600, quality: 0.8),
                                      thumbnail: ui.jpeg(maxDim: 240, quality: 0.7))
            }
        }
    }

    private func pendingStrip(_ a: Message.Attachment, _ session: ProfileSession) -> some View {
        HStack(spacing: 10) {
            if let img = UIImage(data: a.thumbnailJPEG) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(a.name).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer()
            Button { session.setPendingAttachment(nil) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
            }.accessibilityLabel("Remove attachment")
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private func canSend(_ session: ProfileSession) -> Bool {
        session.canSend &&
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
         || session.pendingAttachment != nil)   // image-only send allowed
    }
}

struct MessageRow: View {
    let message: SpectraCore.Message
    @State private var showFullImage = false

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
                VStack(alignment: .trailing, spacing: 6) {
                    if let a = message.attachment, let img = UIImage(data: a.thumbnailJPEG) {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(maxWidth: 200, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .onTapGesture { showFullImage = true }
                            .accessibilityLabel("Attached image \(a.name). Tap to view full screen.")
                            .fullScreenCover(isPresented: $showFullImage) {
                                ImageViewer(data: a.thumbnailJPEG)
                            }
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
                            Text(message.text)
                                .font(Theme.mono(14))
                                .foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
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
