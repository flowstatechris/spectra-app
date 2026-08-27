import Foundation

/// Parses agent-sent media out of a message's text (§9 receive-side). The wire
/// is entirely in-band — verified against Hermes: agents emit `MEDIA:<path>`
/// tags and markdown `![alt](url)` inside their reply text; there is no separate
/// event or display_metadata. We strip those tokens and surface them as
/// structured `ReceivedMedia` so the text renders clean and the media as cards.
///
/// - `MEDIA:<path> [caption]` → server-local file. Image extension → fetched via
///   GET /api/media?path= ; anything else → a file card (GET /api/files/download).
/// - `![alt](http…)` → remote image, fetched directly.
///
/// `::preview file.html` (live-HTML directive) is intentionally not handled —
/// spec §9 has no live-HTML surface in v1; it stays as plain text.
public enum AgentMedia {
    /// Extensions /api/media serves AND UIImage can actually render inline.
    /// svg/ico are server-served but not UIImage-renderable → treated as files.
    static let inlineImageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic"]

    // MEDIA:<non-space path><optional space + caption to end of line>
    private static let mediaRE = try! NSRegularExpression(
        pattern: #"MEDIA:\s*(\S+)([^\n]*)"#)
    // markdown image: ![alt](url)
    private static let mdImageRE = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#)

    public static func parse(_ text: String) -> (clean: String, media: [Message.ReceivedMedia]) {
        var media: [Message.ReceivedMedia] = []
        let ns = text as NSString
        var cuts: [NSRange] = []   // ranges to remove from the display text

        for m in mediaRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1))
            let caption = ns.substring(with: m.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
            let ext = (path as NSString).pathExtension.lowercased()
            let name = (path as NSString).lastPathComponent
            let slot: Message.ReceivedMedia.Slot =
                inlineImageExts.contains(ext) ? .serverImage(path) : .serverFile(path)
            media.append(.init(slot: slot, name: name,
                               caption: caption.isEmpty ? nil : caption))
            // A MEDIA tag owns its whole line — swallow its trailing newline so
            // removing it doesn't leave a blank line (but keep real paragraph
            // breaks in surrounding prose intact).
            var r = m.range
            let end = r.location + r.length
            if end < ns.length, ns.substring(with: NSRange(location: end, length: 1)) == "\n" {
                r.length += 1
            }
            cuts.append(r)
        }

        for m in mdImageRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let alt = ns.substring(with: m.range(at: 1))
            let raw = ns.substring(with: m.range(at: 2))
            guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true else { continue }
            let name = alt.isEmpty ? url.lastPathComponent : alt
            media.append(.init(slot: .remoteURL(url), name: name, caption: nil))
            cuts.append(m.range)
        }

        // Remove matched tokens back-to-front so ranges stay valid.
        var out = text
        for r in cuts.sorted(by: { $0.location > $1.location }) {
            let s = out.index(out.startIndex, offsetBy: r.location)
            let e = out.index(s, offsetBy: r.length)
            out.replaceSubrange(s..<e, with: "")
        }
        // Collapse the blank lines / dangling spaces left behind.
        let clean = out
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, media)
    }
}
