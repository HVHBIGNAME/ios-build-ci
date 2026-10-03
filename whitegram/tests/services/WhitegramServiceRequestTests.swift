import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WhitegramServiceHost

private let fixtureKey = "unit-test-key-not-a-real-credential"
private let fixtureHash = String(repeating: "a", count: 64)

private func json(_ value: Any) throws -> Data {
    return try JSONSerialization.data(withJSONObject: value)
}

private func assertFailure<Value>(_ error: WhitegramServiceError, _ result: Result<Value, WhitegramServiceError>, file: StaticString = #filePath, line: UInt = #line) {
    switch result {
    case let .failure(actual): XCTAssertEqual(actual, error, file: file, line: line)
    case .success: XCTFail("Expected failure", file: file, line: line)
    }
}

final class WhitegramAIRequestTests: XCTestCase {
    func testAbsentModelUsesRecoveredDefaultButExplicitModelIsNotSilentlyReplaced() throws {
        XCTAssertEqual(WhitegramAIProvider.gemini.modelId(storedValue: nil), "gemini-3-flash-preview")
        XCTAssertEqual(WhitegramAIProvider.groq.modelId(storedValue: nil), "llama-3.3-70b-versatile")
        XCTAssertEqual(WhitegramAIProvider.gemini.modelId(storedValue: "my-selected-model"), "my-selected-model")
        XCTAssertEqual(WhitegramAIProvider.groq.modelId(storedValue: ""), "")
        for provider in WhitegramAIProvider.allCases {
            let invalid = provider.modelId(storedValue: true)
            XCTAssertThrowsError(try WhitegramAIWire.request(text: "prompt", provider: provider, model: invalid, apiKey: fixtureKey))
        }
    }

