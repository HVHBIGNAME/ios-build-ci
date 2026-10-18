import Foundation
import XCTest
@testable import TelegramCore

final class WhitegramTextSettingsTests: XCTestCase {
    func testRecoveredMixedScriptDictionaryAndUppercaseExceptions() {
        XCTAssertEqual(WhitegramTextSettings.applyMixedScript("Заказать", uppercase: false), "Zаkаzаtь")
        XCTAssertEqual(WhitegramTextSettings.applyMixedScript("Заказать", uppercase: true), "ZАКАZАТЬ")
        XCTAssertEqual(WhitegramTextSettings.applyMixedScript("КМТ ВДЗЛНРСФ", uppercase: false), "КМТ VDZLNRSF")
        XCTAssertEqual(WhitegramTextSettings.applyMixedScript("вдзклмнрстф", uppercase: false), "vdzklmnrstf")
    }

    func testUppercaseNeverExpandsEntitiesOrSplitsGraphemes() {
        let source = "ß ﬃ ı е\u{301} 👩🏽‍💻 🇺🇦 https://t.me/name"
        let result = WhitegramTextSettings.applyMixedScript(source, uppercase: true)
        XCTAssertEqual(result, "ß ﬃ I Е\u{301} 👩🏽‍💻 🇺🇦 HTTPS://T.ME/NAME")
        XCTAssertEqual(result.utf16.count, source.utf16.count)
        XCTAssertEqual(result.count, source.count)
    }

    func testZalgoUsesOnlyTheFourRecoveredRanges() {
        let settings = WhitegramTextSettings(values: ["zalgoFilterEnabled": true])
        let removed = "\u{300}\u{36f}\u{1ab0}\u{1aff}\u{1dc0}\u{1dff}\u{fe20}\u{fe2f}"
        let preserved = "\u{2ff}\u{370}\u{1aaf}\u{1b00}\u{1dbf}\u{1e00}\u{fe1f}\u{fe30}ُ⃝️😀"
        XCTAssertEqual(settings.stripZalgo("A" + removed + preserved), "A" + preserved)
        XCTAssertEqual(WhitegramTextSettings(values: [:]).stripZalgo(removed), removed)
    }

    func testUTF16RangesFollowFilteringAndRejectSplitSurrogates() {
        let filtered = WhitegramFilteredText("A\u{301}😀B")
        XCTAssertEqual(filtered.text, "A😀B")
        XCTAssertEqual(filtered.mapRange(2..<4), 1..<3)
        XCTAssertEqual(filtered.mapRange(4..<5), 3..<4)
        XCTAssertEqual(filtered.mapRange(0..<5), 0..<4)
        XCTAssertNil(filtered.mapRange(1..<2))
        XCTAssertNil(filtered.mapRange(3..<4))
        XCTAssertNil(filtered.mapRange(0..<6))
        XCTAssertNil(filtered.mapRange(-1..<2))
    }

    func testAttributedFilteringPreservesLinkDestinationAndInput() {
        let key = NSAttributedString.Key("fixtureLink")
        let source = NSMutableAttributedString(string: "A\u{301}😀B")
        source.addAttribute(key, value: "https://example.invalid/unchanged", range: NSRange(location: 2, length: 3))
        let result = WhitegramTextSettings(values: ["zalgoFilterEnabled": true]).stripZalgo(source)
        XCTAssertEqual(result.string, "A😀B")
        XCTAssertEqual(source.string, "A\u{301}😀B")
        var range = NSRange()
        XCTAssertEqual(result.attribute(key, at: 1, effectiveRange: &range) as? String, "https://example.invalid/unchanged")
        XCTAssertEqual(range, NSRange(location: 1, length: 3))
    }

    func testPickerChangesAreAtomicAndClearPreviousModes() throws {
        for selection in 0...7 {
            let changes = try XCTUnwrap(WhitegramTextSettings.selectionChanges(selection))
            let settings = WhitegramTextSettings(values: changes)
            XCTAssertEqual(settings.selection, selection)
            XCTAssertEqual(settings.style.rawValue, selection > 5 ? 0 : selection)
            XCTAssertEqual(settings.mixedScript, selection > 5)
            XCTAssertEqual(settings.uppercase, selection == 7)
        }
        XCTAssertNil(WhitegramTextSettings.selectionChanges(-1))
        XCTAssertNil(WhitegramTextSettings.selectionChanges(8))
    }

