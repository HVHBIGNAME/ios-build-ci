"""Check real translation call sites and replay without modifying the source tree."""

import os
from pathlib import Path
import sys
import unittest

from tree_sitter import Language, Parser
import tree_sitter_swift

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from source_patches import SourcePatches
from translation_patches import CONTROLLER, CORE, FILE_NODE, HISTORY, NODE, SCREEN, STATE, VIDEO_NODE, SEND_OPTIONS, SEND_PARAMS, SEND_SCREEN, TRANSLATION_RUNTIME_FILES, translation_patches


def errors(text):
    parser = Parser(Language(tree_sitter_swift.language()))
    data = text.encode("utf-8")
    stack = [parser.parse(data).root_node]
    result = []
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            result.append((node.type, data[node.start_byte:node.end_byte]))
        stack.extend(reversed(node.children))
    return result


class TranslationSourceTests(unittest.TestCase):
    def test_runtime_files_parse(self):
        files = [ROOT / "cleanroom" / name for name in TRANSLATION_RUNTIME_FILES]
        files += list((ROOT / "tests/translation").glob("*.swift"))
        for path in files:
            with self.subTest(name=path.name):
                self.assertEqual(errors(path.read_text(encoding="utf-8")), [])

    def test_draft_comparison_includes_context_and_reply_not_only_text(self):
        text = (ROOT / "cleanroom/WhitegramTranslationSendCoordinator.swift").read_text(encoding="utf-8")
        for field in ("accountPeerId", "chatLocation", "currentSendAsPeerId", "composeInputState", "replyMessageSubject", "forwardMessageIds", "editMessage", "mediaDraftState", "sendPaidMessageStars"):
            self.assertIn(field, text)
        self.assertNotIn("enqueueMessages(", text)
        self.assertNotIn("sendCurrentMessage(", text)
        self.assertIn("self.observe(state)", text)
        self.assertIn("private var progress: ViewController?", text)
        self.assertIn("snapshot.settings.reviewBeforeSending : snapshot.settings.showsSendAction", text)
        self.assertIn("self.scheduleExplicitSend(snapshot, current: current, send: sendTranslated)", text)
        self.assertIn("let state = current(), WhitegramTranslationDraftSnapshot(state) == snapshot", text)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class TranslationIntegrationTests(unittest.TestCase):
    def patches(self):
        return SourcePatches(Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"]))

    def test_native_integration_is_idempotent_and_preserves_syntax(self):
        patches = self.patches()
        translation_patches(patches)
        first = dict(patches.pending)
        translation_patches(patches)
        self.assertEqual(first, patches.pending)
        self.assertEqual(set(first), {NODE, CONTROLLER, HISTORY, STATE, SCREEN, CORE, FILE_NODE, VIDEO_NODE, SEND_OPTIONS, SEND_PARAMS, SEND_SCREEN})
        for path, text in first.items():
            with self.subTest(path=path):
                self.assertEqual(errors(text), errors(patches.original[path]))
                self.assertEqual((patches.root / path).read_text(encoding="utf-8"), patches.original[path])

    def test_intercept_precedes_native_enqueue_and_preserves_compose_context(self):
        patches = self.patches()
        translation_patches(patches)
        node = patches.pending[NODE]
        send = node[node.index("    func sendCurrentMessage("):]
        self.assertLess(send.index("whitegramTranslationSend.intercept"), send.index("var messages: [EnqueueMessage]"))
        self.assertIn("withUpdatedComposeInputState(replacement)", send)
        intercept = send[:send.index("var messages: [EnqueueMessage]")]
        self.assertNotIn("withUpdatedReplyMessageSubject(nil)", intercept)
        self.assertIn("cancelWhitegramTranslation()", patches.pending[CONTROLLER])

    def test_missing_and_ambiguous_late_target_fail_without_writes(self):
        base = self.patches()
        translation_patches(base)
        before = "        var toLanguage = toLanguage ?? baseLanguageCode\n"
        after = "        var toLanguage = toLanguage ?? whitegramTranslationTarget(defaultLanguage: baseLanguageCode)\n"
        original = base.original[SCREEN].replace(after, before)
        for broken in (original.replace(before, ""), original + before, base.pending[SCREEN] + before):
            patches = self.patches()
            patches.read(SCREEN)
            patches.pending[SCREEN] = broken
            with self.assertRaises(ValueError):
                translation_patches(patches)
            self.assertEqual((patches.root / SCREEN).read_text(encoding="utf-8"), base.original[SCREEN])

    def test_voice_gate_and_original_one_time_notice_are_at_native_consumers(self):
        patches = self.patches()
        translation_patches(patches)
        for path in (CORE, STATE, HISTORY):
            self.assertIn("if WhitegramTranslationSettings.current.translateTranscripts, let audioTranscription", patches.pending[path])
        for path in (FILE_NODE, VIDEO_NODE):
            text = patches.pending[path]
            self.assertEqual(text.count("WhitegramTranslationSettings.claimSiriWarning()"), 1)
            self.assertIn("if whiteGramAppleTranscription, self.transcribeDisposable == nil", text)
            self.assertIn("Siri / Dictation", text)
            self.assertIn("guard WhitegramTranslationSettings.current.transcriptionEnabled", text)
            self.assertIn("WhitegramTranslationSettings.current.usesAppleTranscription", text)
            self.assertIn("if whiteGramAppleTranscription {", text)
            self.assertIn("storeLocallyTranscribedAudio(", text)
        self.assertIn("if WhitegramTranslationSettings.current.translateTranscripts, let translateToLanguage", patches.pending[FILE_NODE])

    def test_apple_route_precedes_network_fallback_and_global_same_language_is_not_changed(self):
        patches = self.patches()
        translation_patches(patches)
        text = patches.pending[STATE]
        self.assertLess(text.index("if whitegramSettings.appleTranslationRequested"), text.index("switch whiteGramOtherSettings.translationService"))
        self.assertNotIn("engineExperimentalInternalTranslationService = ExperimentalGoogleTranslationServiceImpl()", text)
        screen = patches.pending[SCREEN]
        self.assertIn("if toLanguage == fromLanguage && !WhitegramTranslationSettings.current.hasGlobalTarget", screen)
        self.assertEqual(screen.count("self?.whitegramTranslationFailed = true"), 3)
        self.assertNotIn("return alternativeTranslateText(", screen)
        self.assertIn("settings.appleTranslationRequested && self.tone != .neutral", screen)
        self.assertIn("fromLang: fromLang)", screen)

    def test_original_send_option_carries_explicit_intent_and_selected_effect(self):
        patches = self.patches()
        translation_patches(patches)
        params = patches.pending[SEND_PARAMS]
        self.assertIn("whitegramTranslate: ((ChatSendMessageActionSheetController.SendParameters?) -> Void)? = nil", params)
        screen = patches.pending[SEND_SCREEN]
        self.assertEqual(screen.count('"messageAction.withTranslation"'), 1)
        self.assertIn("WhitegramTranslationSettings.current.showsSendAction", screen)
        self.assertIn("sendMessage.mediaPreview == nil, !sendMessage.attachment", screen)
        self.assertIn("translate(parameters)", screen)
        self.assertIn("parameters?.effect.flatMap(ChatSendMessageEffect.init)", patches.pending[SEND_OPTIONS])
        self.assertIn("sendTranslated:", patches.pending[NODE])

    def test_late_send_menu_anchor_failure_leaves_reference_untouched(self):
        patches = self.patches()
        original = patches.read(SEND_SCREEN)
        patches.pending[SEND_SCREEN] = original.replace('id: AnyHashable("schedule")', 'id: AnyHashable("renamed")')
        with self.assertRaises(ValueError):
            translation_patches(patches)
        for path in patches.original:
            self.assertEqual((patches.root / path).read_text(encoding="utf-8"), patches.original[path])


if __name__ == "__main__":
    unittest.main()
