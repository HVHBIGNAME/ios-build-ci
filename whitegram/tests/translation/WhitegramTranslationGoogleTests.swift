import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import TelegramCore

private final class TranslationFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var currentHandler: ((TranslationFixtureProtocol) -> Void)?
    static var handler: ((TranslationFixtureProtocol) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return currentHandler }
        set { lock.lock(); currentHandler = newValue; lock.unlock() }
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
    override func stopLoading() {}
    func respond(_ chunks: [Data], status: Int = 200, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for data in chunks { self.client?.urlProtocol(self, didLoad: data) }
        self.client?.urlProtocolDidFinishLoading(self)
    }
}

final class WhitegramTranslationGoogleTests: XCTestCase {
    override func tearDown() { TranslationFixtureProtocol.handler = nil; super.tearDown() }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationFixtureProtocol.self]
        return configuration
    }

    func testOriginalHTTPSQueryPreservesUnicodeAndExplicitSourceLanguage() throws {
        let text = "  Текст 😀 & q=other+%\n"
        let request = try WhitegramTranslationGoogle.request(text: text, fromLang: "uk", toLang: "zh-TW")
        XCTAssertEqual(request.url?.host, "translate.googleapis.com")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.path, "/translate_a/single")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        let items = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, text)
        XCTAssertEqual(items.first(where: { $0.name == "sl" })?.value, "uk")
        XCTAssertEqual(items.first(where: { $0.name == "tl" })?.value, "zh-TW")
        XCTAssertEqual(items.first(where: { $0.name == "client" })?.value, "gtx")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertThrowsError(try WhitegramTranslationGoogle.request(text: "text", fromLang: nil, toLang: "auto"))
        XCTAssertThrowsError(try WhitegramTranslationGoogle.request(text: "text", fromLang: nil, toLang: "en&key=other"))
    }

    func testResponseKeepsAllSegmentsAndLiteralNullTextWithoutDroppingMalformedRows() throws {
        let good = Data(#"[[["Привет ","Hello",null,null],["😀","emoji"],["null","null"]],null,"en"]"#.utf8)
        XCTAssertEqual(try WhitegramTranslationGoogle.response(status: 200, data: good), "Привет 😀null")
        for body in ["[]", "[[]]", "[[[null]]]", "[[[42]]]", #"[[["partial"],null]]"#, #"{"error":"private content"}"#] {
            XCTAssertThrowsError(try WhitegramTranslationGoogle.response(status: 200, data: Data(body.utf8)))
        }
        XCTAssertThrowsError(try WhitegramTranslationGoogle.response(status: 429, data: Data())) { error in
            XCTAssertEqual(error as? WhitegramTranslationGoogleError, .httpStatus(429))
        }
    }

    func testActualURLSessionDecodesArbitraryUTF8ChunksOnMainQueue() {
        TranslationFixtureProtocol.handler = { fixture in
            let data = Data(#"[[["Привет 😀","hello"]]]"#.utf8)
            fixture.respond(data.map { Data([$0]) })
        }
        let complete = expectation(description: "translation")
        WhitegramTranslationGoogle.translate(text: "hello", fromLang: nil, toLang: "ru", configuration: configuration()) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get(), "Привет 😀")
            complete.fulfill()
        }
        wait(for: [complete], timeout: 5)
    }

    func testCancelBeforeStartPreventsURLSessionAndOverridesQueuedSuccess() throws {
        TranslationFixtureProtocol.handler = { _ in XCTFail("Cancelled request must never start") }
        let complete = expectation(description: "cancelled once")
        complete.assertForOverFulfill = true
        let task = WhitegramTranslationGoogleRequest { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .cancelled) } else { XCTFail("Queued result must lose to cancel") }
            complete.fulfill()
        }
        task.finish(.success("late"))
        task.cancel()
        task.start(try WhitegramTranslationGoogle.request(text: "hello", fromLang: nil, toLang: "ru"), configuration: configuration())
        wait(for: [complete], timeout: 2)
    }

    func testResponseLimitRejectsDeclaredAndIncrementalOverflow() {
        for declared in [false, true] {
            TranslationFixtureProtocol.handler = { fixture in
                if declared {
                    fixture.respond([], headers: ["Content-Length": String(WhitegramTranslationGoogle.maximumResponseBytes + 1)])
                } else {
                    fixture.respond([Data(repeating: 65, count: WhitegramTranslationGoogle.maximumResponseBytes), Data([66])])
                }
            }
            let complete = expectation(description: "bounded response")
            WhitegramTranslationGoogle.translate(text: "hello", fromLang: nil, toLang: "ru", configuration: configuration()) { result in
                if case let .failure(error) = result { XCTAssertEqual(error, .responseTooLarge) } else { XCTFail("Expected response size rejection") }
                complete.fulfill()
            }
            wait(for: [complete], timeout: 5)
        }
    }

    func testNoProviderFallbackAfterRateLimitOrCancellation() {
        TranslationFixtureProtocol.handler = { $0.respond([], status: 429) }
        let limited = expectation(description: "rate limited")
        WhitegramTranslationGoogle.translate(text: "hello", fromLang: nil, toLang: "ru", configuration: configuration()) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .httpStatus(429)) } else { XCTFail("Expected original HTTP failure") }
            limited.fulfill()
        }
        wait(for: [limited], timeout: 5)
        let started = expectation(description: "waiting")
        TranslationFixtureProtocol.handler = { _ in started.fulfill() }
        let cancelled = expectation(description: "cancelled")
        let task = WhitegramTranslationGoogle.translate(text: "hello", fromLang: nil, toLang: "ru", configuration: configuration()) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .cancelled) } else { XCTFail("Expected cancellation") }
            cancelled.fulfill()
        }
        wait(for: [started], timeout: 5)
        task.cancel()
        wait(for: [cancelled], timeout: 5)
    }
}
