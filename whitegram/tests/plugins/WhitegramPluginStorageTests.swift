import Foundation
import XCTest
@testable import SettingsUI

// Run in a macOS/iOS XCTest host that links SettingsUI with testability enabled.
// These exercise the actual Foundation storage implementation, not the Node
// host fixture. They are intentionally not represented as Windows test results.
final class WhitegramPluginStorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false)
        for path in ["package", "data/files"] {
            try FileManager.default.createDirectory(at: self.directory.appendingPathComponent(path, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: self.directory) }

    private func assertCode(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ action: () throws -> Void) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual((error as? WhitegramPluginError)?.code, code, file: file, line: line)
        }
    }

    func testPathContainmentAndSymlinks() throws {
        for path in ["", "../private", "/private/data", "C:\\private", "file:///private", "a/../../private", "a//b", "a/./b", "a\0b"] {
            self.assertCode("INVALID_PATH") { _ = try WhitegramPluginPath.url(root: self.directory, path: path) }
        }
        let outside = self.directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let root = self.directory.appendingPathComponent("data/files", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        self.assertCode("INVALID_PATH") { _ = try WhitegramPluginPath.url(root: root, path: "link/secret") }
        let legal = try WhitegramPluginPath.url(root: root, path: "notes/entry.txt")
        XCTAssertEqual(legal.path, root.appendingPathComponent("notes/entry.txt").path)
    }

    func testModulesPermitInternalParentsButNotEscape() throws {
        XCTAssertEqual(try WhitegramPluginPath.modulePath(directory: "lib/deep", name: "../helper"), "lib/helper")
        self.assertCode("INVALID_PATH") { _ = try WhitegramPluginPath.modulePath(directory: "lib", name: "../../escape") }
        self.assertCode("INVALID_PATH") { _ = try WhitegramPluginPath.modulePath(directory: "", name: "node:fs") }
        try Data("{\"value\":42}".utf8).write(to: self.directory.appendingPathComponent("package/config.json"))
        let files = try WhitegramPluginFiles(root: self.directory)
        let module = try files.resolveModule(directory: "", name: "./config")
        XCTAssertEqual(module["kind"] as? String, "json")
        XCTAssertEqual(module["path"] as? String, "config.json")
        XCTAssertNil(try files.packageFile("missing.txt"))
    }

    func testJSONPersistenceAndFilesAreSeparateFromPackage() throws {
        let files = try WhitegramPluginFiles(root: self.directory)
        _ = try files.storage("set", arguments: ["counter", ["n": 7, "enabled": true] as [String: Any]])
        _ = try files.file("write", arguments: ["notes/one.txt", "persisted"])
        _ = try files.file("writeBytes", arguments: ["binary.bin", ["__wgBase64": Data([0, 127, 128, 255]).base64EncodedString()]])
        let reopened = try WhitegramPluginFiles(root: self.directory)
        let state = try reopened.storage("get", arguments: ["counter"]) as? [String: Any]
        XCTAssertEqual((state?["n"] as? NSNumber)?.intValue, 7)
        XCTAssertEqual(try reopened.file("read", arguments: ["notes/one.txt"]) as? String, "persisted")
        XCTAssertEqual(try reopened.file("readBase64", arguments: ["binary.bin"]) as? String, "AH+A/w==")
        XCTAssertEqual(try reopened.file("list", arguments: []) as? [String], ["binary.bin", "notes/one.txt"])
        self.assertCode("INVALID_PATH") { _ = try reopened.file("write", arguments: ["../../manifest.json", "no"]) }
        XCTAssertNil(try reopened.packageFile("notes/one.txt"))
    }

    func testInvalidStateAndQuotaFailWithoutAWrite() throws {
        try Data("[]".utf8).write(to: self.directory.appendingPathComponent("data/state.json"))
        let files = try WhitegramPluginFiles(root: self.directory)
        self.assertCode("INVALID_STORAGE") { _ = try files.storage("get", arguments: ["key"]) }
        self.assertCode("QUOTA_EXCEEDED") {
            _ = try files.file("write", arguments: ["large.txt", String(repeating: "a", count: WhitegramPluginStorage.maximumFileBytes + 1)])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("data/files/large.txt").path))
        self.assertCode("INVALID_ARGUMENT") { _ = try files.file("writeBase64", arguments: ["bad.bin", "not base64!"]) }
    }

    func testImportDoesNotEvaluateAndRejectsEscapingPackageFiles() throws {
        let storage = try WhitegramPluginStorage(accountId: "test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let script = self.directory.appendingPathComponent("throwing.js")
        try Data("throw new Error('must not run on import');".utf8).write(to: script)
        let installed = try storage.install(from: script)
        XCTAssertEqual(try storage.records().map { $0.id }, [installed.id])
        let package = self.directory.appendingPathComponent("escape.wgplugin")
        let object: [String: Any] = ["name": "Bad package", "entry": "main.js", "files": ["main.js": "", "../escape.js": ""]]
        try JSONSerialization.data(withJSONObject: object).write(to: package)
        self.assertCode("INVALID_PATH") { _ = try storage.install(from: package) }
        XCTAssertEqual(try storage.records().count, 1)
        try storage.remove(installed.id)
        XCTAssertTrue(try storage.records().isEmpty)
    }

    func testReplacedStorageRootsCannotRedirectAnExistingSession() throws {
        let files = try WhitegramPluginFiles(root: self.directory)
        let outside = self.directory.appendingPathComponent("other-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appendingPathComponent("files/secret.txt"))
        let dataRoot = self.directory.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.removeItem(at: dataRoot)
        try FileManager.default.createSymbolicLink(at: dataRoot, withDestinationURL: outside)
        self.assertCode("INVALID_PATH") { _ = try files.file("read", arguments: ["secret.txt"]) }
        self.assertCode("INVALID_PATH") { _ = try files.storage("set", arguments: ["key", "value"]) }
        self.assertCode("INVALID_PATH") { _ = try WhitegramPluginPath.url(root: dataRoot, path: "files/secret.txt") }
        self.assertCode("INVALID_PATH") { _ = try WhitegramPluginStorage(accountId: "../other-account") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("state.json").path))
    }

    func testLimitedReadsPreserveBoundarySizedFiles() throws {
        let file = self.directory.appendingPathComponent("boundary.bin")
        let bytes = Data(repeating: 42, count: 65537)
        try bytes.write(to: file)
        XCTAssertEqual(try WhitegramPluginStorage.readLimited(file, limit: bytes.count), bytes)
        self.assertCode("QUOTA_EXCEEDED") { _ = try WhitegramPluginStorage.readLimited(file, limit: bytes.count - 1) }
        let empty = self.directory.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        XCTAssertEqual(try WhitegramPluginStorage.readLimited(empty, limit: 0), Data())
    }

    func testImportRejectsCanonicalCollisionsAndFileDirectoryConflicts() throws {
        let storage = try WhitegramPluginStorage(accountId: "test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let package = self.directory.appendingPathComponent("collision.wgplugin")
        for files in [["main.js": "", "Main.js": "different"], ["main.js": "", "main.js/child.js": ""]] {
            let object: [String: Any] = ["name": "Collision", "entry": "main.js", "files": files]
            try JSONSerialization.data(withJSONObject: object).write(to: package)
            self.assertCode("INVALID_PACKAGE") { _ = try storage.install(from: package) }
            XCTAssertTrue(try storage.records().isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.root.path).isEmpty)
        }
    }

    func testJSONNumbersAndBooleansAreNotInterchangeable() throws {
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("[true,false,0,1,1.5]".utf8)) as? [Any])
        XCTAssertTrue(try whitegramPluginBool(arguments, 0))
        XCTAssertFalse(try whitegramPluginBool(arguments, 1))
        XCTAssertEqual(try whitegramPluginNumber(arguments, 2), 0)
        XCTAssertEqual(try whitegramPluginNumber(arguments, 3), 1)
        XCTAssertEqual(try whitegramPluginNumber(arguments, 4), 1.5)
        self.assertCode("INVALID_ARGUMENT") { _ = try whitegramPluginNumber(arguments, 0) }
        self.assertCode("INVALID_ARGUMENT") { _ = try whitegramPluginBool(arguments, 3) }
    }
}
