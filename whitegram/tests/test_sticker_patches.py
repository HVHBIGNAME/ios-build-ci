"""Exercise sticker limits and patch composition on the pinned Telegram sources."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sticker_patches import RECENT_TARGETS, SAVED, TOGGLE, apply_sticker_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class StickerPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = os.environ["WHITEGRAM_ASSEMBLED_SOURCE"]
        cls.sources = {
            path: subprocess.check_output(["git", "-C", root, "show", f"{PIN}:{path}"]).decode("utf-8")
            for path in (*RECENT_TARGETS, SAVED, TOGGLE)
        }

    def test_all_recent_insertion_paths_and_favorite_paths_are_connected(self):
        root = MemoryRoot(self.sources)
        apply_sticker_patches(root)
        for path, count in RECENT_TARGETS.items():
            self.assertEqual(root.text(path).count("WhitegramStickerSettings.current.recentLimit"), count)
            self.assertEqual(root.text(path).count("removeTailIfCountExceeds: 200)"), self.sources[path].count("removeTailIfCountExceeds: 200)"), "GIF behavior must retain its own limit")
        saved = root.text(SAVED)
        self.assertEqual(saved.count(", limit: limit)"), 3)
        self.assertIn("WhitegramStickerSettings.current.favoriteLimit(default: limit)", saved)
        self.assertIn("operation: .remove", saved)
        toggle = root.text(TOGGLE)
        self.assertIn("if WhitegramStickerSettings.current.unlimitedFavorites", toggle)
        self.assertIn("else if isPremium && items.count >= premiumLimitsConfiguration.maxFavedStickerCount", toggle)

    def test_second_pass_is_byte_identical_and_does_not_write(self):
        root = MemoryRoot(self.sources)
        report = apply_sticker_patches(root)
        first = root.texts()
        root.writes.clear()
        self.assertEqual(apply_sticker_patches(root), report)
        self.assertEqual(first, root.texts())
        self.assertEqual(root.writes, [])

    def test_late_anchor_failure_does_not_write_earlier_files(self):
        sources = dict(self.sources)
        sources[TOGGLE] = sources[TOGGLE].replace("if isPremium && items.count >=", "if unexpected && items.count >=")
        root = MemoryRoot(sources)
        with self.assertRaises(ValueError):
            apply_sticker_patches(root)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.texts(), sources)

    def test_swift_syntax_matches_baseline(self):
        root = MemoryRoot(self.sources)
        apply_sticker_patches(root)
        self.assertEqual(parse_sources(self.sources), parse_sources(root.texts()))


if __name__ == "__main__":
    unittest.main()
