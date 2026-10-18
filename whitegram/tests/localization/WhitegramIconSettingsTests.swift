import Foundation
import CoreFoundation
import XCTest
@testable import TelegramCore
@testable import SettingsUI

final class WhitegramIconSettingsTests: XCTestCase {
    func testDefaultsAndJSONTypes() throws {
        XCTAssertEqual(WhitegramIconSettings(values: [:]), WhitegramIconSettings(values: ["customSettingsIcons": false, "showOriginalTelegramIcons": false]))
        for (literal, enabled) in [("true", true), ("false", false), ("1", false), ("0", false), ("1.0", false), ("\"true\"", false), ("null", false)] {
            let data = Data("{\"customSettingsIcons\":\(literal),\"showOriginalTelegramIcons\":\(literal)}".utf8)
            let settings = WhitegramIconSettings(values: try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
            XCTAssertEqual(settings.customSettingsIcons, enabled, literal)
            XCTAssertEqual(settings.showOriginalTelegramIcons, enabled, literal)
        }
    }

    func testLegacyFallbackAndCanonicalFalsePrecedence() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in ["customSettingsIcons", "showOriginalTelegramIcons"] { defaults.set(true, forKey: "wg_" + key) }
        XCTAssertTrue(WhitegramIconSettings(values: [:], legacyDefaults: defaults).customSettingsIcons)
        XCTAssertTrue(WhitegramIconSettings(values: [:], legacyDefaults: defaults).showOriginalTelegramIcons)
        let invalid: [Any] = [false, 1, "true", NSNull()]
        for value in invalid {
            let settings = WhitegramIconSettings(values: ["customSettingsIcons": value, "showOriginalTelegramIcons": value], legacyDefaults: defaults)
            XCTAssertFalse(settings.customSettingsIcons)
            XCTAssertFalse(settings.showOriginalTelegramIcons)
        }
        // CFPreferences may retain an existing Bool when an equal NSNumber is set.
        defaults.removeObject(forKey: "wg_customSettingsIcons")
        defaults.set(1, forKey: "wg_customSettingsIcons")
        let number = try XCTUnwrap(defaults.object(forKey: "wg_customSettingsIcons") as? NSNumber)
        XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID())
        defaults.set("true", forKey: "wg_showOriginalTelegramIcons")
        XCTAssertEqual(WhitegramIconSettings(values: [:], legacyDefaults: defaults), WhitegramIconSettings(values: [:]))
    }

    func testPersistenceCapabilitiesAndAppearanceInvalidationAgree() {
        let defaults = UserDefaults.standard
        let keys = [WhitegramPreferences.storageKey, "WhitegramPrivacySettings.v1", "wg_customSettingsIcons", "wg_showOriginalTelegramIcons"]
        var saved: [String: Any] = [:]
        for key in keys { saved[key] = defaults.object(forKey: key); defaults.removeObject(forKey: key) }
        defer { for key in keys { defaults.set(saved[key], forKey: key) } }
        let initialAppearance = WhitegramAppearancePolicy.current
        for enabled in [true, false] {
            for key in ["customSettingsIcons", "showOriginalTelegramIcons"] {
                XCTAssertTrue(WhitegramPreferences.set(enabled, for: key))
                XCTAssertEqual(WhitegramPortCapabilities.booleanValue(key), enabled)
                XCTAssertEqual(defaults.object(forKey: "wg_" + key) as? Bool, enabled)
            }
            XCTAssertEqual(WhitegramIconSettings.current.customSettingsIcons, enabled)
            XCTAssertEqual(WhitegramIconSettings.current.showOriginalTelegramIcons, enabled)
            XCTAssertEqual(WhitegramAppearancePolicy.current == initialAppearance, !enabled)
        }
    }

    func testOriginalPickerOrderAndPreviewBindings() {
        XCTAssertEqual(WhitegramIconSettings.stockIcons.map { $0.name }, ["Blue", "New2", "New1", "Black", "BlueClassic", "BlackClassic", "BlueFilled", "BlackFilled"])
        XCTAssertEqual(WhitegramIconSettings.stockIcons.map { $0.imageName }, ["BlueIcon", "New2", "New1", "BlackIcon", "BlueClassicIcon", "BlackClassicIcon", "BlueFilledIcon", "BlackFilledIcon"])
    }
}
