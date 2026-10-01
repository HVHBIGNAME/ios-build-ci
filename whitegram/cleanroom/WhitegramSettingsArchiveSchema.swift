import Foundation
import CoreFoundation

enum WhitegramSettingsArchiveRule {
    case boolean
    case integer(ClosedRange<Int64>)
    case number(ClosedRange<Double>)
    case string(Int)
    case choice(Set<String>)
    case color
    case bands

    func validate(_ value: Any, key: String) throws -> Any {
        switch self {
        case .boolean:
            if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return value.boolValue }
        case let .integer(range):
            if let value = WhitegramPreferences.exactInteger(value), range.contains(value) { return value }
        case let .number(range):
            if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, range.contains(value.doubleValue) { return value.doubleValue }
        case let .string(limit):
            if let value = value as? String, value.utf8.count <= limit, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return value }
        case let .choice(choices):
            if let value = value as? String, choices.contains(value) { return value }
        case .color:
            if let value = value as? String {
                if value.isEmpty { return value }
                let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
                if hex.utf8.count == 6, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) { return "#" + hex.uppercased() }
            }
        case .bands:
            if let values = value as? [Any], !values.isEmpty, values.count <= 32 {
                return try values.map { value -> Double in
                    guard let normalized = try WhitegramSettingsArchiveRule.number(-24...24).validate(value, key: key) as? Double else {
                        throw WhitegramSettingsArchiveError.invalidValue(key)
                    }
                    return normalized
                }
            }
        }
        throw WhitegramSettingsArchiveError.invalidValue(key)
    }
}

enum WhitegramSettingsArchiveSchema {
    // Only user configuration is portable. Credentials, paths, caches, account IDs,
    // plugin metadata/permissions and arbitrary preference keys are never enumerated.
    static let rules: [String: WhitegramSettingsArchiveRule] = {
        var result: [String: WhitegramSettingsArchiveRule] = [:]
        let booleans = """
        showDeletedMessages showEditedOriginalText messageShortenEnabled saveChatHistory saveDeletedMessagesToBackup
        squareAvatars compactChatList newChatListUI newChatHeaderStyle lightChatUI classicInterface oledMode reactionButtonGlow
        showOriginalTelegramIcons customSettingsIcons hideFavorites hideDevices hideFolders hideEnergySaving hideLanguage
        hideNotifications hidePrivacy hideDataAndStorage hideAppearance hideProxy hideMyProfile hideRecentCalls hidePremium
        hideStars hideWallet hideCryptoBot hideBusiness hideSendGift hideSupport hideFAQ hideTips hideSponsoredProxyChannel
        hideSettingsAddAccount hideSettingsEmojiStatus hideSettingsProfileColor hideSettingsSetPhoto hideSettingsReorderAccounts
        showPeerIDAndDC showTimestampSeconds showFullViewCount hidePhoneNumber hideAccountRating hideAllChatsTab hideContactsTab
        hideCallsTab hideStories hideSearchBar showPostsFeed separateProfileTab messageBorderEnabled transparentMessages
        semiTransparentBubbles liquidGlassBubbles glassMessageBubbles liquidGlassSettings liquidGlassProfile liquidGlassGifts
        liquidGlassInlineButtons glassTinting fakeLiquidGlass colorInsteadOfGlass keepBannedChats bypassContentRestrictions
        iMessageChatStyle whitegramNotificationsEnabled persistentNotificationsEnabled backgroundKeepAlive ghostModeEnabled
        disableOnlineStatus disableTypingStatus disableRecordingStatus disableUploadingStatus disableReadReceipts
        disableStoryReadReceipts disableAds keepUnavailableAccounts saveProtectedContent removeSpoilers maxDownloadSpeed
        hideGalleryCamera cleanMetadataOnSend formattingToolbarEnabled localStarsEnabled customFontEnabled disableChatSwipeOptions
        disableSwipeToRecordStory hideBusinessBotPanel unlimitedPinnedChats showChatCreationDate forceDeviceMicrophone
        sendLargePhotos visualUsernameEnabled showCharCountTyping showCharCountMessages hideChannelAds chatScrollAnimation
        neutralMediaAccent scammerProtectionEnabled hideMyDeletedMessages hideMyEditedMessages onlineHistoryEnabled
        doubleTapEditEnabled hideTabLabels hideBottomTabBar translateMessagesEnabled localTranslationEnabled translateBeforeSending
        voiceTranslationEnabled showSiriTranscriptionWarning showRAMUsage hideSettingsDescriptions alwaysOnline roundProfileButtons
        roundProfileActionButtons wgBubbleFisheyeEffect profileColorEffect avatarBlurEffect avatarBlurInProfile avatarBlurReduced
        avatarBlurTint avatarGlow albumArtBlur bassEffect appBadgeColorIsBlack hideBotEditedMessages hideBotDeletedMessages
        zalgoFilterEnabled inAppVibrationEnabled alwaysSendHD hideReactions showActionTime rememberLastCamera staticZoomEnabled
        warnBeforeCall readOnAction sendAccelerationEnabled autoFormatMixedScript autoFormatMixedScriptUppercase saveViewOnceMedia
        unlimitedRecentStickers unlimitedFavoriteStickers deferredMessages fakeLocationEnabled stopAfterVoiceMessage hideRecordButton
        ghostModeRecordOnce saveToFavoritesInMenu noChannelSwitch showOnlineDotInChats foldersAtBottom hideGifts hideWhitegramUserBadge
        hideOthersCustomMessageStyle highlightMentions trackLastOnline saveReadDates accountSwitcherEnabled hideChatListTitle
        hideChatListPremiumBadge videoBackgroundInProfile antiCensorshipEnabled virusTotalEnabled voiceChangerEnabled
        voiceChangerUseProxy voiceBleepEnabled voiceBleepWholeRecording voiceChangerInCalls geminiEnabled geminiUseProxy groqUseProxy
        musicPlaybackPitchFollowsSpeed musicCrossfadeEnabled musicEqualizerEnabled wgCustomMusicCard profileLyricEnabled
        profileQuoteEnabled profileWallEnabled profileWhitegramBadgeEnabled profileSceneEnabled whitegramStreakEnabled
        whitegramProfileReactionsEnabled whitegramPresenceEnabled whitegramPresencePreciseEnabled showMutualContactsCard
        showRegistrationDateCard wideChannelPosts localPremium
        """
        for key in booleans.split(whereSeparator: { $0.isWhitespace }) { result[String(key)] = .boolean }
        result["useTelegramCameraSettings"] = .boolean
        for key in ["backCameraPreset", "frontCameraPreset"] { result[key] = .string(128) }
        for key in ["backCameraFPS", "frontCameraFPS"] { result[key] = .integer(0...60) }
        result["roundVideoBitrate"] = .choice(["", "500000", "1000000", "2000000", "4000000", "8000000"])
        for key in ["stickerSizeScale", "photoCompressionQuality", "deletedMessagesOpacity"] { result[key] = .number(0...1) }
        result["localStarsCount"] = .integer(0...Int64.max)
        result["videoMessageCamera"] = .integer(0...2)
        result["voiceChangerMode"] = .integer(0...1)
        result["voiceBleepMode"] = .integer(0...1)
        result["voiceChangerPreset"] = .integer(0...10)
        result["voiceChangerPitch"] = .number(-12...12)
        result["voiceChangerTimbre"] = .number(-100...100)
        result["voiceChangerEcho"] = .number(0...100)
        result["voiceChangerClarity"] = .number(-100...100)
        result["fakeLat"] = .number(-90...90)
        result["fakeLon"] = .number(-180...180)
        result["musicPlaybackSpeed"] = .number(0.25...4)
        result["musicCrossfadeDuration"] = .integer(0...30)
        result["musicEqualizerBands"] = .bands
        result["messageBorderColorHex"] = .color
        result["aiProvider"] = .choice(["", "gemini", "groq"])
        for key in ["customFontName", "geminiModelId", "groqModelId", "voiceChangerVoiceId", "voiceChangerVoiceName", "visualUsername", "fakeDeviceName"] { result[key] = .string(256) }
        for key in ["translationTargetLang", "menuLanguageCode"] { result[key] = .string(32) }
        for binding in WhitegramSettingsArchiveMirrors.bindings where binding.key.hasPrefix("public.") { result[binding.key] = binding.rule }
        return result
    }()

