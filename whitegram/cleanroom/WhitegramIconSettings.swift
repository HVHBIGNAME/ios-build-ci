import Foundation
import CoreFoundation

public struct WhitegramIconSettings: Equatable {
    public let showOriginalTelegramIcons: Bool
    public let customSettingsIcons: Bool

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        func flag(_ key: String) -> Bool {
            guard let number = (values[key] ?? legacyDefaults?.object(forKey: "wg_" + key)) as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
        self.showOriginalTelegramIcons = flag("showOriginalTelegramIcons")
        self.customSettingsIcons = flag("customSettingsIcons")
    }

    public static var current: Self {
        return Self(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    // Original TelegramUI alternate-icon getter: 0x3ee70.
    public static let stockIcons: [(name: String, imageName: String)] = [
        ("Blue", "BlueIcon"), ("New2", "New2"), ("New1", "New1"), ("Black", "BlackIcon"),
        ("BlueClassic", "BlueClassicIcon"), ("BlackClassic", "BlackClassicIcon"),
        ("BlueFilled", "BlueFilledIcon"), ("BlackFilled", "BlackFilledIcon")
    ]
}
