import Foundation
import XCTest
import SQLite3
@testable import TelegramCore
@testable import SettingsUI

final class AccountFixtures {
    let values: [String: Any]
    init() throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["WHITEGRAM_ACCOUNTS_FIXTURES"])
        values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(values["synthetic_only"] as? Bool, true)
    }
    func data(_ name: String) throws -> Data { return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(values[name] as? String))) }
    func tdata(unlocked: Bool = false) throws -> WhitegramSessionStagingDirectory {
        let directory = try WhitegramSessionStagingDirectory()
        for (name, value) in try XCTUnwrap(values["tdata"] as? [String: String]) {
            if name == "unlocked_key_datas" { continue }
            let data: Data
            if unlocked && name == "key_datas" {
                data = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap((values["tdata"] as? [String: String])?["unlocked_key_datas"])))
            } else { data = try XCTUnwrap(Data(base64Encoded: value)) }
            try WhitegramSessionFiles.write(data, to: directory.url.appendingPathComponent(name))
        }
        return directory
    }
}

final class WhitegramSessionCodecTests: XCTestCase {
    func testOriginalSessionArchiveAnd64BitPeerIdentity() throws {
        let fixture = try AccountFixtures()
        let backup = try WhitegramSessionBackup(data: fixture.data("session_archive"))
        XCTAssertEqual(backup.account.identity.userId, 5481234567)
        XCTAssertEqual(backup.account.identity.peerId, (fixture.values["peer_id"] as? NSNumber)?.int64Value)
        XCTAssertNotEqual(backup.account.identity.peerId, backup.account.identity.userId)
        XCTAssertEqual(backup.recordId, -123456789)
        XCTAssertEqual(backup.additionalDatacenterKeys.count, 1)
        XCTAssertEqual(backup.notificationEncryptionKey?.count, 256)
        XCTAssertEqual(try WhitegramSessionBackup(data: backup.encoded()), backup)
    }

    func testAuthKeyIdentifierMatchesIndependentSHA1Fixture() throws {
        let fixture = try AccountFixtures()
        XCTAssertEqual(WhitegramSessionCrypto.authKeyId(try fixture.data("auth_key")), (fixture.values["auth_key_id"] as? NSNumber)?.int64Value)
        XCTAssertEqual(try WhitegramSessionIdentity.fromPeerId(WhitegramSessionIdentity(userId: 0x1fffffffffffffff, testingEnvironment: true).peerId, testingEnvironment: true).userId, 0x1fffffffffffffff)
        XCTAssertThrowsError(try WhitegramSessionIdentity.fromPeerId(1 << 32 | 7, testingEnvironment: false))
    }

