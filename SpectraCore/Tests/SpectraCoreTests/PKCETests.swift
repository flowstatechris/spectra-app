import XCTest
import CryptoKit
@testable import SpectraCore

final class PKCETests: XCTestCase {
    func testPKCEShape() {
        let pkce = PKCE()
        XCTAssertEqual(pkce.challenge.count, 43) // 32-byte digest → 43 base64url chars
        XCTAssertFalse(pkce.challenge.contains("="))
        XCTAssertFalse(pkce.challenge.contains("+"))
        XCTAssertFalse(pkce.challenge.contains("/"))
        XCTAssertNotEqual(PKCE().verifier, pkce.verifier) // random per instance
        // challenge really is S256(verifier)
        let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64URLEncoded
        XCTAssertEqual(pkce.challenge, expected)
    }

    func testRFC7636KnownVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
}
