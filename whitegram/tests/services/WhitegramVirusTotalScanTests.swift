import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import WhitegramServiceHost

private final class ScanFixtureRequest: WhitegramServiceCancellable {
    private var completion: ((Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void)?
    let delayCancellation: Bool
    init(delayCancellation: Bool = false, _ completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) {
        self.delayCancellation = delayCancellation
        self.completion = completion
    }
    func finish(_ result: Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) {
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
    func cancel() { if !self.delayCancellation { self.finish(.failure(.cancelled)) } }
}

private final class ScanFixtureTransport: WhitegramServiceUploadTransport {
    var requests: [URLRequest] = []
    var pending: [ScanFixtureRequest] = []
    var uploads: [(request: URLRequest, bodyFile: URL)] = []
    var delayUploadCancellation = false
    var uploadStarted: (() -> Void)?
    func send(_ request: URLRequest, maximumResponseBytes: Int, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        self.requests.append(request)
        let task = ScanFixtureRequest(completion)
        self.pending.append(task)
        return task
    }
    func upload(_ request: URLRequest, bodyFile: URL, maximumResponseBytes: Int, progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        self.uploads.append((request, bodyFile))
        let task = ScanFixtureRequest(delayCancellation: self.delayUploadCancellation, completion)
        self.pending.append(task)
        self.uploadStarted?()
        return task
    }
    func respond(_ value: Any, status: Int = 200, retryAfter: String? = nil) throws {
        let request = self.pending.removeFirst()
        request.finish(.success(WhitegramServiceHTTPResponse(statusCode: status, data: try JSONSerialization.data(withJSONObject: value), retryAfter: retryAfter)))
    }
}

private final class ScanFixtureScheduler: WhitegramServiceScheduler {
    var pending: [(WhitegramServiceTask, () -> Void)] = []
    var delays: [TimeInterval] = []
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> WhitegramServiceCancellable {
        let task = WhitegramServiceTask()
        self.delays.append(delay)
        self.pending.append((task, action))
        return task
    }
    func runNext() {
        let (task, action) = self.pending.removeFirst()
        if !task.isCancelled { action() }
    }
}

final class WhitegramVirusTotalScanTests: XCTestCase {
    private func drain() {
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func analysis(_ status: String, stats: [String: Any]? = nil, id: String = "fixture-analysis") -> [String: Any] {
        var attributes: [String: Any] = ["status": status, "date": 1700000000]
        attributes["stats"] = stats
        return ["data": ["id": id, "type": "analysis", "attributes": attributes]]
    }

    func testURLSubmissionFormPreservesQueryAndDoesNotAppendAPIKey() throws {
        let request = try WhitegramVirusTotalScanWire.submit(target: .url("https://example.com/a?q=one+two&other=тест#discard"), apiKey: "fixture-key")
        XCTAssertEqual(request.url?.absoluteString, "https://www.virustotal.com/api/v3/urls")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-apikey"), "fixture-key")
        let body = try XCTUnwrap(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("%2B"))
        XCTAssertTrue(body.contains("%26other%3D"))
        XCTAssertFalse(body.contains("fixture-key"))
        XCTAssertFalse(body.contains("discard"))
        XCTAssertThrowsError(try WhitegramVirusTotalScanWire.submit(target: .ipAddress("203.0.113.4"), apiKey: "fixture-key"))
        let file = try WhitegramVirusTotalScanWire.submit(target: .file(sha256: String(repeating: "a", count: 64)), apiKey: "fixture-key")
        XCTAssertTrue(file.url?.path.hasSuffix("/analyse") == true)
        XCTAssertNil(file.httpBody)
    }

    func testAcceptedSubmissionAndQueuedStatusAreNotCompletion() throws {
        let transport = ScanFixtureTransport()
        let scheduler = ScanFixtureScheduler()
        let service = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0)
        var received: WhitegramVirusTotalAnalysis?
        var failure: WhitegramServiceError?
        let task = service.startScan(target: .url("https://example.com/"), analysisId: nil, scheduler: scheduler, progress: { _ in }, apiKey: "fixture-key") { result in
            switch result {
            case let .success(value): received = value
            case let .failure(error): failure = error
            }
        }
        drain()
        try transport.respond(["data": ["type": "analysis", "id": "fixture-analysis"]])
        drain()
        XCTAssertNil(received)
        XCTAssertNil(failure)
        XCTAssertEqual(scheduler.delays, [15])
        scheduler.runNext()
        XCTAssertEqual(transport.requests.last?.url?.path, "/api/v3/analyses/fixture-analysis")
        try transport.respond(analysis("queued"))
        drain()
        XCTAssertNil(received)
        scheduler.runNext()
        try transport.respond(analysis("in-progress"))
        drain()
        XCTAssertNil(received)
        scheduler.runNext()
        try transport.respond(analysis("completed", stats: ["malicious": 1, "suspicious": 0, "undetected": 3]))
        drain(); drain()
        XCTAssertNil(failure)
        XCTAssertEqual(received?.status, .completed)
        XCTAssertTrue(received?.summary.contains("malicious or suspicious") == true)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1)
        task.cancel()
    }

    func testCancelAfterSubmissionCancelsPendingPollAndCompletesOnce() throws {
        let transport = ScanFixtureTransport()
        let scheduler = ScanFixtureScheduler()
        let service = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0)
        let completed = expectation(description: "cancelled")
        completed.assertForOverFulfill = true
        let task = service.startScan(target: .url("https://example.com/"), analysisId: nil, scheduler: scheduler, progress: { _ in }, apiKey: "fixture-key") { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .cancelled) } else { XCTFail("Queue acceptance is not success") }
            completed.fulfill()
        }
        drain()
        try transport.respond(["data": ["type": "analysis", "id": "fixture-analysis"]])
        drain()
        task.cancel()
        scheduler.runNext()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testResumeAndPollingLimitNeverResubmitPOST() throws {
        let transport = ScanFixtureTransport()
        let scheduler = ScanFixtureScheduler()
        let service = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0)
        var failure: WhitegramServiceError?
        let task = service.startScan(target: nil, analysisId: "fixture-analysis", scheduler: scheduler, progress: { _ in }, apiKey: "fixture-key") { result in
            if case let .failure(error) = result { failure = error } else { XCTFail("Queued analysis cannot complete successfully") }
        }
        drain()
        for _ in 0..<WhitegramServiceLimits.maximumAnalysisPolls {
            try transport.respond(analysis("queued"))
            drain()
            scheduler.runNext()
        }
        drain()
        XCTAssertEqual(failure, .analysisPending("fixture-analysis"))
        XCTAssertEqual(transport.requests.count, WhitegramServiceLimits.maximumAnalysisPolls)
        XCTAssertTrue(transport.requests.allSatisfy { $0.httpMethod == "GET" })
        task.cancel()
    }

    func testPOSTRateLimitIsNotRetriedAndOriginalProxyDoesNotReachTransport() throws {
        let transport = ScanFixtureTransport()
        let scheduler = ScanFixtureScheduler()
        let service = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0)
        var failure: WhitegramServiceError?
        let task = service.startScan(target: .url("https://example.com/"), analysisId: nil, scheduler: scheduler, progress: { _ in }, apiKey: "fixture-key") { result in
            if case let .failure(error) = result { failure = error }
        }
        drain()
        try transport.respond(["error": ["code": "QuotaExceededError"]], status: 429, retryAfter: "30")
        drain(); drain()
        XCTAssertEqual(failure, .rateLimited(seconds: 30))
        XCTAssertTrue(scheduler.pending.isEmpty)
        let ai = WhitegramAIService(transport: transport, minimumRequestInterval: 0)
        let completed = expectation(description: "proxy blocked")
        ai.generate(text: "private prompt", provider: .gemini, model: "model", apiKey: "fixture-key", route: .originalProxy) { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .originalProxyUnavailable) } else { XCTFail("Proxy must not use a direct endpoint") }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(transport.requests.count, 1)
        task.cancel()
    }

    func testAnalysisIdentityStatusesAndStatisticsAreValidated() throws {
        for value in [analysis("unknown"), analysis("completed", stats: ["malicious": -1]), analysis("completed", stats: ["malicious": true]), analysis("completed", id: "other")] {
            let response = WhitegramServiceHTTPResponse(statusCode: 200, data: try JSONSerialization.data(withJSONObject: value))
            XCTAssertThrowsError(try WhitegramVirusTotalScanWire.analysis(response, expectedId: "fixture-analysis"))
        }
        let unknown = try WhitegramVirusTotalScanWire.analysis(.init(statusCode: 200, data: JSONSerialization.data(withJSONObject: analysis("completed"))), expectedId: "fixture-analysis")
        XCTAssertNil(unknown.statistics)
        XCTAssertTrue(unknown.summary.hasPrefix("Unknown"))
        for id in ["../escape", "job?key=value", "job/other", "", "job\nheader"] { XCTAssertThrowsError(try WhitegramVirusTotalScanWire.analysisId(id)) }
    }

    func testUploadURLIsBoundToOfficialHostAndMultipartFilenameCannotInjectHeaders() throws {
        XCTAssertEqual(try WhitegramVirusTotalScanWire.uploadURL("https://www.virustotal.com/_ah/upload/fixture?token=test").host, "www.virustotal.com")
        for value in ["http://www.virustotal.com/_ah/upload/x", "https://attacker.invalid/_ah/upload/x", "https://www.virustotal.com.attacker.invalid/_ah/upload/x", "https://user:pass@www.virustotal.com/_ah/upload/x", "https://www.virustotal.com/api/v3/other", "https://www.virustotal.com:444/_ah/upload/x"] {
            XCTAssertThrowsError(try WhitegramVirusTotalScanWire.uploadURL(value))
        }
        let header = try WhitegramVirusTotalUpload.header(boundary: "fixture-boundary", fileName: "test\"\r\nInjected: value.bin")
        let text = String(decoding: header, as: UTF8.self)
        XCTAssertFalse(text.contains("\r\nInjected"))
        XCTAssertTrue(text.contains("%22%0D%0A"))
        XCTAssertThrowsError(try WhitegramVirusTotalUpload.header(boundary: "bad\r\n", fileName: "a"))
        XCTAssertThrowsError(try WhitegramVirusTotalUpload.header(boundary: "fixture", fileName: "e" + String(repeating: "\u{301}", count: 1024)))
    }

    func testFixedConnectionProbeUsesOriginalVKURLAndNoUserContent() throws {
        let transport = ScanFixtureTransport()
        let service = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0)
        let completed = expectation(description: "probe")
        service.testConnection(apiKey: "fixture-key") { result in
            XCTAssertEqual(try? result.get(), false)
            completed.fulfill()
        }
        XCTAssertEqual(transport.requests.first?.url?.lastPathComponent, Data("https://vk.com".utf8).base64EncodedString().replacingOccurrences(of: "=", with: ""))
        XCTAssertNil(transport.requests.first?.httpBody)
        try transport.respond(["error": ["code": "NotFoundError"]], status: 404)
        wait(for: [completed], timeout: 2)
    }

    func testProxyDefaultRequiresExplicitBooleanFalseAndVirusTotalNeverFallsBackToDirect() {
        XCTAssertEqual(WhitegramServiceRoute.fromProxyFlag(nil), .originalProxy)
        XCTAssertEqual(WhitegramServiceRoute.fromProxyFlag(true), .originalProxy)
        XCTAssertEqual(WhitegramServiceRoute.fromProxyFlag(0), .originalProxy)
        XCTAssertEqual(WhitegramServiceRoute.fromProxyFlag("false"), .originalProxy)
        XCTAssertEqual(WhitegramServiceRoute.fromProxyFlag(false), .direct)
        let transport = ScanFixtureTransport()
        let service = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0, route: .originalProxy)
        let lookup = expectation(description: "proxy lookup")
        service.lookup(sha256: String(repeating: "a", count: 64), apiKey: "fixture-key") { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .originalProxyUnavailable) } else { XCTFail("Proxy must not send direct requests") }
            lookup.fulfill()
        }
        let upload = expectation(description: "proxy before file read")
        service.uploadAndScan(fileURL: URL(fileURLWithPath: "/must-not-read"), progress: { _ in XCTFail("Proxy failure precedes file materialization") }, apiKey: "fixture-key") { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .originalProxyUnavailable) } else { XCTFail("Proxy must not upload directly") }
            upload.fulfill()
        }
        wait(for: [lookup, upload], timeout: 2)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(transport.uploads.isEmpty)
    }

    func testInvalidCredentialAndHashFailBeforeFileProviderAccess() {
        let service = WhitegramVirusTotalService(transport: ScanFixtureTransport(), minimumRequestInterval: 0)
        for (key, hash, expected) in [("bad key", nil, WhitegramServiceError.invalidAPIKey), ("fixture-key", "invalid", .invalidHash)] as [(String, String?, WhitegramServiceError)] {
            let complete = expectation(description: "invalid upload inputs")
            service.uploadAndScan(fileURL: URL(fileURLWithPath: "/must-not-read"), expectedHash: hash, progress: { _ in XCTFail("No file read") }, apiKey: key) { result in
                if case let .failure(error) = result { XCTAssertEqual(error, expected) } else { XCTFail("Expected validation failure") }
                complete.fulfill()
            }
            wait(for: [complete], timeout: 2)
        }
    }

    #if canImport(CryptoKit) && canImport(Darwin)
    func testUploadThresholdUsesDirectEndpointAt32MiBAndUploadURLAboveIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-upload-threshold-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for size in [WhitegramServiceLimits.directUploadFileBytes, WhitegramServiceLimits.directUploadFileBytes + 1] {
            let file = directory.appendingPathComponent("fixture-\(size)")
            try Data().write(to: file)
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
            let transport = ScanFixtureTransport()
            let scheduler = ScanFixtureScheduler()
            let service = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0)
            let prepared = expectation(description: "snapshot")
            let task = service.startUpload(fileURL: file, fileName: "test.bin", expectedHash: nil, scheduler: scheduler, progress: { progress in
                if case let .prepared(file) = progress { XCTAssertEqual(file.byteCount, size); prepared.fulfill() }
            }, apiKey: "fixture-key", completion: { _ in })
            wait(for: [prepared], timeout: 20)
            if size > WhitegramServiceLimits.directUploadFileBytes {
                XCTAssertEqual(transport.requests.map { $0.url!.path }, ["/api/v3/files/upload_url"])
                XCTAssertTrue(transport.uploads.isEmpty)
                try transport.respond(["data": "https://www.virustotal.com/_ah/upload/fixture?token=opaque"])
                drain()
                scheduler.runNext()
                XCTAssertEqual(transport.uploads.first?.request.url?.path, "/_ah/upload/fixture")
            } else {
                XCTAssertTrue(transport.requests.isEmpty)
                XCTAssertEqual(transport.uploads.first?.request.url?.path, "/api/v3/files")
            }
            XCTAssertEqual(transport.uploads.count, 1)
            XCTAssertEqual(transport.uploads.first?.request.value(forHTTPHeaderField: "x-apikey"), "fixture-key")
            task.cancel()
            drain()
        }
    }

    func testCancelledUploadKeepsSnapshotUntilTransportStopsReading() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-upload-lifetime-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("file")
        try Data("abc".utf8).write(to: source)
        let transport = ScanFixtureTransport()
        transport.delayUploadCancellation = true
        let started = expectation(description: "upload started")
        transport.uploadStarted = { started.fulfill() }
        let cancelled = expectation(description: "UI cancellation")
        cancelled.assertForOverFulfill = true
        let task = WhitegramVirusTotalService(transport: transport, minimumRequestInterval: 0).startUpload(fileURL: source, fileName: "file", expectedHash: nil, scheduler: ScanFixtureScheduler(), progress: { _ in }, apiKey: "fixture-key") { result in
            if case let .failure(error) = result { XCTAssertEqual(error, .cancelled) } else { XCTFail("Expected cancellation") }
            cancelled.fulfill()
        }
        wait(for: [started], timeout: 10)
        let bodyFile = try XCTUnwrap(transport.uploads.first?.bodyFile)
        task.cancel()
        wait(for: [cancelled], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bodyFile.path))
        transport.pending.removeFirst().finish(.failure(.cancelled))
        drain(); drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyFile.path))
    }
    #endif
}
