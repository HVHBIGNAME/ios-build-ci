import Foundation
import XCTest
import TelegramCore
@testable import SettingsUI

final class WhitegramPreferencesTests: XCTestCase {
    private var original: Data?
    private var legacy: Data?

    override func setUp() {
        self.original = UserDefaults.standard.data(forKey: WhitegramPreferences.storageKey)
        self.legacy = UserDefaults.standard.data(forKey: "WhitegramPrivacySettings.v1")
        UserDefaults.standard.removeObject(forKey: WhitegramPreferences.storageKey)
        UserDefaults.standard.removeObject(forKey: "WhitegramPrivacySettings.v1")
        _ = WhitegramPreferences.values()
    }

    override func tearDown() {
        UserDefaults.standard.set(self.original, forKey: WhitegramPreferences.storageKey)
        UserDefaults.standard.set(self.legacy, forKey: "WhitegramPrivacySettings.v1")
        for key in ["ghostModeEnabled", "disableReadReceipts", "customFontName", "customFontEnabled", "showDeletedMessages", "number", "bad"] {
            UserDefaults.standard.removeObject(forKey: "wg_" + key)
        }
    }

    func testSwitchChangesAreVisibleWithoutRestart() {
        XCTAssertFalse(WhitegramPreferences.bool("ghostModeEnabled"))
        XCTAssertTrue(WhitegramPreferences.set(true, for: "ghostModeEnabled"))
        XCTAssertTrue(WhitegramPreferences.bool("ghostModeEnabled"))
        XCTAssertTrue(WhitegramPreferences.set(false, for: "ghostModeEnabled"))
        XCTAssertFalse(WhitegramPreferences.bool("ghostModeEnabled"))
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "wg_ghostModeEnabled"))
    }

    func testExternalDefaultsChangeInvalidatesSnapshot() throws {
        XCTAssertTrue(WhitegramPreferences.set(false, for: "disableReadReceipts"))
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: ["disableReadReceipts": true]), forKey: WhitegramPreferences.storageKey)
        XCTAssertTrue(WhitegramPreferences.bool("disableReadReceipts"))
    }

    func testPartialSchemaAndInvalidFieldDoNotErasePrivacyFlags() throws {
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: ["ghostModeEnabled": true, "particleMode": 1.5, "fontHistory": true]), forKey: WhitegramPreferences.storageKey)
        let value = WhitegramSettingsState.current
        XCTAssertTrue(value.ghostModeEnabled)
        XCTAssertEqual(value.particleMode, 0)
        XCTAssertEqual(value.fontHistory, [])
        XCTAssertEqual(value.stickerSizeScale, 1.0)
    }

    func testOptionalStringsAndFontHistorySurviveMigration() {
        XCTAssertTrue(WhitegramPreferences.update(["translationTargetLang": "ru", "fontHistory": [["name": "Example"]]]))
        let value = WhitegramSettingsState.current
        XCTAssertEqual(value.translationTargetLang, "ru")
        XCTAssertEqual(value.fontHistory, [["name": "Example"]])
    }

    func testLegacyAliasNeverOverridesExplicitNewValue() throws {
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: ["saveDeletedMessages": true]), forKey: "WhitegramPrivacySettings.v1")
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: ["showDeletedMessages": false]), forKey: WhitegramPreferences.storageKey)
        XCTAssertFalse(WhitegramPreferences.bool("showDeletedMessages"))
    }

    func testInvalidNumbersAndBooleanCoercionAreRejected() {
        XCTAssertTrue(WhitegramPreferences.set(1, for: "number"))
        XCTAssertFalse(WhitegramPreferences.bool("number"))
        XCTAssertEqual(WhitegramPreferences.number("number"), 1)
        XCTAssertFalse(WhitegramPreferences.set(Double.nan, for: "bad"))
        XCTAssertNil(WhitegramPreferences.values()["bad"])
    }
}
