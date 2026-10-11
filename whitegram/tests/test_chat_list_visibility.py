"""Replay and scope regressions for chat-list visibility consumers."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chat_list_visibility_patches import CONTROLLER, TITLE, ENTRIES, NODE, apply_chat_list_visibility_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class ChatListVisibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sources = {path: subprocess.check_output(["git", "-C", os.environ["WHITEGRAM_ASSEMBLED_SOURCE"], "show", f"{PIN}:{path}"]).decode("utf-8")
                       for path in (CONTROLLER, TITLE, ENTRIES, NODE)}

    def test_proxy_filter_is_scoped_to_additional_proxy_entries(self):
        root = MemoryRoot(self.sources)
        apply_chat_list_visibility_patches(root)
        entries = root.text(ENTRIES)
        self.assertIn('case .proxy = item.promoInfo.content { return false }', entries)
        self.assertIn('return item.item.renderedPeer.peerId != state.hiddenPsaPeerId', entries)
        self.assertIn('pinnedIndexOffset += UInt16(filteredAdditionalItemEntries.count)', entries)
        self.assertIn('combineLatest(self.statePromise.get(), WhitegramAppearanceSettings.signal())', root.text(NODE))

    def test_title_restores_original_status_and_keeps_lock_and_proxy_actions(self):
        root = MemoryRoot(self.sources)
        apply_chat_list_visibility_patches(root)
        title = root.text(TITLE)
        self.assertIn('self.whitegramUnfilteredTitle = title', title)
        self.assertIn('self.setTitle(title, animated: false)', title)
        self.assertIn('removeObserver(observer)', title)
        for field in ('activity', 'hasProxy', 'connectsViaProxy', 'isPasscodeSet', 'isManuallyLocked'):
            self.assertEqual(title.count('self.title.' + field), self.sources[TITLE].count('self.title.' + field))
        self.assertIn('combineLatest(networkState, WhitegramAppearanceSettings.signal())', root.text(CONTROLLER))

    def test_replay_is_byte_identical_and_no_new_parser_errors(self):
        root = MemoryRoot(self.sources)
        report = apply_chat_list_visibility_patches(root)
        first = root.texts()
        root.writes.clear()
        self.assertEqual(apply_chat_list_visibility_patches(root), report)
        self.assertEqual(root.texts(), first)
        self.assertEqual(root.writes, [])
        self.assertEqual(parse_sources(self.sources), parse_sources(first))

    def test_late_anchor_drift_causes_no_partial_write(self):
        sources = dict(self.sources)
        sources[NODE] = sources[NODE].replace('            self.statePromise.get(),\n', '            renamedPromise.get(),\n')
        root = MemoryRoot(sources)
        with self.assertRaises(ValueError):
            apply_chat_list_visibility_patches(root)
        self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
