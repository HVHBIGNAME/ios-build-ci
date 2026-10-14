"""Check profile rendering filters and their installer composition."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from profile_appearance_patches import DATA, PANES, ITEMS, HEADER, PROFILE_APPEARANCE_RUNTIME_FILES, apply_profile_appearance_patches
from test_history_patches import MemoryRoot, PIN, parse_sources

ROOT = Path(__file__).resolve().parents[1]


class ProfileAppearanceSourceTests(unittest.TestCase):
    def test_runtime_sources_parse(self):
        for path, errors in parse_sources({name: (ROOT / "cleanroom" / name).read_text(encoding="utf-8") for name in PROFILE_APPEARANCE_RUNTIME_FILES}).items():
            self.assertEqual(errors, [], path)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class ProfileAppearancePatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        root = os.environ["WHITEGRAM_ASSEMBLED_SOURCE"]
        cls.original = {path: subprocess.check_output(["git", "-C", root, "show", f"{PIN}:{path}"]).decode() for path in (DATA, PANES, ITEMS, HEADER)}

    def test_installation_replay_and_swift_syntax(self):
        root = MemoryRoot(self.original)
        report = apply_profile_appearance_patches(root)
        first = root.texts()
        root.writes.clear()
        self.assertEqual(apply_profile_appearance_patches(root), report)
        self.assertEqual(first, root.texts())
        self.assertEqual(root.writes, [])
        self.assertEqual(parse_sources(self.original), parse_sources(first))

    def test_hidden_gifts_keep_raw_data_and_repair_pending_initial_selection(self):
        root = MemoryRoot(self.original)
        apply_profile_appearance_patches(root)
        self.assertIn("self.whitegramOriginalPanes = availablePanes", root.text(DATA))
        self.assertIn("self.whitegramOriginalPanes.filter { $0 != .gifts }", root.text(DATA))
        self.assertIn("let profileGiftsContext: ProfileGiftsContext?", root.text(DATA))
        source = root.text(PANES)
        self.assertLess(source.index('if self.pendingSwitchToPaneKey == .gifts && !availablePanes.contains(.gifts)'), source.index("        let currentIndex: Int?"))
        self.assertIn("self.pendingSwitchToPaneKey = availablePanes.first", source)

    def test_username_is_own_profile_only_and_actions_use_real_account(self):
        root = MemoryRoot(self.original)
        apply_profile_appearance_patches(root)
        self.assertIn("isOwnProfile: user.id == context.account.peerId", root.text(ITEMS))
        self.assertIn("isOwnProfile: user.id == self.context.account.peerId", root.text(HEADER))
        self.assertIn("if let actualUsername = user.addressName { interaction.openUsername(actualUsername, true, progress) }", root.text(ITEMS))
        self.assertEqual(root.text(ITEMS).count("interaction.openQrCode()"), self.original[ITEMS].count("interaction.openQrCode()"))
        # Channel/group rendering follows the entire original branch.
        start = self.original[ITEMS].index("        let ItemUsername = 1")
        self.assertTrue(self.original[ITEMS][start:] in root.text(ITEMS))

    def test_missing_late_anchor_is_atomic(self):
        root = MemoryRoot(self.original)
        root.files[HEADER] = root.text(HEADER).replace("if let mainUsername = user.addressName, !mainUsername.isEmpty", "if changed").encode()
        initial = dict(root.files)
        with self.assertRaises(ValueError):
            apply_profile_appearance_patches(root)
        self.assertEqual(root.files, initial)
        self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
