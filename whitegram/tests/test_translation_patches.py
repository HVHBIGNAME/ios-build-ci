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
from translation_patches import CONTROLLER, HISTORY, NODE, SCREEN, STATE, TRANSLATION_RUNTIME_FILES, translation_patches


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
        self.assertEqual(set(first), {NODE, CONTROLLER, HISTORY, STATE, SCREEN})
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


if __name__ == "__main__":
    unittest.main()
