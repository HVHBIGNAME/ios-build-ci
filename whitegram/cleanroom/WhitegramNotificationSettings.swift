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
