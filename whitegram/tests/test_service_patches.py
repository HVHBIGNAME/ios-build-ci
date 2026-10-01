import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from history_patches import _message_menu_patch
from service_patches import MENU, service_patches
from source_patches import SourcePatches


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class ServiceMenuIntegrationTests(unittest.TestCase):
    def test_history_and_indicator_actions_compose_without_duplicate_or_implicit_request(self):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        patches = SourcePatches(root)
        _message_menu_patch(patches)
        service_patches(patches)
        once = dict(patches.pending)
        _message_menu_patch(patches)
        service_patches(patches)
        self.assertEqual(once, patches.pending)
        text = patches.pending[MENU]
        self.assertEqual(text.count("whitegramVirusTotalTargets(text:"), 1)
        self.assertEqual(text.count("whitegramMessageHistoryController("), 1)
        self.assertIn("targets: whitegramTargets", text)
        self.assertNotIn("whitegramLookupVirusTotalTarget(", text)
        self.assertEqual((root / MENU).read_text(encoding="utf-8"), patches.original[MENU])
