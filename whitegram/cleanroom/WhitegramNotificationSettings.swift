import CoreFoundation
import Foundation

public struct WhitegramNotificationSettings: Equatable {
    public let enabled: Bool
    public let persistent: Bool
    public let backgroundKeepAlive: Bool

    public init(values: [String: Any], legacyValues: [String: Any] = [:]) {
        func boolean(_ key: String, default fallback: Bool = false) -> Bool {
            guard let value = (values[key] ?? legacyValues["wg_" + key]) as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else { return fallback }
            return value.boolValue
        }
        self.enabled = boolean("whitegramNotificationsEnabled")
        self.persistent = boolean("persistentNotificationsEnabled")
        self.backgroundKeepAlive = boolean("backgroundKeepAlive", default: true)
    }

    public static var current: Self {
        var legacy: [String: Any] = [:]
        for key in ["whitegramNotificationsEnabled", "persistentNotificationsEnabled", "backgroundKeepAlive"] {
            legacy["wg_" + key] = UserDefaults.standard.object(forKey: "wg_" + key)
        }
        return Self(values: WhitegramPreferences.values(), legacyValues: legacy)
    }

    public func keepAlive(isInBackground: Bool) -> Bool {
        return self.enabled && self.backgroundKeepAlive && isInBackground
    }

    public func shouldNotify(isActive: Bool, notify: Bool, incoming: Bool, selfChat: Bool, wasScheduled: Bool, muted: Bool, restricted: Bool) -> Bool {
        return self.enabled && !isActive && notify && incoming && (!selfChat || wasScheduled) && !muted && !restricted
    }
}

public enum WhitegramNotificationPreview: Equatable {
    case hidden
    case senderOnly
    case full

    public static func resolve(isLocked: Bool, displayPreviews: Bool, displayName: Bool) -> Self {
        guard displayName else { return .hidden }
        return !isLocked && displayPreviews ? .full : .senderOnly
    }
}

public enum WhitegramNotificationText {
    public static func subtitle(baseLanguage: String, replyToMe: Bool, mentioned: Bool) -> String? {
        if replyToMe { return baseLanguage == "ru" ? "↩︎ Ответ на ваше сообщение" : "↩︎ Replied to your message" }
        if mentioned { return baseLanguage == "ru" ? "@ Упоминание" : "@ Mentioned you" }
        return nil
    }

    public static func emojiPresentation(_ text: String, hasCustomEmoji: Bool) -> String {
        guard hasCustomEmoji else { return text }
        var result = ""
        result.reserveCapacity(text.count + 4)
        for character in text {
            result.append(character)
            if character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
               scalar.properties.isEmoji && !scalar.properties.isEmojiPresentation {
                result.append("\u{FE0F}")
            }
        }
        return result
    }

    public static func redactingSpoilers(_ text: String, ranges: [Range<Int>]) -> String {
        let result = NSMutableString(string: text)
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = max(0, range.lowerBound)
            let upper = min(result.length, range.upperBound)
            guard lower < upper else { continue }
            if let last = merged.last, lower <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, upper)
            } else {
                merged.append(lower ..< upper)
            }
        }
        for range in merged.reversed() {
            result.replaceCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: "•••")
        }
        return result as String
    }
}
