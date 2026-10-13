"""Validate online-indicator installation against real, read-only Telegram sources."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))

from online_indicator_patches import HEADER, ONLINE_INDICATOR_RUNTIME_FILES, apply_online_indicator_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


class OnlineIndicatorRuntimeTests(unittest.TestCase):
    def test_runtime_swift_parses(self):
        sources = {name: (OVERLAY / "cleanroom" / name).read_text(encoding="utf-8") for name in ONLINE_INDICATOR_RUNTIME_FILES}
        self.assertEqual(parse_sources(sources), {name: [] for name in sources})


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class OnlineIndicatorPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        cls.pristine = subprocess.check_output(["git", "-C", str(root), "show", f"{PIN}:{HEADER}"]).decode("utf-8")
        cls.assembled = (root / HEADER).read_text(encoding="utf-8")

    def test_pristine_and_assembled_sources_install_and_replay_without_writes(self):
        for source in (self.pristine, self.assembled):
            with self.subTest(assembled=source == self.assembled):
                root = MemoryRoot({HEADER: source})
                self.assertEqual(apply_online_indicator_patches(root), {"showOnlineDotInChats": [HEADER]})
                self.assertEqual(root.writes, [] if "self.whitegramOnlineIndicator =" in source else [HEADER])
                first = root.texts()
                root.writes.clear()
                self.assertEqual(apply_online_indicator_patches(root), {"showOnlineDotInChats": [HEADER]})
                self.assertEqual(root.texts(), first)
                self.assertEqual(root.writes, [])

    def test_only_sender_avatar_header_is_modified(self):
        root = MemoryRoot({HEADER: self.pristine})
        apply_online_indicator_patches(root)
        boundary = "public final class ChatMessageAvatarHeaderNodeImpl:"
        original_prefix, _ = self.pristine.split(boundary, 1)
        patched_prefix, patched_header = root.text(HEADER).split(boundary, 1)
        self.assertEqual(original_prefix, patched_prefix, "Date and peer headers must not gain presence subscriptions")
        self.assertLess(patched_header.index("self.whitegramOnlineIndicator ="), patched_header.index("super.init("))
        self.assertLess(patched_header.index("addSubnode(self.avatarNode)"), patched_header.index("addSubnode(self.whitegramOnlineIndicator)"))
        self.assertEqual(parse_sources({HEADER: self.pristine}), parse_sources(root.texts()))

    def test_late_missing_anchor_aborts_all_writes(self):
        source = self.pristine.replace("transition.updateAlpha(node: self.avatarNode, alpha: isHidden ? 0.0 : 1.0)", "transition.updateAlpha(node: self.avatarNode, alpha: newVisibility)")
        root = MemoryRoot({HEADER: source})
        with self.assertRaises(ValueError):
            apply_online_indicator_patches(root)
        self.assertEqual(root.text(HEADER), source)
        self.assertEqual(root.writes, [])

    def test_ambiguous_target_aborts_all_writes(self):
        root = MemoryRoot({HEADER: self.pristine + self.pristine})
        with self.assertRaises(ValueError):
            apply_online_indicator_patches(root)
        self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
