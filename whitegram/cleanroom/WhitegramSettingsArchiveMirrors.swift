import Foundation

enum WhitegramSettingsArchiveMirrors {
    enum Conversion {
        case identity, inverted, camera, stickerScale, editAction
    }

    struct Binding {
        let key: String
        let store: String
        let field: String?
        let initial: Any
        let rule: WhitegramSettingsArchiveRule
        let conversion: Conversion
    }

    static let chat = "WhiteGramChatSettings.v1"
    static let tabs = "WhiteGramTabSettings.v1"
    static let stories = "WhiteGramStorySettings.v1"
    static let folders = "WhiteGramChatFolderSettings.v1"
    static let notifications = [chat: "WhiteGramChatSettingsUpdated", tabs: "WhiteGramTabSettingsUpdated", stories: "WhiteGramStorySettingsUpdated", folders: "WhiteGramChatFolderSettingsUpdated"]

    static let bindings: [Binding] = {
        var items: [Binding] = []
        func add(_ key: String, _ store: String, _ field: String?, _ initial: Any, _ rule: WhitegramSettingsArchiveRule = .boolean, _ conversion: Conversion = .identity) {
            items.append(Binding(key: key, store: store, field: field, initial: initial, rule: rule, conversion: conversion))
        }
        for (key, field, initial) in [
            ("compactChatList", "compactChatList", false), ("showTimestampSeconds", "showSecondsInMessageTimestamp", false),
            ("wideChannelPosts", "wideChannelPosts", false)
        ] { add(key, chat, field, initial) }
        for (key, field) in [("disableChatSwipeOptions", "chatSwipeOptions"), ("noChannelSwitch", "channelSwipeToNext"), ("hideRecordButton", "voiceMessageButton"), ("hideReactions", "channelPostReactions")] {
            add(key, chat, field, true, .boolean, .inverted)
        }
        add("stickerSizeScale", chat, "stickerSizePercent", 100, .number(0...1), .stickerScale)
        add("videoMessageCamera", chat, "videoMessageCamera", "ask", .integer(0...2), .camera)
        add("doubleTapEditEnabled", chat, "personalChatDoubleTapAction", "reaction", .boolean, .editAction)
        for (field, initial) in [
            ("compactPinnedMessagesPanel", false), ("showStickerTime", true), ("animatePremiumStickers", true),
            ("animateEmojiStickers", true), ("hideMessageTimestamp", false), ("confirmVoiceRecording", false),
            ("swipeToReply", true), ("channelBottomPanel", true), ("chatSwipeDelete", true)
        ] { add("public.chat." + field, chat, field, initial) }
        add("public.chat.personalChatDoubleTapAction", chat, "personalChatDoubleTapAction", "reaction", .choice(["savedMessages", "reaction", "edit", "forward", "reply", "pin", "select", "copy", "contextMenu"]))
        add("public.chat.channelPostDoubleTapAction", chat, "channelPostDoubleTapAction", "reaction", .choice(["savedMessages", "reaction", "forward", "reply", "select", "copy", "contextMenu"]))
        for (key, field) in [("hideContactsTab", "hideContactsTab"), ("hideCallsTab", "hideCallsTab"), ("hideTabLabels", "hideTabTitles"), ("hideSearchBar", "hideSearchButton"), ("hideBottomTabBar", "compactPanel")] {
            add(key, tabs, field, false)
        }
        add("public.tabs.widePanel", tabs, "widePanel", false)
        add("hideStories", stories, "hideStories", false)
        add("disableSwipeToRecordStory", stories, "disableStoryRecordingSwipe", false)
        for field in ["disableStories", "disableStoryRecording", "askBeforeViewingStories"] { add("public.stories." + field, stories, field, false) }
        add("foldersAtBottom", folders, "foldersAtBottom", false)
        for field in ["disableFolders", "compactPanel", "openLastFolder"] { add("public.folders." + field, folders, field, false) }
        for (key, field) in [("translateMessagesEnabled", "autoTranslate"), ("forceDeviceMicrophone", "forceDeviceMicrophone"), ("hideGalleryCamera", "hideCameraInGallery")] {
            add(key, "whitegram.other." + field, nil, false)
        }
        for (field, initial) in [("translationButton", true), ("voiceTranscription", true), ("hideCameraPreviewInGallery", false)] { add("public.other." + field, "whitegram.other." + field, nil, initial) }
        add("public.other.translationService", "whitegram.other.translationService", nil, "gTranslate", .choice(["telegram", "gTranslate"]))
        add("public.other.transcriptionService", "whitegram.other.transcriptionService", nil, "apple", .choice(["telegram", "apple"]))
        for (key, option) in [
            ("hideFavorites", "settingsSavedMessages"), ("hideRecentCalls", "settingsRecentCalls"), ("hideDevices", "settingsDevices"),
            ("hideFolders", "settingsChatFolders"), ("hidePremium", "settingsPremium"), ("hideStars", "settingsStars"),
            ("hideBusiness", "settingsBusiness"), ("hideSendGift", "settingsGifts"), ("hideSupport", "settingsHelp"),
            ("hideFAQ", "settingsFAQ"), ("hideTips", "settingsFeatures")
        ] { add(key, "whitegram.contextMenus." + option, nil, true, .boolean, .inverted) }
        let contextOptions = """
        chatListFolder chatListMark chatListArchive chatListPin chatListMute chatListDelete
        privateReply privateCopy privateEdit privateForward privateHideName privateDelete privateAddToFavorites privatePin privateRemove privateSelect
        channelReply channelCopy channelCopyLink channelEdit channelForward channelHideName channelReport channelDelete channelSaveToFavorites channelPin channelRemove channelSelect
        """
        for option in contextOptions.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            add("public.contextMenu." + option, "whitegram.contextMenus." + option, nil, true)
        }
        return items
    }()

    private static func readGroup(_ store: String, defaults: UserDefaults) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for binding in bindings where binding.store == store {
            if let field = binding.field { result[field] = binding.initial }
        }
        if let object = defaults.object(forKey: store) {
            guard let data = object as? Data, data.count <= WhitegramSettingsArchive.maximumBytes else { throw WhitegramSettingsArchiveError.invalidPublicStore }
            do {
                guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WhitegramSettingsArchiveError.invalidPublicStore }
                result.merge(existing, uniquingKeysWith: { _, new in new })
            } catch { throw WhitegramSettingsArchiveError.invalidPublicStore }
        }
        for binding in bindings where binding.store == store {
            if let field = binding.field, let value = result[field] { _ = try fromStored(value, binding: binding) }
        }
        return result
    }

    private static func fromStored(_ value: Any, binding: Binding) throws -> Any {
        switch binding.conversion {
        case .identity: return try binding.rule.validate(value, key: binding.key)
        case .inverted:
            guard let flag = try binding.rule.validate(value, key: binding.key) as? Bool else { throw WhitegramSettingsArchiveError.invalidPublicStore }
            return !flag
        case .camera:
            guard let camera = value as? String, let index = ["front", "back", "ask"].firstIndex(of: camera) else { throw WhitegramSettingsArchiveError.invalidPublicStore }
            return Int64(index)
        case .stickerScale:
            guard let percent = WhitegramPreferences.exactInteger(value), (0...100).contains(percent) else { throw WhitegramSettingsArchiveError.invalidPublicStore }
            return Double(percent) / 100
        case .editAction:
            guard let action = value as? String else { throw WhitegramSettingsArchiveError.invalidPublicStore }
            return action == "edit"
        }
    }

    private static func toStored(_ value: Any, previous: Any, binding: Binding) throws -> Any {
        let value = try binding.rule.validate(value, key: binding.key)
        switch binding.conversion {
        case .identity: return value
        case .inverted:
            guard let flag = value as? Bool else { throw WhitegramSettingsArchiveError.invalidValue(binding.key) }
            return !flag
        case .camera:
            guard let index = WhitegramPreferences.exactInteger(value) else { throw WhitegramSettingsArchiveError.invalidValue(binding.key) }
            return ["front", "back", "ask"][Int(index)]
        case .stickerScale:
            guard let scale = value as? Double else { throw WhitegramSettingsArchiveError.invalidValue(binding.key) }
            return Int64((scale * 100).rounded())
        case .editAction:
            guard let enabled = value as? Bool else { throw WhitegramSettingsArchiveError.invalidValue(binding.key) }
            return enabled ? "edit" : ((previous as? String) == "edit" ? "reaction" : previous)
        }
    }

    static func capture(preferences: [String: Any], defaults: UserDefaults) throws -> [String: Any] {
        var result = preferences
        for key in WhitegramSettingsArchiveSchema.rules.keys where !key.hasPrefix("public.") && result[key] == nil {
            result[key] = defaults.object(forKey: "wg_" + key)
        }
        var groups: [String: [String: Any]] = [:]
        for binding in bindings {
            if result[binding.key] != nil && !binding.key.hasPrefix("public.") { continue }
            let stored: Any
            if let field = binding.field {
                if groups[binding.store] == nil { groups[binding.store] = try readGroup(binding.store, defaults: defaults) }
                stored = groups[binding.store]?[field] ?? binding.initial
            } else { stored = defaults.object(forKey: binding.store) ?? binding.initial }
            result[binding.key] = try fromStored(stored, binding: binding)
        }
        if let edit = result["doubleTapEditEnabled"] as? Bool {
            let action = result["public.chat.personalChatDoubleTapAction"] as? String
            if edit { result["public.chat.personalChatDoubleTapAction"] = "edit" }
            else if action == "edit" { result["public.chat.personalChatDoubleTapAction"] = "reaction" }
        }
        return result
    }

    static func prepare(_ values: [String: Any], defaults: UserDefaults) throws -> (changes: [String: Any], mirrors: [String: Any], notifications: [Notification.Name]) {
        var changes = values.filter { !$0.key.hasPrefix("public.") }
        if let action = values["public.chat.personalChatDoubleTapAction"] as? String { changes["doubleTapEditEnabled"] = action == "edit" }
        var groups: [String: [String: Any]] = [:]
        var mirrors: [String: Any] = [:]
        if let bands = values["musicEqualizerBands"] { mirrors["wg_musicEqualizerBands"] = bands }
        var names = Set<Notification.Name>()
        for binding in bindings {
            guard let value = values[binding.key] else { continue }
            if let field = binding.field {
                if groups[binding.store] == nil { groups[binding.store] = try readGroup(binding.store, defaults: defaults) }
                let previous = groups[binding.store]?[field] ?? binding.initial
                groups[binding.store]?[field] = try toStored(value, previous: previous, binding: binding)
                if let name = notifications[binding.store] { names.insert(Notification.Name(name)) }
            } else {
                mirrors[binding.store] = try toStored(value, previous: defaults.object(forKey: binding.store) ?? binding.initial, binding: binding)
                names.insert(Notification.Name("WhiteGramChatSettingsUpdated"))
            }
        }
        for (store, fields) in groups { mirrors[store] = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) }
        return (changes, mirrors, Array(names))
    }
}
