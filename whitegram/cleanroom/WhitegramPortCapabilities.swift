import Foundation

enum WhitegramPortCapabilities {
    // Each writable key has an installed consumer in runtime_patches,
    // interface_patches, history_patches, or WhitegramForkBridge.
    static let booleans: [String: String] = [
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
        "customFontEnabled": "customFontEnabled", "hideRecordButton": "hideRecordButton", "noChannelSwitch": "noChannelSwitch"
    ]

    static let screens: [String: String] = [
        "compactChatList": "chats",
        "hideBottomTabBar": "tabs",
        "clearSavedChatHistory": "history", "restoreChatsView": "history", "clearDeletedCache": "history",
        "clearEditedCache": "history", "exportDeletedBackup": "history", "importDeletedBackup": "history",
        "stickerSizeAction": "chats", "stickerSizeSlider": "chats",
        "cameraBack": "chats", "cameraFront": "chats", "cameraSettingsButton": "chats",
        "customFontsManager": "fonts", "customFontPicker": "fonts", "fontHistoryItem": "fonts",
        "pluginsOpen": "plugins", "pluginRow": "plugins",
        "virusTotalEnabled": "virusTotal", "virusTotalApiKeyRow": "virusTotal", "virusTotalStatusRow": "virusTotal",
        "voiceChangerEnabled": "voice", "voiceChangerModeSlider": "voice", "voiceChangerPresetSelector": "voice",
        "voiceChangerPitchSlider": "voice", "voiceChangerTimbreSlider": "voice", "voiceChangerEchoSlider": "voice", "voiceChangerClaritySlider": "voice",
        "geminiEnabled": "ai", "geminiApiKeyRow": "ai", "geminiModelRow": "ai",
        "aiProviderRow": "ai", "groqApiKeyRow": "ai", "groqModelRow": "ai"
    ]

    static let russianTitles: [String: String] = [
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

    static func title(_ row: WhitegramSettingsRowDescriptor, russian: Bool) -> String {
        if russian, let title = russianTitles[row.id] { return title }
        return row.id.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}
