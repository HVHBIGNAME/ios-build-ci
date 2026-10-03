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
        XCTAssertTrue(current.siriWarningRequested, "The original getter cannot be disabled by a stale generated default")
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

    func testSiriNoticeHasIndependentDismissalAndDefaultsOn() {
        let defaults = WhitegramTranslationSettings(values: [:])
        XCTAssertTrue(defaults.shouldShowSiriWarning)
        XCTAssertFalse(defaults.voiceTranslationRequested)
        XCTAssertFalse(defaults.appleTranslationRequested)
        XCTAssertFalse(defaults.reviewBeforeSending)
        let old = WhitegramTranslationSettings(values: [:], originalValues: ["wg_siriTranscriptionWarningDismissed": true, "wg_localTranslationEnabled": true])
        XCTAssertFalse(old.shouldShowSiriWarning)
        XCTAssertTrue(old.localTranslationRequested)
        XCTAssertFalse(old.appleTranslationRequested, "Original local means Google HTTP, not Apple")
        let disabled = WhitegramTranslationSettings(values: ["showSiriTranscriptionWarning": false])
        XCTAssertTrue(disabled.shouldShowSiriWarning, "Only the independent dismissal suppresses the original notice")
    }

    func testOriginalSendActionRequiresBothFlagsAndDoesNotEnableReviewMode() {
        XCTAssertFalse(WhitegramTranslationSettings(values: ["translateBeforeSending": true]).showsSendAction)
        XCTAssertFalse(WhitegramTranslationSettings(values: ["localTranslationEnabled": true]).showsSendAction)
        let original = WhitegramTranslationSettings(values: [:], originalValues: ["wg_localTranslationEnabled": true, "wg_translateBeforeSending": true])
        XCTAssertTrue(original.showsSendAction)
        XCTAssertFalse(original.reviewBeforeSending)
        let apple = WhitegramTranslationSettings(values: ["localTranslationEnabled": true, "translateBeforeSending": true, "translationUseApple": true])
        XCTAssertFalse(apple.showsSendAction)
        let review = WhitegramTranslationSettings(values: ["translationReviewBeforeSending": true])
        XCTAssertTrue(review.reviewBeforeSending)
        XCTAssertFalse(review.showsSendAction)
    }

    func testOriginalVoiceFlagSelectsAppleSpeechIndependentlyOfTextTranslation() {
        let enabled = WhitegramTranslationSettings(values: ["voiceTranslationEnabled": true, "translationTranslateTranscripts": false])
        XCTAssertTrue(enabled.transcriptionEnabled(nativeEnabled: false))
        XCTAssertTrue(enabled.usesAppleTranscription(nativeEnabled: false, appleSelected: false))
        XCTAssertFalse(enabled.translateTranscripts)
        let disabled = WhitegramTranslationSettings(values: [:])
        XCTAssertFalse(disabled.transcriptionEnabled(nativeEnabled: false))
        XCTAssertTrue(disabled.transcriptionEnabled(nativeEnabled: true))
        XCTAssertFalse(disabled.usesAppleTranscription(nativeEnabled: true, appleSelected: false))
        XCTAssertTrue(disabled.usesAppleTranscription(nativeEnabled: true, appleSelected: true))
        XCTAssertTrue(disabled.translateTranscripts, "Native completed-transcript translation stays available")
    }

    func testOutgoingAutomaticTargetMatchesOriginalDeviceAndDetectedLanguageRules() {
        let settings = WhitegramTranslationSettings(values: [:])
        let languages = ["en", "ru", "uk", "de"]
        func target(_ detected: String?, _ preferred: [String]) -> String? {
            settings.resolvedOutgoingTarget(detectedLanguage: detected, preferredLanguages: preferred, supportedLanguages: languages)
        }
        XCTAssertEqual(target("uk", ["ru-RU"]), "ru")
        XCTAssertEqual(target("ru", ["ru-RU"]), "en")
        XCTAssertEqual(target("en", ["en-US"]), "ru")
        XCTAssertEqual(target("de", ["de-DE"]), "en")
        XCTAssertEqual(target(nil, ["ru-RU"]), "en")
        XCTAssertEqual(target("uk", []), "en")
        let selected = WhitegramTranslationSettings(values: ["translationTargetLang": "de"])
        XCTAssertEqual(selected.resolvedOutgoingTarget(detectedLanguage: "de", preferredLanguages: ["en-US"], supportedLanguages: languages), "de")
        let invalid = WhitegramTranslationSettings(values: ["translationTargetLang": "unsupported"])
        XCTAssertNil(invalid.resolvedOutgoingTarget(detectedLanguage: "en", preferredLanguages: ["en"], supportedLanguages: languages))
    }

    func testSegmentedTranslationPreservesNestedFormattingURLAndWhitespace() throws {
        let text = "  Hello https://example.com 😀  "
        let ns = text as NSString
        let link = ns.range(of: "https://example.com")
        let linkRange = link.location..<(link.location + link.length)
        let ranges = [0..<ns.length, 2..<7, linkRange]
        let plan = try XCTUnwrap(WhitegramTranslationSegments(text: text, entityRanges: ranges, protectedRanges: [linkRange]))
        XCTAssertEqual(plan.requests, ["Hello", "😀"])
        let result = try XCTUnwrap(plan.assemble(["Привет", "😀"], entityRanges: ranges))
        XCTAssertEqual(result.text, "  Привет https://example.com 😀  ")
        XCTAssertEqual(result.ranges[0], 0..<result.text.utf16.count)
        XCTAssertEqual(result.ranges[1], 2..<8)
        XCTAssertEqual((result.text as NSString).substring(with: NSRange(location: result.ranges[2].lowerBound, length: result.ranges[2].count)), "https://example.com")
    }

    func testSegmentPlanRejectsSplitSurrogatesMissingResultsAndOversizedOutput() throws {
        XCTAssertNil(WhitegramTranslationSegments(text: "a😀b", entityRanges: [1..<2], protectedRanges: []))
        let plan = try XCTUnwrap(WhitegramTranslationSegments(text: "a😀b", entityRanges: [1..<3], protectedRanges: [1..<3]))
        XCTAssertEqual(plan.requests, ["a", "b"])
        XCTAssertNil(plan.assemble(["only one"], entityRanges: [1..<3]))
        XCTAssertNil(plan.assemble(["", "reply"], entityRanges: [1..<3]))
        XCTAssertNil(plan.assemble([String(repeating: "x", count: 16384), "b"], entityRanges: [1..<3]))
        let unchanged = try XCTUnwrap(plan.assemble(["x", "longer"], entityRanges: [1..<3]))
        XCTAssertEqual(unchanged.text, "x😀longer")
        XCTAssertEqual(unchanged.ranges, [1..<3])
    }

    func testSegmentPlanAcceptsScalarBoundariesInsideCombiningSequences() throws {
        let plan = try XCTUnwrap(WhitegramTranslationSegments(text: "e\u{301}", entityRanges: [1..<2], protectedRanges: []))
        XCTAssertEqual(plan.requests, ["e", "\u{301}"])
        let result = try XCTUnwrap(plan.assemble(["a", "\u{301}"], entityRanges: [1..<2]))
        XCTAssertEqual(result.text, "a\u{301}")
        XCTAssertEqual(result.ranges, [1..<2])
    }
}
