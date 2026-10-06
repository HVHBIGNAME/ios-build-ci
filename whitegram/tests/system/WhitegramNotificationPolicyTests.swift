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
}
