import Foundation

/// Beta 3.2 section dispatch (0x10d0d04) and stable indices (0x10cfbd8).
enum WhitegramSettingsLayout {
    private static let groups: [(Int, String)] = [
        (0, """
        appearanceHeader squareAvatars compactChatList stickerSizeSlider stickerSizeAction showOriginalTelegramIcons
        disableChatSwipeOptions unlimitedPinnedChats roundProfileButtons profileColorEffect avatarBlurEffect avatarBlurInProfile
        albumArtBlur profileCoverPhoto bassEffect videoChatBackground resetVideoBackground newChatListUI resetProfileCoverPhoto
        newChatHeaderStyle bubblesHeader messageBorder transparentMessages semiTransparentBubbles bubblesInfo liquidGlassBubbles
        wideChannelPosts appearanceInfo particleEffectPicker particleModePicker particleSpeedSlider particleDensitySlider appBadgeColorIsBlack
        showRAMUsage hideSearchBar avatarBlurTint avatarBlurReduced avatarGlow customSettingsIcons wgBubbleFisheyeEffect
        roundProfileActionButtons videoBackgroundInProfile profilePhotoWallpaper resetProfilePhotoWallpaper profilePhotoWallPublic
        profilePhotoWallStatus classicInterface customMusicCard oledMode reactionButtonGlow foldersAtBottom hideChatListTitle
        hideChatListPremiumBadge hideRecordButton
        """),
        (1, """
        messagesHeader showDeletedMessages showDeletedInfo showEditedOriginalText showEditedInfo messageShortenEnabled
        showCharCountTyping showCharCountMessages hideMyDeletedMessages hideMyEditedMessages doubleTapEdit hideBotEditedMessages
        hideBotDeletedMessages deletedMessagesOpacitySlider chatScrollAnimation neutralMediaAccent showEditedStrikethrough hideChannelAds
        hideChannelAdsInfo sendOnReturnKey restoreChatsView saveDeletedToBackup keepBannedChats saveChatHistory saveViewOnceMedia
        stopAfterVoiceMessage highlightMentions
        """),
        (2, "cacheHeader clearDeletedCache clearEditedCache clearSavedChatHistory exportDeletedBackup importDeletedBackup cacheInfo"),
        (3, """
        cameraHeader cameraFront cameraBack cameraInfo forceDeviceMicrophone sendLargePhotos photoQualitySlider cameraSettingsButton
        alwaysSendHD rememberLastCamera chooseCameraBeforeRoundVideo staticZoom
        """),
        (4, """
        ghostModeHeader alwaysOnline ghostMode disableOnlineStatus disableTypingStatus disableRecordingStatus disableUploadingStatus
        disableReadReceipts disableStoryReadReceipts ghostModeInfo onlineHistoryEnabled onlineHistoryView onlineHistoryClear
        readOnAction deferredMessages fakeLocationEnabled fakeLocationPicker fakeDeviceName ghostModeRecordOnce
        """),
        (5, "privacyHeader saveProtectedContent scammerProtection bypassContentRestrictions privacyInfo warnBeforeCall removeSpoilers"),
        (6, """
        infoDisplayHeader showPeerIDAndDC showTimestampSeconds showFullViewCount hidePhoneNumber showChatCreationDate
        visualUsernameEnabled visualUsernameButton infoDisplayInfo showMutualContactsCard showRegistrationDateCard
        """),
        (7, """
        miscUIHeader disableAds formattingToolbar translateMessages maxDownloadSpeed hideGalleryCamera exportSettings importSettings
        miscUIInfo localPremium saveSettingsToKeychain restoreSettingsFromKeychain cleanMetadataOnSend keepUnavailableAccounts
        hideDescriptions zalgoFilter inAppVibration hideReactions showActionTime sendAcceleration downloadAccelPicker autoFormatStyleButton
        unlimitedRecentStickers hideGifts unlimitedFavoriteStickers saveToFavoritesInMenu noChannelSwitch disableSwipeToRecordStory
        hideBusinessBotPanel showOnlineDotInChats hideWhitegramUserBadge hideWhitegramUserBadgeInfo hideOthersCustomMessageStyle
        hideOthersCustomMessageStyleInfo
        """),
        (8, """
        interfaceHeader hideFavorites hideDevices hideFolders hideNotifications hidePrivacy hideDataAndStorage hideAppearance
        hideEnergySaving hideLanguage hideAccountRating hideProxy hideMyProfile hideRecentCalls hidePremium hideStars hideBusiness
        hideWallet hideSendGift hideSupport hideFAQ hideTips hideCryptoBot hideSponsoredProxyChannel hideSettingsAddAccount
        hideSettingsEmojiStatus hideSettingsProfileColor hideSettingsSetPhoto hideSettingsReorderAccounts interfaceInfo
        """),
        (9, """
        tabsHeader hideAllChatsTab hideContactsTab hideCallsTab hideStories hideTabLabels tabBarScaleSlider tabBarScaleButton
        tabsInfo tabBarWidthSlider showPostsFeed hideBottomTabBar separateProfileTab accountSwitcherEnabled
        """),
        (12, "localStarsHeader localStarsEnabled localStarsCountSlider localStarsCountCustom localStarsInfo"),
        (13, "fontsHeader customFontEnabled customFontsManager customFontPicker fontHistoryItem fontsInfo"),
        (14, "sessionsHeader keychainAccounts botAccounts accountTransfer sessionsInfo"),
        (16, "whitegramChannelButton whitegramBetaButton developerButton openlockVPN openlockVPNInfo menuLanguagePicker"),
        (17, "spyHeader trackLastOnline saveReadDates spyInfo"),
        (18, "analyticsHeader analyticsStaticRow exportSystemLogs analyticsInfo"),
        (19, "pluginsHeader pluginsOpen pluginsInfo pluginRow"),
        (20, "translationHeader localTranslationEnabled translationTargetLang translateBeforeSending voiceTranslationEnabled siriTranscriptionWarning"),
        (21, """
        liquidGlassHeader glassMessageBubbles liquidGlassSettings liquidGlassProfile liquidGlassGifts lightChatUI
        liquidGlassInlineButtons glassTinting fakeLiquidGlass colorInsteadOfGlass
        """),
        (22, "antiCensorshipHeader antiCensorshipEnabled"),
        (23, "virusTotalHeader virusTotalEnabled virusTotalApiKeyRow virusTotalStatusRow"),
        (24, """
        voiceChangerHeader voiceChangerEnabled voiceChangerApiKeyRow voiceChangerStatusRow voiceChangerVoiceRow voiceChangerUseProxy
        voiceChangerModeSlider voiceChangerPresetSelector voiceChangerCustomHeader voiceChangerPitchSlider voiceChangerTimbreSlider
        voiceChangerEchoSlider voiceChangerClaritySlider voiceChangerInfo voiceChangerInCalls voiceBleepEnabled voiceBleepModeSelector voiceBleepInfo
        """),
        (25, "geminiHeader geminiEnabled geminiApiKeyRow geminiModelRow aiProviderRow groqApiKeyRow groqModelRow geminiUseProxy groqUseProxy"),
        (26, """
        featuresHeader profileLyricEnabled profileLyricPicker profileLyricAnimationPicker profileWallEnabled profileWhitegramBadgeEnabled
        whitegramPresenceEnabled whitegramPresencePreciseEnabled whitegramStreakEnabled whitegramProfileReactionsEnabled accountSettings
        profileQuoteEnabled profileQuoteEditor profilePhotos profileReactionsPicker wallBlockedUsers profileSceneEnabled profileScenePicker
        profileBanner resetProfileBanner profileBannerStatus
        """),
        (27, "playerHeader playbackSpeedSlider playbackPitchFollowsSpeed"),
        (28, "notificationsHeader whitegramNotifications persistentNotifications backgroundKeepAlive persistentNotificationsInfo"),
        (30, "iconsHeader myIconPacks createIconPack iconPackSitePreview iconsInfo"),
        (31, "crossfadeSlider crossfadeEnabled"),
        (32, "equalizerEnabled equalizerOpen")
    ]

    static func rows(_ catalog: [WhitegramSettingsRowDescriptor]) -> [WhitegramSettingsRowDescriptor] {
        var descriptors = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        descriptors["sendOnReturnKey"] = WhitegramSettingsRowDescriptor(id: "sendOnReturnKey", order: 0, section: 1,
            kind: .switchRow, title: "sendOnReturnKey", labelsVerified: true)
        var result: [WhitegramSettingsRowDescriptor] = []
        for (section, keys) in groups {
            for id in keys.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                guard let row = descriptors.removeValue(forKey: id) else { continue }
                result.append(WhitegramSettingsRowDescriptor(id: row.id, order: result.count, section: section,
                    kind: row.kind, title: row.title, labelsVerified: row.labelsVerified))
            }
        }
        for row in descriptors.values.sorted(by: { $0.order < $1.order }) {
            result.append(WhitegramSettingsRowDescriptor(id: row.id, order: result.count, section: 33,
                kind: row.kind, title: row.title, labelsVerified: row.labelsVerified))
        }
        return result
    }
}