    static let aliases = [
        "ghostMode": "ghostModeEnabled", "saveDeletedMessages": "showDeletedMessages",
        "saveDeletedToBackup": "saveDeletedMessagesToBackup", "translateMessages": "translateMessagesEnabled",
        "doubleTapEdit": "doubleTapEditEnabled", "hideDescriptions": "hideSettingsDescriptions",
        "bubbleFisheyeEffect": "wgBubbleFisheyeEffect", "customMusicCard": "wgCustomMusicCard",
        "profileReactionsEnabled": "whitegramProfileReactionsEnabled", "albumArtBlurEnabled": "albumArtBlur",
        "avatarBlurEffectEnabled": "avatarBlurEffect", "avatarBlurTintEnabled": "avatarBlurTint",
        "avatarGlowEnabled": "avatarGlow", "bassEffectEnabled": "bassEffect", "profileColorEffectEnabled": "profileColorEffect"
    ]

    static func canonicalKey(_ key: String) -> String? {
        if rules[key] != nil { return key }
        let primitive = key.hasPrefix("wg_") ? String(key.dropFirst(3)) : key
        let canonical = aliases[primitive] ?? primitive
        guard !canonical.hasPrefix("public."), rules[canonical] != nil else { return nil }
        return canonical
    }

    static func validate(_ values: [String: Any]) throws -> (values: [String: Any], migrated: [String]) {
        guard values.count <= 384 else { throw WhitegramSettingsArchiveError.tooLarge }
        var result: [String: Any] = [:]
        var migrated: [String] = []
        for key in values.keys.sorted() {
            guard let canonical = canonicalKey(key), let rule = rules[canonical] else { throw WhitegramSettingsArchiveError.unsupportedSetting }
            guard result[canonical] == nil else { throw WhitegramSettingsArchiveError.duplicateKey }
            if let value = values[key] { result[canonical] = try rule.validate(value, key: canonical) }
            if key != canonical { migrated.append(canonical) }
        }
        if let action = result["public.chat.personalChatDoubleTapAction"] as? String,
           let edit = result["doubleTapEditEnabled"] as? Bool, edit != (action == "edit") {
            throw WhitegramSettingsArchiveError.conflictingSettings
        }
        return (result, migrated)
    }
}
