import CoreFoundation
import Foundation

public struct WhitegramStickerSettings: Equatable {
    public let unlimitedRecent: Bool
    public let unlimitedFavorites: Bool

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        func enabled(_ key: String) -> Bool {
            guard let number = (values[key] ?? legacyDefaults?.object(forKey: "wg_" + key)) as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
        self.unlimitedRecent = enabled("unlimitedRecentStickers")
        self.unlimitedFavorites = enabled("unlimitedFavoriteStickers")
    }

    public static var current: WhitegramStickerSettings {
        return WhitegramStickerSettings(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    // Original Core 0x470618 and 0x4fb4e8: these switches use finite local limits.
    public var recentLimit: Int { return self.unlimitedRecent ? 999 : 20 }
    public func favoriteLimit(default value: Int) -> Int { return self.unlimitedFavorites ? 9999 : value }
}
