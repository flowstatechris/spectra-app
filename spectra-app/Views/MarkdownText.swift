import SwiftUI
import SpectraCore

/// Renders agent markdown (spec §9, upgraded past v1's plain-mono). Block
/// structure comes from Markdown.blocks; inline syntax (bold/italic/`code`/
/// links) is rendered natively by SwiftUI's AttributedString markdown.
struct MarkdownText: View {
    let text: String
    private var blocks: [Markdown.Block] { Markdown.blocks(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
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
            VStack(alignment: .leading, spacing: 4) {
                if let lang { Eyebrow(lang, color: Theme.muted) }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code).font(Theme.mono(12.5)).foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))

        case .quote(let s):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Theme.accent.opacity(0.5)).frame(width: 2)
                Text(inline(s)).font(Theme.mono(14)).foregroundStyle(Theme.muted)
            }

        case .rule:
            Hairline().padding(.vertical, 2)
        }
    }

    private func marker(_ mark: String, _ item: String) -> some View {
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
