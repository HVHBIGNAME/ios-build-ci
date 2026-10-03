import Foundation
import XCTest
@testable import WhitegramBackendHost

final class WhitegramBackendClientTests: XCTestCase {
    func testMissingSessionFailsWithoutNetwork() {
        let fixture = BackendFixture()
        fixture.sessions.values.removeAll()
        let done = expectation(description: "missing session")
        fixture.client.raw(path: "/v1/profile/about") { result in
            XCTAssertEqual(result.failure, .missingSession)
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        waitForExpectations(timeout: 1)
        XCTAssertTrue(fixture.http.calls.isEmpty)
    }

    func testOldUnauthorizedResponseCannotDeleteReplacementSession() {
        let fixture = BackendFixture()
        let done = expectation(description: "stale response")
        fixture.client.raw(path: "/v1/profile/about") { result in
            XCTAssertEqual(result.failure, .sessionChanged)
            done.fulfill()
        }
        fixture.sessions.values[42] = fixture.session(token: "replacement-fixture")
        fixture.http.respond(0, status: 401)
        waitForExpectations(timeout: 1)
        XCTAssertEqual(fixture.sessions.values[42]?.token, "replacement-fixture")
        XCTAssertEqual(fixture.sessions.removals, 0)
    }

    func testMatchingUnauthorizedResponseInvalidatesOnlyItsAccount() {
        let fixture = BackendFixture()
        let other = WhitegramBackendSession(userId: 43, token: "other-fixture", expiresAt: fixture.date.addingTimeInterval(3600), sessionKey: nil)
        fixture.sessions.values[43] = other
        let done = expectation(description: "unauthorized")
        fixture.client.raw(path: "/v1/profile/about") { result in
            XCTAssertEqual(result.failure, .http(401, retryAfter: nil))
            done.fulfill()
        }
        fixture.http.respond(0, status: 401)
        waitForExpectations(timeout: 1)
        XCTAssertNil(fixture.sessions.values[42])
        XCTAssertEqual(fixture.sessions.values[43], other)
        XCTAssertEqual(fixture.access.state(userId: 42, now: fixture.date), .unknown)
    }

    func testProxyPreservesErrorBodyAndDoesNotDestroySessionForProvider401() {
        let fixture = BackendFixture()
        let transport = WhitegramBackendAuthorizedTransport(client: fixture.client)
        let body = Data(#"{"error":{"code":"WrongCredentialsError"}}"#.utf8)
        let done = expectation(description: "provider response")
        transport.execute(path: "/v1/proxy/virustotal/v3/files/fixture", providerKey: "fixture-key") { result in
            XCTAssertEqual(try? result.get().response.statusCode, 401)
            XCTAssertEqual(try? result.get().data, body)
            done.fulfill()
        }
        fixture.http.respond(0, status: 401, data: body)
        waitForExpectations(timeout: 1)
        XCTAssertEqual(fixture.sessions.values[42]?.token, "synthetic-token")
    }

    func testRateLimitBackoffPreventsImmediateDuplicateRequest() {
        let fixture = BackendFixture()
        let first = expectation(description: "rate limited")
        fixture.client.raw(path: "/v1/profile/about") { result in
            XCTAssertEqual(result.failure, .http(429, retryAfter: 90))
            first.fulfill()
        }
        fixture.http.respond(0, status: 429, headers: ["Retry-After": "90"])
        waitForExpectations(timeout: 1)
        let retry = expectation(description: "local backoff")
        fixture.client.raw(path: "/v1/profile/about") { result in
            XCTAssertEqual(result.failure, .http(429, retryAfter: 90))
            retry.fulfill()
        }
        waitForExpectations(timeout: 1)
        XCTAssertEqual(fixture.http.calls.count, 1)
    }

    func testCancellationAndDuplicateTransportCompletionDeliverExactlyOnce() {
        let fixture = BackendFixture()
        let done = expectation(description: "cancelled")
        var count = 0
        let task = fixture.client.raw(path: "/v1/profile/about") { result in
            count += 1
            XCTAssertEqual(result.failure, .cancelled)
            done.fulfill()
        }
        task.cancel()
        XCTAssertTrue(fixture.http.calls[0].task.cancelled)
        fixture.http.respond(0)
        fixture.http.respond(0)
        waitForExpectations(timeout: 1)
        let drained = expectation(description: "drain duplicate callback")
        DispatchQueue.main.async { XCTAssertEqual(count, 1); drained.fulfill() }
        waitForExpectations(timeout: 1)
    }

    func testSessionChangeStopsStreamAndUploadCallbacks() throws {
        let fixture = BackendFixture()
        fixture.client.raw(path: "/v1/proxy/groq/openai/v1/chat/completions", received: { _ in XCTFail("Stale stream delivered") }) { _ in }
        fixture.sessions.values[42] = fixture.session(token: "replacement-fixture")
        XCTAssertThrowsError(try fixture.http.calls[0].transfer.validateSession()) { XCTAssertEqual($0 as? WhitegramBackendError, .sessionChanged) }
        fixture.http.respond(0)
    }

    func testSessionNotificationCancelsAStalledRequestImmediately() {
        let fixture = BackendFixture()
        let done = expectation(description: "session invalidation")
        fixture.client.raw(path: "/v1/profile/about") { result in
            XCTAssertEqual(result.failure, .sessionChanged)
            done.fulfill()
        }
        fixture.sessions.values[42] = fixture.session(token: "replacement-fixture")
        NotificationCenter.default.post(name: WhitegramBackendClient.sessionUpdated, object: nil, userInfo: ["userId": Int64(42)])
        XCTAssertTrue(fixture.http.calls[0].task.cancelled)
        fixture.http.respond(0)
        waitForExpectations(timeout: 1)
    }

    func testOversizedResponsesAndMixedUploadBodiesFail() {
        let fixture = BackendFixture()
        let oversized = expectation(description: "oversized")
        fixture.client.raw(path: "/v1/profile/about", maximumBytes: 4) { result in
            XCTAssertEqual(result.failure, .responseTooLarge)
            oversized.fulfill()
        }
        fixture.http.respond(0, data: Data(repeating: 0, count: 5))
        waitForExpectations(timeout: 1)
        let invalid = expectation(description: "mixed upload")
        fixture.client.raw(path: "/v1/profile/about", body: Data([0]), bodyFile: URL(fileURLWithPath: "/unused/fixture")) { result in
            XCTAssertEqual(result.failure, .invalidRequest)
            invalid.fulfill()
        }
        waitForExpectations(timeout: 1)
        XCTAssertEqual(fixture.http.calls.count, 1)
    }
}

extension Result where Failure == WhitegramBackendError {
    var failure: WhitegramBackendError? { if case let .failure(value) = self { return value }; return nil }
}
