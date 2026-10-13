"""Real-source Unicode/formatting patch composition, replay, and syntax checks."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))
from text_processing_patches import COMPOSER, MEDIA, TEXT, TITLES, SNIPPETS, TEXT_PROCESSING_RUNTIME_FILES, apply_text_processing_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


class TextProcessingRuntimeTests(unittest.TestCase):
    def test_swift_runtime_and_native_regressions_parse(self):
        sources = {name: (OVERLAY / "cleanroom" / name).read_text(encoding="utf-8") for name in TEXT_PROCESSING_RUNTIME_FILES}
        sources["native-tests"] = (OVERLAY / "tests/localization/WhitegramTextSettingsTests.swift").read_text(encoding="utf-8")
        self.assertEqual(parse_sources(sources), {name: [] for name in sources})


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class TextProcessingPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        paths = (COMPOSER, MEDIA, TEXT, TITLES, SNIPPETS)
        cls.sources = {path: (root / path).read_text(encoding="utf-8") for path in paths}
        cls.pristine = {path: subprocess.check_output(["git", "-C", str(root), "show", f"{PIN}:{path}"]).decode("utf-8") for path in paths}

    def test_both_sources_install_and_replay_without_writes(self):
        for sources in (self.pristine, self.sources):
            root = MemoryRoot(sources)
            report = apply_text_processing_patches(root)
            first = root.texts()
            if sources is self.pristine:
                self.assertEqual(set(root.writes), set(sources))
            else:
                self.assertEqual(set(root.writes), {path for path in sources if first[path] != sources[path]})
            root.writes.clear()
            self.assertEqual(apply_text_processing_patches(root), report)
            self.assertEqual(root.texts(), first)
            self.assertEqual(root.writes, [])

    def test_all_caption_entities_and_text_share_the_same_transformation(self):
        root = MemoryRoot(self.sources)
        apply_text_processing_patches(root)
        media = root.text(MEDIA)
        self.assertEqual(media.count("let whitegramOutgoingText = WhitegramTextEntities.outgoing"), 6)
        self.assertEqual(media.count("text: whitegramOutgoingText.text,"), 12)
        self.assertNotIn(".message(text: text.string,", media)
        self.assertEqual(media.count("outgoing(text: text.string,"), 6)
        self.assertEqual(parse_sources(self.sources), parse_sources(root.texts()))

    def test_display_title_hook_does_not_change_compact_titles_or_sorting(self):
        root = MemoryRoot(self.sources)
        apply_text_processing_patches(root)
        before, after = self.sources[TITLES], root.text(TITLES)
        self.assertEqual(before.split("    func displayTitle(")[0], after.split("    func displayTitle(")[0])
        self.assertEqual(before.split("public extension EnginePeer.IndexName")[1], after.split("public extension EnginePeer.IndexName")[1])

    def test_missing_late_snippet_anchor_aborts_every_file(self):
        sources = dict(self.sources)
        sources[SNIPPETS] = sources[SNIPPETS].replace("let timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)", "let timestamp = changedTimestamp")
        root = MemoryRoot(sources)
        with self.assertRaises(ValueError):
            apply_text_processing_patches(root)
        self.assertEqual(root.texts(), sources)
        self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
