import Foundation
import TelegramCore

public enum WhitegramForkBridge {
    private final class ChangeRelay {
        private var chat = WhiteGramChatSettings.current
        private var tabs = WhiteGramTabSettings.current
        private var stories = WhiteGramStorySettings.current
        private var foldersAtBottom = WhiteGramChatFolderSettings.current.foldersAtBottom
        private var observer: NSObjectProtocol?

        init() {
            self.observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.changed() }
            }
        }

        private func changed() {
            let chat = WhiteGramChatSettings.current
            let tabs = WhiteGramTabSettings.current
            let stories = WhiteGramStorySettings.current
            let foldersAtBottom = WhiteGramChatFolderSettings.current.foldersAtBottom
            if self.chat != chat {
                self.chat = chat
                NotificationCenter.default.post(name: WhiteGramChatSettings.updatedNotification, object: nil)
            }
            if self.tabs != tabs {
                self.tabs = tabs
                NotificationCenter.default.post(name: WhiteGramTabSettings.updatedNotification, object: nil)
            }
            if self.stories != stories {
                self.stories = stories
                NotificationCenter.default.post(name: WhiteGramStorySettings.updatedNotification, object: nil)
            }
            if self.foldersAtBottom != foldersAtBottom {
                self.foldersAtBottom = foldersAtBottom
                NotificationCenter.default.post(name: WhiteGramChatFolderSettings.updatedNotification, object: nil)
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    private static let relay = ChangeRelay()

    public static func migrate() {
        _ = relay
        if !WhitegramPreferences.bool("forkFolderSettingsMigrated") {
            var enabled = (WhitegramPreferences.values()["foldersAtBottom"] as? Bool)
                ?? (UserDefaults.standard.object(forKey: "wg_foldersAtBottom") as? Bool) ?? false
            if let data = UserDefaults.standard.data(forKey: "WhiteGramChatFolderSettings.v1"),
               let original = try? JSONDecoder().decode(WhiteGramChatFolderSettings.self, from: data) {
                enabled = original.foldersAtBottom
            }
            WhitegramPreferences.update(["foldersAtBottom": enabled, "forkFolderSettingsMigrated": true])
        }
        guard !WhitegramPreferences.bool("forkSettingsMigrated") else { return }
        saveChat(WhiteGramChatSettings.current)
        saveTabs(WhiteGramTabSettings.current)
        saveStories(WhiteGramStorySettings.current)
        save(WhiteGramOtherSettings.current, otherBindings)
        let menu = WhiteGramContextMenuSettings.current
        for option in menuBindings.keys { saveMenu(option, enabled: menu.isEnabled(option)) }
        WhitegramPreferences.set(true, for: "forkSettingsMigrated")
    }

    private struct Binding<T> {
        let key: String
        let path: WritableKeyPath<T, Bool>
        let inverted: Bool

        init(_ key: String, _ path: WritableKeyPath<T, Bool>, inverted: Bool = false) {
            self.key = key
            self.path = path
            self.inverted = inverted
        }
    }

    private static func apply<T>(_ value: T, _ bindings: [Binding<T>]) -> T {
        var value = value
        let values = WhitegramPreferences.values()
        for binding in bindings {
            if let enabled = values[binding.key] as? Bool {
                value[keyPath: binding.path] = binding.inverted ? !enabled : enabled
            }
        }
        return value
    }

    private static func save<T>(_ value: T, _ bindings: [Binding<T>]) {
        var changes: [String: Any] = [:]
        for binding in bindings {
            let enabled = value[keyPath: binding.path]
            changes[binding.key] = binding.inverted ? !enabled : enabled
        }
        WhitegramPreferences.update(changes)
    }

    private static let chatBindings: [Binding<WhiteGramChatSettings>] = [
        Binding("compactChatList", \.compactChatList),
        Binding("showTimestampSeconds", \.showSecondsInMessageTimestamp),
        Binding("wideChannelPosts", \.wideChannelPosts),
        Binding("disableChatSwipeOptions", \.chatSwipeOptions, inverted: true),
        Binding("noChannelSwitch", \.channelSwipeToNext, inverted: true),
        Binding("hideRecordButton", \.voiceMessageButton, inverted: true)
    ]

    public static func chat(_ source: WhiteGramChatSettings) -> WhiteGramChatSettings {
        var value = apply(source, chatBindings)
        let preferences = WhitegramPreferences.values()
        if let scale = preferences["stickerSizeScale"] as? Double {
            let scale = scale == 0 ? 1.0 : min(2.0, max(0.1, scale))
            value.stickerSizePercent = Int32((scale * 100.0).rounded())
        }
        if let camera = WhitegramMediaSettings.current.videoMessageCamera {
            value.videoMessageCamera = camera == 1 ? .back : (camera == 2 ? .ask : .front)
        }
        if let edit = preferences["doubleTapEditEnabled"] as? Bool {
            if edit { value.personalChatDoubleTapAction = .edit }
            else if value.personalChatDoubleTapAction == .edit { value.personalChatDoubleTapAction = .reaction }
        }
        return value
    }

    public static func saveChat(_ value: WhiteGramChatSettings) {
        save(value, chatBindings)
        let camera: Int
        switch value.videoMessageCamera {
        case .front: camera = 0
        case .back: camera = 1
        case .ask: camera = 2
        }
        WhitegramPreferences.update([
            "stickerSizeScale": Double(value.stickerSizePercent) / 100.0,
            "videoMessageCamera": camera,
            "doubleTapEditEnabled": value.personalChatDoubleTapAction == .edit
        ])
    }

    private static let tabBindings: [Binding<WhiteGramTabSettings>] = [
        Binding("hideContactsTab", \.hideContactsTab),
        Binding("hideCallsTab", \.hideCallsTab),
        Binding("hideTabLabels", \.hideTabTitles),
        Binding("hideSearchBar", \.hideSearchButton)
    ]

    public static func tabs(_ value: WhiteGramTabSettings) -> WhiteGramTabSettings { return apply(value, tabBindings) }
    public static func saveTabs(_ value: WhiteGramTabSettings) { save(value, tabBindings) }

    private static let storyBindings: [Binding<WhiteGramStorySettings>] = [
        Binding("hideStories", \.hideStories),
        Binding("disableSwipeToRecordStory", \.disableStoryRecordingSwipe)
    ]

    public static func stories(_ value: WhiteGramStorySettings) -> WhiteGramStorySettings { return apply(value, storyBindings) }
    public static func saveStories(_ value: WhiteGramStorySettings) { save(value, storyBindings) }

    private static let folderBindings: [Binding<WhiteGramChatFolderSettings>] = [
        Binding("foldersAtBottom", \.foldersAtBottom)
    ]

    public static func folders(_ value: WhiteGramChatFolderSettings) -> WhiteGramChatFolderSettings { return apply(value, folderBindings) }
    public static func saveFolders(_ value: WhiteGramChatFolderSettings) { save(value, folderBindings) }

    private static let otherBindings: [Binding<WhiteGramOtherSettings>] = [
        Binding("translateMessagesEnabled", \.autoTranslate),
        Binding("forceDeviceMicrophone", \.forceDeviceMicrophone),
        Binding("hideGalleryCamera", \.hideCameraInGallery)
    ]

    public static func other(_ value: WhiteGramOtherSettings) -> WhiteGramOtherSettings { return apply(value, otherBindings) }

    private static let menuBindings: [WhiteGramContextMenuOption: String] = [
        .settingsSavedMessages: "hideFavorites", .settingsRecentCalls: "hideRecentCalls",
        .settingsDevices: "hideDevices", .settingsChatFolders: "hideFolders",
        .settingsPremium: "hidePremium", .settingsStars: "hideStars",
        .settingsBusiness: "hideBusiness", .settingsGifts: "hideSendGift",
        .settingsHelp: "hideSupport", .settingsFAQ: "hideFAQ", .settingsFeatures: "hideTips"
    ]

    public static func menu(_ values: [WhiteGramContextMenuOption: Bool]) -> [WhiteGramContextMenuOption: Bool] {
        var values = values
        let preferences = WhitegramPreferences.values()
        for (option, key) in menuBindings {
            if let hidden = preferences[key] as? Bool { values[option] = !hidden }
        }
        return values
    }

    public static func saveMenu(_ option: WhiteGramContextMenuOption, enabled: Bool) {
        if let key = menuBindings[option] { WhitegramPreferences.set(!enabled, for: key) }
    }
}
