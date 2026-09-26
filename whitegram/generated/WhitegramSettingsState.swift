import Foundation

/// Generated from the audited `WhitegramSettingsState` metadata.
public struct WhitegramSettingsState: Codable, Equatable {
    public var previewRevision: Bool = false
    public var showDeletedMessages: Bool = false
    public var showEditedOriginalText: Bool = false
    public var messageShortenEnabled: Bool = false
    public var saveChatHistory: Bool = false
    public var saveDeletedMessagesToBackup: Bool = false
    public var squareAvatars: Bool = false
    public var compactChatList: Bool = false
    public var newChatListUI: Bool = false
    public var newChatHeaderStyle: Bool = false
    public var lightChatUI: Bool = false
    public var classicInterface: Bool = false
    public var oledMode: Bool = false
    public var reactionButtonGlow: Bool = false
    public var stickerSizeScale: Double = 0.0
    public var showOriginalTelegramIcons: Bool = false
    public var customSettingsIcons: Bool = false
    public var videoMessageCamera: Int = 0
    public var hideFavorites: Bool = false
    public var hideDevices: Bool = false
    public var hideFolders: Bool = false
    public var hideEnergySaving: Bool = false
    public var hideLanguage: Bool = false
    public var hideNotifications: Bool = false
    public var hidePrivacy: Bool = false
    public var hideDataAndStorage: Bool = false
    public var hideAppearance: Bool = false
    public var hideProxy: Bool = false
    public var hideMyProfile: Bool = false
    public var hideRecentCalls: Bool = false
    public var hidePremium: Bool = false
    public var hideStars: Bool = false
    public var hideWallet: Bool = false
    public var hideCryptoBot: Bool = false
    public var hideBusiness: Bool = false
    public var hideSendGift: Bool = false
    public var hideSupport: Bool = false
    public var hideFAQ: Bool = false
    public var hideTips: Bool = false
    public var hideSponsoredProxyChannel: Bool = false
    public var hideSettingsAddAccount: Bool = false
    public var hideSettingsEmojiStatus: Bool = false
    public var hideSettingsProfileColor: Bool = false
    public var hideSettingsSetPhoto: Bool = false
    public var hideSettingsReorderAccounts: Bool = false
    public var showPeerIDAndDC: Bool = false
    public var showTimestampSeconds: Bool = false
    public var showFullViewCount: Bool = false
    public var hidePhoneNumber: Bool = false
    public var hideAccountRating: Bool = false
    public var hideAllChatsTab: Bool = false
    public var hideContactsTab: Bool = false
    public var hideCallsTab: Bool = false
    public var hideStories: Bool = false
    public var hideSearchBar: Bool = false
    public var showPostsFeed: Bool = false
    public var separateProfileTab: Bool = false
    public var messageBorderEnabled: Bool = false
    public var transparentMessages: Bool = false
    public var semiTransparentBubbles: Bool = false
    public var liquidGlassBubbles: Bool = false
    public var glassMessageBubbles: Bool = false
    public var liquidGlassSettings: Bool = false
    public var liquidGlassProfile: Bool = false
    public var liquidGlassGifts: Bool = false
    public var liquidGlassInlineButtons: Bool = false
    public var glassTinting: Bool = false
    public var fakeLiquidGlass: Bool = false
    public var colorInsteadOfGlass: Bool = false
    public var keepBannedChats: Bool = false
    public var bypassContentRestrictions: Bool = false
    public var iMessageChatStyle: Bool = false
    public var messageBorderColorHex: String = ""
    public var whitegramNotificationsEnabled: Bool = false
    public var persistentNotificationsEnabled: Bool = false
    public var backgroundKeepAlive: Bool = false
    public var ghostModeEnabled: Bool = false
    public var disableOnlineStatus: Bool = false
    public var disableTypingStatus: Bool = false
    public var disableRecordingStatus: Bool = false
    public var disableUploadingStatus: Bool = false
    public var disableReadReceipts: Bool = false
    public var disableStoryReadReceipts: Bool = false
    public var disableAds: Bool = false
    public var keepUnavailableAccounts: Bool = false
    public var saveProtectedContent: Bool = false
    public var removeSpoilers: Bool = false
    public var maxDownloadSpeed: Bool = false
    public var hideGalleryCamera: Bool = false
    public var cleanMetadataOnSend: Bool = false
    public var formattingToolbarEnabled: Bool = false
    public var profilePhotosRevision: Int = 0
    public var localStarsEnabled: Bool = false
    public var localStarsCount: Bool = false
    public var customFontEnabled: Bool = false
    public var customFontName: String = ""
    public var fontHistory: Bool = false
    public var disableChatSwipeOptions: Bool = false
    public var disableSwipeToRecordStory: Bool = false
    public var hideBusinessBotPanel: Bool = false
    public var unlimitedPinnedChats: Bool = false
    public var showChatCreationDate: Bool = false
    public var forceDeviceMicrophone: Bool = false
    public var sendLargePhotos: Bool = false
    public var photoCompressionQuality: Double = 0.0
    public var visualUsernameEnabled: Bool = false
    public var visualUsername: String = ""
    public var showCharCountTyping: Bool = false
    public var showCharCountMessages: Bool = false
    public var hideChannelAds: Bool = false
    public var chatScrollAnimation: Bool = false
    public var neutralMediaAccent: Bool = false
    public var scammerProtectionEnabled: Bool = false
    public var hideMyDeletedMessages: Bool = false
    public var deletedMessagesOpacity: Double = 0.0
    public var hideMyEditedMessages: Bool = false
    public var onlineHistoryEnabled: Bool = false
    public var doubleTapEditEnabled: Bool = false
    public var hideTabLabels: Bool = false
    public var hideBottomTabBar: Bool = false
    public var tabBarScale: Double = 0.0
    public var tabBarWidthScale: Double = 0.0
    public var translateMessagesEnabled: Bool = false
    public var localTranslationEnabled: Bool = false
    public var translateBeforeSending: Bool = false
    public var voiceTranslationEnabled: Bool = false
    public var showSiriTranscriptionWarning: Bool = false
    public var showRAMUsage: Bool = false
    public var hideSettingsDescriptions: Bool = false
    public var alwaysOnline: Bool = false
    public var roundProfileButtons: Bool = false
    public var roundProfileActionButtons: Bool = false
    public var wgBubbleFisheyeEffect: Bool = false
    public var profileColorEffect: Bool = false
    public var avatarBlurEffect: Bool = false
    public var avatarBlurInProfile: Bool = false
    public var avatarBlurReduced: Bool = false
    public var avatarBlurTint: Bool = false
    public var avatarGlow: Bool = false
    public var albumArtBlur: Bool = false
    public var bassEffect: Bool = false
    public var appBadgeColorIsBlack: Bool = false
    public var hideBotEditedMessages: Bool = false
    public var hideBotDeletedMessages: Bool = false
    public var zalgoFilterEnabled: Bool = false
    public var inAppVibrationEnabled: Bool = false
    public var alwaysSendHD: Bool = false
    public var hideReactions: Bool = false
    public var showActionTime: Bool = false
    public var rememberLastCamera: Bool = false
    public var staticZoomEnabled: Bool = false
    public var warnBeforeCall: Bool = false
    public var readOnAction: Bool = false
    public var sendAccelerationEnabled: Bool = false
    public var downloadAccelMode: Int = 0
    public var particleEffect: Int = 0
    public var particleSpeed: Int = 0
    public var particleDensity: Int = 0
    public var particleMode: Int = 0
    public var autoFormatStyle: Int = 0
    public var autoFormatMixedScript: Bool = false
    public var autoFormatMixedScriptUppercase: Bool = false
    public var saveViewOnceMedia: Bool = false
    public var unlimitedRecentStickers: Bool = false
    public var unlimitedFavoriteStickers: Bool = false
    public var deferredMessages: Bool = false
    public var fakeDeviceName: String = ""
    public var fakeLocationEnabled: Bool = false
    public var fakeLat: Double = 0.0
    public var fakeLon: Double = 0.0
    public var stopAfterVoiceMessage: Bool = false
    public var hideRecordButton: Bool = false
    public var ghostModeRecordOnce: Bool = false
    public var saveToFavoritesInMenu: Bool = false
    public var noChannelSwitch: Bool = false
    public var showOnlineDotInChats: Bool = false
    public var foldersAtBottom: Bool = false
    public var hideGifts: Bool = false
    public var hideWhitegramUserBadge: Bool = false
    public var hideOthersCustomMessageStyle: Bool = false
    public var highlightMentions: Bool = false
    public var trackLastOnline: Bool = false
    public var saveReadDates: Bool = false
    public var menuLanguage: Int = 0
    public var menuLanguageCode: String = ""
    public var accountSwitcherEnabled: Bool = false
    public var hideChatListTitle: Bool = false
    public var hideChatListPremiumBadge: Bool = false
    public var videoBackgroundPath: Bool = false
    public var videoBackgroundInProfile: Bool = false
    public var profilePhotoWallpaperSet: Bool = false
    public var profilePhotoWallPublic: Bool = false
    public var profilePhotoWallStatusText: Bool = false
    public var translationTargetLang: Bool = false
    public var antiCensorshipEnabled: Bool = false
    public var datacenterID: Int = 0
    public var virusTotalEnabled: Bool = false
    public var virusTotalApiKey: String = ""
    public var virusTotalConnectionStatus: String = ""
    public var voiceChangerEnabled: Bool = false
    public var voiceChangerApiKey: String = ""
    public var voiceChangerConnectionStatus: String = ""
    public var voiceChangerVoiceName: String = ""
    public var voiceChangerUseProxy: Bool = false
    public var voiceChangerMode: Int = 0
    public var voiceBleepEnabled: Bool = false
    public var voiceBleepMode: Int = 0
    public var voiceChangerPreset: Int = 0
    public var voiceChangerPitch: Double = 0.0
    public var voiceChangerTimbre: Double = 0.0
    public var voiceChangerEcho: Double = 0.0
    public var voiceChangerClarity: Double = 0.0
    public var voiceChangerInCalls: Bool = false
    public var geminiEnabled: Bool = false
    public var geminiApiKey: String = ""
    public var geminiModelId: String = ""
    public var geminiUseProxy: Bool = false
    public var aiProvider: String = ""
    public var groqApiKey: String = ""
    public var groqModelId: String = ""
    public var groqUseProxy: Bool = false
    public var musicPlaybackSpeed: Double = 0.0
    public var musicPlaybackPitchFollowsSpeed: Bool = false
    public var musicCrossfadeEnabled: Bool = false
    public var musicCrossfadeDuration: Int = 0
    public var musicEqualizerEnabled: Bool = false
    public var wgCustomMusicCard: Bool = false
    public var profileLyricEnabled: Bool = false
    public var profileLyricText: String = ""
    public var profileLyricAnimation: Int = 0
    public var profileQuoteEnabled: Bool = false
    public var profileQuoteText: String = ""
    public var profileWallEnabled: Bool = false
    public var profileWhitegramBadgeEnabled: Bool = false
    public var profileSceneEnabled: Bool = false
    public var profileScene: String = ""
    public var whitegramStreakEnabled: Bool = false
    public var whitegramProfileReactionsEnabled: Bool = false
    public var whitegramPresenceEnabled: Bool = false
    public var whitegramPresencePreciseEnabled: Bool = false
    public var activeWhitegramAccountId: Bool = false
    public var activeWhitegramAccountName: String = ""
    public var showMutualContactsCard: Bool = false
    public var showRegistrationDateCard: Bool = false
    public var wideChannelPosts: Bool = false
    public var localPremium: Bool = false

