import XCTest
@testable import SpectraCore

final class MarkdownTests: XCTestCase {
    func testPlainParagraph() {
        XCTAssertEqual(Markdown.blocks("just text"), [.paragraph("just text")])
    }

    func testHeadings() {
        XCTAssertEqual(Markdown.blocks("## Title"), [.heading(level: 2, text: "Title")])
        // '#' without a space is not a heading
        XCTAssertEqual(Markdown.blocks("#nospace"), [.paragraph("#nospace")])
    }

    func testFencedCodeWithLanguage() {
        let md = "before\n```swift\nlet x = 1\nlet y = 2\n```\nafter"
        XCTAssertEqual(Markdown.blocks(md), [
            .paragraph("before"),
            .code(language: "swift", code: "let x = 1\nlet y = 2"),
            .paragraph("after"),
        ])
    }

    func testBulletList() {
        XCTAssertEqual(Markdown.blocks("- one\n- two\n* three"),
                       [.bullets(["one", "two", "three"])])
    }

    func testNumberedList() {
        XCTAssertEqual(Markdown.blocks("1. first\n2. second\n3) third"),
                       [.numbered(["first", "second", "third"])])
    }

    func testBlockquoteAndRule() {
        XCTAssertEqual(Markdown.blocks("> quoted line\n\n---"),
                       [.quote("quoted line"), .rule])
    }

    func testInlineLeftForRenderLayer() {
        // Inline syntax stays in the paragraph string (SwiftUI renders it).
        XCTAssertEqual(Markdown.blocks("has **bold** and `code`"),
                       [.paragraph("has **bold** and `code`")])
    }

    func testMixedDocumentOrder() {
        let md = "# H\ntext\n\n- a\n- b\n\n```\ncode\n```"
        XCTAssertEqual(Markdown.blocks(md), [
            .heading(level: 1, text: "H"),
            .paragraph("text"),
            .bullets(["a", "b"]),
            .code(language: nil, code: "code"),
        ])
    }

    func testUnclosedFenceToEOF() {
        XCTAssertEqual(Markdown.blocks("```\nx\ny"),
                       [.code(language: nil, code: "x\ny")])
    }
}