    func testGeminiUsesHeaderAuthenticationAndOnlySubmittedText() throws {
        let text = "  A quoted \"prompt\"\nПривет 🙂  "
        let request = try WhitegramAIWire.request(text: text, provider: .gemini, model: "models/test-model", apiKey: fixtureKey)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/models/test-model:generateContent")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), fixtureKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(request.url?.absoluteString.contains(fixtureKey) ?? true)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, WhitegramServiceLimits.requestTimeout)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["contents", "generationConfig"]))
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0]["role"] as? String, "user")
        XCTAssertEqual((contents[0]["parts"] as? [[String: String]])?.first?["text"], text)
        XCTAssertEqual((body["generationConfig"] as? [String: Int])?["maxOutputTokens"], 4096)
    }

    func testGroqOpenAICompatibleRequest() throws {
        let request = try WhitegramAIWire.request(text: "Only this text", provider: .groq, model: "organization/test-model", apiKey: fixtureKey)
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + fixtureKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), Set(["model", "messages", "max_completion_tokens", "stream"]))
        XCTAssertEqual(body["model"] as? String, "organization/test-model")
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": "Only this text"]])
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 4096)
        XCTAssertNil(request.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.range(of: fixtureKey))
    }

    func testUTF8PromptLimitsAndWhitespaceValidation() throws {
        let exact = String(repeating: "🙂", count: WhitegramServiceLimits.maximumPromptBytes / 4)
        _ = try WhitegramAIWire.request(text: exact, provider: .groq, model: "test", apiKey: fixtureKey)
        assertFailure(.promptTooLarge, whitegramServiceResult { try WhitegramAIWire.request(text: exact + "a", provider: .groq, model: "test", apiKey: fixtureKey) })
        assertFailure(.emptyPrompt, whitegramServiceResult { try WhitegramAIWire.request(text: " \r\n\t", provider: .gemini, model: "test", apiKey: fixtureKey) })
    }

    func testModelAndCredentialInjectionAreRejected() {
        for model in ["", "../other", "a?key=x", "a#fragment", "a%2Fother", "a\r\nx-header:value", "https://example.invalid", "é", String(repeating: "a", count: 201)] {
            assertFailure(.invalidModel, whitegramServiceResult { try WhitegramAIWire.request(text: "prompt", provider: .gemini, model: model, apiKey: fixtureKey) })
        }
        for model in ["../model", "a/../b", "/model", "model/", "a//b"] {
            assertFailure(.invalidModel, whitegramServiceResult { try WhitegramAIProvider.groq.validatedModel(model) })
        }
        for key in ["key\r\nInjected: value", "two words", "clé", String(repeating: "a", count: 4097)] {
            assertFailure(.invalidAPIKey, whitegramServiceResult { try whitegramValidatedAPIKey(key) })
        }
        assertFailure(.missingAPIKey, whitegramServiceResult { try whitegramValidatedAPIKey(" \n") })
    }

    func testGeminiDecodesOneCandidateAndExcludesThoughtParts() throws {
        let data = try json([
            "modelVersion": "reported-model",
            "candidates": [
                ["index": 1, "finishReason": "STOP", "content": ["parts": [["text": "other candidate"]]]],
                ["index": 0, "finishReason": "STOP", "content": ["parts": [["text": "hidden", "thought": true], ["text": "Hello "], ["text": "world 🙂"]]]]
            ],
            "usageMetadata": ["promptTokenCount": 7, "candidatesTokenCount": 3, "totalTokenCount": 10]
        ] as [String: Any])
        let response = try WhitegramAIWire.response(WhitegramServiceHTTPResponse(statusCode: 200, data: data), provider: .gemini, model: "requested-model")
        XCTAssertEqual(response.text, "Hello world 🙂")
        XCTAssertEqual(response.model, "reported-model")
        XCTAssertEqual(response.inputTokens, 7)
        XCTAssertEqual(response.totalTokens, 10)
        XCTAssertFalse(response.isTruncated)
    }

    func testGeminiBlockedEmptyAndPartialResponses() throws {
        let blocked = try json(["promptFeedback": ["blockReason": "SAFETY"]])
        assertFailure(.outputBlocked, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: blocked), provider: .gemini, model: "test") })
        let candidate = try json(["candidates": [["finishReason": "SAFETY", "content": ["parts": [["text": "must not surface"]]]]]])
        assertFailure(.outputBlocked, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: candidate), provider: .gemini, model: "test") })
        let empty = try json(["candidates": [String]()])
        assertFailure(.noText, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: empty), provider: .gemini, model: "test") })
        let partial = try json(["candidates": [["finishReason": "MAX_TOKENS", "content": ["parts": [["text": "Partial"]]]]]])
        XCTAssertTrue(try WhitegramAIWire.response(.init(statusCode: 200, data: partial), provider: .gemini, model: "test").isTruncated)
    }

    func testGroqResponseUsageAndTruncation() throws {
        let data = try json([
            "model": "actual-model",
            "choices": [["index": 0, "finish_reason": "length", "message": ["content": "Some text", "reasoning": "not the answer"]]],
            "usage": ["prompt_tokens": 5, "completion_tokens": 6, "total_tokens": 11]
        ] as [String: Any])
        let response = try WhitegramAIWire.response(.init(statusCode: 200, data: data), provider: .groq, model: "test")
        XCTAssertEqual(response.text, "Some text")
        XCTAssertEqual(response.model, "actual-model")
        XCTAssertEqual(response.outputTokens, 6)
        XCTAssertEqual(response.totalTokens, 11)
        XCTAssertTrue(response.isTruncated)
    }

    func testGroqNullRefusalAndToolOnlyMessages() throws {
        let empty = try json(["choices": [["finish_reason": "stop", "message": ["content": NSNull()]]]])
        assertFailure(.noText, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: empty), provider: .groq, model: "test") })
        let refused = try json(["choices": [["finish_reason": "content_filter", "message": ["content": NSNull()]]]])
        assertFailure(.outputBlocked, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: refused), provider: .groq, model: "test") })
        let tool = try json(["choices": [["finish_reason": "tool_calls", "message": ["content": "not a completed answer"]]]])
        assertFailure(.unsupportedToolCall, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: tool), provider: .groq, model: "test") })
    }

    func testMixedTextAndToolResponsesAreNotMarkedAsCompletedAnswers() throws {
        let gemini = try json(["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "I will send it"], ["functionCall": ["name": "sendMessage"]]]]]]])
        assertFailure(.unsupportedToolCall, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: gemini), provider: .gemini, model: "test") })
        let groq = try json(["choices": [["finish_reason": "stop", "message": ["content": "I will send it", "tool_calls": [["id": "fixture-call"]]]]]])
        assertFailure(.unsupportedToolCall, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: groq), provider: .groq, model: "test") })
    }

    func testStatusErrorsDoNotExposeProviderBody() throws {
        let body = try json(["error": ["message": "Echoed secret " + fixtureKey]])
        for status in [400, 401, 403, 404, 500, 503] {
            let result = whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: status, data: body), provider: .groq, model: "test") }
            assertFailure(.httpStatus(status), result)
            if case let .failure(error) = result { XCTAssertFalse(error.localizedDescription.contains(fixtureKey)) }
        }
        assertFailure(.rateLimited(seconds: 42), whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 429, data: body, retryAfter: "42"), provider: .gemini, model: "test") })
    }

    func testMalformedAndOversizedResponsesFail() {
        assertFailure(.invalidResponse, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: Data("<html>not JSON</html>".utf8)), provider: .groq, model: "test") })
        let large = Data(repeating: 0, count: WhitegramServiceLimits.maximumAIResponseBytes + 1)
        assertFailure(.responseTooLarge, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: large), provider: .gemini, model: "test") })
    }

    func testInvalidUsageMetadataIsNotPresentedAsValidCounts() throws {
        let data = try json([
            "choices": [["finish_reason": "stop", "message": ["content": "Answer"]]],
            "usage": ["prompt_tokens": -5]
        ] as [String: Any])
        assertFailure(.invalidResponse, whitegramServiceResult { try WhitegramAIWire.response(.init(statusCode: 200, data: data), provider: .groq, model: "test") })
    }
}

