import Foundation

/// Incremental sentence cutter for agent text deltas.
///
/// Port of Hermes' `SentenceChunker` (`tools/tts_streaming.py:89`) so voice on
/// the phone cuts speech exactly where the desktop surfaces do. Three behaviours
/// carry over verbatim, and each one exists for a reason:
///
///  - **Boundary** is whitespace *after* `.!?`, or a blank line. Not `.` alone —
///    that fires inside "v1.8" and every filename.
///  - **Fragments shorter than `minLength` merge into the following sentence**,
///    so "Ha!" rides along instead of being synthesised as its own clipped
///    120ms utterance.
///  - **`<think>` blocks are stripped even when split across deltas**: an open
///    `<think` with no close holds the whole buffer until the closing tag
///    arrives, because the reasoning text must never reach the speaker.
///
/// The caller drives `flush()` on end-of-turn *and* on producer idle — a
/// narration line spoken before a long tool call shouldn't wait for the turn
/// to end. `hasPendingText` is how an idle timer knows there's anything to drain.
public struct SentenceChunker {
    public let minLength: Int
    private var buf = ""

    public init(minLength: Int = 20) { self.minLength = minLength }

    /// True when the buffer holds text that only `flush()` will release.
    public var hasPendingText: Bool {
        !Self.stripThink(buf).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // `(?<=[.!?])\s` == Python's `(?<=[.!?])(?:\s|\n)` — `\s` already covers \n.
    private static let boundary = try! NSRegularExpression(pattern: "(?<=[.!?])\\s|\\n\\n")
    private static let thinkBlock = try! NSRegularExpression(
        pattern: "<think[\\s>].*?</think>", options: [.dotMatchesLineSeparators])

    /// Absorb `delta`; return every sentence now complete enough to speak.
    public mutating func feed(_ delta: String) -> [String] {
        buf = Self.stripThink(buf + delta)
        // Open think tag: the closing tag may be in the next delta. Hold everything.
        if buf.contains("<think"), !buf.contains("</think>") { return [] }

        var out: [String] = []
        var start = 0      // boundaries before this left too short a head; skip them
        while true {
            let ns = buf as NSString
            guard start < ns.length else { break }
            // .withTransparentBounds so the lookbehind can still see the character
            // before `start` — Python's search(pos:) does, and without this a
            // boundary right at the resume point would be missed.
            guard let m = Self.boundary.firstMatch(
                in: buf, options: [.withTransparentBounds],
                range: NSRange(location: start, length: ns.length - start))
            else { break }

            let end = m.range.location + m.range.length
            let head = ns.substring(to: end)
            if head.trimmingCharacters(in: .whitespacesAndNewlines).count < minLength {
                start = end
                continue
            }
            out.append(head)
            buf = ns.substring(from: end)
            start = 0
        }
        return out
    }

    /// Drain the tail — end of turn, or a producer that has gone quiet.
    public mutating func flush() -> [String] {
        let tail = Self.stripThink(buf).trimmingCharacters(in: .whitespacesAndNewlines)
        buf = ""
        return tail.isEmpty ? [] : [tail]
    }

    private static func stripThink(_ s: String) -> String {
        thinkBlock.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
    }
}
