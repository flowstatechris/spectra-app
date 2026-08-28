import SwiftUI
import SpectraCore

/// Renders agent markdown (spec §9, upgraded past v1's plain-mono). Block
/// structure comes from Markdown.blocks; inline syntax (bold/italic/`code`/
/// links) is rendered natively by SwiftUI's AttributedString markdown.
struct MarkdownText: View {
    let text: String
    // Parse once per distinct text (via .task(id:)), not on every body pass —
    // sibling updates (new tool rows, other streaming) would otherwise reparse
    // every rendered message each event.
    @State private var blocks: [Markdown.Block] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .task(id: text) { blocks = Markdown.blocks(text) }
    }

    @ViewBuilder private func view(for block: Markdown.Block) -> some View {
        switch block {
        case .paragraph(let s):
            Text(inline(s))
                .font(Theme.mono(14)).foregroundStyle(Theme.ink)
                .textSelection(.enabled)

        case .heading(let level, let s):
            Text(inline(s))
                .font(Theme.serif(headingSize(level)))
                .foregroundStyle(Theme.ink)
                .padding(.top, 2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    marker("•", item)
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    marker("\(idx + 1).", item)
                }
            }

        case .code(let lang, let code):
            CodeBlock(language: lang, code: code)

        case .quote(let s):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 2)
                Text(inline(s)).font(Theme.mono(14)).foregroundStyle(Theme.muted)
            }

        case .rule:
            Hairline().padding(.vertical, 2)
        }
    }

    private func marker(_ mark: String, _ item: String) -> some View {  // list row
        HStack(alignment: .top, spacing: 8) {
            Text(mark).font(Theme.mono(14)).foregroundStyle(Theme.muted)
                .frame(minWidth: 16, alignment: .trailing)
            Text(inline(item)).font(Theme.mono(14)).foregroundStyle(Theme.ink)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level { case 1: return 22; case 2: return 19; case 3: return 17; default: return 15 }
    }

    /// Native inline markdown; preserves whitespace, degrades to plain on parse failure.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Fenced code block: monospace on a surface card, horizontally scrollable,
/// with a language label and a copy button (checkmark on tap).
private struct CodeBlock: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let language { Eyebrow(language, color: Theme.muted) }
                Spacer(minLength: 8)
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(copied ? Theme.ok : Theme.muted)
                }
                .accessibilityLabel(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 12).padding(.top, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(Theme.mono(12.5)).foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