    public static let storageKey = "WhitegramSettingsState.v1"
    public static let updatedNotification = Notification.Name("WhitegramSettingsStateUpdated")

    public static var current: WhitegramSettingsState {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let value = try? JSONDecoder().decode(WhitegramSettingsState.self, from: data) {
            return value
        }
        return WhitegramSettingsState()
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        NotificationCenter.default.post(name: Self.updatedNotification, object: nil)
    }

    public func boolValue(for id: String) -> Bool? {
        switch id {
        case "accountSwitcherEnabled": return self.accountSwitcherEnabled
        case "albumArtBlur": return self.albumArtBlur
        case "alwaysOnline": return self.alwaysOnline
        case "alwaysSendHD": return self.alwaysSendHD
        case "antiCensorshipEnabled": return self.antiCensorshipEnabled
        case "appBadgeColorIsBlack": return self.appBadgeColorIsBlack
        case "avatarBlurEffect": return self.avatarBlurEffect
        case "avatarBlurInProfile": return self.avatarBlurInProfile
        case "avatarBlurReduced": return self.avatarBlurReduced
        case "avatarBlurTint": return self.avatarBlurTint
        case "avatarGlow": return self.avatarGlow
        case "backgroundKeepAlive": return self.backgroundKeepAlive
        case "bassEffect": return self.bassEffect
        case "bypassContentRestrictions": return self.bypassContentRestrictions
        case "chatScrollAnimation": return self.chatScrollAnimation
        case "classicInterface": return self.classicInterface
        case "cleanMetadataOnSend": return self.cleanMetadataOnSend
        case "colorInsteadOfGlass": return self.colorInsteadOfGlass
        case "compactChatList": return self.compactChatList
        case "customFontEnabled": return self.customFontEnabled
        case "customSettingsIcons": return self.customSettingsIcons
        case "deferredMessages": return self.deferredMessages
        case "disableAds": return self.disableAds
        case "disableChatSwipeOptions": return self.disableChatSwipeOptions
        case "disableOnlineStatus": return self.disableOnlineStatus
        case "disableReadReceipts": return self.disableReadReceipts
        case "disableRecordingStatus": return self.disableRecordingStatus
        case "disableStoryReadReceipts": return self.disableStoryReadReceipts
        case "disableSwipeToRecordStory": return self.disableSwipeToRecordStory
        case "disableTypingStatus": return self.disableTypingStatus
        case "disableUploadingStatus": return self.disableUploadingStatus
        case "fakeLiquidGlass": return self.fakeLiquidGlass
        case "fakeLocationEnabled": return self.fakeLocationEnabled
        case "foldersAtBottom": return self.foldersAtBottom
        case "forceDeviceMicrophone": return self.forceDeviceMicrophone
        case "geminiEnabled": return self.geminiEnabled
        case "geminiUseProxy": return self.geminiUseProxy
        case "ghostModeRecordOnce": return self.ghostModeRecordOnce
        case "glassMessageBubbles": return self.glassMessageBubbles
        case "glassTinting": return self.glassTinting
        case "groqUseProxy": return self.groqUseProxy
        case "hideAccountRating": return self.hideAccountRating
        case "hideAllChatsTab": return self.hideAllChatsTab
        case "hideAppearance": return self.hideAppearance
        case "hideBotDeletedMessages": return self.hideBotDeletedMessages
        case "hideBotEditedMessages": return self.hideBotEditedMessages
        case "hideBottomTabBar": return self.hideBottomTabBar
        case "hideBusiness": return self.hideBusiness
        case "hideBusinessBotPanel": return self.hideBusinessBotPanel
        case "hideCallsTab": return self.hideCallsTab
        case "hideChannelAds": return self.hideChannelAds
        case "hideChatListPremiumBadge": return self.hideChatListPremiumBadge
        case "hideChatListTitle": return self.hideChatListTitle
        case "hideContactsTab": return self.hideContactsTab
        case "hideCryptoBot": return self.hideCryptoBot
        case "hideDataAndStorage": return self.hideDataAndStorage
        case "hideDevices": return self.hideDevices
        case "hideEnergySaving": return self.hideEnergySaving
        case "hideFAQ": return self.hideFAQ
        case "hideFavorites": return self.hideFavorites
        case "hideFolders": return self.hideFolders
        case "hideGalleryCamera": return self.hideGalleryCamera
        case "hideGifts": return self.hideGifts
        case "hideLanguage": return self.hideLanguage
        case "hideMyDeletedMessages": return self.hideMyDeletedMessages
        case "hideMyEditedMessages": return self.hideMyEditedMessages
        case "hideMyProfile": return self.hideMyProfile
        case "hideNotifications": return self.hideNotifications
        case "hideOthersCustomMessageStyle": return self.hideOthersCustomMessageStyle
        case "hidePhoneNumber": return self.hidePhoneNumber
        case "hidePremium": return self.hidePremium
        case "hidePrivacy": return self.hidePrivacy
        case "hideProxy": return self.hideProxy
        case "hideReactions": return self.hideReactions
        case "hideRecentCalls": return self.hideRecentCalls
        case "hideRecordButton": return self.hideRecordButton
        case "hideSearchBar": return self.hideSearchBar
        case "hideSendGift": return self.hideSendGift
        case "hideSettingsAddAccount": return self.hideSettingsAddAccount
        case "hideSettingsEmojiStatus": return self.hideSettingsEmojiStatus
        case "hideSettingsProfileColor": return self.hideSettingsProfileColor
        case "hideSettingsReorderAccounts": return self.hideSettingsReorderAccounts
        case "hideSettingsSetPhoto": return self.hideSettingsSetPhoto
        case "hideSponsoredProxyChannel": return self.hideSponsoredProxyChannel
        case "hideStars": return self.hideStars
        case "hideStories": return self.hideStories
        case "hideSupport": return self.hideSupport
        case "hideTabLabels": return self.hideTabLabels
        case "hideTips": return self.hideTips
        case "hideWallet": return self.hideWallet
        case "hideWhitegramUserBadge": return self.hideWhitegramUserBadge
        case "highlightMentions": return self.highlightMentions
        case "keepBannedChats": return self.keepBannedChats
        case "keepUnavailableAccounts": return self.keepUnavailableAccounts
        case "lightChatUI": return self.lightChatUI
        case "liquidGlassBubbles": return self.liquidGlassBubbles
        case "liquidGlassGifts": return self.liquidGlassGifts
        case "liquidGlassInlineButtons": return self.liquidGlassInlineButtons
        case "liquidGlassProfile": return self.liquidGlassProfile
        case "liquidGlassSettings": return self.liquidGlassSettings
        case "localPremium": return self.localPremium
        case "localStarsEnabled": return self.localStarsEnabled
        case "localTranslationEnabled": return self.localTranslationEnabled
        case "maxDownloadSpeed": return self.maxDownloadSpeed
        case "messageShortenEnabled": return self.messageShortenEnabled
        case "neutralMediaAccent": return self.neutralMediaAccent
        case "newChatHeaderStyle": return self.newChatHeaderStyle
        case "newChatListUI": return self.newChatListUI
        case "noChannelSwitch": return self.noChannelSwitch
        case "oledMode": return self.oledMode
        case "onlineHistoryEnabled": return self.onlineHistoryEnabled
        case "profileColorEffect": return self.profileColorEffect
        case "profileLyricEnabled": return self.profileLyricEnabled
        case "profilePhotoWallPublic": return self.profilePhotoWallPublic
        case "profileQuoteEnabled": return self.profileQuoteEnabled
        case "profileSceneEnabled": return self.profileSceneEnabled
        case "profileWallEnabled": return self.profileWallEnabled
        case "profileWhitegramBadgeEnabled": return self.profileWhitegramBadgeEnabled
        case "reactionButtonGlow": return self.reactionButtonGlow
        case "readOnAction": return self.readOnAction
        case "rememberLastCamera": return self.rememberLastCamera
        case "removeSpoilers": return self.removeSpoilers
        case "roundProfileActionButtons": return self.roundProfileActionButtons
        case "roundProfileButtons": return self.roundProfileButtons
        case "saveChatHistory": return self.saveChatHistory
        case "saveProtectedContent": return self.saveProtectedContent
        case "saveReadDates": return self.saveReadDates
        case "saveToFavoritesInMenu": return self.saveToFavoritesInMenu
        case "saveViewOnceMedia": return self.saveViewOnceMedia
        case "semiTransparentBubbles": return self.semiTransparentBubbles
        case "sendLargePhotos": return self.sendLargePhotos
        case "separateProfileTab": return self.separateProfileTab
        case "showActionTime": return self.showActionTime
        case "showCharCountMessages": return self.showCharCountMessages
        case "showCharCountTyping": return self.showCharCountTyping
        case "showChatCreationDate": return self.showChatCreationDate
        case "showDeletedMessages": return self.showDeletedMessages
        case "showEditedOriginalText": return self.showEditedOriginalText
        case "showFullViewCount": return self.showFullViewCount
        case "showMutualContactsCard": return self.showMutualContactsCard
        case "showOnlineDotInChats": return self.showOnlineDotInChats
        case "showOriginalTelegramIcons": return self.showOriginalTelegramIcons
        case "showPeerIDAndDC": return self.showPeerIDAndDC
        case "showPostsFeed": return self.showPostsFeed
        case "showRAMUsage": return self.showRAMUsage
        case "showRegistrationDateCard": return self.showRegistrationDateCard
        case "showTimestampSeconds": return self.showTimestampSeconds
        case "squareAvatars": return self.squareAvatars
        case "stopAfterVoiceMessage": return self.stopAfterVoiceMessage
        case "trackLastOnline": return self.trackLastOnline
        case "translateBeforeSending": return self.translateBeforeSending
        case "transparentMessages": return self.transparentMessages
        case "unlimitedFavoriteStickers": return self.unlimitedFavoriteStickers
        case "unlimitedPinnedChats": return self.unlimitedPinnedChats
        case "unlimitedRecentStickers": return self.unlimitedRecentStickers
        case "videoBackgroundInProfile": return self.videoBackgroundInProfile
        case "virusTotalEnabled": return self.virusTotalEnabled
        case "visualUsernameEnabled": return self.visualUsernameEnabled
        case "voiceBleepEnabled": return self.voiceBleepEnabled
        case "voiceChangerEnabled": return self.voiceChangerEnabled
        case "voiceChangerInCalls": return self.voiceChangerInCalls
        case "voiceChangerUseProxy": return self.voiceChangerUseProxy
        case "voiceTranslationEnabled": return self.voiceTranslationEnabled
        case "warnBeforeCall": return self.warnBeforeCall
        case "wgBubbleFisheyeEffect": return self.wgBubbleFisheyeEffect
        case "whitegramPresenceEnabled": return self.whitegramPresenceEnabled
        case "whitegramPresencePreciseEnabled": return self.whitegramPresencePreciseEnabled
        case "whitegramProfileReactionsEnabled": return self.whitegramProfileReactionsEnabled
        case "whitegramStreakEnabled": return self.whitegramStreakEnabled
        case "wideChannelPosts": return self.wideChannelPosts
        default: return nil
        }
    }

