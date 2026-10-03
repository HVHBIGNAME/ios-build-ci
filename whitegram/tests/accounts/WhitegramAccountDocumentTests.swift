import Foundation
import XCTest
@testable import TelegramCore
@testable import SettingsUI

final class WhitegramAccountDocumentTests: XCTestCase {
    func testSeparateTelethonSidecarSelectionAndSourcePreservation() throws {
        let fixture = try AccountFixtures()
        let source = try WhitegramSessionStagingDirectory()
        let session = source.url.appendingPathComponent("account.session")
        let sidecar = source.url.appendingPathComponent("account.json")
        let data = try fixture.data("telethon")
        try WhitegramSessionFiles.write(data, to: session)
        try WhitegramSessionFiles.write(fixture.data("sidecar"), to: sidecar)
        let documents = try WhitegramAccountDocuments()
        try documents.prepare([sidecar, session])
        XCTAssertEqual(try documents.parse().map { $0.account.identity.userId }, [5481234567])
        XCTAssertEqual(try WhitegramSessionFiles.read(session), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        try documents.staging.remove()
        XCTAssertEqual(try WhitegramSessionFiles.read(session), data)
    }

    func testSelectedSQLiteWALCannotBeImportedAsACompleteSnapshot() throws {
        let fixture = try AccountFixtures()
        let source = try WhitegramSessionStagingDirectory()
        let session = source.url.appendingPathComponent("account.session")
        let wal = source.url.appendingPathComponent("account.session-wal")
        try WhitegramSessionFiles.write(fixture.data("telethon_with_user_id"), to: session)
        try WhitegramSessionFiles.write(Data(), to: wal)
        let documents = try WhitegramAccountDocuments()
        XCTAssertThrowsError(try documents.prepare([session, wal])) { XCTAssertEqual($0 as? WhitegramSessionError, .changedFile) }
    }

    func testFileTypesSizeLimitsAndOwnedStagingCleanup() throws {
        let directory = try WhitegramSessionStagingDirectory()
        let regular = directory.url.appendingPathComponent("account.wgsession")
        try WhitegramSessionFiles.write(Data(repeating: 0x41, count: 4096), to: regular)
        XCTAssertThrowsError(try WhitegramSessionFiles.read(regular, maximumBytes: 4095)) { XCTAssertEqual($0 as? WhitegramSessionError, .tooLarge) }
        XCTAssertThrowsError(try WhitegramSessionFiles.read(directory.url))
        XCTAssertThrowsError(try WhitegramSessionFiles.read(try XCTUnwrap(URL(string: "https://example.invalid/session"))))
        let link = directory.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        XCTAssertThrowsError(try WhitegramSessionFiles.read(link))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: regular.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try directory.remove()
        try directory.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.path))
    }

    func testDirectoryTDataSelectionUsesOnlyAuthFilesAndCancellation() throws {
        let fixture = try AccountFixtures()
        let source = try fixture.tdata(unlocked: true)
        let ignored = source.url.appendingPathComponent("media-cache")
        try WhitegramSessionFiles.write(Data("unrelated media".utf8), to: ignored)
        let documents = try WhitegramAccountDocuments()
        try documents.prepare([source.url])
        XCTAssertEqual(try documents.parse().map { $0.account.identity.userId }, [5481234567, 9876543210])
        XCTAssertEqual(try WhitegramSessionFiles.read(ignored), Data("unrelated media".utf8))
        let cancelled = try WhitegramAccountDocuments()
        cancelled.cancel()
        XCTAssertThrowsError(try cancelled.prepare([source.url])) { XCTAssertEqual($0 as? WhitegramSessionError, .cancelled) }
    }
}
