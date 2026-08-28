import XCTest
@testable import SpectraCore

final class ActivityTitleTests: XCTestCase {
    private func item(_ toolName: String) -> ActivityItem {
        ActivityItem(id: "x", profileName: "p", toolName: toolName,
                     context: "", status: .success)
    }

    func testSyntheticNamesGetPlainLanguage() {
        XCTAssertEqual(item("turn").displayTitle, "Turn update")
        XCTAssertEqual(item("approval").displayTitle, "Approval request")
        XCTAssertEqual(item("clarify").displayTitle, "Question")
    }

    func testToolIdsAreTitleCased() {
        XCTAssertEqual(item("web_search").displayTitle, "Web Search")
        XCTAssertEqual(item("read-file").displayTitle, "Read File")
        XCTAssertEqual(item("bash").displayTitle, "Bash")
    }
}
