import Foundation
import XCTest
@testable import TelegramCore

final class WhitegramTranslationTests: XCTestCase {
    func testLateResultCannotApproveNewDraftOrRequest() {
        let guardState = WhitegramTranslationDraftGuard<String>()
        let old = guardState.begin("first")
        let current = guardState.begin("second")
        XCTAssertFalse(guardState.finish(old, snapshot: "first"))
        XCTAssertTrue(guardState.isCurrent(current, snapshot: "second"))
        XCTAssertTrue(guardState.finish(current, snapshot: "second"))
        XCTAssertFalse(guardState.isReviewed("second"))
        guardState.markForReview("translated second")
        XCTAssertTrue(guardState.isReviewed("translated second"))
        XCTAssertFalse(guardState.isReviewed("second"))
    }

    func testChangedContextAndCancellationInvalidateApproval() {
        let guardState = WhitegramTranslationDraftGuard<String>()
        let id = guardState.begin("chat1/reply1/text")
        XCTAssertTrue(guardState.observe("chat1/reply2/text"))
        XCTAssertFalse(guardState.finish(id, snapshot: "chat1/reply1/text"))
        guardState.markForReview("chat1/reply2/translation")
        XCTAssertFalse(guardState.observe("chat2/reply2/translation"))
        XCTAssertFalse(guardState.isReviewed("chat1/reply2/translation"))
        let cancelled = guardState.begin("draft")
        guardState.cancel()
        XCTAssertFalse(guardState.isPending)
        XCTAssertFalse(guardState.finish(cancelled, snapshot: "draft"))
    }

    func testTargetSelectionDoesNotInventEnglishAndNormalizesSupportedCodes() {
        let supported = ["ru", "en", "pt", "no"]
        let defaults = WhitegramTranslationSettings(values: [:])
        XCTAssertFalse(defaults.hasGlobalTarget)
        XCTAssertEqual(defaults.resolvedTarget(baseLanguage: "ru-raw", supportedLanguages: supported), "ru")
        XCTAssertEqual(WhitegramTranslationSettings.supportedCode("pt_BR", in: supported), "pt")
        XCTAssertEqual(WhitegramTranslationSettings.supportedCode("nb-NO", in: supported), "no")
        let configured = WhitegramTranslationSettings(values: ["translationTargetLang": "EN"])
        XCTAssertEqual(configured.resolvedTarget(baseLanguage: "ru", supportedLanguages: supported), "en")
        XCTAssertNil(WhitegramTranslationSettings(values: ["translationTargetLang": "unsupported"]).resolvedTarget(baseLanguage: "ru", supportedLanguages: supported))
    }

    func testOriginalFlagsAreStrictAndExplicitCurrentValuesWin() {
        let original: [String: Any] = ["wg_translateBeforeSending": true, "wg_localTranslationEnabled": true, "wg_showSiriTranscriptionWarning": true]
        let migrated = WhitegramTranslationSettings(values: [:], originalValues: original)
        XCTAssertTrue(migrated.beforeSending)
        XCTAssertTrue(migrated.localTranslationRequested)
        XCTAssertTrue(migrated.siriWarningRequested)
        let current = WhitegramTranslationSettings(values: ["translateBeforeSending": false, "localTranslationEnabled": 1, "showSiriTranscriptionWarning": false], originalValues: original)
        XCTAssertFalse(current.beforeSending)
        XCTAssertFalse(current.localTranslationRequested)
        XCTAssertFalse(current.siriWarningRequested)
    }

    func testUTF16EntityRangesRejectSplitSurrogatesAndOutOfBounds() {
        let text = "a😀b"
        for range in [0..<1, 1..<3, 3..<4, 0..<4] {
            XCTAssertTrue(WhitegramTranslationTextRules.validRange(range, in: text), "\(range)")
        }
        for range in [0..<2, 1..<2, 2..<3, 2..<4, -1..<1, 0..<5, 1..<1, 4..<4, 0..<Int.max, Int.min..<Int.max] {
            XCTAssertFalse(WhitegramTranslationTextRules.validRange(range, in: text), "\(range)")
        }
        XCTAssertFalse(WhitegramTranslationTextRules.validRange(0..<1, in: ""))
        XCTAssertFalse(WhitegramTranslationTextRules.hasText(" \n\t"))
    }

    func testUTF16EntityRangesAcceptScalarBoundariesWithinGraphemes() {
        let text = "e\u{301}👩\u{200d}💻🇺🇦"
        for range in [0..<1, 1..<2, 2..<4, 4..<5, 5..<7, 7..<9, 9..<11, 0..<11] {
            XCTAssertTrue(WhitegramTranslationTextRules.validRange(range, in: text), "\(range)")
        }
        for range in [2..<3, 3..<4, 5..<6, 6..<7, 7..<8, 8..<9, 9..<10, 10..<11] {
            XCTAssertFalse(WhitegramTranslationTextRules.validRange(range, in: text), "\(range)")
        }
    }
}
