import Foundation
import XCTest
@testable import TelegramCore
@testable import SettingsUI
#if canImport(Security)
import Security

private final class SettingsArchiveKeychainMemory: WhitegramSettingsArchiveKeychainAccess {
    var item: [String: Any]?
    var lastReadQuery: [String: Any] = [:]
    var addFailure: OSStatus?
    var updateFailure: OSStatus?
    var readFailure: OSStatus?
    var substitutedReadData: Data?

    func add(_ attributes: [String: Any]) -> OSStatus {
        if let addFailure { return addFailure }
        if item != nil { return errSecDuplicateItem }
        item = attributes
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        if let updateFailure { return updateFailure }
        guard item != nil else { return errSecItemNotFound }
        item?.merge(attributes, uniquingKeysWith: { _, new in new })
        return errSecSuccess
    }

    func read(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        lastReadQuery = query
        if let readFailure { return (readFailure, nil) }
        guard var item else { return (errSecItemNotFound, nil) }
        if let substitutedReadData { item[kSecValueData as String] = substitutedReadData }
        return (errSecSuccess, item as CFDictionary)
    }
}

final class WhitegramSettingsArchiveKeychainTests: XCTestCase {
    func testDeviceOnlyPolicyVerifiedSaveRestoreAndReplacement() throws {
        let memory = SettingsArchiveKeychainMemory()
        let keychain = WhitegramSettingsArchiveKeychain(service: "test.settings.archive", access: memory)
        let first = try SettingsArchiveFixture.archive(["ghostModeEnabled": true])
        try keychain.save(first)
        XCTAssertEqual(memory.item?[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(memory.item?[kSecAttrService as String] as? String, "test.settings.archive")
        XCTAssertEqual(memory.item?[kSecAttrAccount as String] as? String, "settings-v1")
        XCTAssertEqual(memory.item?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(memory.item?[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(memory.item?[kSecAttrAccessGroup as String])
        XCTAssertEqual(memory.lastReadQuery[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(memory.lastReadQuery[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(try keychain.restore().encoded(), try first.encoded())
        let replacement = try SettingsArchiveFixture.archive(["disableReadReceipts": true])
        try keychain.save(replacement)
        XCTAssertEqual(try keychain.restore().keys, ["disableReadReceipts"])
    }

    func testMissingLockedAndFailedUpdateAreVisibleAndPreserveBackup() throws {
        let memory = SettingsArchiveKeychainMemory()
        let keychain = WhitegramSettingsArchiveKeychain(service: "test.settings.archive", access: memory)
        XCTAssertThrowsError(try keychain.restore())
        memory.addFailure = errSecInteractionNotAllowed
        XCTAssertThrowsError(try keychain.save(SettingsArchiveFixture.archive(["ghostModeEnabled": true])))
        XCTAssertNil(memory.item)
        memory.addFailure = nil
        let first = try SettingsArchiveFixture.archive(["ghostModeEnabled": true])
        try keychain.save(first)
        memory.updateFailure = errSecAuthFailed
        XCTAssertThrowsError(try keychain.save(SettingsArchiveFixture.archive(["disableReadReceipts": true])))
        XCTAssertEqual(try keychain.restore().encoded(), try first.encoded())
    }

    func testReadbackFailureNeverReportsSuccessfulSave() throws {
        let memory = SettingsArchiveKeychainMemory()
        let keychain = WhitegramSettingsArchiveKeychain(service: "test.settings.archive", access: memory)
        memory.substitutedReadData = Data("different".utf8)
        XCTAssertThrowsError(try keychain.save(SettingsArchiveFixture.archive(["ghostModeEnabled": true]))) { error in
            guard let error = error as? WhitegramSettingsArchiveKeychainError, case .verificationFailed = error else { return XCTFail("Expected failed readback verification") }
        }
        XCTAssertNotNil(memory.item)
        memory.substitutedReadData = nil
        memory.readFailure = errSecInteractionNotAllowed
        XCTAssertThrowsError(try keychain.save(SettingsArchiveFixture.archive(["ghostModeEnabled": false])))
    }

    func testUnexpectedProtectionOversizedOrInvalidPayloadCannotRestore() throws {
        let memory = SettingsArchiveKeychainMemory()
        let keychain = WhitegramSettingsArchiveKeychain(service: "test.settings.archive", access: memory)
        try keychain.save(SettingsArchiveFixture.archive(["ghostModeEnabled": true]))
        memory.item?[kSecAttrSynchronizable as String] = true
        XCTAssertThrowsError(try keychain.restore())
        memory.item?[kSecAttrSynchronizable as String] = false
        memory.item?[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        XCTAssertThrowsError(try keychain.restore())
        memory.item?[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        memory.substitutedReadData = Data(repeating: 32, count: WhitegramSettingsArchive.maximumBytes + 1)
        XCTAssertThrowsError(try keychain.restore())
        memory.substitutedReadData = SettingsArchiveFixture.raw(#"{"geminiApiKey":"secret"}"#)
        XCTAssertThrowsError(try keychain.restore())
    }
}
#endif

#if canImport(Darwin)
final class WhitegramSettingsTransferDocumentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsTransferTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCoordinatedNativeFileRoundTripAndTemporaryCleanup() throws {
        let archive = try SettingsArchiveFixture.archive(["ghostModeEnabled": true, "localStarsCount": Int64.max])
        let file = try WhitegramSettingsTransferExportFile(archive, parent: directory)
        let url = file.url
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let read = try WhitegramSettingsTransferDocumentRead().read(url)
        XCTAssertEqual(try read.encoded(), try archive.encoded())
        try file.remove()
        try file.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDirectorySymlinkAndNonFileURLReject() throws {
        let file = try WhitegramSettingsTransferExportFile(SettingsArchiveFixture.archive(["ghostModeEnabled": true]), parent: directory)
        let symlink = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file.url)
        for url in [directory!, symlink, try XCTUnwrap(URL(string: "https://example.invalid/settings.json"))] {
            XCTAssertThrowsError(try WhitegramSettingsTransferDocumentRead().read(url))
        }
    }

    func testOversizedSparseAndMalformedFilesReject() throws {
        let file = directory.appendingPathComponent("too-large.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(WhitegramSettingsArchive.maximumBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try WhitegramSettingsTransferDocumentRead().read(file))
        try Data("{invalid".utf8).write(to: file)
        XCTAssertThrowsError(try WhitegramSettingsTransferDocumentRead().read(file))
    }

    func testReadCancellationBeforeCoordinationAndQueuedWorkCancellation() throws {
        let file = try WhitegramSettingsTransferExportFile(SettingsArchiveFixture.archive(["ghostModeEnabled": true]), parent: directory)
        let read = WhitegramSettingsTransferDocumentRead()
        read.cancel()
        XCTAssertThrowsError(try read.read(file.url)) { error in
            guard let error = error as? WhitegramSettingsTransferDocumentError, case .cancelled = error else { return XCTFail("Expected cancellation") }
        }
        let cancelled = WhitegramSettingsTransferWork()
        cancelled.cancel()
        XCTAssertFalse(cancelled.begin())
        let started = WhitegramSettingsTransferWork()
        XCTAssertTrue(started.begin())
        XCTAssertFalse(started.begin())
        started.cancel()
        XCTAssertFalse(started.begin())
    }
}
#endif
