import Foundation
import XCTest
@testable import WhitegramServiceHost

final class WhitegramVirusTotalTargetTests: XCTestCase {
    func testTargetNormalizationRejectsCredentialsInvalidIPsAndMalformedEscapes() throws {
        XCTAssertEqual(try WhitegramVirusTotalTarget.parse("HTTPS://EXAMPLE.COM:443/a?q=1#fragment"), .url("https://example.com/a?q=1"))
        XCTAssertEqual(try WhitegramVirusTotalTarget.parse("2001:0db8::1"), .ipAddress("2001:db8::1"))
        XCTAssertEqual(try WhitegramVirusTotalTarget.parse("1.2.3.4"), .ipAddress("1.2.3.4"))
        for value in ["https://user:pass@example.com/", "file:///tmp/file", "1.2.3.999", "01.2.3.4", "https://example.com/%zz", "https://example.com/a\nb", "fe80::1%en0"] {
            XCTAssertThrowsError(try WhitegramVirusTotalTarget.parse(value), value)
        }
    }

    func testAllTargetsUseOfficialReadOnlyRoutes() throws {
        let targets: [WhitegramVirusTotalTarget] = [.file(sha256: String(repeating: "a", count: 64)), .url("https://example.com/"), .ipAddress("1.2.3.4")]
        let expectedPaths = ["/api/v3/files/" + String(repeating: "a", count: 64), "/api/v3/urls/aHR0cHM6Ly9leGFtcGxlLmNvbS8", "/api/v3/ip_addresses/1.2.3.4"]
        for (target, path) in zip(targets, expectedPaths) {
            let request = try WhitegramVirusTotalWire.request(target: target, apiKey: "test-key")
            XCTAssertEqual(request.url?.host, "www.virustotal.com")
            XCTAssertEqual(request.url?.path, path)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-apikey"), "test-key")
            XCTAssertFalse(request.url?.absoluteString.contains("test-key") ?? true)
        }
    }

    func testMessageExtractionUsesLinkEntitiesAndDeduplicatesIndicators() {
        let text = "😀 link and 1.2.3.4, https://example.com/."
        let linkRange = (text as NSString).range(of: "link")
        let targets = WhitegramVirusTotalTargets.extractAllTargets(from: text, links: [WhitegramVirusTotalTextLink(range: linkRange, url: "https://example.com/")])
        XCTAssertEqual(targets, [.url("https://example.com/"), .ipAddress("1.2.3.4")])
        XCTAssertTrue(WhitegramVirusTotalTargets.extractAllTargets(from: "plain message").isEmpty)
        XCTAssertEqual(WhitegramVirusTotalTargets.extractAllTargets(from: "https://example.com/1.2.3.4"), [.url("https://example.com/1.2.3.4")])
    }
}
