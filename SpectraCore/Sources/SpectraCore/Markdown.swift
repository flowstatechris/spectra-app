import Foundation

/// Block-level markdown split for agent messages. SwiftUI's Text already does
/// inline markdown (bold/italic/`code`/links) but not block structure, so this
/// groups lines into blocks the view renders; inline syntax is left in each
/// block's string and handled natively at render time.
///
/// Covers the 90% agents actually emit: headings, bullet/numbered lists, fenced
/// code, blockquotes, rules, paragraphs. Tables / nested lists degrade to
/// paragraphs (ponytail: add if agents start leaning on them).
public enum Markdown {
    public enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case bullets([String])
        case numbered([String])
        case code(language: String?, code: String)
        case quote(String)
        case rule
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
}
