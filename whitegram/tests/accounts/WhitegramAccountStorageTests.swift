import Foundation
import Security
import XCTest
@testable import TelegramCore
@testable import SettingsUI

private final class AccountKeychainMemory: WhitegramSessionKeychainAccess {
    var items: [[String: Any]] = []
    var readError: OSStatus?
    var writeError: OSStatus?
    var substitute: Data?
    var substituteProtection: String?
    var queries: [[String: Any]] = []

    private func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        for key in [kSecClass, kSecAttrService, kSecAttrAccount] {
            if let value = query[key as String] as? String, value != item[key as String] as? String { return false }
        }
        return true
    }
    func read(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        queries.append(query)
        if let readError { return (readError, nil) }
        let found = items.filter { matches($0, query) }
        guard !found.isEmpty else { return (errSecItemNotFound, nil) }
        if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
            return (errSecSuccess, found as CFArray)
        }
        if query[kSecReturnAttributes as String] as? Bool == true {
            var item = found[0]
            if let substitute { item[kSecValueData as String] = substitute }
            if let substituteProtection { item[kSecAttrAccessible as String] = substituteProtection }
            return (errSecSuccess, item as CFDictionary)
        }
        guard let data = substitute ?? (found[0][kSecValueData as String] as? Data) else { return (errSecDecode, nil) }
        return (errSecSuccess, data as CFData)
    }
    func add(_ query: [String: Any]) -> OSStatus {
        if let writeError { return writeError }
        if items.contains(where: { matches($0, query) }) { return errSecDuplicateItem }
        items.append(query)
        return errSecSuccess
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        if let writeError { return writeError }
        guard let index = items.firstIndex(where: { matches($0, query) }) else { return errSecItemNotFound }
        items[index].merge(attributes, uniquingKeysWith: { _, new in new })
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        if let writeError { return writeError }
        items.removeAll(where: { matches($0, query) })
        return errSecSuccess
    }
}

final class WhitegramAccountStorageTests: XCTestCase {
    private func backup() throws -> WhitegramSessionBackup { return try WhitegramSessionBackup(data: AccountFixtures().data("session_archive")) }

    func testKeychainSaveListRestoreDeleteAndProtection() throws {
        let memory = AccountKeychainMemory()
        let keychain = WhitegramSessionKeychain(service: "test.accounts", access: memory)
        let backup = try backup()
        try keychain.save(backup)
        let item = try XCTUnwrap(memory.items.first)
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(item[kSecAttrAccessGroup as String])
        XCTAssertEqual(try keychain.list().count, 1)
        XCTAssertEqual(try keychain.restore(id: backup.account.identity.keychainId), backup)
        try keychain.save(backup)
        XCTAssertEqual(memory.items.count, 1)
        try keychain.delete(id: backup.account.identity.keychainId)
        XCTAssertEqual(try keychain.list().count, 0)
    }

    func testKeychainFailureDoesNotOverwriteOrReportSuccess() throws {
        let memory = AccountKeychainMemory()
        let keychain = WhitegramSessionKeychain(service: "test.accounts", access: memory)
        let backup = try backup()
        try keychain.save(backup)
        let original = memory.items[0][kSecValueData as String] as? Data
        memory.writeError = errSecInteractionNotAllowed
        XCTAssertThrowsError(try keychain.save(backup)) { XCTAssertEqual($0 as? WhitegramSessionError, .storage(errSecInteractionNotAllowed)) }
        XCTAssertEqual(memory.items[0][kSecValueData as String] as? Data, original)
        memory.writeError = nil
        memory.substitute = Data("not-the-written-data".utf8)
        XCTAssertThrowsError(try keychain.save(backup)) { XCTAssertEqual($0 as? WhitegramSessionError, .storageVerification) }
        memory.substitute = nil
        memory.substituteProtection = kSecAttrAccessibleAfterFirstUnlock as String
        XCTAssertThrowsError(try keychain.save(backup)) { XCTAssertEqual($0 as? WhitegramSessionError, .storageVerification) }
        memory.substituteProtection = nil
        memory.readError = errSecAuthFailed
        XCTAssertThrowsError(try keychain.list()) { XCTAssertEqual($0 as? WhitegramSessionError, .storage(errSecAuthFailed)) }
    }

