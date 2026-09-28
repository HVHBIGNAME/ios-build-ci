import Foundation
import XCTest
@testable import WhitegramServiceHost
#if canImport(CryptoKit) && canImport(Darwin)
import CryptoKit

@available(macOS 10.15.4, *)
final class WhitegramVirusTotalHashTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // Keep test writes beneath tests/services (including when copied into its host package).
        self.directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(".hash-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: self.directory) }

    private func assertHash(_ data: Data, expected: String, name: String = "fixture.bin") throws {
        let url = self.directory.appendingPathComponent(name)
        try data.write(to: url)
        let completed = self.expectation(description: "hash")
        WhitegramVirusTotalFileHasher.hash(url: url) { result in
            XCTAssertTrue(Thread.isMainThread)
            switch result {
            case let .success(hash):
                XCTAssertEqual(hash.sha256, expected)
                XCTAssertEqual(hash.byteCount, Int64(data.count))
                XCTAssertEqual(hash.fileName, name)
            case let .failure(error): XCTFail(error.localizedDescription)
            }
            completed.fulfill()
        }
        self.wait(for: [completed], timeout: 10)
    }

    func testKnownSHA256Vectors() throws {
        try self.assertHash(Data(), expected: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", name: "empty")
        try self.assertHash(Data("abc".utf8), expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", name: "abc")
    }

    func testMultipleChunkBoundariesMatchIndependentOneShotDigest() throws {
        let data = Data((0..<(WhitegramServiceLimits.fileChunkBytes * 2 + 13)).map { UInt8($0 % 251) })
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try self.assertHash(data, expected: expected)
    }

    func testOversizedSparseFileIsRejected() throws {
        let url = self.directory.appendingPathComponent("too-large.bin")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(WhitegramServiceLimits.maximumFileBytes + 1))
        try handle.close()
        let completed = self.expectation(description: "size rejected")
        WhitegramVirusTotalFileHasher.hash(url: url) { result in
            guard case let .failure(error) = result else { XCTFail("Expected file limit"); completed.fulfill(); return }
            XCTAssertEqual(error, .fileTooLarge)
            completed.fulfill()
        }
        self.wait(for: [completed], timeout: 5)
    }

    func testDirectoriesAndSymlinksAreRejected() throws {
        let regular = self.directory.appendingPathComponent("original")
        try Data("abc".utf8).write(to: regular)
        let link = self.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        for url in [self.directory!, link] {
            let completed = self.expectation(description: "not a regular file")
            WhitegramVirusTotalFileHasher.hash(url: url) { result in
                guard case let .failure(error) = result else { XCTFail("Expected regular-file validation"); completed.fulfill(); return }
                XCTAssertEqual(error, .notRegularFile)
                completed.fulfill()
            }
            self.wait(for: [completed], timeout: 5)
        }
    }

    func testImmediateCancellationCompletesOnce() throws {
        let url = self.directory.appendingPathComponent("cancel.bin")
        try Data("abc".utf8).write(to: url)
        let completed = self.expectation(description: "cancelled")
        completed.assertForOverFulfill = true
        let task = WhitegramVirusTotalFileHasher.hash(url: url) { result in
            guard case let .failure(error) = result else { XCTFail("Expected cancellation"); completed.fulfill(); return }
            XCTAssertEqual(error, .cancelled)
            completed.fulfill()
        }
        task.cancel()
        self.wait(for: [completed], timeout: 5)
    }
}
#endif
