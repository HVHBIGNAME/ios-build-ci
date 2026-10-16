"""Check both presence inputs, preservation of native merging and overlay replay."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from online_history_patches import ONLINE_HISTORY_RUNTIME_FILES, PEERS, apply_online_history_patches
from test_history_patches import MemoryRoot, PIN, parse_sources

ROOT = Path(__file__).resolve().parents[1]


class OnlineHistorySourceTests(unittest.TestCase):
    def test_runtime_sources_and_settings_routes_parse(self):
        names = list(ONLINE_HISTORY_RUNTIME_FILES) + ["WhitegramPortCapabilities.swift", "WhitegramGeneratedSettingsScreen.swift"]
        sources = {name: (ROOT / "cleanroom" / name).read_text(encoding="utf-8") for name in names}
        sources["WhitegramOnlineHistoryTests.swift"] = (ROOT / "tests/history/WhitegramOnlineHistoryTests.swift").read_text(encoding="utf-8")
        for name, errors in parse_sources(sources).items():
            self.assertEqual(errors, [], name)

    def test_runtime_is_installed_and_clear_uses_its_controller(self):
        installer = (ROOT / "compat-12.9.4.py").read_text(encoding="utf-8")
        self.assertIn("ONLINE_HISTORY_RUNTIME_FILES,", installer)
        self.assertIn("apply_history_patches, apply_online_history_patches,", installer)
        controller = (ROOT / "cleanroom/WhitegramGeneratedSettingsScreen.swift").read_text(encoding="utf-8")
        self.assertIn('case "onlineHistory": target = whitegramOnlineHistoryController(context: self.context, clearOnOpen: id == "onlineHistoryClear")', controller)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class OnlineHistoryPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        cls.original = subprocess.check_output(["git", "-C", str(source), "show", f"{PIN}:{PEERS}"]).decode()
        cls.assembled = (source / PEERS).read_text(encoding="utf-8")

    def test_both_inputs_install_and_replay_without_altering_merge_rules(self):
        for source in (self.original, self.assembled):
            root = MemoryRoot({PEERS: source})
            report = apply_online_history_patches(root)
            first = root.text(PEERS)
            self.assertEqual(first.count("WhitegramOnlineHistoryCapture.recordUsers("), 1)
            self.assertEqual(first.count("WhitegramOnlineHistoryCapture.record("), 1)
            original_without_hooks = "\n".join(line for line in first.split("\n") if "WhitegramOnlineHistoryCapture." not in line)
            source_without_hooks = "\n".join(line for line in source.split("\n") if "WhitegramOnlineHistoryCapture." not in line)
            self.assertEqual(original_without_hooks, source_without_hooks)
            root.writes.clear()
            self.assertEqual(apply_online_history_patches(root), report)
            self.assertEqual(root.text(PEERS), first)
            self.assertEqual(root.writes, [])
            self.assertEqual(parse_sources({PEERS: source}), parse_sources({PEERS: first}))

    def test_bad_second_anchor_aborts_first_patch_too(self):
        for replacement in ("changedNextFunction(", "updatePeerPresenceLastActivities(\n    })\n}\n\nfunc updatePeerPresenceLastActivities("):
            source = self.original.replace("updatePeerPresenceLastActivities(", replacement)
            root = MemoryRoot({PEERS: source})
            with self.assertRaises(ValueError):
                apply_online_history_patches(root)
            self.assertEqual(root.text(PEERS), source)
            self.assertEqual(root.writes, [])

    def test_drifted_installed_hook_is_rejected(self):
        root = MemoryRoot({PEERS: self.original})
        apply_online_history_patches(root)
        broken = root.text(PEERS).replace("acceptedPeerIds: Set(parsedPresences.keys)", "acceptedPeerIds: []", 1)
        root = MemoryRoot({PEERS: broken})
        with self.assertRaisesRegex(ValueError, "partial presence hook"):
            apply_online_history_patches(root)
        self.assertEqual(root.writes, [])

    def test_capture_uses_only_accepted_contact_statuses(self):
        capture = (ROOT / "cleanroom/WhitegramOnlineHistoryCapture.swift").read_text(encoding="utf-8")
        for guard in ("guard enabled", "peerId != accountPeerId", "Namespaces.Peer.CloudUser", "transaction.isPeerContact(peerId: peerId)"):
            self.assertIn(guard, capture)
        self.assertIn("case .userStatusOnline: isOnline = true", capture)
        self.assertIn("case .userStatusOffline: isOnline = false", capture)
        self.assertIn("default: continue", capture)
        self.assertIn("Date().timeIntervalSince1970", capture)
        self.assertNotIn("Timer", capture)
        self.assertNotIn("network.request", capture)


if __name__ == "__main__":
    unittest.main()