    func testKeychainIsolationAndExplicitLegacyCompatibility() throws {
        let memory = AccountKeychainMemory()
        let main = WhitegramSessionKeychain(service: "current", legacyServices: ["legacy"], access: memory)
        let legacy = WhitegramSessionKeychain(service: "legacy", access: memory)
        let unrelated = WhitegramSessionKeychain(service: "unrelated", access: memory)
        let original = try backup()
        try legacy.save(original)
        try unrelated.save(original)
        let testAccount = try WhitegramPortableAccount(dcId: 2, authKey: original.account.authKey, userId: original.account.identity.userId, name: "Test", testingEnvironment: true)
        try main.save(WhitegramSessionBackup(account: testAccount, recordId: 7))
        try main.save(original)
        XCTAssertEqual(try main.list().count, 3)
        XCTAssertTrue(try main.restore(id: testAccount.identity.keychainId).account.identity.testingEnvironment)
        XCTAssertEqual(try main.restore(id: original.account.identity.keychainId, service: "legacy"), original)
        XCTAssertThrowsError(try main.restore(id: original.account.identity.keychainId, service: "unrelated"))
        try main.deleteAll()
        XCTAssertEqual(try unrelated.list().count, 1)
        XCTAssertTrue(try main.list().isEmpty)
    }

