import Foundation

/// Block-level markdown split for agent messages. SwiftUI's Text already does
/// inline markdown (bold/italic/`code`/links) but not block structure, so this
/// groups lines into blocks the view renders; inline syntax is left in each
/// block's string and handled natively at render time.
///
/// Covers the 90% agents actually emit: headings, bullet/numbered lists, fenced
/// code, blockquotes, rules, GFM pipe tables, paragraphs. Nested lists degrade
/// to paragraphs (ponytail: add if agents start leaning on them).
public enum Markdown {
    /// Per-column alignment from a table's `:---:` separator row.
    public enum TableAlignment: Equatable, Sendable { case leading, center, trailing }

    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullets([String])
        case numbered([String])
        case code(language: String?, code: String)
        case quote(String)
        case rule
        /// GFM pipe table. `alignments` holds one entry per column; every data
        /// row is padded or truncated to the header's column count.
        case table(headers: [String], alignments: [TableAlignment], rows: [[String]])
    }

    public static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        func flushParagraph(_ buf: inout [String]) {
            if !buf.isEmpty { out.append(.paragraph(buf.joined(separator: "\n"))); buf.removeAll() }
        }

        var para: [String] = []
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)

            // Fenced code — verbatim until the closing fence (or EOF).
            if t.hasPrefix("```") {
                flushParagraph(&para)
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                i += 1  // consume closing fence
                out.append(.code(language: lang.isEmpty ? nil : lang,
                                 code: body.joined(separator: "\n")))
                continue
            }

            if t.isEmpty { flushParagraph(&para); i += 1; continue }

            if t == "---" || t == "***" || t == "___" {
                flushParagraph(&para); out.append(.rule); i += 1; continue
            }

            if let h = heading(t) {
                flushParagraph(&para); out.append(h); i += 1; continue
            }

            if isBullet(t) {
                flushParagraph(&para)
                var items: [String] = []
                while i < lines.count {
                    let s = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isBullet(s) else { break }
                    items.append(String(s.drop(while: { $0 == "-" || $0 == "*" || $0 == "+" }))
                        .trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.bullets(items)); continue
            }

            if numberedPrefixLen(t) != nil {
                flushParagraph(&para)
                var items: [String] = []
                while i < lines.count {
                    let s = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let n = numberedPrefixLen(s) else { break }
                    items.append(String(s.dropFirst(n)).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.numbered(items)); continue
            }

            if t.hasPrefix(">") {
                flushParagraph(&para)
                var quoted: [String] = []
                while i < lines.count {
                    let s = lines[i].trimmingCharacters(in: .whitespaces)
                    guard s.hasPrefix(">") else { break }
                    quoted.append(String(s.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out.append(.quote(quoted.joined(separator: "\n"))); continue
            }

            // A pipe table, but only when the separator row confirms it — an
            // ordinary sentence containing a pipe has to stay prose.
            if let (block, consumed) = parseTable(lines, at: i) {
                flushParagraph(&para)
                out.append(block)
                i += consumed
                continue
            }

            para.append(line); i += 1
        }
        flushParagraph(&para)
        return out
    }

    private static func heading(_ t: String) -> Block? {
        var level = 0
        for c in t { if c == "#" { level += 1 } else { break } }
        guard (1...6).contains(level), t.count > level,
              t[t.index(t.startIndex, offsetBy: level)] == " " else { return nil }
        return .heading(level: level,
                        text: String(t.dropFirst(level)).trimmingCharacters(in: .whitespaces))
    }

    private static func isBullet(_ t: String) -> Bool {
        (t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ "))
    }

    // Length of a "12. " / "3) " numbered-list prefix, or nil.
    private static func numberedPrefixLen(_ t: String) -> Int? {
        var digits = 0
        for c in t { if c.isNumber { digits += 1 } else { break } }
        guard digits > 0, t.count > digits + 1 else { return nil }
        let after = t[t.index(t.startIndex, offsetBy: digits)]
        let sep = t[t.index(t.startIndex, offsetBy: digits + 1)]
        guard (after == "." || after == ")"), sep == " " else { return nil }
        return digits + 2
    }

    // MARK: Tables

    /// A GFM pipe table starting at `start`: a header row, a separator row, then
    /// data rows until the first line without a pipe. Returns the block and how
    /// many lines it consumed, or nil if this isn't a table.
    ///
    /// The separator is what makes it a table — without that requirement any
    /// prose line containing a `|` would open one.
    private static func parseTable(_ lines: [String], at start: Int) -> (Block, Int)? {
        guard start + 1 < lines.count, lines[start].contains("|"),
              let alignments = separatorRow(lines[start + 1]) else { return nil }
        let headers = cells(lines[start])
        guard headers.count == alignments.count else { return nil }

        var rows: [[String]] = []
        var i = start + 2
        while i < lines.count, lines[i].contains("|") {
            var row = cells(lines[i])
            if row.count < headers.count {
                row += Array(repeating: "", count: headers.count - row.count)
            }
            rows.append(Array(row.prefix(headers.count)))
            i += 1
        }
        return (.table(headers: headers, alignments: alignments, rows: rows), i - start)
    }

    /// One alignment per column if every cell is a `---` / `:--` / `--:` / `:-:`
    /// run, else nil (meaning the line above it wasn't a table header).
    private static func separatorRow(_ line: String) -> [TableAlignment]? {
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        var out: [TableAlignment] = []
        for part in parts {
            guard part.contains("-"),
                  part.allSatisfy({ $0 == "-" || $0 == ":" }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true):  out.append(.center)
            case (false, true): out.append(.trailing)
            default:            out.append(.leading)
            }
        }
        return out
    }

    /// Split a pipe row into trimmed cells. The outer pipes are optional (GFM
    /// allows `a | b` as well as `| a | b |`), and `\|` is a literal pipe.
    private static func cells(_ line: String) -> [String] {
        var out: [String] = []
        var cell = ""
        var escaped = false
        for c in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                if c != "|" { cell.append("\\") }   // only `\|` is an escape
                cell.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "|" {
                out.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(c)
            }
        }
        if escaped { cell.append("\\") }
        out.append(cell.trimmingCharacters(in: .whitespaces))
        // The optional outer pipes leave an empty cell at each end.
        if out.count > 1, out.first == "" { out.removeFirst() }
        if out.count > 1, out.last == "" { out.removeLast() }
        return out
    }
}
