import Foundation
import XCTest
@testable import TelegramCore
@testable import SettingsUI

final class WhitegramLocalizationTests: XCTestCase {
    func testOriginalFileFormatHeadersUnicodeDuplicatesAndUnknownKeys() throws {
        let source = """
        # Whitegram localization
        # name: Мой перевод
        # AUTHOR: Author
        # lang: uk
        section.ghost: "Перша назва"
        ignored line
        section.ghost: "Режим привида"
        custom.plugin: "Перша\\nДруга: \\"цитата\\""
        empty: ""
        """
        let pack = try XCTUnwrap(WhitegramLocalizationPack.parse(source))
        XCTAssertEqual(pack.name, "Мой перевод")
        XCTAssertEqual(pack.author, "Author")
        XCTAssertEqual(pack.languageCode, "uk")
        XCTAssertEqual(pack.entries["section.ghost"], "Режим привида")
        XCTAssertEqual(pack.entries["custom.plugin"], "Перша\nДруга: \"цитата\"")
        XCTAssertNil(pack.entries["empty"])
    }

    func testExportUsesOriginalHeadersAndRoundTripsQuotedMultilineText() throws {
        let original = WhitegramLocalizationPack(name: "Тест", author: "Автор", languageCode: "ru",
            entries: ["a": "строка\n\"цитата\" 😀", "b": "двоеточие: текст"])
        let exported = original.serialized()
        XCTAssertTrue(exported.hasPrefix("# Whitegram localization\n# name: Тест\n# author: Автор\n# language: ru\n"))
        XCTAssertTrue(exported.contains("a: \"строка\\n\\\"цитата\\\" 😀\""))
        XCTAssertEqual(WhitegramLocalizationPack.parse(exported), original)
        XCTAssertNil(WhitegramLocalizationPack.parse("# name: only headers\nempty: \"\""))
        XCTAssertEqual(WhitegramLocalizationPack.parse("a: text")?.name, "Localization")
    }

    func testRecoveredTableAndLanguageNormalization() {
        XCTAssertEqual(WhitegramLocalizationStrings.values.count, 1597)
        XCTAssertEqual(WhitegramLocalization.builtInString("desc.camera", language: "ru"), "Зум, HD-отправка, кружки")
        XCTAssertEqual(WhitegramLocalization.builtInString("section.ghost", language: "uk"), "Режим привида")
        XCTAssertEqual(WhitegramLocalization.builtInString("section.camera", language: "en"), "Camera")
        XCTAssertEqual(WhitegramLocalization.normalizedLanguage(" UK_ua "), "uk")
        XCTAssertEqual(WhitegramLocalization.normalizedLanguage("ru-raw"), "ru")
        XCTAssertEqual(WhitegramLocalization.normalizedLanguage("de"), "en")
        XCTAssertNil(WhitegramLocalization.builtInString("not.present", language: "en"))
    }

    func testOriginalStoredDictionaryAndMetadataSurviveRestartAndRemoval() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = directory.appendingPathComponent("wg_localization.json")
        let store = WhitegramLocalizationStore(fileURL: url, defaults: defaults)
        let pack = WhitegramLocalizationPack(name: "Name", author: "Author", languageCode: "uk", entries: ["section.camera": "Камера"])
        try store.apply(pack)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url)), pack.entries)
        XCTAssertEqual(defaults.string(forKey: "wg_customLocalizationName"), "Name")
        XCTAssertEqual(try WhitegramLocalizationStore(fileURL: url, defaults: defaults).activePack(), pack)
        try store.remove()
        XCTAssertNil(try store.activePack())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(defaults.object(forKey: "wg_customLocalizationName"))
    }

    func testFailedWriteDoesNotPublishPackOrReplaceMetadata() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("wg_localization.json")
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhitegramLocalizationStore(fileURL: missing, defaults: defaults)
        let pack = WhitegramLocalizationPack(name: "New", author: "", languageCode: "ru", entries: ["a": "b"])
        XCTAssertThrowsError(try store.apply(pack))
        XCTAssertNil(try store.activePack())
        XCTAssertNil(defaults.object(forKey: "wg_customLocalizationName"))
    }

    func testCustomLookupFormattingAndExportUseOnePersistedPack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WhitegramLocalizationStore(fileURL: directory.appendingPathComponent("wg_localization.json"), defaults: defaults)
        try store.apply(WhitegramLocalizationPack(name: "My translation", author: "Translator", languageCode: "uk", entries: [
            "section.camera": "📷 Custom camera", "test.format": "%10 / %1 / %2 / %99"
        ]))
        XCTAssertEqual(WhitegramLocalization.string("section.camera", baseLanguage: "en", store: store), "📷 Custom camera")
        XCTAssertEqual(WhitegramLocalization.string("missing.key", fallback: "Fallback", store: store), "Fallback")
        XCTAssertEqual(WhitegramLocalization.format("test.format", ["first", "%1", "3", "4", "5", "6", "7", "8", "9", "tenth"], store: store), "tenth / first / %1 / %99")
        let exported = try WhitegramLocalization.exportPack(baseLanguage: "en", store: store)
        XCTAssertEqual(exported.entries.count, 1597)
        XCTAssertEqual(exported.entries["section.camera"], "📷 Custom camera")
        XCTAssertEqual(exported.name, "My translation")
        XCTAssertEqual(exported.author, "Translator")
        XCTAssertEqual(exported.languageCode, "uk")
    }

    func testInvalidStoredPackCannotBeExportedAsSuccessfulCustomTranslation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = directory.appendingPathComponent("wg_localization.json")
        try Data("broken json".utf8).write(to: url)
        let store = WhitegramLocalizationStore(fileURL: url, defaults: defaults)
        XCTAssertThrowsError(try WhitegramLocalization.exportPack(baseLanguage: "en", store: store))
        try store.remove()
        XCTAssertEqual(try WhitegramLocalization.exportPack(baseLanguage: "en", store: store).entries.count, 1597)
    }

    func testGeneratedControlsUseOriginalDefaultsAndCanonicalAliases() {
        let defaults = UserDefaults.standard
        let keys = [WhitegramPreferences.storageKey, "WhitegramPrivacySettings.v1", "wg_musicCrossfadeEnabled", "wg_bypassContentRestrictions", "wg_readOnAction"]
        var saved: [String: Any] = [:]
        for key in keys {
            saved[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
        defer { for key in keys { defaults.set(saved[key], forKey: key) } }
        XCTAssertEqual(WhitegramPortCapabilities.booleanValue("crossfadeEnabled"), true)
        XCTAssertEqual(WhitegramPortCapabilities.booleanValue("bypassContentRestrictions"), true)
        XCTAssertEqual(WhitegramPortCapabilities.booleanValue("readOnAction"), false)
        XCTAssertTrue(WhitegramPreferences.set(false, for: "musicCrossfadeEnabled"))
        XCTAssertEqual(WhitegramPortCapabilities.booleanValue("crossfadeEnabled"), false)
        defaults.set(false, forKey: "wg_bypassContentRestrictions")
        XCTAssertEqual(WhitegramPortCapabilities.booleanValue("bypassContentRestrictions"), false)
        XCTAssertTrue(WhitegramPreferences.set(1, for: "readOnAction"))
        XCTAssertEqual(WhitegramPortCapabilities.booleanValue("readOnAction"), false)
        XCTAssertNil(WhitegramPortCapabilities.booleanValue("not.a.control"))
    }
}
