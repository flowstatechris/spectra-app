import XCTest
@testable import SpectraCore

/// The chunker decides where synthesised speech is cut, so every rule here is
/// audible when it breaks: a missed boundary stalls audio to end-of-turn, a
/// spurious one clips mid-word, and a leaked `<think>` block speaks the model's
/// reasoning aloud. Mirrors Hermes' own cases (`tools/tts_streaming.py:89`).
final class SentenceChunkerTests: XCTestCase {

    func testCutsOnSentenceBoundary() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("The build is finished and green. "),
                       ["The build is finished and green. "])
    }

    func testHoldsIncompleteSentence() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("The build is finished"), [])
        XCTAssertTrue(c.hasPendingText)
        XCTAssertEqual(c.feed(" and green. "), ["The build is finished and green. "])
    }

    /// A bare period is not a boundary — "v1.8" and "main.swift" must not cut.
    func testDoesNotCutMidToken() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Released v1.8 from main.swift today"), [])
    }

    /// Short fragments merge forward instead of becoming their own tiny clip.
    func testShortFragmentMergesIntoFollowingSentence() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Ha! That took much longer than expected. "),
                       ["Ha! That took much longer than expected. "])
    }

    func testBlankLineIsABoundary() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("Here is the first paragraph of it\n\n"),
                       ["Here is the first paragraph of it\n\n"])
    }

    func testStripsThinkBlock() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("<think>weighing the options</think>The answer is fourteen. "),
                       ["The answer is fourteen. "])
    }

    /// The open tag arrives in one delta and closes in a later one; nothing may
    /// escape to the speaker in between.
    func testThinkBlockSplitAcrossDeltas() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("<think>still "), [])
        XCTAssertEqual(c.feed("reasoning about it. "), [])
        XCTAssertEqual(c.feed("</think>Done thinking about that one. "),
                       ["Done thinking about that one. "])
    }

    func testMultipleSentencesInOneDelta() {
        var c = SentenceChunker()
        XCTAssertEqual(c.feed("The first sentence lands here. The second one follows it. "),
                       ["The first sentence lands here. ", "The second one follows it. "])
    }

    func testFlushDrainsTailAndResets() {
        var c = SentenceChunker()
        _ = c.feed("A trailing clause with no terminator")
        XCTAssertEqual(c.flush(), ["A trailing clause with no terminator"])
        XCTAssertFalse(c.hasPendingText)
        XCTAssertEqual(c.flush(), [])
    }

    func testFlushIgnoresWhitespaceOnlyTail() {
        var c = SentenceChunker()
        _ = c.feed("Complete sentence right here. ")
        XCTAssertEqual(c.flush(), [])
    }
}
