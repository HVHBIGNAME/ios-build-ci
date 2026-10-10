import Foundation
import CoreFoundation
import TelegramCore

enum WhitegramPortCapabilities {
    private static let defaults = WhitegramSettingsState()
    private static let booleanDefaults: [String: Bool] = Dictionary(uniqueKeysWithValues: Mirror(reflecting: defaults).children.compactMap { child -> (String, Bool)? in
        guard let key = child.label, let value = child.value as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return (key, value.boolValue)
    })
    // Each writable key has an installed consumer in runtime_patches,
    // interface_patches, history_patches, or WhitegramForkBridge.
    static let booleans: [String: String] = [
        "showRAMUsage": "showRAMUsage",
        "whitegramNotifications": "whitegramNotificationsEnabled",
        "persistentNotifications": "persistentNotificationsEnabled", "backgroundKeepAlive": "backgroundKeepAlive",
        "hideDescriptions": "hideSettingsDescriptions",
        "keepUnavailableAccounts": "keepUnavailableAccounts", "accountSwitcherEnabled": "accountSwitcherEnabled",
        "playbackPitchFollowsSpeed": "musicPlaybackPitchFollowsSpeed", "crossfadeEnabled": "musicCrossfadeEnabled",
        "equalizerEnabled": "musicEqualizerEnabled", "stopAfterVoiceMessage": "stopAfterVoiceMessage",
        "readOnAction": "readOnAction", "warnBeforeCall": "warnBeforeCall",
        "bypassContentRestrictions": "bypassContentRestrictions", "keepBannedChats": "keepBannedChats",
        "saveProtectedContent": "saveProtectedContent", "removeSpoilers": "removeSpoilers",
        "saveViewOnceMedia": "saveViewOnceMedia", "ghostModeRecordOnce": "ghostModeRecordOnce",
        "hideAllChatsTab": "hideAllChatsTab", "hideAccountRating": "hideAccountRating",
        "showPeerIDAndDC": "showPeerIDAndDC", "showChatCreationDate": "showChatCreationDate",
        "foldersAtBottom": "foldersAtBottom", "saveToFavoritesInMenu": "saveToFavoritesInMenu",
        "showDeletedMessages": "showDeletedMessages", "showEditedOriginalText": "showEditedOriginalText",
        "saveChatHistory": "saveChatHistory", "saveDeletedToBackup": "saveDeletedMessagesToBackup",
        "hideMyDeletedMessages": "hideMyDeletedMessages", "hideMyEditedMessages": "hideMyEditedMessages",
        "hideBotDeletedMessages": "hideBotDeletedMessages", "hideBotEditedMessages": "hideBotEditedMessages",
        "squareAvatars": "squareAvatars",
        "hideFavorites": "hideFavorites", "hideDevices": "hideDevices", "hideFolders": "hideFolders",
        "hideEnergySaving": "hideEnergySaving", "hideLanguage": "hideLanguage",
        "hideNotifications": "hideNotifications", "hidePrivacy": "hidePrivacy",
        "hideDataAndStorage": "hideDataAndStorage", "hideAppearance": "hideAppearance",
        "hideProxy": "hideProxy", "hideMyProfile": "hideMyProfile", "hideRecentCalls": "hideRecentCalls",
        "hidePremium": "hidePremium", "hideStars": "hideStars", "hideBusiness": "hideBusiness",
        "hideSendGift": "hideSendGift", "hideSupport": "hideSupport", "hideFAQ": "hideFAQ", "hideTips": "hideTips",
        "hideSettingsAddAccount": "hideSettingsAddAccount", "hideSettingsEmojiStatus": "hideSettingsEmojiStatus",
        "hideSettingsProfileColor": "hideSettingsProfileColor", "hideSettingsSetPhoto": "hideSettingsSetPhoto",
        "showTimestampSeconds": "showTimestampSeconds", "showFullViewCount": "showFullViewCount",
        "hidePhoneNumber": "hidePhoneNumber", "hideContactsTab": "hideContactsTab", "hideCallsTab": "hideCallsTab",
        "hideStories": "hideStories", "hideSearchBar": "hideSearchBar", "hideGalleryCamera": "hideGalleryCamera",
        "translateMessages": "translateMessagesEnabled", "disableChatSwipeOptions": "disableChatSwipeOptions",
        "disableSwipeToRecordStory": "disableSwipeToRecordStory", "forceDeviceMicrophone": "forceDeviceMicrophone",
        "hideChannelAds": "hideChannelAds", "doubleTapEdit": "doubleTapEditEnabled",
        "hideTabLabels": "hideTabLabels", "wideChannelPosts": "wideChannelPosts", "hideReactions": "hideReactions",
        "ghostMode": "ghostModeEnabled", "alwaysOnline": "alwaysOnline", "disableOnlineStatus": "disableOnlineStatus",
        "disableTypingStatus": "disableTypingStatus", "disableRecordingStatus": "disableRecordingStatus",
        "disableUploadingStatus": "disableUploadingStatus", "disableReadReceipts": "disableReadReceipts",
        "disableStoryReadReceipts": "disableStoryReadReceipts", "disableAds": "disableAds",
        "customFontEnabled": "customFontEnabled", "hideRecordButton": "hideRecordButton", "noChannelSwitch": "noChannelSwitch",
        "fakeLocationEnabled": "fakeLocationEnabled",
        "messageShortenEnabled": "messageShortenEnabled",
        "unlimitedRecentStickers": "unlimitedRecentStickers", "unlimitedFavoriteStickers": "unlimitedFavoriteStickers",
        "bassEffect": "bassEffect", "customMusicCard": "wgCustomMusicCard",
        "staticZoom": "staticZoomEnabled", "maxDownloadSpeed": "maxDownloadSpeed", "sendAcceleration": "sendAccelerationEnabled",
        "localStarsEnabled": "localStarsEnabled",
        "sendLargePhotos": "sendLargePhotos", "alwaysSendHD": "alwaysSendHD",
        "cleanMetadataOnSend": "cleanMetadataOnSend", "rememberLastCamera": "rememberLastCamera",
        "messageBorder": "messageBorderEnabled", "transparentMessages": "transparentMessages",
        "semiTransparentBubbles": "semiTransparentBubbles", "showCharCountTyping": "showCharCountTyping",
        "showCharCountMessages": "showCharCountMessages", "showActionTime": "showActionTime", "hideBusinessBotPanel": "hideBusinessBotPanel",
        "liquidGlassBubbles": "liquidGlassBubbles", "glassMessageBubbles": "glassMessageBubbles", "liquidGlassSettings": "liquidGlassSettings",
        "liquidGlassProfile": "liquidGlassProfile", "liquidGlassGifts": "liquidGlassGifts", "liquidGlassInlineButtons": "liquidGlassInlineButtons",
        "glassTinting": "glassTinting", "fakeLiquidGlass": "fakeLiquidGlass", "colorInsteadOfGlass": "colorInsteadOfGlass", "lightChatUI": "lightChatUI",
        "voiceChangerEnabled": "voiceChangerEnabled", "voiceBleepEnabled": "voiceBleepEnabled", "voiceChangerInCalls": "voiceChangerInCalls"
    ]

