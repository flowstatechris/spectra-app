import XCTest
@testable import SpectraCore

/// The data-URL split is the only parsing in the speech path; getting it wrong
/// yields either silence or a decode error rather than anything diagnosable.
final class SpeechFetchTests: XCTestCase {

    func testDecodesBase64Payload() {
        let payload = Data("hello".utf8).base64EncodedString()
        let bytes = SpeechFetch.decodeDataURL("data:audio/mpeg;base64,\(payload)")
        XCTAssertEqual(bytes.map { String(decoding: $0, as: UTF8.self) }, "hello")
    }

    /// The mime section can carry its own commas; only the first one separates.
    func testSplitsOnFirstCommaOnly() {
        let payload = Data([0xFF, 0xFB, 0x90]).base64EncodedString()
        XCTAssertEqual(SpeechFetch.decodeDataURL("data:audio/mpeg;codecs=a,b;base64,\(payload)"),
                       Data([0xFF, 0xFB, 0x90]))
    }

    func testRejectsNonBase64AndMalformed() {
        XCTAssertNil(SpeechFetch.decodeDataURL("data:audio/mpeg,rawbytes"))  // not base64
        XCTAssertNil(SpeechFetch.decodeDataURL("no-comma-at-all"))
        XCTAssertNil(SpeechFetch.decodeDataURL("data:audio/mpeg;base64,!!!not-base64!!!"))
    }
}
