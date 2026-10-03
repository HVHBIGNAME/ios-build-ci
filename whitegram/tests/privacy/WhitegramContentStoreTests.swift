import Foundation
import XCTest
@testable import TelegramCore

final class WhitegramContentStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func source(_ name: String, bytes: Data = Data([1, 2, 3, 4])) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    func testCompleteCopySurvivesOriginalExpiryAndIsIdempotent() throws {
        let root = directory.appendingPathComponent("account-a")
        let original = try source("original.mp4")
        let candidate = WhitegramContentMediaStore.Candidate(id: "123_0_55_0", source: original, kind: .video, timestamp: 100, viewOnce: true)
        let entry = try WhitegramContentMediaStore.capture(root: root, candidate: candidate)
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(try Data(contentsOf: WhitegramContentMediaStore.fileURL(root: root, entry: entry)), Data([1, 2, 3, 4]))
        XCTAssertEqual(try WhitegramContentMediaStore.capture(root: root, candidate: candidate), entry)
        XCTAssertEqual(try WhitegramContentMediaStore.entries(root: root), [entry])
    }

    func testSameMessageIdsInDifferentAccountsDoNotShareBytes() throws {
        let first = WhitegramContentMediaStore.root(mediaBoxPath: directory.appendingPathComponent("account-a/postbox/media").path)
        let second = WhitegramContentMediaStore.root(mediaBoxPath: directory.appendingPathComponent("account-b/postbox/media").path)
        XCTAssertNotEqual(first, second)
        let a = try WhitegramContentMediaStore.capture(root: first, candidate: .init(id: "1_0_1_0", source: source("a"), kind: .image, timestamp: 1, viewOnce: true))
        let b = try WhitegramContentMediaStore.capture(root: second, candidate: .init(id: "1_0_1_0", source: source("b", bytes: Data([9, 8, 7])), kind: .image, timestamp: 1, viewOnce: true))
        XCTAssertNotEqual(try Data(contentsOf: WhitegramContentMediaStore.fileURL(root: first, entry: a)), try Data(contentsOf: WhitegramContentMediaStore.fileURL(root: second, entry: b)))
        try WhitegramContentMediaStore.remove(root: first, entry: a)
        XCTAssertEqual(try WhitegramContentMediaStore.entries(root: second), [b])
    }

    func testInvalidOrMissingSourcesDoNotCreatePublishedEntries() throws {
        let root = directory.appendingPathComponent("account")
        XCTAssertThrowsError(try WhitegramContentMediaStore.capture(root: root, candidate: .init(id: "../escape", source: source("a"), kind: .image, timestamp: 1, viewOnce: true)))
        XCTAssertThrowsError(try WhitegramContentMediaStore.capture(root: root, candidate: .init(id: "1_0_1_0", source: directory.appendingPathComponent("missing"), kind: .image, timestamp: 1, viewOnce: true)))
        XCTAssertThrowsError(try WhitegramContentMediaStore.capture(root: root, candidate: .init(id: "1_0_2_0", source: source("empty", bytes: Data()), kind: .image, timestamp: 1, viewOnce: true)))
        XCTAssertEqual(try WhitegramContentMediaStore.entries(root: root), [])
    }

    func testPhotosSuccessIsPersistedOnlyByAnActualIdentifier() throws {
        let root = directory.appendingPathComponent("account")
        let entry = try WhitegramContentMediaStore.capture(root: root, candidate: .init(id: "1_0_1_0", source: source("a"), kind: .image, timestamp: 1, viewOnce: true))
        XCTAssertThrowsError(try WhitegramContentMediaStore.markSavedToPhotos(root: root, entry: entry, identifier: ""))
        XCTAssertNil(try WhitegramContentMediaStore.entries(root: root).first?.photoLibraryIdentifier)
        try WhitegramContentMediaStore.markSavedToPhotos(root: root, entry: entry, identifier: "fixture-photo-id")
        XCTAssertEqual(try WhitegramContentMediaStore.entries(root: root).first?.photoLibraryIdentifier, "fixture-photo-id")
    }

    func testTruncatedCopyIsReportedInsteadOfClaimedAsRetained() throws {
        let root = directory.appendingPathComponent("account")
        let entry = try WhitegramContentMediaStore.capture(root: root, candidate: .init(id: "1_0_1_0", source: source("a"), kind: .image, timestamp: 1, viewOnce: true))
        try Data([1]).write(to: WhitegramContentMediaStore.fileURL(root: root, entry: entry))
        XCTAssertThrowsError(try WhitegramContentMediaStore.entries(root: root))
    }
}