    static let informationKeys: [String: String] = [
        "persistentNotificationsInfo": "info.persistentNotifications",
        "showDeletedInfo": "di.showDeleted", "showEditedInfo": "di.showEdited", "cacheInfo": "di.cache",
        "appearanceInfo": "di.appearance", "cameraInfo": "di.camera", "interfaceInfo": "di.interface",
        "infoDisplayInfo": "di.info", "tabsInfo": "di.tabs", "miscUIInfo": "di.misc", "bubblesInfo": "di.bubbles",
        "ghostModeInfo": "di.ghost", "privacyInfo": "di.privacy", "localStarsInfo": "di.stars", "fontsInfo": "di.fonts",
        "sessionsInfo": "di.sessions", "spyInfo": "di.spy", "analyticsInfo": "di.analytics", "pluginsInfo": "di.plugins",
        "openlockVPNInfo": "di.openlockVPN", "voiceBleepInfo": "s.voiceBleep.desc", "voiceChangerInfo": "wh.voiceChangerEnabled"
    ]

    static let titleKeys: [String: String] = [
        "messagesHeader": "h.messages", "cacheHeader": "h.cache", "appearanceHeader": "h.appearance",
        "cameraHeader": "h.camera", "interfaceHeader": "h.interface", "infoDisplayHeader": "h.info",
        "tabsHeader": "h.tabs", "miscUIHeader": "h.misc", "bubblesHeader": "h.bubbles", "liquidGlassHeader": "h.liquidGlass",
        "notificationsHeader": "h.notifications", "ghostModeHeader": "h.ghost", "privacyHeader": "h.privacy",
        "localStarsHeader": "h.stars", "fontsHeader": "h.fonts", "sessionsHeader": "h.sessions", "spyHeader": "h.spy",
        "analyticsHeader": "h.analytics", "iconsHeader": "h.icons", "pluginsHeader": "h.plugins", "translationHeader": "h.translation",
        "antiCensorshipHeader": "h.antiCensorship", "virusTotalHeader": "h.virusTotal", "featuresHeader": "h.features", "playerHeader": "section.player",
        "fakeLocationEnabled": "s.fakeLocation", "fakeLocationPicker": "s.fakeLocationPicker",
        "messageShortenEnabled": "s.shortenMenu",
        "unlimitedRecentStickers": "s.unlimitedStickers", "unlimitedFavoriteStickers": "s.unlimitedFavoriteStickers",
        "stickerSizeSlider": "s.stickerSize", "stickerSizeAction": "s.stickerSize",
        "tabBarScaleSlider": "s.tabBarScale", "tabBarWidthSlider": "s.tabBarWidth",
        "photoQualitySlider": "s.photoQuality", "deletedMessagesOpacitySlider": "s.deletedOpacity",
        "playbackSpeedSlider": "player.playbackSpeed", "playbackPitchFollowsSpeed": "player.pitchFollowsSpeed",
        "crossfadeEnabled": "player.crossfadeEnabled", "crossfadeSlider": "player.crossfade", "equalizerOpen": "player.equalizerOpen",
        "showDeletedMessages": "s.showDeleted", "showCharCountTyping": "s.charCountTyping", "showCharCountMessages": "s.charCountMsgs",
        "localStarsEnabled": "s.localStars", "localStarsCountSlider": "s.starsCount",
        "alwaysSendHD": "s.alwaysHD", "rememberLastCamera": "s.rememberCamera", "sendAcceleration": "s.sendAccel",
        "liquidGlassBubbles": "s.liquidGlass", "voiceBleepEnabled": "s.voiceBleep"
    ]

