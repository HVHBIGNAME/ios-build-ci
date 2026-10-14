import Foundation
import XCTest
@testable import Diagnostics

private final class DiagnosticProtocol: URLProtocol {
    static var response: (Int, Data) = (200, Data())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: self.request.url!, statusCode: Self.response.0, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Self.response.1)
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DiagnosticsTests: XCTestCase {
    func testMetadataAndStackAllowlistExcludeSensitiveValues() throws {
        let uuid = UUID().uuidString
        let tree: [String: Any] = ["callStacks": [["threadAttributed": true, "callStackRootFrames": [
            ["binaryName": "TelegramUIFramework", "binaryUUID": uuid, "offsetIntoBinary": 1234,
             "symbol": "PRIVATE_MESSAGE", "path": "/private/SECRET", "subFrames": [
                ["binaryName": "/private/SECRET", "binaryUUID": uuid, "offsetIntoBinary": 10],
                ["binaryName": "Foundation", "binaryUUID": uuid, "offsetIntoBinary": true]
             ]]
        ]]], "exceptionReason": "SECRET_TOKEN"]
        let frames = WhitegramErrorReport.frames(from: try JSONSerialization.data(withJSONObject: tree))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].offset, 1234)
        let report = WhitegramErrorReport(kind: .crash, component: .app, code: 11, frames: frames,
            info: ["CFBundleVersion": "SECRET", "WhitegramSourceRevision": "TOKEN"])
        let data = try JSONEncoder().encode(report)
        let encoded = String(decoding: data, as: UTF8.self)
        for secret in ["PRIVATE_MESSAGE", "SECRET", "TOKEN", "exceptionReason", "symbol", "path"] { XCTAssertFalse(encoded.contains(secret)) }
        XCTAssertEqual(report.build, "0")
        XCTAssertEqual(report.revision, "unknown")
        XCTAssertEqual(try JSONDecoder().decode(WhitegramErrorReport.self, from: data), report)
    }

    func testStackSizeLimitsAndInvalidInput() throws {
        let frame: [String: Any] = ["binaryName": "Telegram", "binaryUUID": UUID().uuidString, "offsetIntoBinary": 42]
        let tree: [String: Any] = ["callStacks": [["callStackRootFrames": Array(repeating: frame, count: 1000)]]]
        XCTAssertEqual(WhitegramErrorReport.frames(from: try JSONSerialization.data(withJSONObject: tree)).count, 64)
        XCTAssertTrue(WhitegramErrorReport.frames(from: Data("{}".utf8)).isEmpty)
        XCTAssertTrue(WhitegramErrorReport.frames(from: Data(repeating: 0, count: 4 * 1024 * 1024 + 1)).isEmpty)
    }

    func testDelayedCrashDoesNotClaimTheCurrentSourceRevision() {
        let info: [String: Any] = ["CFBundleVersion": "34640", "CFBundleShortVersionString": "12.9.4", "WhitegramSourceRevision": String(repeating: "a", count: 40)]
        let previous = WhitegramErrorReport(kind: .crash, component: .app, code: 11, info: info, diagnosticBuild: "34639")
        XCTAssertEqual(previous.build, "34639")
        XCTAssertEqual(previous.revision, "unknown")
        let current = WhitegramErrorReport(kind: .crash, component: .app, code: 11, info: info, diagnosticBuild: "34640")
        XCTAssertEqual(current.revision, String(repeating: "a", count: 40))
    }

    func testUploaderRequiresMatchingBoundedAcknowledgment() throws {
        let id = UUID()
        let valid = try JSONSerialization.data(withJSONObject: ["accepted": true, "id": id.uuidString])
        let wrong = try JSONSerialization.data(withJSONObject: ["accepted": true, "id": UUID().uuidString])
        for (status, body, expected) in [(202, valid, true), (200, wrong, false), (500, valid, false), (200, Data(repeating: 32, count: 4097), false)] {
            DiagnosticProtocol.response = (status, body)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DiagnosticProtocol.self]
            let completed = expectation(description: "Diagnostic acknowledgment")
            let task = WhitegramDiagnosticsUpload(request: URLRequest(url: URL(string: "https://diagnostics.invalid/v1/reports")!), reportId: id, configuration: config) { accepted, _ in
                XCTAssertEqual(accepted, expected)
                completed.fulfill()
            }
            wait(for: [completed], timeout: 5)
            withExtendedLifetime(task) {}
        }
    }
}
