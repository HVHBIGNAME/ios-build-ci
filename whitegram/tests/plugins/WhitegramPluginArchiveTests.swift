import Foundation
import XCTest
import zlib
@testable import SettingsUI

final class WhitegramPluginArchiveTests: XCTestCase {
    private struct File {
        let name: String
        let data: Data
        var compressed: Data? = nil
        var descriptor = false
        var mode: UInt32 = 0x81a4
        var declaredSize: UInt32? = nil
    }

    private func zip(_ files: [File]) -> Data {
        var local = Data(), central = Data()
        func word(_ value: UInt16, _ data: inout Data) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func dword(_ value: UInt32, _ data: inout Data) {
            word(UInt16(truncatingIfNeeded: value), &data); word(UInt16(truncatingIfNeeded: value >> 16), &data)
        }
        for file in files {
            let name = Data(file.name.utf8), content = file.compressed ?? file.data
            let crc = file.data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
            let flags: UInt16 = file.descriptor ? 0x808 : 0x800
            let method: UInt16 = file.compressed == nil ? 0 : 8
            let size = file.declaredSize ?? UInt32(file.data.count), offset = UInt32(local.count)
            dword(0x04034b50, &local); word(20, &local); word(flags, &local); word(method, &local)
            dword(0, &local); dword(file.descriptor ? 0 : crc, &local)
            dword(file.descriptor ? 0 : UInt32(content.count), &local); dword(file.descriptor ? 0 : size, &local)
            word(UInt16(name.count), &local); word(0, &local); local.append(name); local.append(content)
            if file.descriptor {
                dword(0x08074b50, &local); dword(crc, &local); dword(UInt32(content.count), &local); dword(size, &local)
            }
            dword(0x02014b50, &central); word(0x0314, &central); word(20, &central); word(flags, &central); word(method, &central)
            dword(0, &central); dword(crc, &central); dword(UInt32(content.count), &central); dword(size, &central)
            word(UInt16(name.count), &central); word(0, &central); word(0, &central); word(0, &central); word(0, &central)
            dword(file.mode << 16, &central); dword(offset, &central); central.append(name)
        }
        let offset = UInt32(local.count)
        local.append(central)
        dword(0x06054b50, &local); word(0, &local); word(0, &local)
        word(UInt16(files.count), &local); word(UInt16(files.count), &local)
        dword(UInt32(central.count), &local); dword(offset, &local); word(0, &local)
        return local
    }