    static let screens: [String: String] = [
        "analyticsStaticRow": "diagnostics", "exportSystemLogs": "diagnostics",
        "menuLanguagePicker": "localization",
        "keychainAccounts": "keychainAccounts", "accountTransfer": "accountTransfer", "botAccounts": "botAccounts",
        "playbackSpeedSlider": "player", "crossfadeSlider": "player", "equalizerOpen": "equalizer",
        "antiCensorshipEnabled": "traffic",
        "profilePhotos": "profilePhotos", "profilePhotoWallpaper": "profilePhotos",
        "resetProfilePhotoWallpaper": "profilePhotos", "profilePhotoWallPublic": "profilePhotos", "profilePhotoWallStatus": "profilePhotos",
        "profileLyricEnabled": "profile", "profileLyricPicker": "profile", "profileLyricAnimationPicker": "profile",
        "profileQuoteEnabled": "profile", "profileQuoteEditor": "profile", "profileWhitegramBadgeEnabled": "profile",
        "profileSceneEnabled": "profile", "profileScenePicker": "profile",
        "whitegramProfileReactionsEnabled": "profile", "profileReactionsPicker": "profile",
        "profileWallEnabled": "profileWall", "wallBlockedUsers": "profileWall", "whitegramStreakEnabled": "streaks",
        "whitegramPresenceEnabled": "radio", "whitegramPresencePreciseEnabled": "radio",
        "downloadAccelPicker": "media", "fakeLocationPicker": "location",
        "localStarsCountSlider": "localStars", "localStarsCountCustom": "localStars",
        "tabBarScaleButton": "appearanceControls", "tabBarScaleSlider": "appearanceControls", "tabBarWidthSlider": "appearanceControls",
        "myIconPacks": "iconPacks", "createIconPack": "iconPacks",
        "photoQualitySlider": "media",
        "translationTargetLang": "translation", "translateBeforeSending": "translation",
        "localTranslationEnabled": "translation", "voiceTranslationEnabled": "translation", "siriTranscriptionWarning": "translation",
        "exportSettings": "settingsTransfer", "importSettings": "settingsTransfer",
        "saveSettingsToKeychain": "settingsTransfer", "restoreSettingsFromKeychain": "settingsTransfer",
        "compactChatList": "chats",
        "clearSavedChatHistory": "history", "restoreChatsView": "history", "clearDeletedCache": "history",
        "clearEditedCache": "history", "exportDeletedBackup": "history", "importDeletedBackup": "history",
        "stickerSizeAction": "appearanceControls", "stickerSizeSlider": "appearanceControls",
        "cameraBack": "media", "cameraFront": "media", "cameraSettingsButton": "media",
        "customFontsManager": "fonts", "customFontPicker": "fonts", "fontHistoryItem": "fonts",
        "pluginsOpen": "plugins", "pluginRow": "plugins",
        "virusTotalEnabled": "virusTotal", "virusTotalApiKeyRow": "virusTotal", "virusTotalStatusRow": "virusTotal",
        "voiceChangerModeSlider": "voice", "voiceChangerPresetSelector": "voice",
        "voiceChangerPitchSlider": "voice", "voiceChangerTimbreSlider": "voice", "voiceChangerEchoSlider": "voice", "voiceChangerClaritySlider": "voice",
        "voiceBleepModeSelector": "voice",
        "voiceChangerApiKeyRow": "voiceRemote", "voiceChangerStatusRow": "voiceRemote",
        "voiceChangerVoiceRow": "voiceRemote", "voiceChangerUseProxy": "voiceRemote",
        "geminiEnabled": "ai", "geminiApiKeyRow": "ai", "geminiModelRow": "ai",
        "aiProviderRow": "ai", "groqApiKeyRow": "ai", "groqModelRow": "ai",
        "geminiUseProxy": "ai", "groqUseProxy": "ai"
    ]