    func testStoredSettingsPrecedeLegacyAndInvalidBooleansStayDisabled() throws {
        let suite = "WhitegramTextSettingsTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "wg_zalgoFilterEnabled")
        defaults.set(3, forKey: "wg_autoFormatStyle")
        XCTAssertTrue(WhitegramTextSettings(values: [:], legacyDefaults: defaults).zalgoFilter)
        let settings = WhitegramTextSettings(values: ["zalgoFilterEnabled": false, "autoFormatMixedScript": 1], legacyDefaults: defaults)
        XCTAssertFalse(settings.zalgoFilter)
        XCTAssertFalse(settings.mixedScript)
        XCTAssertEqual(settings.style, .monospace)
        XCTAssertEqual(WhitegramTextSettings(values: ["autoFormatStyle": 9]).style, .bold)
        XCTAssertEqual(WhitegramTextSettings(values: ["autoFormatStyle": -1]).style, .off)
    }

    func testHardwareReturnRespectsPlainShiftAndCommandModes() {
        let cases: [(sendOnReturn: Bool, commandMode: Bool, plain: Bool, command: Bool)] = [
            (false, false, false, false), (false, true, false, true),
            (true, false, true, false), (true, true, true, true)
        ]
        for test in cases {
            let settings = WhitegramTextSettings(values: ["sendOnReturnKey": test.sendOnReturn])
            XCTAssertEqual(settings.sendOnHardwareReturn(hasModifiers: false, commandPressed: false, sendWithCommand: test.commandMode), test.plain)
            XCTAssertFalse(settings.sendOnHardwareReturn(hasModifiers: true, commandPressed: false, sendWithCommand: test.commandMode))
            XCTAssertEqual(settings.sendOnHardwareReturn(hasModifiers: true, commandPressed: true, sendWithCommand: test.commandMode), test.command)
        }
    }

    func testSoftwareReturnNeverSendsSelectionReplacementCompositionOrHardwareNewline() {
        let settings = WhitegramTextSettings(values: ["sendOnReturnKey": true])
        XCTAssertTrue(settings.sendOnSoftwareReturn(replacement: "\n", selectionLength: 0, hasMarkedText: false))
        for replacement in ["", "\r", "\r\n", "text\n", "\n\n", "😀"] {
            XCTAssertFalse(settings.sendOnSoftwareReturn(replacement: replacement, selectionLength: 0, hasMarkedText: false))
        }
        XCTAssertFalse(settings.sendOnSoftwareReturn(replacement: "\n", selectionLength: 1, hasMarkedText: false))
        XCTAssertFalse(settings.sendOnSoftwareReturn(replacement: "\n", selectionLength: 0, hasMarkedText: true))
        XCTAssertFalse(settings.sendOnSoftwareReturn(replacement: "\n", selectionLength: 0, hasMarkedText: false, handlingHardwareReturn: true))
        XCTAssertFalse(WhitegramTextSettings(values: [:]).sendOnSoftwareReturn(replacement: "\n", selectionLength: 0, hasMarkedText: false))
    }

    func testReturnSettingRequiresBooleanAndCanonicalFalseOverridesLegacyTrue() throws {
        let suite = "WhitegramReturnTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(WhitegramTextSettings(values: [:], legacyDefaults: defaults).sendOnReturnKey)
        defaults.set(true, forKey: "wg_sendOnReturnKey")
        XCTAssertTrue(WhitegramTextSettings(values: [:], legacyDefaults: defaults).sendOnReturnKey)
        let invalid: [Any] = [false, 1, "true", NSNull()]
        for value in invalid {
            XCTAssertFalse(WhitegramTextSettings(values: ["sendOnReturnKey": value], legacyDefaults: defaults).sendOnReturnKey)
        }
    }

    func testInAppVibrationDefaultsOffAndRequiresCanonicalBoolean() {
        XCTAssertFalse(WhitegramTextSettings(values: [:]).inAppVibrationEnabled)
        XCTAssertTrue(WhitegramTextSettings(values: ["inAppVibrationEnabled": true]).inAppVibrationEnabled)
        XCTAssertFalse(WhitegramTextSettings(values: ["inAppVibrationEnabled": false]).inAppVibrationEnabled)
        XCTAssertFalse(WhitegramTextSettings(values: ["inAppVibration": true]).inAppVibrationEnabled)
        let invalid: [Any] = [0, 1, -1, 1.0, "true", "1", NSNull(), [true], ["enabled": true]]
        for value in invalid {
            XCTAssertFalse(WhitegramTextSettings(values: ["inAppVibrationEnabled": value]).inAppVibrationEnabled, "Accepted \(value)")
        }
    }

