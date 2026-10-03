import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WhitegramServiceHost

// Every URL is intercepted. This test transport cannot fall through to a live API.
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var currentHandler: ((FixtureURLProtocol) -> Void)?

    static var handler: ((FixtureURLProtocol) -> Void)? {
        get { self.lock.lock(); defer { self.lock.unlock() }; return self.currentHandler }
        set { self.lock.lock(); self.currentHandler = newValue; self.lock.unlock() }
    }

    override class func canInit(with request: URLRequest) -> Bool { return true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        handler(self)
    }
    override func stopLoading() {
    }

    func respond(status: Int = 200, chunks: [Data], headers: [String: String] = [:]) {
        guard let url = self.request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { self.client?.urlProtocol(self, didLoad: chunk) }
        self.client?.urlProtocolDidFinishLoading(self)
    }
}

final class WhitegramServiceHTTPTests: XCTestCase {
    override func tearDown() {
        FixtureURLProtocol.handler = nil
        super.tearDown()
    }

    private func transport() -> WhitegramURLSessionTransport {
        return WhitegramURLSessionTransport(makeConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureURLProtocol.self]
            return configuration
        })
    }

    private func request() throws -> URLRequest {
        return try WhitegramVirusTotalWire.request(sha256: String(repeating: "b", count: 64), apiKey: "fixture-key")
    }

    func testRealURLSessionCollectsChunksAndPreservesStatusAndRetryAfter() throws {
        FixtureURLProtocol.handler = { fixture in
            XCTAssertEqual(fixture.request.value(forHTTPHeaderField: "x-apikey"), "fixture-key")
            fixture.respond(status: 429, chunks: [Data("first".utf8), Data("second".utf8)], headers: ["Retry-After": "17"])
        }
        let completed = self.expectation(description: "response")
        self.transport().send(try self.request(), maximumResponseBytes: 1024) { result in
            switch result {
            case let .success(response):
                XCTAssertEqual(response.statusCode, 429)
                XCTAssertEqual(response.retryAfter, "17")
                XCTAssertEqual(String(data: response.data, encoding: .utf8), "firstsecond")
            case let .failure(error): XCTFail(error.localizedDescription)
            }
            completed.fulfill()
        }
        self.wait(for: [completed], timeout: 5)
    }

    func testUnknownLengthResponseIsCancelledAtByteLimit() throws {
        FixtureURLProtocol.handler = { $0.respond(chunks: [Data(repeating: 1, count: 6), Data(repeating: 2, count: 6)]) }
        let completed = self.expectation(description: "response too large")
        completed.assertForOverFulfill = true
        self.transport().send(try self.request(), maximumResponseBytes: 8) { result in
            guard case let .failure(error) = result else { XCTFail("Expected a response limit error"); completed.fulfill(); return }
            XCTAssertEqual(error, .responseTooLarge)
            completed.fulfill()
        }
        self.wait(for: [completed], timeout: 5)
    }

    func testOversizedContentLengthIsRejectedBeforeCollectingBody() throws {
        FixtureURLProtocol.handler = { $0.respond(chunks: [], headers: ["Content-Length": "1000"]) }
        let completed = self.expectation(description: "declared length too large")
        self.transport().send(try self.request(), maximumResponseBytes: 8) { result in
            guard case let .failure(error) = result else { XCTFail("Expected a response limit error"); completed.fulfill(); return }
            XCTAssertEqual(error, .responseTooLarge)
            completed.fulfill()
        }
        self.wait(for: [completed], timeout: 5)
    }

    func testCancellationCompletesEvenWithoutServerResponse() throws {
        let started = self.expectation(description: "started")
        let completed = self.expectation(description: "cancelled")
        completed.assertForOverFulfill = true
        FixtureURLProtocol.handler = { _ in started.fulfill() }
        let task = self.transport().send(try self.request(), maximumResponseBytes: 1024) { result in
            guard case let .failure(error) = result else { XCTFail("Expected cancellation"); completed.fulfill(); return }
            XCTAssertEqual(error, .cancelled)
            completed.fulfill()
        }
        self.wait(for: [started], timeout: 5)
        task.cancel()
        task.cancel()
        self.wait(for: [completed], timeout: 5)
    }

    func testTimeoutIsMappedWithoutServerOrCredentialDetails() throws {
        FixtureURLProtocol.handler = { fixture in
            fixture.client?.urlProtocol(fixture, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "fixture-key must not be propagated"]))
        }
        let completed = self.expectation(description: "timeout")
        self.transport().send(try self.request(), maximumResponseBytes: 1024) { result in
            guard case let .failure(error) = result else { XCTFail("Expected timeout"); completed.fulfill(); return }
            XCTAssertEqual(error, .timedOut)
            XCTAssertFalse(error.localizedDescription.contains("fixture-key"))
            completed.fulfill()
        }
        self.wait(for: [completed], timeout: 5)
    }

    func testInsecureOrCredentialedURLsAreRejectedBeforeLoading() throws {
        FixtureURLProtocol.handler = { _ in XCTFail("Invalid URL must not reach URLSession") }
        for value in ["http://example.invalid", "https:/missing-host", "https://user:pass@example.invalid/", "https://example.invalid/?key=secret", "https://example.invalid/#fragment"] {
            let completed = self.expectation(description: value)
            let request = URLRequest(url: try XCTUnwrap(URL(string: value)))
            self.transport().send(request, maximumResponseBytes: 1024) { result in
                guard case let .failure(error) = result else { XCTFail("Expected URL rejection"); completed.fulfill(); return }
                XCTAssertEqual(error, .invalidResponse)
                completed.fulfill()
            }
            self.wait(for: [completed], timeout: 2)
        }
    }

    func testOversizedRequestIsRejectedBeforeLoading() throws {
        FixtureURLProtocol.handler = { _ in XCTFail("Oversized request must not reach URLSession") }
        var request = try self.request()
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 0, count: WhitegramServiceLimits.maximumRequestBytes + 1)
        let completed = self.expectation(description: "request rejected")
        self.transport().send(request, maximumResponseBytes: 1024) { result in
            guard case let .failure(error) = result else { XCTFail("Expected request limit"); completed.fulfill(); return }
            XCTAssertEqual(error, .requestTooLarge)
            completed.fulfill()
        }
        self.wait(for: [completed], timeout: 2)
    }

    func testRedirectDoesNotForwardCredentials() throws {
        #if canImport(Darwin)
        FixtureURLProtocol.handler = { fixture in
            guard let original = fixture.request.url, original.host == "www.virustotal.com",
                  let destination = URL(string: "https://redirect.invalid/"),
                  let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString]) else {
                XCTFail("Redirect destination was contacted")
                fixture.client?.urlProtocol(fixture, didFailWithError: URLError(.badServerResponse))
                return
            }
            var request = fixture.request
            request.url = destination
            fixture.client?.urlProtocol(fixture, wasRedirectedTo: request, redirectResponse: response)
        }
        let completed = self.expectation(description: "redirect rejected")
        self.transport().send(try self.request(), maximumResponseBytes: 1024) { result in
            guard case let .failure(error) = result else { XCTFail("Expected redirect rejection"); completed.fulfill(); return }
            XCTAssertEqual(error, .redirectRefused)
            completed.fulfill()
        }
        self.wait(for: [completed], timeout: 5)
        #else
        throw XCTSkip("FoundationNetworking's URLProtocol redirect callback is not implemented; run this transport test on macOS.")
        #endif
    }

    func testStreamingTransportFeedsSuccessfulChunksAndPropagatesParserFailure() throws {
        FixtureURLProtocol.handler = { $0.respond(chunks: [Data("data: invalid\n\n".utf8)], headers: ["Content-Type": "text/event-stream"]) }
        let completed = expectation(description: "parser failure")
        self.transport().stream(try self.request(), maximumResponseBytes: 1024, received: { _ in
            throw WhitegramServiceError.invalidResponse
        }) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .invalidResponse) } else { XCTFail("Parser error must terminate the request") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }

    func testHTTPErrorBodyIsNeverDeliveredAsStreamText() throws {
        FixtureURLProtocol.handler = { $0.respond(status: 401, chunks: [Data("data: secret-error-body\n\n".utf8)]) }
        let completed = expectation(description: "HTTP error")
        self.transport().stream(try self.request(), maximumResponseBytes: 1024, received: { _ in XCTFail("Error bodies must not reach the model stream decoder") }) { result in
            if case let .success(response) = result { XCTAssertEqual(response.statusCode, 401) } else { XCTFail("Expected status for service error mapping") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
    }

    func testModelPaginationQueryIsAllowedButCredentialQueryIsRefused() throws {
        FixtureURLProtocol.handler = { fixture in
            XCTAssertEqual(fixture.request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-key")
            fixture.respond(chunks: [Data(#"{"models":[]}"#.utf8)])
        }
        let completed = expectation(description: "model page")
        self.transport().send(try WhitegramAIModelsWire.request(provider: .gemini, apiKey: "fixture-key", pageToken: "opaque"), maximumResponseBytes: 1024) { result in
            XCTAssertNotNil(try? result.get())
            completed.fulfill()
        }
        wait(for: [completed], timeout: 5)
        FixtureURLProtocol.handler = { _ in XCTFail("Credential query must be rejected") }
        let rejected = expectation(description: "credential in query")
        self.transport().send(URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=fixture-key")!), maximumResponseBytes: 1024) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .invalidResponse) } else { XCTFail("Expected URL rejection") }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 5)
    }
}
