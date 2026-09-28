import Foundation
import XCTest
@testable import WhitegramServiceHost

private final class SecretFixture: WhitegramServiceSecretStorage {
    var values: [WhitegramServiceCredential: String] = [:]
    var readError: WhitegramServiceError?
    var writeError: WhitegramServiceError?
    var deleteError: WhitegramServiceError?
    var writes = 0
    func read(_ credential: WhitegramServiceCredential) throws -> String? {
        if let error = self.readError { throw error }
        return self.values[credential]
    }
    func write(_ value: String, for credential: WhitegramServiceCredential) throws {
        if let error = self.writeError { throw error }
        self.writes += 1
        self.values[credential] = value
    }
    func remove(_ credential: WhitegramServiceCredential) throws {
        if let error = self.deleteError { throw error }
        self.values.removeValue(forKey: credential)
    }
}

private final class LegacyFixture: WhitegramServiceLegacyCredentialStorage {
    var values: [WhitegramServiceCredential: String] = [:]
    var clearError: WhitegramServiceError?
    var reads = 0
    var clears = 0
    func read(_ credential: WhitegramServiceCredential) throws -> String? { self.reads += 1; return self.values[credential] }
    func clear(_ credential: WhitegramServiceCredential) throws {
        if let error = self.clearError { throw error }
        self.clears += 1
        self.values.removeValue(forKey: credential)
    }
}

final class WhitegramServiceCredentialTests: XCTestCase {
    func testMigrationStoresBeforeRemovingPlaintext() throws {
        let secrets = SecretFixture()
        let legacy = LegacyFixture()
        legacy.values[.gemini] = "fixture-legacy-key"
        let vault = WhitegramServiceCredentialVault(secrets: secrets, legacy: legacy)
        XCTAssertEqual(try vault.token(for: .gemini), "fixture-legacy-key")
        XCTAssertEqual(secrets.values[.gemini], "fixture-legacy-key")
        XCTAssertNil(legacy.values[.gemini])
        XCTAssertEqual(secrets.writes, 1)
        _ = try vault.token(for: .gemini)
        XCTAssertEqual(secrets.writes, 1)
    }

    func testExistingSecureValueWinsOverStalePreferences() throws {
        let secrets = SecretFixture()
        let legacy = LegacyFixture()
        secrets.values[.groq] = "fixture-current-key"
        legacy.values[.groq] = "fixture-stale-key"
        let vault = WhitegramServiceCredentialVault(secrets: secrets, legacy: legacy)
        XCTAssertEqual(try vault.token(for: .groq), "fixture-current-key")
        XCTAssertNil(legacy.values[.groq])
        XCTAssertEqual(secrets.writes, 0)
    }

    func testLockedKeychainDoesNotFallBackToPlaintext() {
        let secrets = SecretFixture()
        let legacy = LegacyFixture()
        secrets.readError = .keychain(status: -25308)
        legacy.values[.virusTotal] = "fixture-key"
        let vault = WhitegramServiceCredentialVault(secrets: secrets, legacy: legacy)
        XCTAssertThrowsError(try vault.token(for: .virusTotal)) { XCTAssertEqual($0 as? WhitegramServiceError, .keychain(status: -25308)) }
        XCTAssertEqual(legacy.reads, 0)
        XCTAssertEqual(legacy.clears, 0)
        XCTAssertEqual(legacy.values[.virusTotal], "fixture-key")
    }

    func testWriteFailureLeavesLegacyKeyForRetry() throws {
        let secrets = SecretFixture()
        let legacy = LegacyFixture()
        secrets.writeError = .keychain(status: -1)
        legacy.values[.gemini] = "fixture-key"
        let vault = WhitegramServiceCredentialVault(secrets: secrets, legacy: legacy)
        XCTAssertThrowsError(try vault.token(for: .gemini))
        XCTAssertEqual(legacy.values[.gemini], "fixture-key")
        XCTAssertEqual(legacy.clears, 0)
        secrets.writeError = nil
        XCTAssertEqual(try vault.token(for: .gemini), "fixture-key")
        XCTAssertNil(legacy.values[.gemini])
    }

    func testCleanupFailureDoesNotReturnUsableTokenAndCanBeRetried() throws {
        let secrets = SecretFixture()
        let legacy = LegacyFixture()
        legacy.values[.groq] = "fixture-key"
        legacy.clearError = .preferences
        let vault = WhitegramServiceCredentialVault(secrets: secrets, legacy: legacy)
        XCTAssertThrowsError(try vault.token(for: .groq)) { XCTAssertEqual($0 as? WhitegramServiceError, .preferences) }
        XCTAssertEqual(secrets.values[.groq], "fixture-key")
        XCTAssertEqual(legacy.values[.groq], "fixture-key")
        legacy.clearError = nil
        XCTAssertEqual(try vault.token(for: .groq), "fixture-key")
        XCTAssertEqual(secrets.writes, 1)
        XCTAssertNil(legacy.values[.groq])
    }

    func testDeleteClearsLegacyEvenIfSecureDeleteFails() {
        let secrets = SecretFixture()
        let legacy = LegacyFixture()
        secrets.values[.virusTotal] = "fixture-current"
        secrets.deleteError = .keychain(status: -1)
        legacy.values[.virusTotal] = "fixture-old"
        let vault = WhitegramServiceCredentialVault(secrets: secrets, legacy: legacy)
        XCTAssertThrowsError(try vault.remove(.virusTotal))
        XCTAssertNil(legacy.values[.virusTotal])
        XCTAssertEqual(secrets.values[.virusTotal], "fixture-current")
    }

    func testInvalidKeysCannotBeSaved() {
        let secrets = SecretFixture()
        let legacy = LegacyFixture()
        let vault = WhitegramServiceCredentialVault(secrets: secrets, legacy: legacy)
        for key in ["", "two words", "header\r\nattack"] { XCTAssertThrowsError(try vault.save(key, for: .gemini)) }
        XCTAssertEqual(secrets.writes, 0)
        XCTAssertEqual(legacy.clears, 0)
    }

    func testSaveAndDeleteNotificationsCarryOnlyCredentialIdentity() throws {
        let vault = WhitegramServiceCredentialVault(secrets: SecretFixture(), legacy: LegacyFixture())
        var credentials: [WhitegramServiceCredential] = []
        let observer = NotificationCenter.default.addObserver(forName: WhitegramServiceCredential.updatedNotification, object: nil, queue: nil) { notification in
            XCTAssertNil(notification.userInfo)
            if let credential = notification.object as? WhitegramServiceCredential { credentials.append(credential) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try vault.save("fixture-key", for: .gemini)
        try vault.remove(.gemini)
        XCTAssertEqual(credentials, [.gemini, .gemini])
    }

    func testChangeNotificationDoesNotHoldTheVaultLock() throws {
        let vault = WhitegramServiceCredentialVault(secrets: SecretFixture(), legacy: LegacyFixture())
        let observer = NotificationCenter.default.addObserver(forName: WhitegramServiceCredential.updatedNotification, object: nil, queue: nil) { _ in
            let readFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = try? vault.token(for: .gemini)
                readFinished.signal()
            }
            XCTAssertEqual(readFinished.wait(timeout: .now() + 2), .success)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try vault.save("fixture-key", for: .gemini)
    }
}
