"""Source integration for the original local shorten/expand interaction."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from shortening_patches import MENU, TEXT, apply_shortening_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class MessageShorteningPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = os.environ["WHITEGRAM_ASSEMBLED_SOURCE"]
        cls.sources = {
            path: subprocess.check_output(["git", "-C", root, "show", f"{PIN}:{path}"]).decode("utf-8")
            for path in (MENU, TEXT)
        }

    def test_menu_and_entity_safe_rendering_compose_and_replay(self):
        root = MemoryRoot(self.sources)
        report = apply_shortening_patches(root)
        menu = root.text(MENU)
        text = root.text(TEXT)
        self.assertIn("if shortened || (WhitegramPreferences.bool", menu, "Expansion remains reachable when the setting is disabled")
        self.assertIn("setShortened(postbox: context.account.postbox, id: message.id, shortened: !shortened)", menu)
        self.assertIn("rawText == item.message.text", text, "Do not truncate a translated or edited draft using the original entity offsets")
        self.assertIn("case .messageOptions = subject { whitegramCanShorten = false }", text)
        self.assertIn("WhitegramTranslationTextRules.validRange(range, in: prefix)", text)
        self.assertLess(text.index("WhitegramMessageShortening.prefix"), text.index("var formattedDateUpdatePeriod"))
        first = root.texts()
        root.writes.clear()
        self.assertEqual(apply_shortening_patches(root), report)
        self.assertEqual(root.texts(), first)
        self.assertEqual(root.writes, [])

    def test_changed_render_anchor_aborts_before_writes(self):
        sources = dict(self.sources)
        sources[TEXT] = sources[TEXT].replace("var formattedDateUpdatePeriod: Int32?", "var changedUpdatePeriod: Int32?")
        root = MemoryRoot(sources)
        with self.assertRaises(ValueError):
            apply_shortening_patches(root)
        self.assertEqual(root.writes, [])

    def test_both_transformed_sources_parse(self):
        root = MemoryRoot(self.sources)
        apply_shortening_patches(root)
        self.assertEqual(parse_sources(self.sources), parse_sources(root.texts()))


if __name__ == "__main__":
    unittest.main()