    func testInAppVibrationLegacyFallbackIsStrictAndCanonicalValuesTakePrecedence() throws {
        let suite = "WhitegramVibrationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(WhitegramTextSettings(values: [:], legacyDefaults: defaults).inAppVibrationEnabled)
        defaults.set(true, forKey: "wg_inAppVibrationEnabled")
        XCTAssertTrue(WhitegramTextSettings(values: [:], legacyDefaults: defaults).inAppVibrationEnabled)
        let disabled: [Any] = [false, 0, 1, 1.0, "true", NSNull(), [true], ["enabled": true]]
        for value in disabled {
            XCTAssertFalse(WhitegramTextSettings(values: ["inAppVibrationEnabled": value], legacyDefaults: defaults).inAppVibrationEnabled, "Accepted \(value)")
        }
        let invalidLegacy: [Any] = [0, 1, 1.0, "true", "1", [true], ["enabled": true]]
        for value in invalidLegacy {
            defaults.set(value, forKey: "wg_inAppVibrationEnabled")
            XCTAssertFalse(WhitegramTextSettings(values: [:], legacyDefaults: defaults).inAppVibrationEnabled, "Accepted legacy \(value)")
        }
        defaults.set(false, forKey: "wg_inAppVibrationEnabled")
        XCTAssertFalse(WhitegramTextSettings(values: [:], legacyDefaults: defaults).inAppVibrationEnabled)
        XCTAssertTrue(WhitegramTextSettings(values: ["inAppVibrationEnabled": true], legacyDefaults: defaults).inAppVibrationEnabled)
    }

    func testInAppVibrationDecodesJSONBooleansWithoutCoercingNumbers() throws {
        for (literal, expected) in [("true", true), ("false", false), ("1", false), ("0", false), ("1.0", false), ("\"true\"", false), ("null", false)] {
            let data = Data("{\"inAppVibrationEnabled\":\(literal)}".utf8)
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(WhitegramTextSettings(values: values).inAppVibrationEnabled, expected, literal)
        }
    }

    func testInAppVibrationCurrentReloadsLegacyAndPersistsCanonicalAndMirror() {
        struct SiblingSettings: Codable { let fixtureSibling: Bool }
        self.withClearedPreferences {
            XCTAssertFalse(WhitegramTextSettings.current.inAppVibrationEnabled)
            UserDefaults.standard.set(true, forKey: "wg_inAppVibrationEnabled")
            XCTAssertTrue(WhitegramTextSettings.current.inAppVibrationEnabled)
            UserDefaults.standard.set(false, forKey: "wg_inAppVibrationEnabled")
            XCTAssertFalse(WhitegramTextSettings.current.inAppVibrationEnabled)
            XCTAssertTrue(WhitegramPreferences.set(true, for: "inAppVibrationEnabled"))
            XCTAssertTrue(WhitegramTextSettings.current.inAppVibrationEnabled)
            XCTAssertEqual(UserDefaults.standard.object(forKey: "wg_inAppVibrationEnabled") as? Bool, true)
            UserDefaults.standard.set(false, forKey: "wg_inAppVibrationEnabled")
            XCTAssertTrue(WhitegramTextSettings.current.inAppVibrationEnabled)
            XCTAssertTrue(WhitegramPreferences.save(SiblingSettings(fixtureSibling: true)))
            XCTAssertTrue(WhitegramTextSettings.current.inAppVibrationEnabled)
            XCTAssertTrue(WhitegramPreferences.set(false, for: "inAppVibrationEnabled"))
            XCTAssertFalse(WhitegramTextSettings.current.inAppVibrationEnabled)
            XCTAssertEqual(UserDefaults.standard.object(forKey: "wg_inAppVibrationEnabled") as? Bool, false)
            UserDefaults.standard.set(true, forKey: "wg_inAppVibrationEnabled")
            XCTAssertFalse(WhitegramTextSettings.current.inAppVibrationEnabled)
        }
    }