    private func rejected(_ expected: String, _ bytes: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try WhitegramPluginArchive.decode(bytes), file: file, line: line) {
            XCTAssertEqual(($0 as? WhitegramPluginError)?.code, expected, file: file, line: line)
        }
    }

    func testStoredAndDeflatedWithDescriptorHaveIdenticalContent() throws {
        let source = Data("console.log(1);".utf8)
        // Python zlib.compress(source, wbits=-15), not this decoder's output.
        let compressed = Data([0x4b, 0xce, 0xcf, 0x2b, 0xce, 0xcf, 0x49, 0xd5, 0xcb, 0xc9, 0x4f, 0xd7, 0x30, 0xd4, 0xb4, 0x06, 0x00])
        for descriptor in [false, true] {
            let archive = self.zip([File(name: "main.js", data: source, compressed: compressed, descriptor: descriptor)])
            XCTAssertEqual(try WhitegramPluginArchive.decode(archive)["main.js"], source)
        }
        XCTAssertEqual(try WhitegramPluginArchive.decode(self.zip([File(name: "main.js", data: source)]))["main.js"], source)
    }

    func testOriginalManifestAliasesOuterDirectoryAndMainPath() throws {
        for manifest in ["plugin.json", "manifest.json", "whitegram.json"] {
            let archive = self.zip([
                File(name: "Example/\(manifest)", data: Data("{\"name\":\"Archive\",\"main\":\"./lib/start.js\",\"id\":\"org.example.plugin\"}".utf8)),
                File(name: "Example/lib/start.js", data: Data("throw Error('not evaluated');".utf8)),
                File(name: "__MACOSX/._Example", data: Data())
            ])
            let result = try WhitegramPluginPackage.archive(archive, name: "fallback")
            XCTAssertEqual(result.entry, "lib/start.js")
            XCTAssertEqual(result.metadata["id"] as? String, "org.example.plugin")
            XCTAssertEqual(result.files.count, 2)
        }
    }

    func testEntryPrecedenceAndNestedRelativeModules() throws {
        let archive = self.zip([File(name: "index.js", data: Data()), File(name: "main.js", data: Data()), File(name: "lib/helper.js", data: Data())])
        XCTAssertEqual(try WhitegramPluginPackage.archive(archive, name: "example").entry, "main.js")
        let fallback = self.zip([File(name: "custom.js", data: Data()), File(name: "data/settings.json", data: Data("{}".utf8))])
        XCTAssertEqual(try WhitegramPluginPackage.archive(fallback, name: "example").entry, "custom.js")
    }

    func testTraversalLinksAndCanonicalCollisionsRejectBeforeExtraction() {
        for name in ["../escape.js", "/absolute.js", "a/../escape.js", "a\\main.js", "C:main.js", "a//b.js"] {
            self.rejected("INVALID_PATH", self.zip([File(name: name, data: Data())]))
        }
        self.rejected("INVALID_PATH", self.zip([File(name: "main.js", data: Data("../private".utf8), mode: 0xa1ff)]))
        self.rejected("INVALID_PACKAGE", self.zip([File(name: "main.js", data: Data()), File(name: "Main.js", data: Data())]))
        self.rejected("INVALID_PACKAGE", self.zip([File(name: "main.js", data: Data()), File(name: "main.js/child.js", data: Data())]))
        self.rejected("INVALID_PACKAGE", self.zip([File(name: "main.js", data: Data()), File(name: "main.js", data: Data())]))
    }

    func testCRCTruncationBombsAndEncryptionReject() {
        let archive = self.zip([File(name: "main.js", data: Data("hello".utf8))])
        self.rejected("INVALID_ARCHIVE", archive.dropLast())
        var corrupt = archive
        corrupt[37] ^= 1
        self.rejected("INVALID_ARCHIVE", corrupt)
        self.rejected("QUOTA_EXCEEDED", self.zip([File(name: "main.js", data: Data(), declaredSize: UInt32(WhitegramPluginStorage.maximumFileBytes + 1))]))
        self.rejected("INVALID_ARCHIVE", self.zip([File(name: "main.js", data: Data("hello".utf8), compressed: Data([0xff, 0xff]))]))
        var encrypted = archive
        let central = 30 + "main.js".utf8.count + 5
        encrypted[6] |= 1; encrypted[central + 8] |= 1
        self.rejected("UNSUPPORTED_ARCHIVE", encrypted)
    }

    func testOriginalZIPInstallationPreservesMetadataAndDoesNotExecute() throws {
        let storage = try WhitegramPluginStorage(accountId: "archive-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let url = storage.root.appendingPathComponent("Example.wgplugin")
        let data = self.zip([
            File(name: "plugin.json", data: Data("{\"id\":\"example\",\"name\":\"Original format\",\"author\":\"Fixture\",\"permissions\":[\"messages.intercept\"]}".utf8)),
            File(name: "main.js", data: Data("throw Error('do not execute on import');".utf8))
        ])
        try data.write(to: url)
        let record = try storage.install(from: url)
        XCTAssertEqual(record.packageId, "example")
        XCTAssertEqual(record.author, "Fixture")
        XCTAssertEqual(record.permissions, ["messages.intercept"])
        XCTAssertEqual(try storage.records().first, record)
        let files = try WhitegramPluginFiles(root: storage.pluginRoot(record.id))
        XCTAssertEqual(try files.packageFile("main.js"), Data("throw Error('do not execute on import');".utf8))
    }

    func testTypeScriptRequiresActualCompilerAndCannotBecomeAnEmptySuccessfulPlugin() throws {
        let storage = try WhitegramPluginStorage(accountId: "archive-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage.root) }
        let url = storage.root.appendingPathComponent("Typed.plugin")
        try self.zip([File(name: "main.ts", data: Data("const n: number = 1;".utf8))]).write(to: url)
        XCTAssertThrowsError(try storage.install(from: url)) { XCTAssertEqual(($0 as? WhitegramPluginError)?.code, "UNSUPPORTED_LANGUAGE") }
        XCTAssertTrue(try storage.records().isEmpty)
    }

    func testExistingRecordDecodingRetainsInstallationIdentity() throws {
        let original = "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Existing\",\"version\":\"1.0\",\"entry\":\"main.js\",\"permissions\":[],\"installedAt\":0}"
        let record = try JSONDecoder().decode(WhitegramPluginRecord.self, from: Data(original.utf8))
        XCTAssertNil(record.packageId)
        XCTAssertEqual(record.id, "00000000-0000-0000-0000-000000000001")
    }
}
