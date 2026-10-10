import Foundation
import XCTest
@testable import WhitegramBackendHost

final class WhitegramBackendURLSessionTests: XCTestCase {
    override func tearDown() {
        BackendNoNetworkProtocol.handler = nil
        BackendNoNetworkProtocol.stopped = nil
        super.tearDown()
    }

    private func transport(_ fixture: BackendFixture) -> WhitegramBackendAuthorizedTransport {
        return WhitegramBackendAuthorizedTransport(client: WhitegramBackendClient(userId: 42, sessions: fixture.sessions,
            http: WhitegramBackendPinnedHTTP(configuration: BackendNoNetworkProtocol.configuration), now: { fixture.date },
            access: fixture.access, recordUsage: { _ in }, applicationKey: { BackendFixture.applicationKey }, deviceSignature: { _ in nil }))
    }

    func testIncrementalChunksAreSerialMainQueueAndCompletionRetainsBody() {
        let fixture = BackendFixture()
        let chunks = [Data("data: {\"text\":\"one\"}\n\n".utf8), Data("data: [DONE]\n\n".utf8)]
        BackendNoNetworkProtocol.handler = { $0.respond(status: 200, chunks: chunks) }
        var received = Data()
        let done = expectation(description: "stream")
        transport(fixture).execute(path: "/v1/proxy/groq/openai/v1/chat/completions", accept: "text/event-stream", received: { data in
            XCTAssertTrue(Thread.isMainThread)
            received.append(data)
        }) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(received, chunks.reduce(Data(), +))
            XCTAssertEqual(try? result.get().data, received)
            done.fulfill()
        }
        waitForExpectations(timeout: 3)
    }

    func testNonSuccessBodyIsPreservedWithoutStreamingItAsContent() {
        let fixture = BackendFixture()
        let body = Data(#"{"error":{"code":"NotFoundError"}}"#.utf8)
        BackendNoNetworkProtocol.handler = { $0.respond(status: 404, chunks: [body]) }
        let done = expectation(description: "404")
        transport(fixture).execute(path: "/v1/proxy/virustotal/v3/files/fixture", received: { _ in XCTFail("404 streamed as content") }) { result in
            XCTAssertEqual(try? result.get().response.statusCode, 404)
            XCTAssertEqual(try? result.get().data, body)
            done.fulfill()
        }
        waitForExpectations(timeout: 3)
    }

    func testConsumerFailureAbortsWithoutLaterSuccessfulCompletion() {
        let fixture = BackendFixture()
        BackendNoNetworkProtocol.handler = { $0.respond(status: 200, chunks: [Data("invalid SSE".utf8)]) }
        let done = expectation(description: "consumer failure")
        transport(fixture).execute(path: "/v1/proxy/groq/openai/v1/chat/completions", received: { _ in
            throw WhitegramBackendError.invalidResponse
        }) { result in
            XCTAssertEqual(result.failure, .invalidResponse)
            done.fulfill()
        }
        waitForExpectations(timeout: 3)
    }

    func testCancelCompletesAfterURLSessionStopsItsBodyReader() throws {
        let fixture = BackendFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhitegramBackendUploadTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("body.bin")
        try Data(repeating: 65, count: 4096).write(to: file)
        let started = expectation(description: "upload started")
        let stopped = expectation(description: "URLSession stopped")
        BackendNoNetworkProtocol.handler = { _ in started.fulfill() }
        BackendNoNetworkProtocol.stopped = { stopped.fulfill() }
        let done = expectation(description: "cancel completed")
        done.assertForOverFulfill = true
        let task = transport(fixture).execute(path: "/v1/proxy/virustotal/v3/files", method: "POST", bodyFile: file, contentType: "application/octet-stream") { result in
            XCTAssertEqual(result.failure, .cancelled)
            done.fulfill()
        }
        wait(for: [started], timeout: 3)
        task.cancel()
        task.cancel()
        wait(for: [stopped, done], timeout: 3, enforceOrder: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancellationBeforeProtocolStartsStillCompletesExactlyOnce() {
        let fixture = BackendFixture()
        BackendNoNetworkProtocol.handler = { _ in }
        let done = expectation(description: "early cancellation")
        done.assertForOverFulfill = true
        let task = transport(fixture).execute(path: "/v1/proxy/virustotal/v3/files/fixture") { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result.failure, .cancelled)
            done.fulfill()
        }
        task.cancel()
        task.cancel()
        wait(for: [done], timeout: 3)
    }

    func testSPKIWrappingMatchesOriginalP256AndP384Prefixes() {
        let p256 = Data(repeating: 4, count: 65)
        let p384 = Data(repeating: 4, count: 97)
        XCTAssertEqual(WhitegramBackendPinnedHTTP.subjectPublicKeyInfo(p256).count, 26 + 65)
        XCTAssertEqual(WhitegramBackendPinnedHTTP.subjectPublicKeyInfo(p384).count, 23 + 97)
        XCTAssertEqual(WhitegramBackendPinnedHTTP.subjectPublicKeyInfo(p256).suffix(65), p256)
        let other = Data([1, 2, 3])
        XCTAssertEqual(WhitegramBackendPinnedHTTP.subjectPublicKeyInfo(other), other)
    }
}
