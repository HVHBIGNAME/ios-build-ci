import Foundation
import XCTest
@testable import WhitegramHistory

private struct ArchiveFixture: Codable {
    let version: Int
    let accountId: String
    let entries: [WhitegramHistoryEntry]
}

final class WhitegramHistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: self.directory.path) {
            try FileManager.default.removeItem(at: self.directory)
        }
    }

    private func store(account: Int64 = 101) -> WhitegramHistoryStore {
        return WhitegramHistoryStore(directory: self.directory, accountId: account, cloudNamespace: 0)
    }

    private func entry(account: String = "101", peer: String = "200", id: Int32 = 7, revision: UInt32 = 1, event: WhitegramHistoryEvent = .received, text: String = "original", capturedAt: Double = 1700000100, namespace: Int32 = 0, media: [WhitegramHistoryMedia]? = nil) -> WhitegramHistoryEntry {
        return WhitegramHistoryEntry(accountId: account, peerId: peer, namespace: namespace, messageId: id, revision: revision, messageDate: 1700000000, capturedAt: capturedAt, event: event, text: text, authorId: "300", outgoing: false, mediaCount: media?.count ?? 0, peerTitle: "A chat", authorName: "An author", editedAt: 1700000010, textTruncated: false, media: media)
    }

    private func archive(_ entries: [WhitegramHistoryEntry], account: String = "101", version: Int = 1) throws -> Data {
        return try JSONEncoder().encode(ArchiveFixture(version: version, accountId: account, entries: entries))
    }

    private func result<T>(_ operation: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            operation { continuation.resume(with: $0) }
        }
    }

    private func snapshot(_ store: WhitegramHistoryStore, query: WhitegramHistoryQuery = WhitegramHistoryQuery()) async throws -> [WhitegramHistoryEntry] {
        return try await self.result { store.snapshot(matching: query, completion: $0) }
    }

    private func exported(_ store: WhitegramHistoryStore, query: WhitegramHistoryQuery = WhitegramHistoryQuery()) async throws -> Data {
        return try await self.result { store.export(matching: query, completion: $0) }
    }

    private func imported(_ data: Data, into store: WhitegramHistoryStore) async throws -> Int {
        return try await self.result { store.importArchive(data, completion: $0) }
    }

    func testCaptureReplayKeepsFirstObservationAndPersistsBeforeSnapshot() async throws {
        let store = self.store()
        let original = self.entry()
        store.append(original)
        store.append(self.entry(text: "later duplicate", capturedAt: 1700000200))
        let snapshot = try await self.snapshot(store)
        XCTAssertEqual(snapshot, [original])
        let reloaded = try await self.snapshot(self.store())
        XCTAssertEqual(reloaded, [original])
    }

    func testRegistryAndDiskRemainIsolatedForAccountsSharingDirectory() async throws {
        let first = WhitegramHistoryStore.accountStore(directory: self.directory, accountId: 101, cloudNamespace: 0)
        let second = WhitegramHistoryStore.accountStore(directory: self.directory, accountId: 102, cloudNamespace: 0)
        XCTAssertFalse(first === second)
        let alias = WhitegramHistoryStore.accountStore(directory: self.directory.appendingPathComponent("."), accountId: 101, cloudNamespace: 0)
        XCTAssertTrue(first === alias)
        first.append(self.entry(text: "first account"))
        second.append(self.entry(account: "102", text: "second account"))
        let one = try await self.snapshot(first)
        let two = try await self.snapshot(second)
        XCTAssertEqual(one.map(\.text), ["first account"])
        XCTAssertEqual(two.map(\.text), ["second account"])
        let reloadedOne = try await self.snapshot(self.store())
        let reloadedTwo = try await self.snapshot(self.store(account: 102))
        XCTAssertEqual(reloadedOne, one)
        XCTAssertEqual(reloadedTwo, two)
    }

    func testMessageQueryDoesNotMixPeersMessagesOrEvents() async throws {
        let store = self.store()
        let original = self.entry()
        let edit = self.entry(revision: 2, event: .edited, text: "edited original")
        for item in [original, edit, self.entry(peer: "2000"), self.entry(id: 70)] { store.append(item) }
        let query = WhitegramHistoryQuery(scope: .message(original.messageIdentity))
        let selected = try await self.snapshot(store, query: query)
        XCTAssertEqual(Set(selected.map(\.key)), Set([original.key, edit.key]))
        let onlyEdited = try await self.snapshot(store, query: WhitegramHistoryQuery(scope: query.scope, event: .edited))
        XCTAssertEqual(onlyEdited, [edit])
    }

    func testScopedExportAndClearShareTheFilterAndKeepOtherChats() async throws {
        let store = self.store()
        let selected = self.entry(event: .deleted, text: "needle")
        let kept = [self.entry(id: 8, event: .deleted, text: "other"), self.entry(peer: "201", event: .deleted, text: "needle"), self.entry(event: .edited, text: "needle")]
        for item in [selected] + kept { store.append(item) }
        let query = WhitegramHistoryQuery(scope: .peer("200"), event: .deleted, text: "needle")
        let data = try await self.exported(store, query: query)
        XCTAssertEqual(try JSONDecoder().decode(ArchiveFixture.self, from: data).entries, [selected])
        try await self.result { store.clear(matching: query, completion: $0) }
        let remaining = try await self.snapshot(self.store())
        XCTAssertEqual(Set(remaining.map(\.key)), Set(kept.map(\.key)))
    }

    func testImportReplayReportsOnlyNewRetainedVersionsWithoutReplacingLocalContent() async throws {
        let store = self.store()
        store.append(self.entry())
        let incoming = self.entry(id: 8)
        let data = try self.archive([self.entry(text: "overwrite attempt", capturedAt: 1700000300), incoming, incoming])
        let added = try await self.imported(data, into: store)
        let before = try await self.exported(store)
        let repeated = try await self.imported(data, into: store)
        let after = try await self.exported(store)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(repeated, 0)
        XCTAssertEqual(before, after)
        let entries = try await self.snapshot(store)
        XCTAssertEqual(entries.first(where: { $0.messageId == 7 })?.text, "original")
        XCTAssertEqual(entries.first(where: { $0.messageId == 7 })?.capturedAt, 1700000100)
    }

    func testForeignMixedAccountAndInvalidImportsAreAllOrNothing() async throws {
        let store = self.store()
        store.append(self.entry())
        let before = try await self.exported(store)
        let inputs = [
            try self.archive([self.entry(account: "102")], account: "102"),
            try self.archive([self.entry(id: 8), self.entry(account: "102", id: 9)]),
            try self.archive([self.entry(id: 8), self.entry(id: 9, namespace: 2)]),
            try self.archive([self.entry(id: 8, text: String(repeating: "x", count: 8196))]),
            try self.archive([self.entry(id: 8, media: [WhitegramHistoryMedia(kind: .file, size: -1)])]),
            try self.archive([self.entry(id: 8)], version: 2),
            Data(repeating: 0, count: WhitegramHistoryStore.maximumArchiveBytes + 1)
        ]
        for data in inputs {
            do { _ = try await self.imported(data, into: store); XCTFail("Invalid archive accepted") }
            catch { }
            let after = try await self.exported(store)
            XCTAssertEqual(after, before)
        }
    }

    func testLegacyArchiveMigratesWithoutInventingMetadataOrLeavingOldCopy() async throws {
        let legacy = self.directory.appendingPathComponent("whitegram-history-v1.json")
        let json = Data("""
        {"version":1,"accountId":"101","entries":[{"key":"200:0:7:received:1","accountId":"101","peerId":"200","namespace":0,"messageId":7,"revision":1,"messageDate":1700000000,"capturedAt":1700000100,"event":"received","text":"legacy","authorId":"300","outgoing":false,"mediaCount":1}]}
        """.utf8)
        try json.write(to: legacy)
        let entries = try await self.snapshot(self.store())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.text, "legacy")
        XCTAssertNil(entries.first?.media)
        XCTAssertNil(entries.first?.textTruncated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: self.directory.appendingPathComponent("whitegram-history-101-v1.json")), json)
    }

    func testForeignLegacyArchiveIsLeftForItsOwner() async throws {
        let legacy = self.directory.appendingPathComponent("whitegram-history-v1.json")
        let data = try self.archive([self.entry(account: "102", text: "legacy foreign")], account: "102")
        try data.write(to: legacy)
        let store = self.store()
        store.append(self.entry())
        let first = try await self.snapshot(store)
        XCTAssertEqual(first.map(\.text), ["original"])
        XCTAssertEqual(try Data(contentsOf: legacy), data)
        let second = try await self.snapshot(self.store(account: 102))
        XCTAssertEqual(second.map(\.text), ["legacy foreign"])
        let unchanged = try await self.snapshot(store)
        XCTAssertEqual(unchanged, first)
    }

    func testAttachmentMetadataSurvivesExportImportAndReload() async throws {
        let file = WhitegramHistoryMedia(kind: .voice, mediaId: "5:900", fileName: "voice.ogg", mimeType: "audio/ogg", size: 1024, duration: 3.25)
        let photo = WhitegramHistoryMedia(kind: .photo, mediaId: "0:901", width: 1920, height: 1080)
        let entry = self.entry(media: [file, photo])
        let store = self.store()
        let added = try await self.imported(self.archive([entry]), into: store)
        XCTAssertEqual(added, 1)
        let data = try await self.exported(store)
        let decoded = try JSONDecoder().decode(ArchiveFixture.self, from: data)
        XCTAssertEqual(decoded.entries, [entry])
        let reloaded = try await self.snapshot(self.store())
        XCTAssertEqual(reloaded, [entry])
    }

    func testCorruptArchiveCannotBeErasedByClearOrImport() async throws {
        let file = self.directory.appendingPathComponent("whitegram-history-101-v1.json")
        let damaged = Data("{damaged archive".utf8)
        try damaged.write(to: file)
        let store = self.store()
        do { try await self.result { store.clear(completion: $0) }; XCTFail("Corrupt archive cleared") }
        catch { }
        do { _ = try await self.imported(self.archive([self.entry()]), into: store); XCTFail("Corrupt archive replaced") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testEntryLimitRetainsNewestCaptures() async throws {
        let store = self.store()
        for id in 1...2001 {
            store.append(self.entry(id: Int32(id), capturedAt: 1700000100 + Double(id)))
        }
        let entries = try await self.snapshot(store, query: WhitegramHistoryQuery(order: .captureTime))
        XCTAssertEqual(entries.count, WhitegramHistoryStore.maximumEntries)
        XCTAssertEqual(entries.first?.messageId, 2001)
        XCTAssertNil(entries.first(where: { $0.messageId == 1 }))
    }

    func testByteLimitBoundsPersistedArchiveAsWellAsMemory() async throws {
        let store = self.store()
        let text = String(repeating: "x", count: 8192)
        for id in 1...1100 { store.append(self.entry(id: Int32(id), text: text, capturedAt: 1700000100 + Double(id))) }
        let entries = try await self.snapshot(store)
        let file = try Data(contentsOf: self.directory.appendingPathComponent("whitegram-history-101-v1.json"))
        XCTAssertLessThan(entries.count, 1100)
        XCTAssertLessThanOrEqual(file.count, WhitegramHistoryStore.maximumArchiveBytes)
        let reloaded = try await self.snapshot(self.store())
        XCTAssertEqual(reloaded, entries)
    }

    func testTransientWriteFailureCanRetryWithoutLosingCapture() async throws {
        let store = self.store()
        _ = try await self.snapshot(store)
        let blocker = self.directory.appendingPathComponent("whitegram-history-101-v1.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        store.append(self.entry())
        do { _ = try await self.snapshot(store); XCTFail("Write to directory succeeded") }
        catch { }
        try FileManager.default.removeItem(at: blocker)
        let retried = try await self.snapshot(store)
        XCTAssertEqual(retried, [self.entry()])
        let reloaded = try await self.snapshot(self.store())
        XCTAssertEqual(reloaded, retried)
    }

    func testRemovedAccountDirectoryIsNotRecreated() async throws {
        let store = self.store()
        _ = try await self.snapshot(store)
        try FileManager.default.removeItem(at: self.directory)
        store.append(self.entry())
        do { _ = try await self.snapshot(store); XCTFail("Removed account persisted") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.directory.path))
    }
}