    static let russianTitles: [String: String] = [
        "foldersAtBottom": "Папки внизу", "saveToFavoritesInMenu": "Сохранить в Избранное в меню сообщения",
        "exportSettings": "Экспорт настроек", "importSettings": "Импорт настроек",
        "saveSettingsToKeychain": "Сохранить настройки в Связку ключей",
        "restoreSettingsFromKeychain": "Восстановить настройки из Связки ключей",
        "messageBorder": "Обводка сообщений", "transparentMessages": "Прозрачные сообщения",
        "semiTransparentBubbles": "Полупрозрачные пузыри", "showCharCountTyping": "Счётчик при наборе",
        "showCharCountMessages": "Счётчик в сообщениях", "showActionTime": "Время служебных сообщений",
        "hideBusinessBotPanel": "Скрыть панель бизнес-бота",
        "ghostMode": "Режим призрака", "alwaysOnline": "Оставаться онлайн, пока клиент работает",
        "disableOnlineStatus": "Не показывать онлайн", "disableTypingStatus": "Не показывать набор текста",
        "disableRecordingStatus": "Не показывать запись голоса и видео", "disableUploadingStatus": "Не показывать загрузку файлов",
        "disableReadReceipts": "Не отправлять прочтения сообщений", "disableStoryReadReceipts": "Не отправлять просмотры историй",
        "showDeletedMessages": "Сохранять удалённые сообщения", "showEditedOriginalText": "Сохранять текст до изменения",
        "saveChatHistory": "Архив полученных сообщений", "saveDeletedToBackup": "Хранить удалённые в локальном архиве",
        "squareAvatars": "Квадратные аватары", "compactChatList": "Компактный список чатов",
        "showTimestampSeconds": "Секунды во времени сообщения", "showFullViewCount": "Полное число просмотров",
        "customFontEnabled": "Использовать выбранный шрифт", "hidePhoneNumber": "Скрыть номер в редактировании профиля",
        "hideContactsTab": "Скрыть вкладку контактов", "hideCallsTab": "Скрыть вкладку звонков",
        "hideTabLabels": "Скрыть подписи вкладок", "hideBottomTabBar": "Компактное меню вместо панели вкладок",
        "hideChannelAds": "Скрыть рекламу в каналах", "disableAds": "Скрыть спонсируемые сообщения и поиск",
        "hideStories": "Скрыть истории", "hideGalleryCamera": "Скрыть камеру в галерее",
        "translateMessages": "Автоматический перевод", "forceDeviceMicrophone": "Микрофон устройства",
        "disableChatSwipeOptions": "Отключить действия свайпом", "disableSwipeToRecordStory": "Отключить свайп записи истории",
        "wideChannelPosts": "Широкие посты каналов", "doubleTapEdit": "Редактировать двойным нажатием",
        "hideRecordButton": "Скрыть кнопку голосовой записи", "noChannelSwitch": "Не переключать на следующий канал",
        "hideFavorites": "Скрыть Избранное", "hideDevices": "Скрыть Устройства", "hideFolders": "Скрыть Папки",
        "hideEnergySaving": "Скрыть Энергосбережение", "hideLanguage": "Скрыть Язык", "hideNotifications": "Скрыть Уведомления",
        "hidePrivacy": "Скрыть Конфиденциальность", "hideDataAndStorage": "Скрыть Данные и память", "hideAppearance": "Скрыть Оформление",
        "hideProxy": "Скрыть строку прокси", "hideMyProfile": "Скрыть Мой профиль", "hideRecentCalls": "Скрыть недавние звонки",
        "hidePremium": "Скрыть Telegram Premium", "hideStars": "Скрыть Звёзды", "hideBusiness": "Скрыть Telegram Business",
        "hideSendGift": "Скрыть Отправить подарок", "hideSupport": "Скрыть Поддержку", "hideFAQ": "Скрыть FAQ", "hideTips": "Скрыть Советы",
        "hideSettingsAddAccount": "Скрыть Добавить аккаунт", "hideSettingsEmojiStatus": "Скрыть эмодзи-статус",
        "hideSettingsProfileColor": "Скрыть цвет профиля", "hideSettingsSetPhoto": "Скрыть Установить фото"
    ]

