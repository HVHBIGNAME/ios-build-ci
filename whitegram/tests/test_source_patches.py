"""Regression checks for overlapping before/after anchors and replay."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from source_patches import SourcePatches
from test_history_patches import MemoryRoot


class SourcePatchReplacementTests(unittest.TestCase):
    before = "let unused = account.id\nobserve(account)\n"
    after = "observe(account)\n"

    def test_shortening_patch_removes_the_old_fragment_and_replays(self):
        for count in (1, 2):
            with self.subTest(count=count):
                root = MemoryRoot({"source.swift": "// Keep this line\n" + self.before * count})
                patches = SourcePatches(root)
                patches.replace("logout", "source.swift", self.before, self.after, count=count)
                report = patches.write()
                self.assertEqual(root.text("source.swift"), "// Keep this line\n" + self.after * count)
                self.assertEqual(root.writes, ["source.swift"])
                root.writes.clear()
                replay = SourcePatches(root)
                replay.replace("logout", "source.swift", self.before, self.after, count=count)
                self.assertEqual(replay.write(), report)
                self.assertEqual(root.writes, [])

    def test_expanding_patch_preserves_an_already_installed_fragment(self):
        root = MemoryRoot({"source.swift": self.before})
        patches = SourcePatches(root)
        patches.replace("logout", "source.swift", self.after, self.before)
        patches.write()
        self.assertEqual(root.text("source.swift"), self.before)
        self.assertEqual(root.writes, [])

    def test_shortening_patch_rejects_mixed_old_and_new_fragments(self):
        for count in (1, 2):
            with self.subTest(count=count):
                original = self.before + self.after
                root = MemoryRoot({"source.swift": original})
                patches = SourcePatches(root)
                with self.assertRaises(ValueError):
                    patches.replace("logout", "source.swift", self.before, self.after, count=count)
                self.assertEqual(patches.pending["source.swift"], original)
                self.assertEqual(root.writes, [])

    def test_shortening_patch_rejects_duplicate_unapplied_fragments(self):
        root = MemoryRoot({"source.swift": self.before * 2})
        patches = SourcePatches(root)
        with self.assertRaises(ValueError):
            patches.replace("logout", "source.swift", self.before, self.after)
        self.assertEqual(patches.pending["source.swift"], self.before * 2)
        self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
