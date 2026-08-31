import XCTest
@testable import SpectraCore

/// The scheme default decides whether a connection is even attempted: App
/// Transport Security refuses plaintext to a real host, so guessing `http` for
/// a domain name makes the backend unreachable no matter how it's configured.
final class BackendURLTests: XCTestCase {

    func testExplicitSchemeIsHonoured() {
        XCTAssertEqual(BackendURL.normalize("https://box.tail1234.ts.net")?.scheme, "https")
        XCTAssertEqual(BackendURL.normalize("http://10.0.0.182:9119")?.scheme, "http")
    }

    /// The regression: a Tailscale/public hostname must not be downgraded.
    func testBareHostnameDefaultsToHTTPS() {
        let url = BackendURL.normalize("box.tail1234.ts.net")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host(), "box.tail1234.ts.net")
    }

    func testLANAddressesStayPlaintext() {
        for host in ["10.0.0.182:9119", "192.168.1.50:9119", "172.16.4.4", "127.0.0.1:9119"] {
            XCTAssertEqual(BackendURL.normalize(host)?.scheme, "http", host)
        }
    }

    func testLocalhostAndBonjourStayPlaintext() {
        XCTAssertEqual(BackendURL.normalize("localhost:9119")?.scheme, "http")
        XCTAssertEqual(BackendURL.normalize("mac-mini.local:9119")?.scheme, "http")
        XCTAssertEqual(BackendURL.normalize("hermes")?.scheme, "http")   // bare name
    }

    /// A public IP is not a LAN address, so it should not be downgraded.
    func testPublicIPDefaultsToHTTPS() {
        XCTAssertEqual(BackendURL.normalize("203.0.113.7:9119")?.scheme, "https")
        XCTAssertFalse(BackendURL.isLocal("172.32.0.1"))   // just outside 172.16/12
        XCTAssertTrue(BackendURL.isLocal("172.31.255.1"))
    }

    func testPortAndPathSurvive() {
        let url = BackendURL.normalize("box.tail1234.ts.net:9119")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.port, 9119)
    }

    func testJunkIsRejected() {
        XCTAssertNil(BackendURL.normalize(""))
        XCTAssertNil(BackendURL.normalize("   "))
    }
}