    static func booleanValue(_ id: String) -> Bool? {
        guard let key = booleans[id] else { return nil }
        var fallback = defaults.boolValue(for: id) ?? booleanDefaults[key] ?? false
        if let legacy = UserDefaults.standard.object(forKey: "wg_" + key) as? NSNumber,
           CFGetTypeID(legacy) == CFBooleanGetTypeID() {
            fallback = legacy.boolValue
        }
        return WhitegramPreferences.bool(key, default: fallback)
    }

    static func supports(_ id: String) -> Bool {
        return booleans[id] != nil || screens[id] != nil || informationKeys[id] != nil
    }

    static func title(_ row: WhitegramSettingsRowDescriptor, baseLanguage: String) -> String {
        if let key = informationKeys[row.id] { return WhitegramLocalization.string(key, baseLanguage: baseLanguage) }
        if let key = titleKeys[row.id] { return WhitegramLocalization.string(key, baseLanguage: baseLanguage) }
        let key = (row.kind == .headerRow ? "h." : "s.") + row.id
        if WhitegramLocalizationStrings.values[key] != nil {
            return WhitegramLocalization.string(key, baseLanguage: baseLanguage)
        }
        let russian = WhitegramLocalization.selectedLanguage(baseLanguage: baseLanguage) == "ru"
        if russian, let title = russianTitles[row.id] { return title }
        return row.id.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}
