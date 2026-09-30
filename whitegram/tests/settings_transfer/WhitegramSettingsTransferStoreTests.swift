import Foundation
import XCTest
@testable import TelegramCore
import TelegramUIPreferences

final class WhitegramSettingsTransferStoreTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private var ownedKeys = Set<String>()

    override func setUp() {
        super.setUp()
        ownedKeys = [WhitegramPreferences.storageKey, "WhitegramPrivacySettings.v1", "WhitegramArchiveTest-Unrelated", "geminiApiKey", "wg_geminiApiKey", "wg_groqApiKey", "wg_virusTotalApiKey", "wg_voiceChangerApiKey"]
        ownedKeys.formUnion(WhitegramSettingsArchiveMirrors.bindings.map { $0.store })
        ownedKeys.formUnion(WhitegramSettingsArchiveSchema.rules.keys.map { "wg_" + $0 })
        for key in ownedKeys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        _ = WhitegramPreferences.values()
    }

    override func tearDown() {
        for key in ownedKeys { UserDefaults.standard.set(saved[key], forKey: key) }
        _ = WhitegramPreferences.values()
        saved.removeAll()
        super.tearDown()
    }

    private func store(_ values: [String: Any], key: String = WhitegramPreferences.storageKey) throws {
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), forKey: key)
    }

    func testPartialImportPreservesLatestPrivacySecretsAndUnrelatedSettings() throws {
        try store(["ghostModeEnabled": true, "disableReadReceipts": true, "unrelatedSetting": "retained",
                   "geminiApiKey": "keep-secret", "pluginRuntime.permissions.1.plugin": ["messages": true]])
        let reviewed = try SettingsArchiveFixture.archive(["showFullViewCount": true])
        XCTAssertTrue(WhitegramPreferences.set(true, for: "disableStoryReadReceipts"))
        let result = try WhitegramSettingsArchiveStore.importSettings(reviewed)
        XCTAssertEqual(result.importedKeys, ["showFullViewCount"])
        XCTAssertTrue(WhitegramPreferences.bool("ghostModeEnabled"))
        XCTAssertTrue(WhitegramPreferences.bool("disableReadReceipts"))
        XCTAssertTrue(WhitegramPreferences.bool("disableStoryReadReceipts"))
        XCTAssertTrue(WhitegramPreferences.bool("showFullViewCount"))
        XCTAssertEqual(WhitegramPreferences.string("unrelatedSetting"), "retained")
        XCTAssertEqual(WhitegramPreferences.string("geminiApiKey"), "keep-secret")
        XCTAssertEqual(WhitegramPreferences.values()["pluginRuntime.permissions.1.plugin"] as? [String: Bool], ["messages": true])
        XCTAssertNil(WhitegramPreferences.values()["disableOnlineStatus"])
    }

    func testExportExcludesUnmigratedCredentialsAndUnrelatedDefaults() throws {
        try store(["ghostModeEnabled": true, "geminiEnabled": true, "geminiApiKey": ["invalidLegacyToken": "SECRET-MARKER"],
                   "groqApiKey": "SECRET-MARKER", "virusTotalApiKey": "SECRET-MARKER", "voiceChangerApiKey": "SECRET-MARKER",
                   "pluginRuntime.permissions.account.plugin": ["network": true], "apiSessionToken_42": "SECRET-MARKER",
                   "activeWhitegramAccountId": "SECRET-MARKER", "fontHistory": [["path": "SECRET-MARKER"]]])
        try store(["ghostModeEnabled": false, "geminiApiKey": "SECRET-MARKER"], key: "WhitegramPrivacySettings.v1")
        for key in ["geminiApiKey", "wg_geminiApiKey", "wg_groqApiKey", "wg_virusTotalApiKey", "wg_voiceChangerApiKey", "WhitegramArchiveTest-Unrelated"] {
            UserDefaults.standard.set("SECRET-MARKER", forKey: key)
        }
        let snapshot = try WhitegramSettingsArchiveStore.exportSettings(date: Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(snapshot.archive.values["ghostModeEnabled"] as? Bool, true)
        XCTAssertEqual(snapshot.archive.values["geminiEnabled"] as? Bool, true)
        let json = String(decoding: try snapshot.archive.encoded(), as: UTF8.self)
        for forbidden in ["SECRET-MARKER", "ApiKey", "permissions.account", "apiSessionToken", "activeWhitegramAccountId", "fontHistory", "WhitegramArchiveTest-Unrelated"] {
            XCTAssertFalse(json.contains(forbidden), forbidden)
        }
        XCTAssertNotNil(WhitegramPreferences.values()["geminiApiKey"])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "wg_geminiApiKey"), "SECRET-MARKER")
    }

    func testPublicMirrorsDecodeUsingActualPublicForkTypes() throws {
        var chat = WhiteGramChatSettings.defaultSettings
        chat.compactPinnedMessagesPanel = true
        chat.personalChatDoubleTapAction = .reply
        UserDefaults.standard.set(try JSONEncoder().encode(chat), forKey: WhitegramSettingsArchiveMirrors.chat)
        var folders = WhiteGramChatFolderSettings.defaultSettings
        folders.lastFolderId = 42
        UserDefaults.standard.set(try JSONEncoder().encode(folders), forKey: WhitegramSettingsArchiveMirrors.folders)
        let archive = try SettingsArchiveFixture.archive([
            "showTimestampSeconds": true, "disableChatSwipeOptions": true, "hideRecordButton": true,
            "stickerSizeScale": 0.6, "videoMessageCamera": 1, "hideContactsTab": true, "hideTabLabels": true,
            "hideStories": true, "disableSwipeToRecordStory": true, "hideFavorites": true,
            "foldersAtBottom": true, "public.folders.openLastFolder": true,
            "public.other.translationService": "telegram", "forceDeviceMicrophone": true,
            "musicEqualizerBands": [-2.5, 0.0, 1.25]
        ])
        _ = try WhitegramSettingsArchiveStore.importSettings(archive)
        let currentChat = WhiteGramChatSettings.current
        XCTAssertTrue(currentChat.showSecondsInMessageTimestamp)
        XCTAssertFalse(currentChat.chatSwipeOptions)
        XCTAssertFalse(currentChat.voiceMessageButton)
        XCTAssertEqual(currentChat.stickerSizePercent, 60)
        XCTAssertEqual(currentChat.videoMessageCamera, .back)
        XCTAssertEqual(currentChat.personalChatDoubleTapAction, .reply)
        XCTAssertTrue(currentChat.compactPinnedMessagesPanel)
        let rawChat = try JSONDecoder().decode(WhiteGramChatSettings.self, from: XCTUnwrap(UserDefaults.standard.data(forKey: WhitegramSettingsArchiveMirrors.chat)))
        XCTAssertEqual(rawChat, currentChat)
        XCTAssertTrue(WhiteGramTabSettings.current.hideContactsTab)
        XCTAssertTrue(WhiteGramTabSettings.current.hideTabTitles)
        XCTAssertTrue(WhiteGramStorySettings.current.hideStories)
        XCTAssertTrue(WhiteGramStorySettings.current.disableStoryRecordingSwipe)
        XCTAssertTrue(WhiteGramChatFolderSettings.current.foldersAtBottom)
        XCTAssertTrue(WhiteGramChatFolderSettings.current.openLastFolder)
        XCTAssertEqual(WhiteGramChatFolderSettings.current.lastFolderId, 42)
        XCTAssertFalse(WhiteGramContextMenuSettings.current.isEnabled(.settingsSavedMessages))
        XCTAssertEqual(WhiteGramOtherSettings.current.translationService, .telegram)
        XCTAssertTrue(WhiteGramOtherSettings.current.forceDeviceMicrophone)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "wg_showTimestampSeconds"))
        XCTAssertEqual(UserDefaults.standard.array(forKey: "wg_musicEqualizerBands") as? [Double], [-2.5, 0, 1.25])
    }

    func testPublicOnlyImportPreservesCanonicalFlagsAndDoubleTapStaysCoherent() throws {
        try store(["ghostModeEnabled": true, "disableReadReceipts": true, "doubleTapEditEnabled": false])
        _ = try WhitegramSettingsArchiveStore.importSettings(SettingsArchiveFixture.archive([
            "public.chat.personalChatDoubleTapAction": "edit", "public.contextMenu.privateCopy": false
        ]))
        XCTAssertTrue(WhitegramPreferences.bool("doubleTapEditEnabled"))
        XCTAssertEqual(WhiteGramChatSettings.current.personalChatDoubleTapAction, .edit)
        XCTAssertFalse(WhiteGramContextMenuSettings.current.isEnabled(.privateCopy))
        XCTAssertTrue(WhitegramPreferences.bool("ghostModeEnabled"))
        XCTAssertTrue(WhitegramPreferences.bool("disableReadReceipts"))
        XCTAssertNil(WhitegramPreferences.values()["public.chat.personalChatDoubleTapAction"])
        _ = try WhitegramSettingsArchiveStore.importSettings(SettingsArchiveFixture.archive(["public.chat.personalChatDoubleTapAction": "reply"]))
        XCTAssertFalse(WhitegramPreferences.bool("doubleTapEditEnabled"))
        XCTAssertEqual(WhiteGramChatSettings.current.personalChatDoubleTapAction, .reply)
        let exported = try WhitegramSettingsArchiveStore.exportSettings()
        XCTAssertEqual(exported.archive.values["public.chat.personalChatDoubleTapAction"] as? String, "reply")
        XCTAssertEqual(exported.archive.values["doubleTapEditEnabled"] as? Bool, false)
    }

    func testObserversSeeAllMirrorsAfterUnlockedCommitAndRepeatIsIdempotent() throws {
        var count = 0
        var chatNotifications = 0
        let observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { _ in
            count += 1
            XCTAssertTrue(WhiteGramTabSettings.current.hideCallsTab)
            XCTAssertTrue(WhiteGramChatSettings.current.showSecondsInMessageTimestamp)
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { _ = WhitegramPreferences.values(); semaphore.signal() }
            XCTAssertEqual(semaphore.wait(timeout: .now() + 2), .success, "Preference lock must be released before observer delivery")
        }
        let chatObserver = NotificationCenter.default.addObserver(forName: WhiteGramChatSettings.updatedNotification, object: nil, queue: nil) { _ in chatNotifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer); NotificationCenter.default.removeObserver(chatObserver) }
        let archive = try SettingsArchiveFixture.archive(["hideCallsTab": true, "showTimestampSeconds": true])
        _ = try WhitegramSettingsArchiveStore.importSettings(archive)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(chatNotifications, 1)
        _ = try WhitegramSettingsArchiveStore.importSettings(archive)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(chatNotifications, 1)
    }

    func testMalformedImportDoesNotMutateAnyStoreOrNotify() throws {
        try store(["ghostModeEnabled": true])
        let before = UserDefaults.standard.data(forKey: WhitegramPreferences.storageKey)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        for raw in [
            #"{"hideCallsTab":true,"voiceChangerPitch":999}"#,
            #"{"hideCallsTab":true,"wg_geminiApiKey":"secret"}"#,
            #"{"hideCallsTab":true,"ghostModeEnabled":0}"#
        ] {
            XCTAssertThrowsError(try WhitegramSettingsArchiveStore.importSettings(WhitegramSettingsArchive(data: SettingsArchiveFixture.raw(raw))))
            XCTAssertEqual(UserDefaults.standard.data(forKey: WhitegramPreferences.storageKey), before)
            XCTAssertNil(UserDefaults.standard.object(forKey: WhitegramSettingsArchiveMirrors.tabs))
            XCTAssertNil(UserDefaults.standard.object(forKey: "wg_hideCallsTab"))
        }
        XCTAssertEqual(notifications, 0)
    }

    func testCorruptTouchedPublicStoreRejectsBeforeCanonicalOrOtherMirrorWrites() throws {
        try store(["ghostModeEnabled": true])
        let corrupt = Data("{invalid".utf8)
        UserDefaults.standard.set(corrupt, forKey: WhitegramSettingsArchiveMirrors.chat)
        let before = UserDefaults.standard.data(forKey: WhitegramPreferences.storageKey)
        let archive = try SettingsArchiveFixture.archive(["hideCallsTab": true, "showTimestampSeconds": true])
        XCTAssertThrowsError(try WhitegramSettingsArchiveStore.importSettings(archive))
        XCTAssertEqual(UserDefaults.standard.data(forKey: WhitegramPreferences.storageKey), before)
        XCTAssertEqual(UserDefaults.standard.data(forKey: WhitegramSettingsArchiveMirrors.chat), corrupt)
        XCTAssertNil(UserDefaults.standard.object(forKey: WhitegramSettingsArchiveMirrors.tabs))
        XCTAssertNil(UserDefaults.standard.object(forKey: "wg_showTimestampSeconds"))
    }

    func testCorruptCanonicalOrLegacyStoreCannotBeSilentlyReplaced() throws {
        for key in [WhitegramPreferences.storageKey, "WhitegramPrivacySettings.v1"] {
            UserDefaults.standard.removeObject(forKey: WhitegramPreferences.storageKey)
            UserDefaults.standard.removeObject(forKey: "WhitegramPrivacySettings.v1")
            let corrupt = Data("[]".utf8)
            UserDefaults.standard.set(corrupt, forKey: key)
            XCTAssertThrowsError(try WhitegramSettingsArchiveStore.importSettings(SettingsArchiveFixture.archive(["showFullViewCount": true])))
            XCTAssertEqual(UserDefaults.standard.data(forKey: key), corrupt)
            XCTAssertNil(UserDefaults.standard.object(forKey: "wg_showFullViewCount"))
        }
    }

    func testLegacyBooleanStarCountsMigrateWithoutAffectingOtherFields() throws {
        for old in [false, true] {
            UserDefaults.standard.removeObject(forKey: "wg_localStarsCount")
            try store(["localStarsCount": old, "ghostModeEnabled": true, "particleMode": 1.5, "fontHistory": true])
            let current = WhitegramSettingsState.current
            XCTAssertEqual(current.localStarsCount, 0)
            XCTAssertTrue(current.ghostModeEnabled)
            XCTAssertEqual(current.particleMode, 0)
            XCTAssertEqual(current.fontHistory, [])
            let data = try XCTUnwrap(UserDefaults.standard.data(forKey: WhitegramPreferences.storageKey))
            XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["localStarsCount"] as? Bool, old, "Read migration must not overwrite storage")
        }
    }

    func testNumericStarMirrorSurvivesLegacyBooleanAndCurrentInt64RoundTrips() throws {
        let exact: Int64 = 9007199254740993
        UserDefaults.standard.set(exact, forKey: "wg_localStarsCount")
        try store(["localStarsCount": false, "disableReadReceipts": true])
        XCTAssertEqual(WhitegramSettingsState.current.localStarsCount, exact)
        XCTAssertTrue(WhitegramSettingsState.current.disableReadReceipts)
        _ = try WhitegramSettingsArchiveStore.importSettings(SettingsArchiveFixture.archive(["localStarsCount": Int64.max]))
        XCTAssertEqual(WhitegramSettingsState.current.localStarsCount, Int64.max)
        XCTAssertTrue(WhitegramSettingsState.current.disableReadReceipts)
        let exported = try WhitegramSettingsArchiveStore.exportSettings()
        XCTAssertEqual((exported.archive.values["localStarsCount"] as? NSNumber)?.int64Value, Int64.max)
        XCTAssertTrue(WhitegramSettingsState.current.save())
        XCTAssertEqual(WhitegramSettingsState.current.localStarsCount, Int64.max)
    }

    func testLegacyPrivacyChangesInvalidateCacheAndExplicitCurrentValuesWin() throws {
        try store(["showDeletedMessages": false])
        try store(["saveDeletedMessages": true, "ghostModeEnabled": false], key: "WhitegramPrivacySettings.v1")
        XCTAssertFalse(WhitegramPreferences.bool("ghostModeEnabled"))
        try store(["saveDeletedMessages": true, "ghostModeEnabled": true], key: "WhitegramPrivacySettings.v1")
        XCTAssertTrue(WhitegramPreferences.bool("ghostModeEnabled"))
        XCTAssertFalse(WhitegramPreferences.bool("showDeletedMessages"))
        _ = try WhitegramSettingsArchiveStore.importSettings(SettingsArchiveFixture.archive(["showFullViewCount": true]))
        XCTAssertTrue(WhitegramPreferences.bool("ghostModeEnabled"))
        XCTAssertFalse(WhitegramPreferences.bool("showDeletedMessages"))
    }

    func testCompactModeImportReportsItsExistingRestartRequirement() throws {
        let result = try WhitegramSettingsArchiveStore.importSettings(SettingsArchiveFixture.archive(["compactChatList": true]))
        XCTAssertTrue(result.restartRecommended)
        XCTAssertTrue(WhiteGramChatSettings.current.compactChatList)
    }
}