final class WhitegramVirusTotalRequestTests: XCTestCase {
    private func report(attributes: [String: Any], id: String = fixtureHash, type: String = "file") throws -> WhitegramVirusTotalReport {
        let body = try json(["data": ["id": id, "type": type, "attributes": attributes, "links": ["self": "https://untrusted.invalid/"]]])
        guard case let .found(report) = try WhitegramVirusTotalWire.response(.init(statusCode: 200, data: body), sha256: fixtureHash) else {
            throw WhitegramServiceError.invalidResponse
        }
        return report
    }

    func testGetUsesOnlyHashAndAPIKeyHeader() throws {
        let request = try WhitegramVirusTotalWire.request(sha256: " \n" + fixtureHash.uppercased() + "\n", apiKey: fixtureKey)
        XCTAssertEqual(request.url?.absoluteString, "https://www.virustotal.com/api/v3/files/" + fixtureHash)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-apikey"), fixtureKey)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.url?.query)
        XCTAssertFalse(request.url?.absoluteString.contains(fixtureKey) ?? true)
    }

    func testHashValidation() {
        for value in ["", String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "g", count: 64), fixtureHash + "/other", "https://www.virustotal.com/" + fixtureHash, String(repeating: "é", count: 64)] {
            assertFailure(.invalidHash, whitegramServiceResult { try WhitegramVirusTotalWire.validatedHash(value) })
        }
    }

    func testActualStatsEnginesDatesAndCanonicalReportURL() throws {
        let report = try self.report(attributes: [
            "sha256": fixtureHash, "last_analysis_date": 1700000000,
            "last_analysis_stats": ["malicious": 1, "suspicious": 0, "undetected": 1, "failure": 2],
            "last_analysis_results": [
                "A": ["category": "undetected", "engine_name": "A", "result": NSNull()],
                "Z": ["category": "malicious", "engine_name": "Z", "result": "Test.Detection", "engine_version": "1", "engine_update": "20260927"]
            ]
        ])
        XCTAssertEqual(report.statistics?["failure"], 2)
        XCTAssertEqual(report.engines.map { $0.name }, ["Z", "A"])
        XCTAssertEqual(report.engines.first?.result, "Test.Detection")
        XCTAssertNil(report.engines.last?.result)
        XCTAssertEqual(report.analysisDate, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(report.reportURL.absoluteString, "https://www.virustotal.com/gui/file/" + fixtureHash + "/detection")
        XCTAssertTrue(report.summary.contains("malicious or suspicious"))
    }

    func testMissingReportIsUnknownAndNotAnEmptyCleanReport() throws {
        let body = try json(["error": ["code": "NotFoundError", "message": "not found"]])
        let result = try WhitegramVirusTotalWire.response(.init(statusCode: 404, data: body), sha256: fixtureHash)
        XCTAssertEqual(result, .notFound(sha256: fixtureHash))
        assertFailure(.httpStatus(404), whitegramServiceResult { try WhitegramVirusTotalWire.response(.init(statusCode: 404, data: Data("404 page".utf8)), sha256: fixtureHash) })
        assertFailure(.httpStatus(401), whitegramServiceResult { try WhitegramVirusTotalWire.response(.init(statusCode: 401, data: body), sha256: fixtureHash) })
    }

    func testMissingOrInconclusiveStatisticsRemainUnknown() throws {
        let missing = try self.report(attributes: [:])
        XCTAssertNil(missing.statistics)
        XCTAssertTrue(missing.summary.hasPrefix("Unknown"))
        for statistics in [[:], ["malicious": 0, "suspicious": 0], ["undetected": 50], ["malicious": 0, "suspicious": 0, "timeout": 50]] as [[String: Int]] {
            XCTAssertTrue(try self.report(attributes: ["last_analysis_stats": statistics]).summary.hasPrefix("Unknown"))
        }
        let noDetections = try self.report(attributes: ["last_analysis_stats": ["malicious": 0, "suspicious": 0, "undetected": 50]])
        XCTAssertTrue(noDetections.summary.hasPrefix("No detections"))
        XCTAssertFalse(noDetections.summary.contains("clean"))
    }

    func testMismatchedReportInvalidCountsAndTypeFail() {
        assertFailure(.invalidResponse, whitegramServiceResult { try self.report(attributes: [:], id: String(repeating: "b", count: 64)) })
        assertFailure(.invalidResponse, whitegramServiceResult { try self.report(attributes: ["sha256": String(repeating: "b", count: 64)]) })
        assertFailure(.invalidResponse, whitegramServiceResult { try self.report(attributes: [:], type: "analysis") })
        assertFailure(.invalidResponse, whitegramServiceResult { try self.report(attributes: ["last_analysis_stats": ["malicious": -1]]) })
        assertFailure(.invalidResponse, whitegramServiceResult { try self.report(attributes: ["last_analysis_stats": ["malicious": true]]) })
        assertFailure(.invalidResponse, whitegramServiceResult { try self.report(attributes: ["last_analysis_date": -1]) })
    }

    func testEngineDetectionsAreNotHiddenByZeroStatistics() throws {
        let report = try self.report(attributes: [
            "last_analysis_stats": ["malicious": 0, "suspicious": 0, "undetected": 10],
            "last_analysis_results": ["Engine": ["category": "suspicious", "result": "test"]]
        ])
        XCTAssertTrue(report.summary.contains("malicious or suspicious"))
    }

    func testRateLimitedAndOversizedReports() {
        assertFailure(.rateLimited(seconds: 60), whitegramServiceResult { try WhitegramVirusTotalWire.response(.init(statusCode: 429, data: Data()), sha256: fixtureHash) })
        let data = Data(repeating: 0, count: WhitegramServiceLimits.maximumVirusTotalResponseBytes + 1)
        assertFailure(.responseTooLarge, whitegramServiceResult { try WhitegramVirusTotalWire.response(.init(statusCode: 200, data: data), sha256: fixtureHash) })
    }
}

