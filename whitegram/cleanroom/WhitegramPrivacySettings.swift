import Foundation
import TelegramCore

public struct WhitegramPrivacySettings: Codable, Equatable {
    public var ghostModeEnabled: Bool
    public var disableReadReceipts: Bool
    public var disableTypingStatus: Bool
    public var disableOnlineStatus: Bool
    public var alwaysOnline: Bool
    public var disableRecordingStatus: Bool
    public var disableUploadingStatus: Bool
    public var disableStoryReadReceipts: Bool
    public var disableAds: Bool
    public var readOnAction: Bool
    public var saveProtectedContent: Bool
    public var removeSpoilers: Bool
    public var bypassContentRestrictions: Bool
    public var keepBannedChats: Bool
    public var saveViewOnceMedia: Bool
    public var warnBeforeCall: Bool
    public var ghostModeRecordOnce: Bool
    public var hidePhoneNumber: Bool
    public var hideAvatarInGroups: Bool
    public var saveDeletedMessages: Bool
    public var antiCensorshipEnabled: Bool

    public static let storageKey = WhitegramPreferences.storageKey
    public static let updatedNotification = WhitegramPreferences.updatedNotification

    public init(
        ghostModeEnabled: Bool = false,
        disableReadReceipts: Bool = false,
        disableTypingStatus: Bool = false,
        disableOnlineStatus: Bool = false,
        hidePhoneNumber: Bool = false,
        hideAvatarInGroups: Bool = false,
        saveDeletedMessages: Bool = false,
        antiCensorshipEnabled: Bool = false,
        alwaysOnline: Bool = false,
        disableRecordingStatus: Bool = false,
        disableUploadingStatus: Bool = false,
        disableStoryReadReceipts: Bool = false,
        disableAds: Bool = false,
        readOnAction: Bool = false,
        saveProtectedContent: Bool = false,
        removeSpoilers: Bool = false,
        bypassContentRestrictions: Bool = true,
        keepBannedChats: Bool = false,
        saveViewOnceMedia: Bool = false,
        warnBeforeCall: Bool = false,
        ghostModeRecordOnce: Bool = false
    ) {
        self.ghostModeEnabled = ghostModeEnabled
        self.disableReadReceipts = disableReadReceipts
        self.disableTypingStatus = disableTypingStatus
        self.disableOnlineStatus = disableOnlineStatus
        self.hidePhoneNumber = hidePhoneNumber
        self.hideAvatarInGroups = hideAvatarInGroups
        self.saveDeletedMessages = saveDeletedMessages
        self.antiCensorshipEnabled = antiCensorshipEnabled
        self.alwaysOnline = alwaysOnline
        self.disableRecordingStatus = disableRecordingStatus
        self.disableUploadingStatus = disableUploadingStatus
        self.disableStoryReadReceipts = disableStoryReadReceipts
        self.disableAds = disableAds
        self.readOnAction = readOnAction
        self.saveProtectedContent = saveProtectedContent
        self.removeSpoilers = removeSpoilers
        self.bypassContentRestrictions = bypassContentRestrictions
        self.keepBannedChats = keepBannedChats
        self.saveViewOnceMedia = saveViewOnceMedia
        self.warnBeforeCall = warnBeforeCall
        self.ghostModeRecordOnce = ghostModeRecordOnce
    }

    public static var current: WhitegramPrivacySettings {
        var value = WhitegramPreferences.load(defaults: WhitegramPrivacySettings())
        value.ghostModeEnabled = WhitegramContentSettings.bool("ghostModeEnabled")
        value.disableReadReceipts = WhitegramContentSettings.bool("disableReadReceipts")
        value.disableTypingStatus = WhitegramContentSettings.bool("disableTypingStatus")
        value.disableOnlineStatus = WhitegramContentSettings.bool("disableOnlineStatus")
        value.alwaysOnline = WhitegramContentSettings.bool("alwaysOnline")
        value.disableRecordingStatus = WhitegramContentSettings.bool("disableRecordingStatus")
        value.disableUploadingStatus = WhitegramContentSettings.bool("disableUploadingStatus")
        value.disableStoryReadReceipts = WhitegramContentSettings.bool("disableStoryReadReceipts")
        value.disableAds = WhitegramContentSettings.bool("disableAds")
        value.readOnAction = WhitegramContentSettings.readOnAction
        value.saveProtectedContent = WhitegramContentSettings.saveProtectedContent
        value.removeSpoilers = WhitegramContentSettings.removeSpoilers
        value.bypassContentRestrictions = WhitegramContentSettings.bypassContentRestrictions
        value.keepBannedChats = WhitegramContentSettings.keepBannedChats
        value.saveViewOnceMedia = WhitegramContentSettings.saveViewOnceMedia
        value.warnBeforeCall = WhitegramContentSettings.warnBeforeCall
        value.ghostModeRecordOnce = WhitegramContentSettings.bool("ghostModeRecordOnce")
        return value
    }

    public var shouldSendReadReceipts: Bool {
        return !ghostModeEnabled && !disableReadReceipts && !readOnAction
    }

    public var shouldSendTypingStatus: Bool {
        return !ghostModeEnabled && !disableTypingStatus
    }

    public var shouldSendOnlineStatus: Bool {
        return !ghostModeEnabled && !disableOnlineStatus
    }

    public func save() {
        WhitegramPreferences.save(self)
    }
}
