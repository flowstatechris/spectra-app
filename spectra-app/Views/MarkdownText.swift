import SwiftUI
import SpectraCore

/// A markdown block with its inline syntax already parsed to AttributedString.
/// Everything expensive (block split + AttributedString(markdown:)) is computed
/// once, off the main thread, so rendering — and re-rendering as LazyVStack rows
/// scroll in and out — never parses on the main actor.
enum RenderedBlock: Equatable, Sendable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case bullets([AttributedString])
    case numbered([AttributedString])
    case code(language: String?, code: String)
    case quote(AttributedString)
    case rule
    case table(headers: [AttributedString],
               alignments: [Markdown.TableAlignment],
               rows: [[AttributedString]])

    /// Native inline markdown; preserves whitespace, degrades to plain on failure.
    nonisolated private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    /// Pure, main-thread-free: block structure + inline parse for a whole message.
    nonisolated static func render(_ text: String) -> [RenderedBlock] {
        Markdown.blocks(text).map { block in
            switch block {
            case .paragraph(let s):        return .paragraph(inline(s))
            case .heading(let l, let s):   return .heading(level: l, text: inline(s))
            case .bullets(let items):      return .bullets(items.map(inline))
            case .numbered(let items):     return .numbered(items.map(inline))
            case .code(let lang, let code):return .code(language: lang, code: code)
            case .quote(let s):            return .quote(inline(s))
            case .rule:                    return .rule
            case .table(let headers, let alignments, let rows):
                return .table(headers: headers.map(inline),
                              alignments: alignments,
                              rows: rows.map { $0.map(inline) })
            }
        }
    }
}

/// Bounded cache of rendered messages, so a row scrolling back into view reuses
/// its parse instead of recomputing. Main-actor isolated; the parse itself runs
/// off-main and only the lookup/store touch this.
@MainActor
private final class MarkdownCache {
    static let shared = MarkdownCache()
    private final class Box { let blocks: [RenderedBlock]; init(_ b: [RenderedBlock]) { blocks = b } }
    private let cache = NSCache<NSString, Box>()
    init() { cache.countLimit = 200 }
    func get(_ key: String) -> [RenderedBlock]? { cache.object(forKey: key as NSString)?.blocks }
    func set(_ key: String, _ v: [RenderedBlock]) { cache.setObject(Box(v), forKey: key as NSString) }
}

/// Renders agent markdown (spec §9). Block structure from Markdown.blocks, inline
/// syntax pre-parsed to AttributedString — both off the main thread (see
/// RenderedBlock.render) and cached, so scrolling through long threads is smooth.
struct MarkdownText: View {
    let text: String
    @State private var blocks: [RenderedBlock] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .task(id: text) {
            if let cached = MarkdownCache.shared.get(text) { blocks = cached; return }
            let rendered = await Task.detached { RenderedBlock.render(text) }.value
            MarkdownCache.shared.set(text, rendered)
            blocks = rendered
        }
    }

    @ViewBuilder private func view(for block: RenderedBlock) -> some View {
        switch block {
        case .paragraph(let s):
            Text(s)
                .font(Theme.mono(14)).foregroundStyle(Theme.ink)
                .textSelection(.enabled)

        case .heading(let level, let s):
            Text(s)
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
                Text(s).font(Theme.mono(14)).foregroundStyle(Theme.muted)
            }

        case .rule:
            Hairline().padding(.vertical, 2)

        case .table(let headers, let alignments, let rows):
            MarkdownTable(headers: headers, alignments: alignments, rows: rows)
        }
    }

    private func marker(_ mark: String, _ item: AttributedString) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(mark).font(Theme.mono(14)).foregroundStyle(Theme.muted)
                .frame(minWidth: 16, alignment: .trailing)
            Text(item).font(Theme.mono(14)).foregroundStyle(Theme.ink)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level { case 1: return 22; case 2: return 19; case 3: return 17; default: return 15 }
    }
}

/// A GFM table as a real grid. Kept as a grid rather than the card-per-row
/// treatment a records list would use: the columns here are whatever the agent
/// emitted, so there is no domain shape to reformat them into. Wide tables
/// scroll horizontally inside their own card — the same containment CodeBlock
/// uses — so the thread itself never scrolls sideways.
private struct MarkdownTable: View {
    let headers: [AttributedString]
    let alignments: [Markdown.TableAlignment]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { column, cell in
                        Text(cell)
                            .font(Theme.mono(12.5, .semibold))
                            .foregroundStyle(Theme.ink)
                            .gridColumnAlignment(alignment(column))
                    }
                }
                Divider().overlay(Theme.hairline)
                    .gridCellColumns(max(headers.count, 1))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(Theme.mono(12.5, .regular))
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(12)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// Column alignment from the separator row, defaulting to leading for a
    /// ragged table the parser padded out.
    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
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
