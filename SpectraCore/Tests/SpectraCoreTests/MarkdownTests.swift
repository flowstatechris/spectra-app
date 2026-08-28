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

    // MARK: Tables

    func testTable() {
        let md = "| Flight | Price |\n|---|---|\n| CX 811 | $8,602 |\n| JL 7 | $9,140 |"
        XCTAssertEqual(Markdown.blocks(md), [
            .table(headers: ["Flight", "Price"],
                   alignments: [.leading, .leading],
                   rows: [["CX 811", "$8,602"], ["JL 7", "$9,140"]]),
        ])
    }

    func testTableAlignments() {
        let md = "| L | C | R |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |"
        XCTAssertEqual(Markdown.blocks(md), [
            .table(headers: ["L", "C", "R"],
                   alignments: [.leading, .center, .trailing],
                   rows: [["1", "2", "3"]]),
        ])
    }

    func testTableWithoutOuterPipes() {
        XCTAssertEqual(Markdown.blocks("a | b\n--- | ---\n1 | 2"),
                       [.table(headers: ["a", "b"],
                               alignments: [.leading, .leading],
                               rows: [["1", "2"]])])
    }

    // The separator row is what makes it a table; prose with a pipe stays prose.
    func testPipeLineWithoutSeparatorStaysParagraph() {
        XCTAssertEqual(Markdown.blocks("use a | b to pipe\nand more text"),
                       [.paragraph("use a | b to pipe\nand more text")])
    }

    func testRaggedRowsPadAndTruncateToHeaderWidth() {
        let md = "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |"
        XCTAssertEqual(Markdown.blocks(md), [
            .table(headers: ["a", "b", "c"],
                   alignments: [.leading, .leading, .leading],
                   rows: [["1", "", ""], ["1", "2", "3"]]),
        ])
    }

    func testEscapedPipeIsALiteralCellCharacter() {
        XCTAssertEqual(Markdown.blocks("| cmd |\n|---|\n| a \\| b |"),
                       [.table(headers: ["cmd"], alignments: [.leading],
                               rows: [["a | b"]])])
    }

    func testTableEndsAtBlankLineAndProseFollows() {
        let md = "| a |\n|---|\n| 1 |\n\nafter"
        XCTAssertEqual(Markdown.blocks(md), [
            .table(headers: ["a"], alignments: [.leading], rows: [["1"]]),
            .paragraph("after"),
        ])
    }

    func testUnclosedFenceToEOF() {
        XCTAssertEqual(Markdown.blocks("```\nx\ny"),
                       [.code(language: nil, code: "x\ny")])
    }
}
