import Foundation

public struct WhitegramPrivacySettings: Codable, Equatable {
    public var ghostModeEnabled: Bool
    public var disableReadReceipts: Bool
    public var disableTypingStatus: Bool
    public var disableOnlineStatus: Bool
    public var hidePhoneNumber: Bool
    public var hideAvatarInGroups: Bool
    public var saveDeletedMessages: Bool
    public var antiCensorshipEnabled: Bool

    public static let storageKey = "WhitegramPrivacySettings.v1"
    public static let updatedNotification = Notification.Name("WhitegramPrivacySettingsUpdated")

    public init(
        ghostModeEnabled: Bool = false,
        disableReadReceipts: Bool = false,
        disableTypingStatus: Bool = false,
        disableOnlineStatus: Bool = false,
        hidePhoneNumber: Bool = false,
        hideAvatarInGroups: Bool = false,
        saveDeletedMessages: Bool = false,
        antiCensorshipEnabled: Bool = false
    ) {
        self.ghostModeEnabled = ghostModeEnabled
        self.disableReadReceipts = disableReadReceipts
        self.disableTypingStatus = disableTypingStatus
        self.disableOnlineStatus = disableOnlineStatus
        self.hidePhoneNumber = hidePhoneNumber
        self.hideAvatarInGroups = hideAvatarInGroups
        self.saveDeletedMessages = saveDeletedMessages
        self.antiCensorshipEnabled = antiCensorshipEnabled
    }

    public static var current: WhitegramPrivacySettings {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let value = try? JSONDecoder().decode(WhitegramPrivacySettings.self, from: data) {
            return value
        }
        return WhitegramPrivacySettings()
    }

    public var shouldSendReadReceipts: Bool {
        return !ghostModeEnabled && !disableReadReceipts
    }

    public var shouldSendTypingStatus: Bool {
        return !ghostModeEnabled && !disableTypingStatus
    }

    public var shouldSendOnlineStatus: Bool {
        return !ghostModeEnabled && !disableOnlineStatus
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        NotificationCenter.default.post(name: Self.updatedNotification, object: nil)
    }
}