    func testFormattingComplementsMergeOverlapsAndExpandGraphemeExclusions() {
        XCTAssertEqual(WhitegramTextSettings.formattingRanges(in: "0123456789", excluding: [6..<8, 2..<5, 4..<7]), [0..<2, 8..<10])
        XCTAssertEqual(WhitegramTextSettings.formattingRanges(in: "A😀Bе\u{301}C", excluding: [2..<3, 5..<6]), [0..<1, 3..<4, 6..<7])
        XCTAssertEqual(WhitegramTextSettings.formattingRanges(in: "0123456789", excluding: [-1..<3, 0..<100, 4..<4]), [0..<10])
        XCTAssertEqual(WhitegramTextSettings.formattingRanges(in: "0123456789", excluding: [0..<2, 8..<10]), [2..<8])
        XCTAssertEqual(WhitegramTextSettings.formattingRanges(in: "abc", excluding: [0..<3]), [])
        XCTAssertEqual(WhitegramTextSettings.formattingRanges(in: "", excluding: []), [])
    }

    func testMixedScriptKeepsProtectedDestinationsAndWholeGraphemes() {
        let text = "Заказать https://t.me/Заказ @Заказ 😀"
        let ranges = ["https://t.me/Заказ", "@Заказ"].map { part -> Range<Int> in
            let range = (text as NSString).range(of: part)
            return range.location..<(range.location + range.length)
        }
        let settings = WhitegramTextSettings(values: ["autoFormatMixedScript": true, "autoFormatMixedScriptUppercase": true])
        let result = settings.outgoingText(text, preserving: ranges)
        XCTAssertEqual(result, "ZАКАZАТЬ https://t.me/Заказ @Заказ 😀")
        XCTAssertEqual(result.utf16.count, text.utf16.count)
        XCTAssertEqual(WhitegramTextSettings.applyMixedScript("в е\u{301} р", uppercase: true, preserving: [3..<4]), "V е\u{301} R")
    }

    func testReturnSettingSurvivesCanonicalRoundTripAndUnrelatedTypedSave() {
        struct SiblingSettings: Codable { let fixtureSibling: Bool }
        self.withClearedPreferences {
            XCTAssertTrue(WhitegramPreferences.set(true, for: "sendOnReturnKey"))
            XCTAssertTrue(WhitegramTextSettings.current.sendOnReturnKey)
            XCTAssertEqual(UserDefaults.standard.object(forKey: "wg_sendOnReturnKey") as? Bool, true)
            XCTAssertTrue(WhitegramPreferences.save(SiblingSettings(fixtureSibling: true)))
            XCTAssertTrue(WhitegramTextSettings.current.sendOnReturnKey)
            XCTAssertTrue(WhitegramPreferences.set(false, for: "sendOnReturnKey"))
            XCTAssertFalse(WhitegramTextSettings.current.sendOnReturnKey)
        }
    }

    func testComposerLabelsFollowLanguageAndCustomPackOverrides() throws {
        try self.withClearedPreferences {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = WhitegramLocalizationStore(fileURL: directory.appendingPathComponent("wg_localization.json"), defaults: defaults)
            XCTAssertEqual(WhitegramComposerStrings.string("composer.undo", baseLanguage: "ru-RU", store: store), "Отменить")
            XCTAssertEqual(WhitegramComposerStrings.string("composer.undo", baseLanguage: "uk-UA", store: store), "Скасувати")
            XCTAssertEqual(WhitegramComposerStrings.string("composer.undo", baseLanguage: "de", store: store), "Undo")
            try store.apply(WhitegramLocalizationPack(name: "Custom", author: "", languageCode: "en", entries: ["composer.undo": "Custom undo"]))
            XCTAssertEqual(WhitegramComposerStrings.string("composer.undo", baseLanguage: "ru", store: store), "Custom undo")
            XCTAssertTrue(WhitegramPreferences.set("uk", for: "menuLanguageCode"))
            XCTAssertEqual(WhitegramComposerStrings.string("composer.sendOnReturn", baseLanguage: "en", store: store), "Надсилати клавішею Enter")
        }
    }

    private func withClearedPreferences(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [WhitegramPreferences.storageKey, "WhitegramPrivacySettings.v1", "wg_sendOnReturnKey", "wg_inAppVibrationEnabled", "wg_menuLanguageCode", "wg_fixtureSibling"]
        var saved: [String: Any] = [:]
        for key in keys {
            saved[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
        defer { for key in keys { defaults.set(saved[key], forKey: key) } }
        try body()
    }
}