private final class PendingRequest: WhitegramServiceCancellable {
    private var completion: ((Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void)?
    private(set) var cancelCount = 0

    init(_ completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) { self.completion = completion }
    func complete(_ result: Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) {
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
    func cancel() { self.cancelCount += 1; self.complete(.failure(.cancelled)) }
}

private final class ManualTransport: WhitegramServiceTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var pending: [PendingRequest] = []
    func send(_ request: URLRequest, maximumResponseBytes: Int, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        self.requests.append(request)
        let pending = PendingRequest(completion)
        self.pending.append(pending)
        return pending
    }
}

final class WhitegramServiceLifecycleTests: XCTestCase {
    func testMissingCredentialsNeverReachTransportAndCompleteOnMain() {
        let transport = ManualTransport()
        let service = WhitegramAIService(transport: transport)
        let completed = self.expectation(description: "completion")
        service.generate(text: "prompt", provider: .gemini, model: "test", apiKey: "") { result in
            XCTAssertTrue(Thread.isMainThread)
            assertFailure(.missingAPIKey, result)
            completed.fulfill()
        }
        XCTAssertTrue(transport.requests.isEmpty)
        self.wait(for: [completed], timeout: 2)
    }

    func testInvalidVirusTotalHashNeverReachesTransport() {
        let transport = ManualTransport()
        let service = WhitegramVirusTotalService(transport: transport)
        let completed = self.expectation(description: "completion")
        service.lookup(sha256: "not a hash", apiKey: fixtureKey) { result in
            assertFailure(.invalidHash, result)
            completed.fulfill()
        }
        XCTAssertTrue(transport.requests.isEmpty)
        self.wait(for: [completed], timeout: 2)
    }

