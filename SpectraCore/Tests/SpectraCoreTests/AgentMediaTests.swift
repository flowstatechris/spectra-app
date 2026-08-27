import XCTest
@testable import SpectraCore

final class AgentMediaTests: XCTestCase {
    func testServerImageWithCaption() {
        let (clean, m) = AgentMedia.parse("Here you go:\nMEDIA:/root/.hermes/images/plot.png the sales plot")
        XCTAssertEqual(clean, "Here you go:")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].name, "plot.png")
        XCTAssertEqual(m[0].caption, "the sales plot")
        XCTAssertTrue(m[0].isImage)
        XCTAssertEqual(m[0].slot, .serverImage("/root/.hermes/images/plot.png"))
    }

    func testNonImageBecomesFileCard() {
        let (_, m) = AgentMedia.parse("MEDIA:/tmp/report.pdf Q3 numbers")
        XCTAssertEqual(m[0].slot, .serverFile("/tmp/report.pdf"))
        XCTAssertFalse(m[0].isImage)
        XCTAssertEqual(m[0].name, "report.pdf")
    }

    func testMarkdownImageStrippedAndKept() {
        let (clean, m) = AgentMedia.parse("Look ![diagram](https://x.com/d.png) at this")
        XCTAssertEqual(clean, "Look  at this")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].name, "diagram")
        XCTAssertEqual(m[0].slot, .remoteURL(URL(string: "https://x.com/d.png")!))
    }

    func testMediaNoCaption() {
        let (clean, m) = AgentMedia.parse("MEDIA:~/.hermes/images/a.jpg")
        XCTAssertEqual(clean, "")
        XCTAssertNil(m[0].caption)
        XCTAssertEqual(m[0].slot, .serverImage("~/.hermes/images/a.jpg"))
    }

    func testPlainTextUntouched() {
        let (clean, m) = AgentMedia.parse("just a normal reply, no media")
        XCTAssertEqual(clean, "just a normal reply, no media")
        XCTAssertTrue(m.isEmpty)
    }

    func testNonHttpMarkdownIgnored() {
        // relative/local markdown target isn't fetchable → leave as text, no media
        let (_, m) = AgentMedia.parse("![x](./local.png)")
        XCTAssertTrue(m.isEmpty)
    }

    func testMultipleMixed() {
        let (clean, m) = AgentMedia.parse(
            "Two things:\nMEDIA:/i/one.png first\nand ![two](https://h/two.gif) inline")
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(clean, "Two things:\nand  inline")
    }
}
