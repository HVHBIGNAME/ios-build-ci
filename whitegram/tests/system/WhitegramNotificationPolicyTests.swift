import Foundation
import TelegramCore
import XCTest

final class WhitegramNotificationPolicyTests: XCTestCase {
    func testOriginalDefaultsRequireOptInBeforeBackgroundAudio() {
        let settings = WhitegramNotificationSettings(values: [:])
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.persistent)
        XCTAssertTrue(settings.backgroundKeepAlive)
        XCTAssertFalse(settings.keepAlive(isInBackground: true))
        let enabled = WhitegramNotificationSettings(values: ["whitegramNotificationsEnabled": true])
        XCTAssertTrue(enabled.keepAlive(isInBackground: true))
        XCTAssertFalse(enabled.keepAlive(isInBackground: false))
    }

    func testExplicitOffSurvivesTheRecoveredBackgroundDefaultAndLegacyMirror() {
        let values: [String: Any] = ["whitegramNotificationsEnabled": true, "backgroundKeepAlive": false]
        let legacy: [String: Any] = ["wg_backgroundKeepAlive": true, "wg_whitegramNotificationsEnabled": false]
        let settings = WhitegramNotificationSettings(values: values, legacyValues: legacy)
        XCTAssertTrue(settings.enabled)
        XCTAssertFalse(settings.backgroundKeepAlive)
        XCTAssertFalse(settings.keepAlive(isInBackground: true))
    }

    func testLegacyPreferencesRemainReadableWithoutOverwritingCanonicalValues() {
        let legacy: [String: Any] = ["wg_whitegramNotificationsEnabled": true,
            "wg_persistentNotificationsEnabled": true, "wg_backgroundKeepAlive": false]
        let settings = WhitegramNotificationSettings(values: [:], legacyValues: legacy)
        XCTAssertTrue(settings.enabled)
        XCTAssertTrue(settings.persistent)
        XCTAssertFalse(settings.backgroundKeepAlive)
    }

    func testNumbersAndStringsAreNotMistakenForNotificationOptIn() {
        let invalidValues: [Any] = [1, "true", NSNull()]
        for value in invalidValues {
            let settings = WhitegramNotificationSettings(values: ["whitegramNotificationsEnabled": value,
                "persistentNotificationsEnabled": value, "backgroundKeepAlive": value])
            XCTAssertFalse(settings.enabled)
            XCTAssertFalse(settings.persistent)
            XCTAssertTrue(settings.backgroundKeepAlive)
        }
    }

    func testIncomingMessageGatesAndScheduledSelfChatException() {
        let settings = WhitegramNotificationSettings(values: ["whitegramNotificationsEnabled": true])
        func accepts(active: Bool = false, notify: Bool = true, incoming: Bool = true,
                     selfChat: Bool = false, scheduled: Bool = false, muted: Bool = false, restricted: Bool = false) -> Bool {
            return settings.shouldNotify(isActive: active, notify: notify, incoming: incoming,
                selfChat: selfChat, wasScheduled: scheduled, muted: muted, restricted: restricted)
        }
        XCTAssertTrue(accepts())
        XCTAssertFalse(accepts(active: true))
        XCTAssertFalse(accepts(notify: false))
        XCTAssertFalse(accepts(incoming: false))
        XCTAssertFalse(accepts(muted: true))
        XCTAssertFalse(accepts(restricted: true))
        XCTAssertFalse(accepts(selfChat: true))
        XCTAssertTrue(accepts(selfChat: true, scheduled: true))
        XCTAssertFalse(accepts(incoming: false, selfChat: true, scheduled: true))
    }

    func testAppLockAndHiddenPreviewsDoNotExposeMessageText() {
        XCTAssertEqual(WhitegramNotificationPreview.resolve(isLocked: false, displayPreviews: true, displayName: true), .full)
        XCTAssertEqual(WhitegramNotificationPreview.resolve(isLocked: true, displayPreviews: true, displayName: true), .senderOnly)
        XCTAssertEqual(WhitegramNotificationPreview.resolve(isLocked: false, displayPreviews: false, displayName: true), .senderOnly)
        for locked in [false, true] {
            for previews in [false, true] {
                XCTAssertEqual(WhitegramNotificationPreview.resolve(isLocked: locked, displayPreviews: previews, displayName: false), .hidden)
            }
        }
    }

    func testOriginalReplySubtitleTakesPrecedenceOverMention() {
        XCTAssertEqual(WhitegramNotificationText.subtitle(baseLanguage: "ru", replyToMe: true, mentioned: true), "↩︎ Ответ на ваше сообщение")
        XCTAssertEqual(WhitegramNotificationText.subtitle(baseLanguage: "en", replyToMe: true, mentioned: false), "↩︎ Replied to your message")
        XCTAssertEqual(WhitegramNotificationText.subtitle(baseLanguage: "ru", replyToMe: false, mentioned: true), "@ Упоминание")
        XCTAssertEqual(WhitegramNotificationText.subtitle(baseLanguage: "uk", replyToMe: false, mentioned: true), "@ Mentioned you")
        XCTAssertNil(WhitegramNotificationText.subtitle(baseLanguage: "en", replyToMe: false, mentioned: false))
    }

    func testCustomEmojiPresentationPreservesAlreadyQualifiedAndCombinedCharacters() {
        XCTAssertEqual(WhitegramNotificationText.emojiPresentation("❤", hasCustomEmoji: false), "❤")
        XCTAssertEqual(WhitegramNotificationText.emojiPresentation("❤", hasCustomEmoji: true), "❤️")
        let combined = "❤️ 👩‍💻 🇺🇦 😀 текст"
        XCTAssertEqual(WhitegramNotificationText.emojiPresentation(combined, hasCustomEmoji: true), combined)
    }

    func testOverlappingSpoilersCannotExposeTheBeginningAfterOffsetsShift() {
        XCTAssertEqual(WhitegramNotificationText.redactingSpoilers("0123456789abcdef", ranges: [0 ..< 10, 5 ..< 15]), "•••f")
        XCTAssertEqual(WhitegramNotificationText.redactingSpoilers("😀secret end", ranges: [2 ..< 8]), "😀••• end")
        XCTAssertEqual(WhitegramNotificationText.redactingSpoilers("secret", ranges: [-2 ..< 100]), "•••")
    }
}