    public mutating func setBool(_ value: Bool, for id: String) {
        switch id {
        case "accountSwitcherEnabled": self.accountSwitcherEnabled = value
        case "albumArtBlur": self.albumArtBlur = value
        case "alwaysOnline": self.alwaysOnline = value
        case "alwaysSendHD": self.alwaysSendHD = value
        case "antiCensorshipEnabled": self.antiCensorshipEnabled = value
        case "appBadgeColorIsBlack": self.appBadgeColorIsBlack = value
        case "avatarBlurEffect": self.avatarBlurEffect = value
        case "avatarBlurInProfile": self.avatarBlurInProfile = value
        case "avatarBlurReduced": self.avatarBlurReduced = value
        case "avatarBlurTint": self.avatarBlurTint = value
        case "avatarGlow": self.avatarGlow = value
        case "backgroundKeepAlive": self.backgroundKeepAlive = value
        case "bassEffect": self.bassEffect = value
        case "bypassContentRestrictions": self.bypassContentRestrictions = value
        case "chatScrollAnimation": self.chatScrollAnimation = value
        case "classicInterface": self.classicInterface = value
        case "cleanMetadataOnSend": self.cleanMetadataOnSend = value
        case "colorInsteadOfGlass": self.colorInsteadOfGlass = value
        case "compactChatList": self.compactChatList = value
        case "customFontEnabled": self.customFontEnabled = value
        case "customSettingsIcons": self.customSettingsIcons = value
        case "deferredMessages": self.deferredMessages = value
        case "disableAds": self.disableAds = value
        case "disableChatSwipeOptions": self.disableChatSwipeOptions = value
        case "disableOnlineStatus": self.disableOnlineStatus = value
        case "disableReadReceipts": self.disableReadReceipts = value
        case "disableRecordingStatus": self.disableRecordingStatus = value
        case "disableStoryReadReceipts": self.disableStoryReadReceipts = value
        case "disableSwipeToRecordStory": self.disableSwipeToRecordStory = value
        case "disableTypingStatus": self.disableTypingStatus = value
        case "disableUploadingStatus": self.disableUploadingStatus = value
        case "fakeLiquidGlass": self.fakeLiquidGlass = value
        case "fakeLocationEnabled": self.fakeLocationEnabled = value
        case "foldersAtBottom": self.foldersAtBottom = value
        case "forceDeviceMicrophone": self.forceDeviceMicrophone = value
        case "geminiEnabled": self.geminiEnabled = value
        case "geminiUseProxy": self.geminiUseProxy = value
        case "ghostModeRecordOnce": self.ghostModeRecordOnce = value
        case "glassMessageBubbles": self.glassMessageBubbles = value
        case "glassTinting": self.glassTinting = value
        case "groqUseProxy": self.groqUseProxy = value
        case "hideAccountRating": self.hideAccountRating = value
        case "hideAllChatsTab": self.hideAllChatsTab = value
        case "hideAppearance": self.hideAppearance = value
        case "hideBotDeletedMessages": self.hideBotDeletedMessages = value
        case "hideBotEditedMessages": self.hideBotEditedMessages = value
        case "hideBottomTabBar": self.hideBottomTabBar = value
        case "hideBusiness": self.hideBusiness = value
        case "hideBusinessBotPanel": self.hideBusinessBotPanel = value
        case "hideCallsTab": self.hideCallsTab = value
        case "hideChannelAds": self.hideChannelAds = value
        case "hideChatListPremiumBadge": self.hideChatListPremiumBadge = value
        case "hideChatListTitle": self.hideChatListTitle = value
        case "hideContactsTab": self.hideContactsTab = value
        case "hideCryptoBot": self.hideCryptoBot = value
        case "hideDataAndStorage": self.hideDataAndStorage = value
        case "hideDevices": self.hideDevices = value
        case "hideEnergySaving": self.hideEnergySaving = value
        case "hideFAQ": self.hideFAQ = value
        case "hideFavorites": self.hideFavorites = value
        case "hideFolders": self.hideFolders = value
        case "hideGalleryCamera": self.hideGalleryCamera = value
        case "hideGifts": self.hideGifts = value
        case "hideLanguage": self.hideLanguage = value
        case "hideMyDeletedMessages": self.hideMyDeletedMessages = value
        case "hideMyEditedMessages": self.hideMyEditedMessages = value
        case "hideMyProfile": self.hideMyProfile = value
        case "hideNotifications": self.hideNotifications = value
        case "hideOthersCustomMessageStyle": self.hideOthersCustomMessageStyle = value
        case "hidePhoneNumber": self.hidePhoneNumber = value
        case "hidePremium": self.hidePremium = value
        case "hidePrivacy": self.hidePrivacy = value
        case "hideProxy": self.hideProxy = value
        case "hideReactions": self.hideReactions = value
        case "hideRecentCalls": self.hideRecentCalls = value
        case "hideRecordButton": self.hideRecordButton = value
        case "hideSearchBar": self.hideSearchBar = value
        case "hideSendGift": self.hideSendGift = value
        case "hideSettingsAddAccount": self.hideSettingsAddAccount = value
        case "hideSettingsEmojiStatus": self.hideSettingsEmojiStatus = value
        case "hideSettingsProfileColor": self.hideSettingsProfileColor = value
        case "hideSettingsReorderAccounts": self.hideSettingsReorderAccounts = value
        case "hideSettingsSetPhoto": self.hideSettingsSetPhoto = value
        case "hideSponsoredProxyChannel": self.hideSponsoredProxyChannel = value
        case "hideStars": self.hideStars = value
        case "hideStories": self.hideStories = value
        case "hideSupport": self.hideSupport = value
        case "hideTabLabels": self.hideTabLabels = value
        case "hideTips": self.hideTips = value
        case "hideWallet": self.hideWallet = value
        case "hideWhitegramUserBadge": self.hideWhitegramUserBadge = value
        case "highlightMentions": self.highlightMentions = value
        case "keepBannedChats": self.keepBannedChats = value
        case "keepUnavailableAccounts": self.keepUnavailableAccounts = value
        case "lightChatUI": self.lightChatUI = value
        case "liquidGlassBubbles": self.liquidGlassBubbles = value
        case "liquidGlassGifts": self.liquidGlassGifts = value
        case "liquidGlassInlineButtons": self.liquidGlassInlineButtons = value
        case "liquidGlassProfile": self.liquidGlassProfile = value
        case "liquidGlassSettings": self.liquidGlassSettings = value
        case "localPremium": self.localPremium = value
        case "localStarsEnabled": self.localStarsEnabled = value
        case "localTranslationEnabled": self.localTranslationEnabled = value
        case "maxDownloadSpeed": self.maxDownloadSpeed = value
        case "messageShortenEnabled": self.messageShortenEnabled = value
        case "neutralMediaAccent": self.neutralMediaAccent = value
        case "newChatHeaderStyle": self.newChatHeaderStyle = value
        case "newChatListUI": self.newChatListUI = value
        case "noChannelSwitch": self.noChannelSwitch = value
        case "oledMode": self.oledMode = value
        case "onlineHistoryEnabled": self.onlineHistoryEnabled = value
        case "profileColorEffect": self.profileColorEffect = value
        case "profileLyricEnabled": self.profileLyricEnabled = value
        case "profilePhotoWallPublic": self.profilePhotoWallPublic = value
        case "profileQuoteEnabled": self.profileQuoteEnabled = value
        case "profileSceneEnabled": self.profileSceneEnabled = value
        case "profileWallEnabled": self.profileWallEnabled = value
        case "profileWhitegramBadgeEnabled": self.profileWhitegramBadgeEnabled = value
        case "reactionButtonGlow": self.reactionButtonGlow = value
        case "readOnAction": self.readOnAction = value
        case "rememberLastCamera": self.rememberLastCamera = value
        case "removeSpoilers": self.removeSpoilers = value
        case "roundProfileActionButtons": self.roundProfileActionButtons = value
        case "roundProfileButtons": self.roundProfileButtons = value
        case "saveChatHistory": self.saveChatHistory = value
        case "saveProtectedContent": self.saveProtectedContent = value
        case "saveReadDates": self.saveReadDates = value
        case "saveToFavoritesInMenu": self.saveToFavoritesInMenu = value
        case "saveViewOnceMedia": self.saveViewOnceMedia = value
        case "semiTransparentBubbles": self.semiTransparentBubbles = value
        case "sendLargePhotos": self.sendLargePhotos = value
        case "separateProfileTab": self.separateProfileTab = value
        case "showActionTime": self.showActionTime = value
        case "showCharCountMessages": self.showCharCountMessages = value
        case "showCharCountTyping": self.showCharCountTyping = value
        case "showChatCreationDate": self.showChatCreationDate = value
        case "showDeletedMessages": self.showDeletedMessages = value
        case "showEditedOriginalText": self.showEditedOriginalText = value
        case "showFullViewCount": self.showFullViewCount = value
        case "showMutualContactsCard": self.showMutualContactsCard = value
        case "showOnlineDotInChats": self.showOnlineDotInChats = value
        case "showOriginalTelegramIcons": self.showOriginalTelegramIcons = value
        case "showPeerIDAndDC": self.showPeerIDAndDC = value
        case "showPostsFeed": self.showPostsFeed = value
        case "showRAMUsage": self.showRAMUsage = value
        case "showRegistrationDateCard": self.showRegistrationDateCard = value
        case "showTimestampSeconds": self.showTimestampSeconds = value
        case "squareAvatars": self.squareAvatars = value
        case "stopAfterVoiceMessage": self.stopAfterVoiceMessage = value
        case "trackLastOnline": self.trackLastOnline = value
        case "translateBeforeSending": self.translateBeforeSending = value
        case "transparentMessages": self.transparentMessages = value
        case "unlimitedFavoriteStickers": self.unlimitedFavoriteStickers = value
        case "unlimitedPinnedChats": self.unlimitedPinnedChats = value
        case "unlimitedRecentStickers": self.unlimitedRecentStickers = value
        case "videoBackgroundInProfile": self.videoBackgroundInProfile = value
        case "virusTotalEnabled": self.virusTotalEnabled = value
        case "visualUsernameEnabled": self.visualUsernameEnabled = value
        case "voiceBleepEnabled": self.voiceBleepEnabled = value
        case "voiceChangerEnabled": self.voiceChangerEnabled = value
        case "voiceChangerInCalls": self.voiceChangerInCalls = value
        case "voiceChangerUseProxy": self.voiceChangerUseProxy = value
        case "voiceTranslationEnabled": self.voiceTranslationEnabled = value
        case "warnBeforeCall": self.warnBeforeCall = value
        case "wgBubbleFisheyeEffect": self.wgBubbleFisheyeEffect = value
        case "whitegramPresenceEnabled": self.whitegramPresenceEnabled = value
        case "whitegramPresencePreciseEnabled": self.whitegramPresencePreciseEnabled = value
        case "whitegramProfileReactionsEnabled": self.whitegramProfileReactionsEnabled = value
        case "whitegramStreakEnabled": self.whitegramStreakEnabled = value
        case "wideChannelPosts": self.wideChannelPosts = value
        default: break
        }
    }
}
