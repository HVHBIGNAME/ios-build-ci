import Foundation
import XCTest
@testable import TelegramCore
import TelegramUIPreferences

final class WhitegramPrivacySettingsTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private var keys: [String] { [WhitegramPreferences.storageKey, "WhitegramPrivacySettings.v1", "wg_perChatGhost", "wg_unrelatedFeature"] + WhitegramContentSettings.originalDefaults.keys.map { "wg_" + $0 } }

    override func setUp() {
        for key in keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    override func tearDown() {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
        }
    }

    func testRecoveredDefaultAndLegacyMirrorPrecedence() {
        XCTAssertTrue(WhitegramContentSettings.bypassContentRestrictions)
        XCTAssertFalse(WhitegramContentSettings.readOnAction)
        UserDefaults.standard.set(true, forKey: "wg_readOnAction")
        XCTAssertTrue(WhitegramContentSettings.readOnAction)
        XCTAssertTrue(WhitegramContentSettings.set(false, for: "readOnAction"))
        UserDefaults.standard.set(true, forKey: "wg_readOnAction")
        XCTAssertFalse(WhitegramContentSettings.readOnAction)
        XCTAssertFalse(WhitegramPrivacySettings.current.readOnAction)
    }

    func testSettingsWritesPreserveOtherFieldsAndMirrorOriginalKeys() {
        XCTAssertTrue(WhitegramPreferences.set("retained", for: "unrelatedFeature"))
        XCTAssertTrue(WhitegramContentSettings.set(true, for: "saveProtectedContent"))
        XCTAssertEqual(WhitegramPreferences.string("unrelatedFeature"), "retained")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "wg_saveProtectedContent"))
        XCTAssertTrue(WhitegramPrivacySettings.current.saveProtectedContent)
    }

    func testIntegerIsNotAcceptedAsBooleanAndReadingDoesNotRewriteIt() {
        UserDefaults.standard.set(NSNumber(value: 1), forKey: "wg_readOnAction")
        XCTAssertFalse(WhitegramContentSettings.readOnAction)
        XCTAssertNil(UserDefaults.standard.data(forKey: WhitegramPreferences.storageKey))
    }

    func testReadOnActionDoesNotEnableTypingOrPresenceSuppression() {
        let settings = WhitegramPrivacySettings(readOnAction: true)
        XCTAssertFalse(settings.shouldSendReadReceipts)
        XCTAssertTrue(settings.shouldSendOnlineStatus)
        XCTAssertTrue(settings.shouldSendTypingStatus)
        let ghost = WhitegramPrivacySettings(ghostModeEnabled: true, alwaysOnline: true, readOnAction: true)
        XCTAssertFalse(ghost.shouldSendOnlineStatus)
        XCTAssertFalse(ghost.shouldSendReadReceipts)
    }

    func testReadOnActionDefersReceiptsButCannotOverrideGhostOrExplicitSuppression() {
        XCTAssertTrue(WhitegramContentSettings.set(true, for: "readOnAction"))
        var policy = WhitegramContentSettings.readPolicy(peerId: 100)
        XCTAssertTrue(policy.suppressAutomaticReceipts)
        XCTAssertFalse(policy.suppressActionReceipts)
        XCTAssertFalse(policy.suppressLocalHistoryRead)
        for key in ["ghostModeEnabled", "disableReadReceipts"] {
            XCTAssertTrue(WhitegramContentSettings.set(true, for: key))
            policy = WhitegramContentSettings.readPolicy(peerId: 100)
            XCTAssertTrue(policy.suppressActionReceipts)
            XCTAssertTrue(policy.suppressAutomaticReceipts)
            XCTAssertEqual(policy.suppressLocalHistoryRead, key == "ghostModeEnabled")
            XCTAssertTrue(WhitegramContentSettings.set(false, for: key))
        }
    }

    func testPerChatSuppressionNeverAffectsOtherPeers() {
        UserDefaults.standard.set(" 100, -99, invalid, 9223372036854775808 ", forKey: "wg_perChatGhost")
        XCTAssertEqual(WhitegramContentSettings.perChatGhostIds, [100, -99])
        XCTAssertTrue(WhitegramContentSettings.set(true, for: "readOnAction"))
        XCTAssertTrue(WhitegramContentSettings.readPolicy(peerId: 100).suppressActionReceipts)
        XCTAssertTrue(WhitegramContentSettings.readPolicy(peerId: -99).suppressLocalHistoryRead)
        XCTAssertFalse(WhitegramContentSettings.readPolicy(peerId: 101).suppressActionReceipts)
        XCTAssertTrue(WhitegramContentSettings.togglePerChatGhost(id: 100))
        XCTAssertEqual(WhitegramContentSettings.perChatGhostIds, [-99])
        XCTAssertEqual(UserDefaults.standard.string(forKey: "wg_perChatGhost"), "-99")
    }

    func testPerChatParserMatchesOriginalCommaAndWhitespaceContract() {
        XCTAssertEqual(WhitegramContentSettings.parsePerChatGhostIds(" 100,\t-99 ,+42,100,,9223372036854775807,-9223372036854775808 "), [100, -99, 42, Int64.max, Int64.min])
        XCTAssertEqual(WhitegramContentSettings.parsePerChatGhostIds("100;101,200 201,\n300,9223372036854775808,-9223372036854775809"), [])
    }

    func testOriginalRestrictionPolicyPreservesExcludedReasonsAndLegacyBypasses() {
        for enabled in [false, true] {
            XCTAssertTrue(WhitegramContentSettings.set(enabled, for: "bypassContentRestrictions"))
            for reason in ["child_abuse", "child_pornography", "csae", "csam", "CSAM"] {
                XCTAssertFalse(WhitegramContentSettings.shouldBypassRestriction(reason: reason), reason)
            }
            for reason in ["pornography", "tos_violation", "apple", "age_restriction", "APPLE"] {
                XCTAssertTrue(WhitegramContentSettings.shouldBypassRestriction(reason: reason), reason)
            }
            XCTAssertEqual(WhitegramContentSettings.shouldBypassRestriction(reason: "copyright"), enabled)
        }
    }

    func testStoryPromptMatchesOriginalIndependentPreferenceAndEnablesOnlyStoryReads() {
        XCTAssertFalse(WhitegramContentSettings.shouldSuggestStoryGhost)
        XCTAssertTrue(WhitegramContentSettings.set(true, for: "suggestGhostForStories"))
        XCTAssertTrue(WhitegramContentSettings.shouldSuggestStoryGhost)
        XCTAssertTrue(WhitegramContentSettings.set(true, for: "ghostModeEnabled"))
        XCTAssertTrue(WhitegramContentSettings.shouldSuggestStoryGhost)
        XCTAssertTrue(WhitegramContentSettings.set(false, for: "ghostModeEnabled"))
        XCTAssertTrue(WhitegramContentSettings.set(true, for: "disableStoryReadReceipts"))
        XCTAssertFalse(WhitegramContentSettings.shouldSuggestStoryGhost)
        XCTAssertFalse(WhitegramContentSettings.bool("ghostModeEnabled"))
        XCTAssertFalse(WhitegramContentSettings.bool("disableReadReceipts"))
    }

    func testConcurrentPerChatTogglesDoNotLoseOtherPeers() {
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            XCTAssertTrue(WhitegramContentSettings.togglePerChatGhost(id: Int64(index)))
        }
        XCTAssertEqual(WhitegramContentSettings.perChatGhostIds, Set((0 ..< 64).map(Int64.init)))
        XCTAssertFalse(WhitegramContentSettings.bool("ghostModeEnabled"))
    }
}
