import Foundation
import CoreFoundation

/// Values used by appearance consumers, independently of the public-fork settings.
public struct WhitegramAppearancePolicy: Equatable {
    public static let stickerPercentRange: ClosedRange<Double> = 10.0 ... 200.0
    public static let tabPercentRange: ClosedRange<Double> = 50.0 ... 150.0
    public static let tabHeightInputRange: ClosedRange<Double> = 50.0 ... 100.0

    public static let visibilityKeys: [String] = [
        "hideFavorites", "hideDevices", "hideFolders", "hideEnergySaving", "hideLanguage",
        "hideNotifications", "hidePrivacy", "hideDataAndStorage", "hideAppearance", "hideProxy",
        "hideMyProfile", "hideRecentCalls", "hidePremium", "hideStars", "hideWallet", "hideCryptoBot",
        "hideBusiness", "hideSendGift", "hideSupport", "hideFAQ", "hideTips", "hideAccountRating",
        "hideSettingsAddAccount", "hideSettingsEmojiStatus", "hideSettingsProfileColor",
        "hideSettingsSetPhoto", "hideSettingsReorderAccounts", "hidePhoneNumber", "showPeerIDAndDC",
        "showChatCreationDate", "hideReactions", "hideAllChatsTab", "hideSponsoredProxyChannel",
        "squareAvatars", "showFullViewCount", "showTimestampSeconds", "showOnlineDotInChats",
        "classicInterface", "liquidGlassBubbles", "glassMessageBubbles", "liquidGlassSettings",
        "liquidGlassProfile", "liquidGlassGifts", "liquidGlassInlineButtons", "glassTinting",
        "fakeLiquidGlass", "colorInsteadOfGlass", "lightChatUI"
    ]

    private let flags: [String: Bool]
    public let stickerScale: Double
    public let tabHeightPercent: Double
    public let tabWidthPercent: Double
    public let customFontName: String
    public let customFontEnabled: Bool
    public let assetRevision: String

    public init(values: [String: Any], legacyDefaults: UserDefaults? = nil) {
        func value(_ key: String) -> Any? {
            return values[key] ?? legacyDefaults?.object(forKey: "wg_" + key)
        }
        self.flags = Dictionary(uniqueKeysWithValues: Self.visibilityKeys.map { ($0, Self.boolean(value($0))) })
        let scale = Self.number(value("stickerSizeScale"), default: 1.0)
        // The original getter treats zero as unset, not as a request to hide stickers.
        self.stickerScale = scale == 0.0 ? 1.0 : min(2.0, max(0.1, scale))
        let width = Self.number(value("tabBarWidthScale"), default: 100.0)
        self.tabWidthPercent = width <= 0.0 ? 100.0 : min(150.0, max(50.0, width))
        let height = Self.number(value("tabBarScale"), default: 100.0)
        self.tabHeightPercent = height <= 0.0 ? 100.0 : min(150.0, max(50.0, height))
        self.customFontName = value("customFontName") as? String ?? ""
        self.customFontEnabled = Self.boolean(value("customFontEnabled"))
        let packId = (value("activeIconPackId") as? String) ?? ""
        let revision = (value("appearanceAssetRevision") as? String) ?? ""
        self.assetRevision = packId + ":" + revision
    }

    public static var current: WhitegramAppearancePolicy {
        return WhitegramAppearancePolicy(values: WhitegramPreferences.values(), legacyDefaults: .standard)
    }

    public func isEnabled(_ key: String) -> Bool {
        return self.flags[key] ?? false
    }

    public static func parseStickerPercent(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text), Self.stickerPercentRange.contains(Double(value)) else { return nil }
        return Double(value) / 100.0
    }

    public static func parseTabHeightPercent(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text) else { return nil }
        guard value.isFinite, Self.tabHeightInputRange.contains(value) else { return nil }
        return value
    }

    public static func bubbleFillOpacity(transparent: Bool, semiTransparent: Bool) -> Double {
        if transparent { return 0.0 }
        return semiTransparent ? 0.7 : 1.0
    }

    public static func messageStatus(enabled: Bool, dateText: String, text: String, russian: Bool) -> String {
        guard enabled, !text.isEmpty else { return dateText }
        let count = String(text.count) + (russian ? " симв." : " chars")
        return dateText.isEmpty ? count : count + " · " + dateText
    }

    public static func inputCounter(enabled: Bool, text: String, limit: Int32?) -> (text: String, isOverLimit: Bool) {
        let count = text.count
        if let limit {
            let remaining = max(-999, Int(limit) - count)
            if remaining < 5 { return (String(remaining), count > Int(limit)) }
        }
        guard enabled, !text.isEmpty else { return ("", false) }
        if let limit { return ("\(count) / \(limit)", false) }
        return (String(count), false)
    }

    public static func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }

    public static func number(_ value: Any?, default defaultValue: Double) -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return defaultValue }
        return number.doubleValue
    }
}
