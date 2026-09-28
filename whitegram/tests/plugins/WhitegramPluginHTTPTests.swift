import Foundation
import XCTest
@testable import SettingsUI

// Requires an Apple XCTest host. No network or Telegram account is used here.
final class WhitegramPluginHTTPTests: XCTestCase {
    func testRequestsHaveNoImplicitAuthenticationOrCookies() throws {
        let request = try WhitegramPluginHTTP.makeRequest(["url": "https://example.test/path"])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Proxy-Authorization"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 30)
    }

    func testJSONBinaryAndTimeoutContracts() throws {
        let json = try WhitegramPluginHTTP.makeRequest(["url": "https://example.test", "method": "post", "body": ["value": 42], "timeout": 500])
        XCTAssertEqual(json.httpMethod, "POST")
        XCTAssertEqual(json.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        let body = try XCTUnwrap(json.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: Int], ["value": 42])
        XCTAssertEqual(json.timeoutInterval, 60)
        let binary = try WhitegramPluginHTTP.makeRequest(["url": "https://example.test", "method": "POST", "bodyBase64": "AH+A/w==", "timeout": 0])
        XCTAssertEqual(binary.httpBody, Data([0, 127, 128, 255]))
        XCTAssertEqual(binary.timeoutInterval, 1)
    }

    func testInvalidURLsOptionsHeadersAndQuotasFail() throws {
        for url in ["file:///private/key", "ftp://example.test", "https://user:password@example.test", "relative/path"] {
            XCTAssertThrowsError(try WhitegramPluginHTTP.makeRequest(["url": url])) { error in
                XCTAssertEqual((error as? WhitegramPluginError)?.code, "INVALID_URL")
            }
        }
        let invalid: [[String: Any]] = [
            ["method": 1], ["method": "CONNECT"], ["timeout": true], ["timeout": "30"],
            ["bodyBase64": 3], ["bodyBase64": "!"], ["bodyBase64": "", "body": "also present"],
            ["headers": ["Authorization": "bad\r\nCookie: injected"]],
            ["headers": ["Host": "other.test"]], ["headers": ["Proxy-Authorization": "fixture"]]
        ]
        for options in invalid {
            var options = options
            options["url"] = "https://example.test"
            XCTAssertThrowsError(try WhitegramPluginHTTP.makeRequest(options), "Accepted invalid options: \(options)") { error in
                XCTAssertEqual((error as? WhitegramPluginError)?.code, "INVALID_ARGUMENT")
            }
        }
        XCTAssertThrowsError(try WhitegramPluginHTTP.makeRequest([
            "url": "https://example.test", "method": "POST",
            "body": String(repeating: "a", count: 2 * 1024 * 1024 + 1)
        ])) { error in
            XCTAssertEqual((error as? WhitegramPluginError)?.code, "QUOTA_EXCEEDED")
        }
    }

    func testHeaderSeparatorsAreRejectedAtByteBoundaries() {
        for separator in ["\r", "\n", "\r\n", "\0"] {
            XCTAssertThrowsError(try WhitegramPluginHTTP.makeRequest([
                "url": "https://example.test",
                "headers": ["X-Test": "before" + separator + "after"]
            ]), "Accepted separator: \(separator.debugDescription)") { error in
                XCTAssertEqual((error as? WhitegramPluginError)?.code, "INVALID_ARGUMENT")
            }
        }
    }

    func testCrossOriginRedirectsStripCallerCredentials() throws {
        let original = try WhitegramPluginHTTP.makeRequest([
            "url": "https://example.test/path", "headers": ["Authorization": "Bearer fixture", "Cookie": "session=fixture", "Accept": "application/json"]
        ])
        let sameOrigin = WhitegramPluginHTTP.redirectRequest(original, from: URL(string: "https://example.test/first"))
        XCTAssertEqual(sameOrigin.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
        for url in ["https://other.test/path", "http://example.test/path", "https://example.test:8443/path"] {
            var proposed = original
            proposed.url = URL(string: url)
            let redirected = WhitegramPluginHTTP.redirectRequest(proposed, from: original.url)
            XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(redirected.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertFalse(redirected.httpShouldHandleCookies)
        }
    }
}