    func testMalformedSavedEntryRemainsVisibleAndDiagnosticsReadNoData() throws {
        let memory = AccountKeychainMemory()
        let keychain = WhitegramSessionKeychain(service: "test", access: memory)
        try keychain.save(backup())
        memory.items[0][kSecValueData as String] = Data("broken".utf8)
        let entries = try keychain.list()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].backup)
        XCTAssertEqual(entries[0].error, .invalidFormat)
        memory.queries.removeAll()
        XCTAssertEqual(keychain.diagnostics()[0].count, 1)
        XCTAssertNil(memory.queries.last?[kSecReturnData as String])
    }

    func testCancellationBeforeAllocationAndAfterCommit() {
        let cancelled = WhitegramAccountImportState()
        XCTAssertNil(cancelled.cancel())
        XCTAssertNil(cancelled.allocate { XCTFail("Cancelled operation allocated an account"); return 1 })
        XCTAssertFalse(cancelled.commit { XCTFail("Cancelled operation committed"); return true })
        let committed = WhitegramAccountImportState()
        XCTAssertEqual(committed.allocate { 42 }, 42)
        XCTAssertTrue(committed.commit { true })
        XCTAssertNil(committed.cancel(), "Disposal must not roll back a committed account")
        XCTAssertFalse(committed.commit { XCTFail("Duplicate commit"); return true })
    }

    func testFailedCommitRollsBackOnlyStagedId() {
        let state = WhitegramAccountImportState()
        XCTAssertEqual(state.allocate { -900 }, -900)
        XCTAssertFalse(state.commit { false })
        XCTAssertEqual(state.cancel(), -900)
        XCTAssertNil(state.cancel())
        XCTAssertFalse(state.commit { true })
    }

    func testCancellationCannotInterleaveWithPublicationTransaction() {
        let state = WhitegramAccountImportState()
        _ = state.allocate { 99 }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let publication = expectation(description: "published")
        let cancellation = expectation(description: "cancelled after publication")
        DispatchQueue.global().async {
            XCTAssertTrue(state.commit { entered.signal(); release.wait(); return true })
            publication.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { XCTAssertNil(state.cancel()); cancellation.fulfill() }
        release.signal()
        wait(for: [publication, cancellation], timeout: 3)
    }

    func testFrozenStateIsAccountScopedPersistentAndDoesNotDowngradeReasons() throws {
        let suite = "WhitegramAccountTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhitegramAccountFrozenStore(defaults: defaults)
        XCTAssertTrue(store.markFrozen(accountId: 10, peerId: 123, reason: .unknown, now: Date(timeIntervalSince1970: 50)))
        XCTAssertTrue(store.markFrozen(accountId: 10, peerId: 123, reason: .banned, now: Date(timeIntervalSince1970: 60)))
        XCTAssertTrue(store.markFrozen(accountId: 10, peerId: nil, reason: .sessionRevoked, now: Date(timeIntervalSince1970: 70)))
        XCTAssertTrue(store.markFrozen(accountId: 11, peerId: 123, reason: .frozen))
        let reloaded = WhitegramAccountFrozenStore(defaults: defaults)
        XCTAssertEqual(reloaded.entry(accountId: 10)?.reason, .banned)
        XCTAssertEqual(reloaded.entry(accountId: 10)?.frozenAt, 60)
        XCTAssertTrue(reloaded.clear(accountId: 10))
        XCTAssertNil(reloaded.entry(accountId: 10))
        XCTAssertNotNil(reloaded.entry(accountId: 11))
    }

    func testCorruptFrozenStateIsNotSilentlyReplaced() throws {
        let suite = "WhitegramAccountTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let broken = Data("not-json".utf8)
        defaults.set(broken, forKey: "wg_frozenAccounts_v1")
        let store = WhitegramAccountFrozenStore(defaults: defaults)
        XCTAssertFalse(store.markFrozen(accountId: 1, peerId: 1, reason: .unknown))
        XCTAssertEqual(defaults.data(forKey: "wg_frozenAccounts_v1"), broken)
        XCTAssertEqual(store.error(), .invalidFormat)
        defaults.set("invalid-type", forKey: "wg_frozenAccounts_v1")
        XCTAssertFalse(store.markFrozen(accountId: 1, peerId: 1, reason: .unknown))
        XCTAssertEqual(defaults.string(forKey: "wg_frozenAccounts_v1"), "invalid-type")
        defaults.removeObject(forKey: "wg_frozenAccounts_v1")
        XCTAssertTrue(store.clear(accountId: 1))
        XCTAssertNil(store.error())
    }

    func testSwitcherUsesNativeOrderAndWrapsOnlyWhenEnabled() {
        XCTAssertEqual(WhitegramAccountSelection.next(current: 4, orderedIds: [9, 4, -2], enabled: true), -2)
        XCTAssertEqual(WhitegramAccountSelection.next(current: -2, orderedIds: [9, 4, -2], enabled: true), 9)
        XCTAssertNil(WhitegramAccountSelection.next(current: 4, orderedIds: [4], enabled: true))
        XCTAssertNil(WhitegramAccountSelection.next(current: 7, orderedIds: [9, 4], enabled: true))
        XCTAssertNil(WhitegramAccountSelection.next(current: 4, orderedIds: [9, 4], enabled: false))
    }

    func testFrozenStoreLimitPreservesTheExistingArchive() throws {
        let suite = "WhitegramAccountTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let entries = Dictionary(uniqueKeysWithValues: (1...1000).map { index in
            (Int64(index), WhitegramFrozenAccount(accountId: Int64(index), peerId: Int64(index), reason: .deleted, frozenAt: 1))
        })
        let data = try JSONEncoder().encode(entries)
        defaults.set(data, forKey: "wg_frozenAccounts_v1")
        let store = WhitegramAccountFrozenStore(defaults: defaults)
        XCTAssertFalse(store.markFrozen(accountId: 1001, peerId: 1001, reason: .unknown))
        XCTAssertEqual(store.error(), .tooLarge)
        XCTAssertEqual(defaults.data(forKey: "wg_frozenAccounts_v1"), data)
        XCTAssertEqual(try store.all().count, 1000)
    }

    func testBotInputAndServerErrorsDoNotLeakTokens() throws {
        XCTAssertEqual(try WhitegramAccountSelection.botUserId(token: "1234567:SYNTHETIC_TEST_TOKEN_ONLY"), 1234567)
        for token in ["", "0:SYNTHETIC_TEST_TOKEN_ONLY", "1234567:no", "1234567:SYNTHETIC:TEST_TOKEN_ONLY", "x:SYNTHETIC_TEST_TOKEN_ONLY"] { XCTAssertThrowsError(try WhitegramAccountSelection.botUserId(token: token)) }
        XCTAssertEqual(WhitegramSessionError.authorization("FLOOD_WAIT_120"), .floodWait(120))
        XCTAssertEqual(WhitegramSessionError.authorization("SESSION_PASSWORD_NEEDED"), .passwordRequired)
        XCTAssertEqual(WhitegramSessionError.authorization("ACCESS_TOKEN_EXPIRED"), .tokenExpired)
        XCTAssertEqual(WhitegramSessionError.authorization("SECRET_TEST_TOKEN"), .network)
        XCTAssertEqual(WhitegramAccountUnavailableReason.rpcError("USER_DEACTIVATED_BAN"), .banned)
        XCTAssertNil(WhitegramAccountUnavailableReason.rpcError("INTERNAL_SERVER_ERROR"))
    }
}
