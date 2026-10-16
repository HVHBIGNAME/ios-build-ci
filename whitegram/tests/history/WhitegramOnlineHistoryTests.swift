import Foundation
import XCTest
@testable import WhitegramHistory

final class WhitegramOnlineHistoryTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "whitegram-online-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws { defaults.removePersistentDomain(forName: suite) }

    private func store(_ accountId: Int64 = 101) -> WhitegramOnlineHistoryStore {
        return WhitegramOnlineHistoryStore(accountId: accountId, defaults: defaults)
    }

    private func entry(_ peer: Int64 = 201, online: Bool = true, time: Double = 1700000000) -> WhitegramOnlineHistoryEntry {
        return WhitegramOnlineHistoryEntry(peerId: peer, peerName: "Contact \(peer)", peerUsername: "person\(peer)", isOnline: online, timestamp: time)
    }

    private func snapshot(_ store: WhitegramOnlineHistoryStore) async throws -> [WhitegramOnlineHistoryEntry] {
        return try await withCheckedThrowingContinuation { continuation in store.snapshot { continuation.resume(with: $0) } }
    }

    private func clear(_ store: WhitegramOnlineHistoryStore) async throws {
        let _: Void = try await withCheckedThrowingContinuation { continuation in store.clear { continuation.resume(with: $0) } }
    }

    func testOnlyTransitionsSurviveReplayAndColdReload() async throws {
        let first = entry()
        let offline = entry(online: false, time: 1700000050)
        let store = self.store()
        store.append([first, entry(time: 1700000020), entry(202), offline])
        let saved = try await snapshot(store)
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(saved.first, first)
        let reopened = self.store()
        reopened.append([entry(online: false, time: 1700000060)])
        let replayed = try await snapshot(reopened)
        XCTAssertEqual(replayed, saved)
    }

    func testAccountStoresAndClearingAreIsolated() async throws {
        let one = store(), two = store(102)
        one.append([entry(), entry(101)])
        two.append([entry(online: false)])
        let first = try await snapshot(one)
        XCTAssertEqual(first.count, 1)
        try await clear(one)
        let empty = try await snapshot(store())
        let other = try await snapshot(store(102))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(other.map(\.isOnline), [false])
    }

    func testCapKeepsLatest2000AndFiltersBeforePagination() async throws {
        let store = self.store()
        store.append((0..<2051).map { entry(online: $0 % 2 == 0, time: 1700000000 + Double($0)) })
        let entries = try await snapshot(store)
        XCTAssertEqual(entries.count, 2000)
        XCTAssertEqual(entries.first?.timestamp, 1700000051)
        let all = WhitegramOnlineHistoryQuery().apply(to: entries)
        XCTAssertEqual(all.first?.timestamp, 1700002050)
        XCTAssertEqual(all.prefix(WhitegramOnlineHistoryStore.pageSize).count, 50)
        var query = WhitegramOnlineHistoryQuery()
        query.peerId = 201
        query.date = DateInterval(start: Date(timeIntervalSince1970: 1700000100), end: Date(timeIntervalSince1970: 1700000103))
        query.text = "PERSON201"
        XCTAssertEqual(query.apply(to: entries).map(\.timestamp), [1700000102, 1700000101, 1700000100])
        query.peerId = 202
        XCTAssertTrue(query.apply(to: entries).isEmpty)
    }

    func testClearOrdersPendingWritesAndAcceptsNextObservation() async throws {
        let store = self.store()
        store.append([entry()])
        try await clear(store)
        let empty = try await snapshot(self.store())
        XCTAssertTrue(empty.isEmpty)
        store.append([entry(time: 1700000050)])
        let fresh = try await snapshot(store)
        XCTAssertEqual(fresh.map(\.timestamp), [1700000050])
    }

    func testCorruptionIsNotSilentlyOverwrittenByCapture() async throws {
        let store = self.store()
        let original = Data("broken-json".utf8)
        defaults.set(original, forKey: store.storageKey)
        store.append([entry()])
        do { _ = try await snapshot(store); XCTFail("Expected load failure") } catch {}
        XCTAssertEqual(defaults.data(forKey: store.storageKey), original)
        try await clear(store)
        let entries = try await snapshot(self.store())
        XCTAssertTrue(entries.isEmpty)
    }

    func testForeignAccountArchiveIsRejected() async throws {
        let first = store()
        first.append([entry()])
        _ = try await snapshot(first)
        let second = store(102)
        defaults.set(defaults.data(forKey: first.storageKey), forKey: second.storageKey)
        do { _ = try await snapshot(second); XCTFail("Foreign archive was accepted") } catch {}
    }

    func testInvalidObservationsDoNotPoisonTheArchive() async throws {
        let store = self.store()
        store.append([entry(-1), entry(time: .nan), entry(time: .infinity), entry(time: .greatestFiniteMagnitude), entry(time: -10), entry()])
        let valid = try await snapshot(store)
        XCTAssertEqual(valid.count, 1)
    }

    func testOutOfCalendarRangeArchiveIsRejectedBeforePresentation() async throws {
        let store = self.store()
        let entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode([entry(time: 1e300)]))
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "accountId": 101, "entries": entries])
        defaults.set(data, forKey: store.storageKey)
        do { _ = try await snapshot(store); XCTFail("Unsupported date reached the UI snapshot") } catch {}
        XCTAssertEqual(defaults.data(forKey: store.storageKey), data)
    }
}