    func testRejectsInvalidKeysDatacentersAndDuplicateBackupAttributes() throws {
        XCTAssertThrowsError(try WhitegramPortableAccount(dcId: 2, authKey: Data(repeating: 0, count: 256), userId: 123, name: ""))
        XCTAssertThrowsError(try WhitegramPortableAccount(dcId: 0, authKey: Data(repeating: 1, count: 256), userId: 123, name: ""))
        XCTAssertThrowsError(try WhitegramPortableAccount(dcId: 5, authKey: Data(repeating: 1, count: 256), userId: 123, name: "", testingEnvironment: true))
        let fixture = try AccountFixtures()
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.data("session_archive")) as? [String: Any])
        var record = try XCTUnwrap(archive["accountRecord"] as? [String: Any])
        var attributes = try XCTUnwrap(record["attributes"] as? [[String: Any]])
        attributes.append(attributes[0]); record["attributes"] = attributes; archive["accountRecord"] = record
        XCTAssertThrowsError(try WhitegramSessionBackup(data: JSONSerialization.data(withJSONObject: archive)))
        XCTAssertThrowsError(try WhitegramSessionBackup(data: Data(repeating: 65, count: WhitegramSessionBackup.maximumBytes + 1)))
    }

    func testTelethonRequiresSidecarOrActualUserIdColumn() throws {
        let fixture = try AccountFixtures()
        let directory = try WhitegramSessionStagingDirectory()
        let session = directory.url.appendingPathComponent("synthetic.session")
        try WhitegramSessionFiles.write(fixture.data("telethon"), to: session)
        XCTAssertThrowsError(try WhitegramSessionTelethon.read(at: session)) { XCTAssertEqual($0 as? WhitegramSessionError, .missingIdentity) }
        let account = try WhitegramSessionTelethon.read(at: session, sidecar: fixture.data("sidecar"))
        XCTAssertEqual(account.identity.userId, 5481234567)
        XCTAssertEqual(account.name, "Synthetic Account")
        XCTAssertEqual(account.authKey, try fixture.data("auth_key"))
        let withId = directory.url.appendingPathComponent("id.session")
        try WhitegramSessionFiles.write(fixture.data("telethon_with_user_id"), to: withId)
        XCTAssertEqual(try WhitegramSessionTelethon.read(at: withId).identity, account.identity)
        XCTAssertThrowsError(try WhitegramSessionTelethon.read(at: withId, sidecar: Data("{\"id\":9876543210}".utf8))) { XCTAssertEqual($0 as? WhitegramSessionError, .identityMismatch) }
        XCTAssertThrowsError(try WhitegramSessionTelethon.read(at: session, sidecar: Data("{\"id\":true}".utf8)))
    }

    func testTelethonExportOpensAsStockSQLiteAndRoundTrips() throws {
        let backup = try WhitegramSessionBackup(data: AccountFixtures().data("session_archive"))
        let directory = try WhitegramSessionStagingDirectory()
        let urls = try WhitegramSessionTelethon.write(backup.account, to: directory.url)
        XCTAssertEqual(urls.count, 2)
        let imported = try WhitegramSessionTelethon.read(at: urls[0], sidecar: WhitegramSessionFiles.read(urls[1]))
        XCTAssertEqual(imported.identity, backup.account.identity)
        XCTAssertEqual(imported.authKey, backup.account.authKey)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(urls[0].path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT version FROM version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 8)
        XCTAssertThrowsError(try WhitegramSessionTelethon.write(backup.account, to: directory.url))
    }

    func testPyrogramHasItsOwnIdentityAndEnvironmentColumns() throws {
        let fixture = try AccountFixtures()
        let directory = try WhitegramSessionStagingDirectory()
        for (name, testing) in [("pyrogram", false), ("pyrogram_test", true)] {
            let url = directory.url.appendingPathComponent(name + ".session")
            try WhitegramSessionFiles.write(fixture.data(name), to: url)
            let account = try WhitegramSessionTelethon.read(at: url)
            XCTAssertEqual(account.identity.userId, 5481234567)
            XCTAssertEqual(account.identity.testingEnvironment, testing)
            XCTAssertEqual(account.authKey, try fixture.data("auth_key"))
            let conflict = try JSONSerialization.data(withJSONObject: ["whitegram_test_environment": !testing])
            XCTAssertThrowsError(try WhitegramSessionTelethon.read(at: url, sidecar: conflict)) { XCTAssertEqual($0 as? WhitegramSessionError, .identityMismatch) }
        }
    }

    func testLegacyDuplicatesAreDeduplicatedButDifferentKeysAreNotGuessed() throws {
        let original = try WhitegramSessionBackup(data: AccountFixtures().data("session_archive"))
        XCTAssertEqual(try WhitegramSessionBackup.unique([original, original]), [original])
        let account = try WhitegramPortableAccount(dcId: original.account.dcId, authKey: Data(original.account.authKey.reversed()), userId: original.account.identity.userId, name: "Conflicting backup")
        let other = try WhitegramSessionBackup(account: account, recordId: 456)
        XCTAssertThrowsError(try WhitegramSessionBackup.unique([original, other])) { XCTAssertEqual($0 as? WhitegramSessionError, .conflictingSessions) }
        let testAccount = try WhitegramPortableAccount(dcId: original.account.dcId, authKey: original.account.authKey, userId: original.account.identity.userId, name: "Test environment", testingEnvironment: true)
        XCTAssertEqual(try WhitegramSessionBackup.unique([original, WhitegramSessionBackup(account: testAccount, recordId: 456)]).count, 2)
    }

    func testIGEUsesIndependentOpenSSLKnownAnswer() throws {
        let fixture = try AccountFixtures()
        let aes = try XCTUnwrap(fixture.values["aes"] as? [String: String])
        func field(_ key: String) throws -> Data { return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(aes[key]))) }
        let decrypted = try WhitegramSessionCrypto.aesIGE(field("ciphertext"), key: field("key"), iv: field("iv"), encrypt: false)
        XCTAssertEqual(decrypted, try field("plaintext"))
        XCTAssertEqual(try WhitegramSessionCrypto.aesIGE(decrypted, key: field("key"), iv: field("iv"), encrypt: true), try field("ciphertext"))
    }

    func testEncryptedAndUnlockedMultiAccountTData() throws {
        let fixture = try AccountFixtures()
        let encrypted = try fixture.tdata()
        let passcode = try XCTUnwrap(fixture.values["tdata_passcode"] as? String)
        XCTAssertThrowsError(try WhitegramSessionTData.read(directory: encrypted.url)) { XCTAssertEqual($0 as? WhitegramSessionError, .passcodeRequired) }
        XCTAssertThrowsError(try WhitegramSessionTData.read(directory: encrypted.url, passcode: "wrong")) { XCTAssertEqual($0 as? WhitegramSessionError, .invalidPasscode) }
        let result = try WhitegramSessionTData.read(directory: encrypted.url, passcode: passcode)
        XCTAssertEqual(result.map { $0.identity.userId }, [5481234567, 9876543210])
        XCTAssertEqual(result.map(\.dcId), [2, 5])
        XCTAssertEqual(result[0].authKey, try fixture.data("auth_key"))
        let unlocked = try fixture.tdata(unlocked: true)
        XCTAssertEqual(try WhitegramSessionTData.read(directory: unlocked.url), result)
    }

    func testTDataChecksOuterChecksumAndMasterDCMapping() throws {
        let fixture = try AccountFixtures()
        let directory = try fixture.tdata(unlocked: true)
        let keyURL = directory.url.appendingPathComponent("key_datas")
        var damaged = try WhitegramSessionFiles.read(keyURL)
        damaged[damaged.count - 1] ^= 1
        try damaged.write(to: keyURL)
        XCTAssertThrowsError(try WhitegramSessionTData.read(directory: directory.url)) { XCTAssertEqual($0 as? WhitegramSessionError, .damagedTData) }
        var auth = Data([0, 0, 0, 123, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 1])
        auth.append(try fixture.data("auth_key"))
        XCTAssertThrowsError(try WhitegramSessionTData.parseAuthorization(auth)) { XCTAssertEqual($0 as? WhitegramSessionError, .invalidDatacenter) }
        XCTAssertEqual(WhitegramSessionTData.accountFileName("data"), "D877F783D5D3EF8C")
    }

    func testZIPInteroperabilityAndTraversalRejection() throws {
        let fixture = try AccountFixtures()
        let decoded = try WhitegramSessionZip.decode(fixture.data("zip_deflate"))
        XCTAssertEqual(decoded.map(\.name), ["sessions/synthetic.session", "sessions/synthetic.json"])
        XCTAssertEqual(decoded[0].data, try fixture.data("telethon"))
        let encoded = try WhitegramSessionZip.encode(decoded)
        XCTAssertEqual(try WhitegramSessionZip.decode(encoded).map(\.data), decoded.map(\.data))
        XCTAssertThrowsError(try WhitegramSessionZip.decode(fixture.data("zip_unsafe_path"))) { XCTAssertEqual($0 as? WhitegramSessionError, .unsafeFile) }
        for name in ["../x", "/x", "a/../../x", "a\\x", "C:x", "a//x", "./x", "a\0x"] {
            XCTAssertFalse(WhitegramSessionZip.safePath(name))
        }
        XCTAssertThrowsError(try WhitegramSessionZip.encode([.init(name: "A.session", data: Data()), .init(name: "a.session", data: Data())]))
    }

    func testDocumentReviewParsesAllBeforeAnyAccountImport() throws {
        let fixture = try AccountFixtures()
        let directory = try WhitegramSessionStagingDirectory()
        let zip = directory.url.appendingPathComponent("synthetic.zip")
        try WhitegramSessionFiles.write(fixture.data("zip_deflate"), to: zip)
        let documents = try WhitegramAccountDocuments()
        try documents.prepare([zip])
        XCTAssertEqual(try documents.parse().map { $0.account.identity.userId }, [5481234567])
        documents.cancel()
        XCTAssertThrowsError(try documents.parse()) { XCTAssertEqual($0 as? WhitegramSessionError, .cancelled) }
    }
}
