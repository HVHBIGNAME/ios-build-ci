"""Exercise contact filtering against pinned sources without modifying the checkout."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from contact_visibility_patches import CONTACTS, CONTROLLER, apply_contact_visibility_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class ContactVisibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        cls.pristine = {path: subprocess.check_output(["git", "-C", str(source), "show", f"{PIN}:{path}"]).decode("utf-8")
                        for path in (CONTACTS, CONTROLLER)}
        cls.assembled = {path: (source / path).read_text(encoding="utf-8") for path in (CONTACTS, CONTROLLER)}

    def test_installation_and_replay_preserve_syntax_and_unrelated_sources(self):
        for sources in (self.pristine, self.assembled):
            with self.subTest(assembled=sources is self.assembled):
                root = MemoryRoot({**sources, "unrelated.swift": "// user work\r\n"})
                report = apply_contact_visibility_patches(root)
                self.assertEqual(report, {"hideCryptoBot": sorted((CONTACTS, CONTROLLER))})
                first = root.texts()
                root.writes.clear()
                self.assertEqual(apply_contact_visibility_patches(root), report)
                self.assertEqual(root.texts(), first)
                self.assertEqual(root.writes, [])
                self.assertEqual(first["unrelated.swift"], "// user work\r\n")
                self.assertEqual(parse_sources({path: first[path] for path in sources}), parse_sources(sources))

    def test_main_contacts_opt_in_but_search_and_selectors_keep_original_paths(self):
        root = MemoryRoot(self.pristine)
        apply_contact_visibility_patches(root)
        contacts = root.text(CONTACTS)
        self.assertIn("whitegramContactsVisibility: Bool = false", contacts)
        self.assertIn("whitegramContactsVisibility: true, displaySortOptions: true", root.text(CONTROLLER))
        # The entire search branch and entry/sort builder remain byte-identical.
        original = self.pristine[CONTACTS]
        start = original.index("        let transition")
        end = original.index("                struct TopPeer", start)
        self.assertIn(original[start:end], contacts)
        start = original.index("private func contactListNodeEntries(")
        end = original.index("private func preparedContactListNodeTransition", start)
        self.assertIn(original[start:end], contacts)
        self.assertIn("user.usernames.filter { $0.isActive }", contacts)
        self.assertIn("[user.username].compactMap { $0 }", contacts)
        self.assertIn("isBot: user.botInfo != nil", contacts)
        self.assertLess(contacts.index("let whitegramVisiblePeers"), contacts.index("if (authorizationStatus == .notDetermined || authorizationStatus == .denied) && peers.isEmpty"))

    def test_preference_updates_share_the_contact_subscription_and_capture_a_snapshot(self):
        root = MemoryRoot(self.pristine)
        apply_contact_visibility_patches(root)
        contacts = root.text(CONTACTS)
        self.assertIn('WhitegramAppearanceSettings.signal()\n                    |> map { $0.policy.isEnabled("hideCryptoBot") }\n                    |> distinctUntilChanged', contacts)
        self.assertIn("combineLatest(self.contactPeersViewPromise.get(), whitegramContactVisibility)", contacts)
        self.assertIn("let (view, whitegramHideCryptoBot) = whitegramContactView\n                        let signal = deferred", contacts)
        self.assertIn("whitegramContactVisibility = .single(false)", contacts)
        self.assertIn("self.disposable.dispose()", contacts)

    def test_late_anchor_drift_and_ambiguous_replay_do_not_write(self):
        root = MemoryRoot(self.pristine)
        root.files[CONTROLLER] = root.files[CONTROLLER].replace(b"displaySortOptions: true,", b"displaySortOptions: changed,")
        initial = dict(root.files)
        with self.assertRaises(ValueError):
            apply_contact_visibility_patches(root)
        self.assertEqual(root.files, initial)
        self.assertEqual(root.writes, [])
        for duplicate in (b"        isGroupInvitation: Bool,\n", b"        isGroupInvitation: Bool,\n        whitegramContactsVisibility: Bool = false,\n"):
            root = MemoryRoot(self.pristine)
            apply_contact_visibility_patches(root)
            root.files[CONTACTS] += duplicate
            root.writes.clear()
            initial = dict(root.files)
            with self.assertRaises(ValueError):
                apply_contact_visibility_patches(root)
            self.assertEqual(root.files, initial)
            self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
