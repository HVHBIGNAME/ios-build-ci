import Foundation
import XCTest
@testable import WhitegramBackendHost

final class WhitegramServiceProxyTests: XCTestCase {
    override func tearDown() {
        BackendNoNetworkProtocol.handler = nil
        BackendNoNetworkProtocol.stopped = nil
        super.tearDown()
    }

    private func account(_ fixture: BackendFixture) -> WhitegramAccountServices {
        return WhitegramAccountServices(backend: WhitegramBackendAuthorizedTransport(client: fixture.client))
    }

    private func interceptedProxy(_ fixture: BackendFixture) -> WhitegramServiceProxyTransport {
        let client = WhitegramBackendClient(userId: 42, sessions: fixture.sessions,
            http: WhitegramBackendPinnedHTTP(configuration: BackendNoNetworkProtocol.configuration), now: { fixture.date },
            access: fixture.access, recordUsage: { _ in }, applicationKey: { BackendFixture.applicationKey }, deviceSignature: { _ in nil })
        return WhitegramServiceProxyTransport(backend: WhitegramBackendAuthorizedTransport(client: client))
    }

    private func drain() {
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testGeminiGenerationSignsProxyPathAndSeparatesProviderCredentials() throws {
        let fixture = BackendFixture()
        let services = account(fixture)
        let done = expectation(description: "Gemini response")
        services.ai(route: .originalProxy).generate(text: "fixture prompt", provider: .gemini, model: "gemini-fixture",
            apiKey: "fixture-provider-key", route: .originalProxy) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result.get().text, "fixture reply")
            done.fulfill()
        }
        let request = try XCTUnwrap(fixture.http.calls.first?.request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.whitegram.heypainservice.online/v1/proxy/gemini/v1beta/models/gemini-fixture:generateContent")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Whitegram synthetic-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Provider-Key"), "fixture-provider-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
        let canonical = "1700000000:POST:/v1/proxy/gemini/v1beta/models/gemini-fixture:generateContent"
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-WG-Device-Sig"), "synthetic-device-signature:" + canonical)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-WG-Sig"), WhitegramBackendProtocol.signature(message: canonical, key: BackendFixture.applicationKey))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-WG-Session-Sig"), WhitegramBackendProtocol.signature(message: canonical, key: Data(0..<32)))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual((contents.first?["parts"] as? [[String: String]])?.first?["text"], "fixture prompt")
        XCTAssertNil(body["user_id"])
        fixture.http.respond(0, data: Data(#"{"candidates":[{"index":0,"content":{"parts":[{"text":"fixture reply"}]},"finishReason":"STOP"}]}"#.utf8))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(fixture.http.calls.count, 1)
    }

    func testModelDiscoveryPreservesGeminiPageTokenAndGroqModelsPath() throws {
        let token = "page/with +=雪&next=value"
        for provider in WhitegramAIProvider.allCases {
            let fixture = BackendFixture()
            let done = expectation(description: "\(provider) models")
            account(fixture).ai(route: .originalProxy).fetchModels(provider: provider, apiKey: "fixture-key", route: .originalProxy,
                pageToken: provider == .gemini ? token : nil) { result in
                XCTAssertEqual(try? result.get().models.map { $0.id }, ["fixture-model"])
                done.fulfill()
            }
            let request = try XCTUnwrap(fixture.http.calls.first?.request)
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Whitegram synthetic-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Provider-Key"), "fixture-key")
            XCTAssertNil(request.httpBody)
            let response: String
            if provider == .gemini {
                XCTAssertEqual(url.path, "/v1/proxy/gemini/v1beta/models")
                XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                    [URLQueryItem(name: "pageSize", value: "20"), URLQueryItem(name: "pageToken", value: token)])
                response = #"{"models":[{"name":"models/fixture-model","supportedGenerationMethods":["generateContent"]}]}"#
            } else {
                XCTAssertEqual(url.path, "/v1/proxy/groq/openai/v1/models")
                XCTAssertNil(url.query)
                response = #"{"data":[{"id":"fixture-model","active":true}]}"#
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-WG-Device-Sig"),
                "synthetic-device-signature:1700000000:GET:" + url.path + (url.query.map { "?" + $0 } ?? ""))
            fixture.http.respond(0, data: Data(response.utf8))
            wait(for: [done], timeout: 2)
        }
    }

    func testMissingExpiredMismatchedAndUnverifiedSessionsNeverReachHTTP() {
        let missing = BackendFixture()
        missing.sessions.values.removeAll()
        let expired = BackendFixture()
        expired.date = expired.date.addingTimeInterval(3601)
        let mismatched = BackendFixture()
        mismatched.sessions.values[42] = WhitegramBackendSession(userId: 43, token: "wrong-account",
            expiresAt: mismatched.date.addingTimeInterval(3600), sessionKey: nil)
        let cases: [(BackendFixture, WhitegramServiceError)] = [
            (missing, .originalProxyUnavailable), (expired, .originalProxyUnavailable),
            (mismatched, .originalProxyUnavailable), (BackendFixture(allowed: nil), .originalProxyAccessUnverified),
            (BackendFixture(allowed: false), .originalProxyAccessDenied)
        ]
        for (fixture, error) in cases {
            let done = expectation(description: "proxy authorization failure")
            account(fixture).ai(route: .originalProxy).generate(text: "fixture prompt", provider: .gemini, model: "fixture",
                apiKey: "fixture-key", route: .originalProxy) { result in
                XCTAssertEqual(result.serviceFailure, error)
                done.fulfill()
            }
            wait(for: [done], timeout: 2)
            XCTAssertTrue(fixture.http.calls.isEmpty)
        }
    }

    func testMissingApplicationKeyFailsBeforeSendingProviderContent() {
        let fixture = BackendFixture()
        let client = WhitegramBackendClient(userId: 42, sessions: fixture.sessions, http: fixture.http,
            now: { fixture.date }, access: fixture.access, recordUsage: { _ in },
            applicationKey: { throw WhitegramBackendError.missingApplicationKey }, deviceSignature: { _ in nil })
        let services = WhitegramAccountServices(backend: WhitegramBackendAuthorizedTransport(client: client))
        let done = expectation(description: "missing signing configuration")
        services.virusTotal(route: .originalProxy).lookup(sha256: String(repeating: "a", count: 64), apiKey: "fixture-key") { result in
            XCTAssertEqual(result.serviceFailure, .originalProxySigningUnavailable)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(fixture.http.calls.isEmpty)
    }

    func testRoutesRequireExplicitAccountAndMatchingTransport() throws {
        XCTAssertThrowsError(try WhitegramServiceRoute.originalProxy.aiService(account: nil)) {
            XCTAssertEqual($0 as? WhitegramServiceError, .originalProxyUnavailable)
        }
        XCTAssertThrowsError(try WhitegramServiceRoute.originalProxy.virusTotalService(account: nil)) {
            XCTAssertEqual($0 as? WhitegramServiceError, .originalProxyUnavailable)
        }
        XCTAssertTrue(try WhitegramServiceRoute.direct.aiService(account: nil) === WhitegramAIService.shared)
        XCTAssertTrue(try WhitegramServiceRoute.direct.virusTotalService(account: nil) === WhitegramVirusTotalService.shared)
        let fixture = BackendFixture()
        let services = account(fixture)
        XCTAssertTrue(services.ai(route: .originalProxy) === services.ai(route: .originalProxy))
        XCTAssertTrue(services.virusTotal(route: .originalProxy) === services.virusTotal(route: .originalProxy))
        let done = expectation(description: "route mismatch")
        services.ai(route: .originalProxy).generate(text: "fixture prompt", provider: .gemini, model: "fixture",
            apiKey: "fixture-key", route: .direct) { result in
            XCTAssertEqual(result.serviceFailure, .originalProxyUnavailable)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(fixture.http.calls.isEmpty)
    }

    func testVirusTotalErrorBodiesStayTypedAndProvider401KeepsSession() throws {
        let hash = String(repeating: "a", count: 64)
        let cases = [(404, #"{"error":{"code":"NotFoundError"}}"#), (404, "<html>missing</html>"), (401, #"{"error":{"code":"WrongCredentialsError"}}"#)]
        for (status, body) in cases {
            let fixture = BackendFixture()
            let done = expectation(description: "VirusTotal HTTP \(status)")
            account(fixture).virusTotal(route: .originalProxy).lookup(sha256: hash, apiKey: "fixture-key") { result in
                if body.contains("NotFoundError") {
                    XCTAssertEqual(try? result.get(), .notFound(sha256: hash))
                } else {
                    XCTAssertEqual(result.serviceFailure, .httpStatus(status))
                }
                done.fulfill()
            }
            let request = try XCTUnwrap(fixture.http.calls.first?.request)
            XCTAssertEqual(request.url?.path, "/v1/proxy/virustotal/v3/files/" + hash)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Provider-Key"), "fixture-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-apikey"))
            fixture.http.respond(0, status: status, data: Data(body.utf8))
            wait(for: [done], timeout: 2)
            XCTAssertEqual(fixture.sessions.values[42]?.token, "synthetic-token")
            XCTAssertEqual(fixture.sessions.removals, 0)
        }
    }

    func testBackendRetryAfterBlocksANewServiceClientWithoutResending() throws {
        let fixture = BackendFixture()
        let first = expectation(description: "provider rate limit")
        account(fixture).ai(route: .originalProxy).generate(text: "fixture", provider: .groq, model: "fixture",
            apiKey: "fixture-key", route: .originalProxy) { result in
            XCTAssertEqual(result.serviceFailure, .rateLimited(seconds: 90))
            first.fulfill()
        }
        _ = try XCTUnwrap(fixture.http.calls.first)
        fixture.http.respond(0, status: 429, headers: ["Retry-After": "90"])
        wait(for: [first], timeout: 2)
        let second = expectation(description: "backend backoff")
        account(fixture).ai(route: .originalProxy).generate(text: "fixture", provider: .groq, model: "fixture",
            apiKey: "fixture-key", route: .originalProxy) { result in
            XCTAssertEqual(result.serviceFailure, .rateLimited(seconds: 90))
            second.fulfill()
        }
        wait(for: [second], timeout: 2)
        XCTAssertEqual(fixture.http.calls.count, 1)
    }

    func testSessionReplacementCancelsStreamAndPreservesOtherAccounts() throws {
        let fixture = BackendFixture()
        let other = WhitegramBackendSession(userId: 43, token: "other-account", expiresAt: fixture.date.addingTimeInterval(3600), sessionKey: nil)
        fixture.sessions.values[43] = other
        let done = expectation(description: "session replaced")
        done.assertForOverFulfill = true
        account(fixture).ai(route: .originalProxy).generateStreaming(messages: [.init(role: .user, text: "fixture")],
            provider: .groq, model: "fixture", apiKey: "fixture-key", route: .originalProxy,
            onText: { _ in XCTFail("Changed session delivered text") }) { result in
            XCTAssertEqual(result.serviceFailure, .originalProxySessionChanged)
            done.fulfill()
        }
        let call = try XCTUnwrap(fixture.http.calls.first)
        fixture.sessions.values[42] = fixture.session(token: "replacement-token")
        NotificationCenter.default.post(name: whitegramBackendSessionUpdated, object: nil, userInfo: ["userId": Int64(42)])
        XCTAssertTrue(call.task.cancelled)
        XCTAssertThrowsError(try call.transfer.validateSession())
        fixture.http.respond(0)
        fixture.http.respond(0)
        wait(for: [done], timeout: 2)
        drain()
        XCTAssertEqual(fixture.sessions.values[42]?.token, "replacement-token")
        XCTAssertEqual(fixture.sessions.values[43], other)
    }

    func testGroqStreamThroughURLSessionPreservesSplitUTF8AndCompletion() throws {
        let fixture = BackendFixture()
        let first = Data("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello 👋\"}}]}\r\n\r\n".utf8)
        let split = try XCTUnwrap(first.firstIndex(of: 0xf0)) + 1
        let terminal = Data("data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
        BackendNoNetworkProtocol.handler = { protocolObject in
            XCTAssertEqual(protocolObject.request.url?.absoluteString, "https://api.whitegram.heypainservice.online/v1/proxy/groq/openai/v1/chat/completions")
            XCTAssertEqual(protocolObject.request.value(forHTTPHeaderField: "Authorization"), "Whitegram synthetic-token")
            XCTAssertEqual(protocolObject.request.value(forHTTPHeaderField: "X-Provider-Key"), "fixture-key")
            XCTAssertEqual(protocolObject.request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
            protocolObject.respond(status: 200, chunks: [Data(first.prefix(split)), Data(first.dropFirst(split)), terminal])
        }
        var partials: [String] = []
        let done = expectation(description: "stream complete")
        WhitegramAIService(transport: interceptedProxy(fixture)).generateStreaming(messages: [.init(role: .user, text: "fixture")],
            provider: .groq, model: "fixture", apiKey: "fixture-key", route: .originalProxy, onText: { text in
                XCTAssertTrue(Thread.isMainThread)
                partials.append(text)
            }) { result in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(partials, ["Hello 👋"])
                XCTAssertEqual(try? result.get().text, "Hello 👋")
                XCTAssertEqual(try? result.get().finishReason, "stop")
                done.fulfill()
            }
        wait(for: [done], timeout: 3)
    }

    func testGroqConsumerErrorsSurviveBackendErrorMapping() {
        let cases: [(String, WhitegramServiceError)] = [
            (#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0}]}}]}"#, .unsupportedToolCall),
            (#"{"choices":[{"index":0,"delta":{},"finish_reason":"content_filter"}]}"#, .outputBlocked)
        ]
        for (body, error) in cases {
            let fixture = BackendFixture()
            BackendNoNetworkProtocol.handler = { $0.respond(status: 200, chunks: [Data(("data: " + body + "\n\n").utf8)]) }
            let done = expectation(description: "typed stream failure")
            done.assertForOverFulfill = true
            WhitegramAIService(transport: interceptedProxy(fixture)).generateStreaming(messages: [.init(role: .user, text: "fixture")],
                provider: .groq, model: "fixture", apiKey: "fixture-key", route: .originalProxy,
                onText: { _ in XCTFail("Rejected output became text") }) { result in
                XCTAssertEqual(result.serviceFailure, error)
                done.fulfill()
            }
            wait(for: [done], timeout: 3)
        }
    }

    func testVirusTotalSubmissionAndPollingKeepSignedProxyRoute() throws {
        let fixture = BackendFixture()
        let scheduler = ServiceProxyScheduler()
        let service = WhitegramVirusTotalService(transport: WhitegramServiceProxyTransport(backend: account(fixture).backend),
            minimumRequestInterval: 0, route: .originalProxy)
        var completed = false
        let submitted = expectation(description: "submitted; waiting to poll")
        scheduler.scheduled = { submitted.fulfill() }
        let done = expectation(description: "analysis completed")
        let task = service.startScan(target: .url("https://example.com/a?q=one+two&x=1"), analysisId: nil, scheduler: scheduler,
            progress: { _ in }, apiKey: "fixture-key") { result in
            completed = true
            XCTAssertEqual(try? result.get().status, .completed)
            XCTAssertEqual(try? result.get().statistics?["malicious"], 1)
            done.fulfill()
        }
        drain()
        let post = try XCTUnwrap(fixture.http.calls.first?.request)
        XCTAssertEqual(post.url?.path, "/v1/proxy/virustotal/v3/urls")
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(post.httpBody.map { String(decoding: $0, as: UTF8.self) }, "url=https%3A%2F%2Fexample.com%2Fa%3Fq%3Done%2Btwo%26x%3D1")
        fixture.http.respond(0, data: Data(#"{"data":{"type":"analysis","id":"fixture-analysis"}}"#.utf8))
        wait(for: [submitted], timeout: 2)
        XCTAssertFalse(completed)
        let pending = expectation(description: "queued; waiting to poll again")
        scheduler.scheduled = { pending.fulfill() }
        try scheduler.runNext()
        XCTAssertEqual(fixture.http.calls.count, 2)
        fixture.http.respond(1, data: Data(#"{"data":{"type":"analysis","id":"fixture-analysis","attributes":{"status":"queued"}}}"#.utf8))
        wait(for: [pending], timeout: 2)
        XCTAssertFalse(completed)
        scheduler.scheduled = nil
        try scheduler.runNext()
        XCTAssertEqual(fixture.http.calls.count, 3)
        fixture.http.respond(2, data: Data(#"{"data":{"type":"analysis","id":"fixture-analysis","attributes":{"status":"completed","stats":{"malicious":1}}}}"#.utf8))
        wait(for: [done], timeout: 2)
        XCTAssertEqual(scheduler.delays, [15, 15])
        for call in fixture.http.calls {
            XCTAssertEqual(call.request.url?.host, "api.whitegram.heypainservice.online")
            XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"), "Whitegram synthetic-token")
            XCTAssertEqual(call.request.value(forHTTPHeaderField: "X-Provider-Key"), "fixture-key")
        }
        for call in fixture.http.calls.dropFirst() {
            XCTAssertEqual(call.request.httpMethod, "GET")
            XCTAssertEqual(call.request.url?.path, "/v1/proxy/virustotal/v3/analyses/fixture-analysis")
        }
        task.cancel()
    }

    func testUploadDestinationsStayWithinSignedVirusTotalNamespace() throws {
        let fixture = BackendFixture()
        let proxy = WhitegramServiceProxyTransport(backend: account(fixture).backend)
        let base = WhitegramBackendAuthorizedTransport.baseURL.absoluteString
        for origin in ["https://www.virustotal.com/api", base + "/v1/proxy/virustotal"] {
            let url = try proxy.validatedUploadURL(origin + "/v3/files/upload/fixture?token=opaque%2Bvalue")
            XCTAssertEqual(url.host, "api.whitegram.heypainservice.online")
            XCTAssertEqual(url.path, "/v1/proxy/virustotal/v3/files/upload/fixture")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "token", value: "opaque+value")])
        }
        for value in ["https://attacker.invalid/api/v3/files", "https://www.virustotal.com.attacker.invalid/api/v3/files",
                      "http://www.virustotal.com/api/v3/files", "https://user:pass@www.virustotal.com/api/v3/files",
                      "https://www.virustotal.com:444/api/v3/files", "https://www.virustotal.com/api/v3/files#fragment",
                      "https://www.virustotal.com/api/v3/files/%2e%2e/auth", "https://www.virustotal.com/_ah/upload/fixture",
                      base + "/v1/auth/session", base + "/v1/proxy/groq/openai/v1/chat/completions"] {
            XCTAssertThrowsError(try proxy.validatedUploadURL(value), value)
        }
        XCTAssertTrue(fixture.http.calls.isEmpty)
    }

    func testProxyUploadCancellationCompletesAfterURLSessionStopsReading() throws {
        let fixture = BackendFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhitegramServiceProxyUpload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("multipart.bin")
        try Data(repeating: 65, count: 4096).write(to: file)
        let started = expectation(description: "proxy upload started")
        let stopped = expectation(description: "backend stopped reading")
        BackendNoNetworkProtocol.handler = { protocolObject in
            XCTAssertEqual(protocolObject.request.url?.path, "/v1/proxy/virustotal/v3/files")
            XCTAssertEqual(protocolObject.request.value(forHTTPHeaderField: "Authorization"), "Whitegram synthetic-token")
            XCTAssertEqual(protocolObject.request.value(forHTTPHeaderField: "X-Provider-Key"), "fixture-key")
            started.fulfill()
        }
        BackendNoNetworkProtocol.stopped = { stopped.fulfill() }
        var request = try WhitegramVirusTotalScanWire.request(path: "files", method: "POST", apiKey: "fixture-key")
        request.setValue("multipart/form-data; boundary=fixture", forHTTPHeaderField: "Content-Type")
        let done = expectation(description: "proxy upload cancelled")
        done.assertForOverFulfill = true
        let task = interceptedProxy(fixture).upload(request, bodyFile: file, maximumResponseBytes: 4096, progress: { _, _ in }) { result in
            XCTAssertEqual(result.serviceFailure, .cancelled)
            XCTAssertTrue(Thread.isMainThread)
            done.fulfill()
        }
        wait(for: [started], timeout: 3)
        task.cancel()
        wait(for: [stopped, done], timeout: 3, enforceOrder: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

private extension Result where Failure == WhitegramServiceError {
    var serviceFailure: WhitegramServiceError? { if case let .failure(error) = self { return error }; return nil }
}

private final class ServiceProxyScheduler: WhitegramServiceScheduler {
    var scheduled: (() -> Void)?
    var delays: [TimeInterval] = []
    private var pending: [(WhitegramServiceTask, () -> Void)] = []

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> WhitegramServiceCancellable {
        let task = WhitegramServiceTask()
        delays.append(delay)
        pending.append((task, action))
        scheduled?()
        return task
    }

    func runNext() throws {
        let (task, action) = try XCTUnwrap(pending.first)
        pending.removeFirst()
        if !task.isCancelled { action() }
    }
}