    func testConcurrentRequestsAreRejectedAndCancellationIsPropagated() {
        let transport = ManualTransport()
        let service = WhitegramAIService(transport: transport, minimumRequestInterval: 0)
        let first = self.expectation(description: "cancelled")
        let second = self.expectation(description: "busy")
        let task = service.generate(text: "first", provider: .groq, model: "test", apiKey: fixtureKey) { result in
            assertFailure(.cancelled, result); first.fulfill()
        }
        service.generate(text: "second", provider: .groq, model: "test", apiKey: fixtureKey) { result in
            assertFailure(.busy, result); second.fulfill()
        }
        XCTAssertEqual(transport.requests.count, 1)
        task.cancel()
        task.cancel()
        XCTAssertEqual(transport.pending.first?.cancelCount, 1)
        self.wait(for: [first, second], timeout: 2)
    }

    func testCancellationReleasesRequestGate() throws {
        let transport = ManualTransport()
        let service = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0)
        let cancelled = self.expectation(description: "cancelled")
        let finished = self.expectation(description: "second result")
        let task = service.lookup(sha256: fixtureHash, apiKey: fixtureKey) { result in assertFailure(.cancelled, result); cancelled.fulfill() }
        task.cancel()
        service.lookup(sha256: fixtureHash, apiKey: fixtureKey) { result in
            XCTAssertEqual(try? result.get(), .notFound(sha256: fixtureHash)); finished.fulfill()
        }
        XCTAssertEqual(transport.requests.count, 2)
        transport.pending[1].complete(.success(.init(statusCode: 404, data: try json(["error": ["code": "NotFoundError"]]))))
        self.wait(for: [cancelled, finished], timeout: 2)
    }

    func testCancelWinsOverQueuedSuccessAndCompletionIsExactlyOnce() {
        let completed = self.expectation(description: "single cancellation")
        completed.assertForOverFulfill = true
        let operation = WhitegramServiceOperation<Int> { result in
            assertFailure(.cancelled, result)
            completed.fulfill()
        }
        operation.finish(.success(1))
        operation.finish(.success(2))
        operation.task.cancel()
        self.wait(for: [completed], timeout: 2)
    }

    func testGateSpacingUsesMonotonicTimeAndServerBackoff() throws {
        var now: TimeInterval = 100
        let gate = WhitegramServiceRequestGate(minimumInterval: 15, now: { now })
        try gate.begin()
        assertFailure(.busy, whitegramServiceResult { try gate.begin() })
        gate.end()
        now = 114
        assertFailure(.rateLimited(seconds: 1), whitegramServiceResult { try gate.begin() })
        now = 115
        try gate.begin()
        gate.end(retryAfter: 90)
        now = 204
        assertFailure(.rateLimited(seconds: 1), whitegramServiceResult { try gate.begin() })
        now = 205
        try gate.begin()
        gate.end()
    }

    func testRetryAfterSecondsDatesAndInvalidValues() {
        XCTAssertEqual(whitegramRetryAfter("1.2"), 2)
        XCTAssertEqual(whitegramRetryAfter("0"), 1)
        XCTAssertEqual(whitegramRetryAfter("Thu, 01 Jan 1970 00:01:30 GMT", now: Date(timeIntervalSince1970: 0)), 90)
        for value in ["NaN", "inf", "-5", "invalid"] { XCTAssertEqual(whitegramRetryAfter(value), 60) }
        XCTAssertEqual(whitegramRetryAfter("99999999999999999999999"), 604800)
        XCTAssertEqual(whitegramHTTPError(status: 307, retryAfter: nil), .redirectRefused)
        XCTAssertEqual(WhitegramServiceHTTPResponse(statusCode: 503, data: Data(), retryAfter: "30").cooldownSeconds, 30)
        XCTAssertNil(WhitegramServiceHTTPResponse(statusCode: 200, data: Data(), retryAfter: "30").cooldownSeconds)
    }

    func testServerRateLimitBackoffPreventsASecondHTTPCall() {
        let transport = ManualTransport()
        let service = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0)
        let first = self.expectation(description: "server limit")
        let second = self.expectation(description: "local backoff")
        service.lookup(sha256: fixtureHash, apiKey: fixtureKey) { result in
            assertFailure(.rateLimited(seconds: 60), result)
            first.fulfill()
        }
        transport.pending[0].complete(.success(.init(statusCode: 429, data: Data(), retryAfter: "60")))
        service.lookup(sha256: fixtureHash, apiKey: fixtureKey) { result in
            guard case let .failure(.rateLimited(seconds)) = result else { XCTFail("Expected active backoff"); second.fulfill(); return }
            XCTAssertGreaterThan(seconds, 0)
            second.fulfill()
        }
        XCTAssertEqual(transport.requests.count, 1)
        self.wait(for: [first, second], timeout: 2)
    }
}
