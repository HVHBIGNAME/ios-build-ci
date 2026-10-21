"""Check authorization-state protection and local diagnostic hooks on pinned sources."""

import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from session_patches import AUTH, AUTHORIZATION, ACCOUNT, NETWORK, SHARED, APP, APPLICATION, apply_session_patches
from test_history_patches import MemoryRoot, PIN, parse_sources
from account_patches import apply_account_patches


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class SessionPatchTests(unittest.TestCase):
    def root(self):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        paths = {AUTH, AUTHORIZATION, ACCOUNT, NETWORK, SHARED, APP, APPLICATION}
        from account_patches import CHAT, MANAGER, NOTIFICATIONS
        paths.update((CHAT, MANAGER, NOTIFICATIONS))
        root = MemoryRoot({path: subprocess.check_output(["git", "-C", str(source), "show", f"{PIN}:{path}"]).decode("utf-8") for path in paths})
        apply_account_patches(root)
        return root

    def test_committed_state_guard_precedes_every_login_ui_write(self):
        root = self.root()
        apply_session_patches(root)
        setter = root.text(AUTH).split("public func setState(state: UnauthorizedAccountState)", 1)[1].split("|> ignoreValues", 1)[0]
        self.assertLess(setter.index("transaction.getState() is AuthorizedAccountState"), setter.index("transaction.setState(state)"))
        self.assertIn(".staleLoginWriteBlocked", setter)
        self.assertIn("return\n                }\n                transaction.setState(state)", setter)

    def test_hooks_replay_and_parse_without_mutating_authorization_requests(self):
        root = self.root()
        before = root.texts()
        report = apply_session_patches(root)
        first = root.texts()
        root.writes.clear()
        self.assertEqual(apply_session_patches(root), report)
        self.assertEqual(root.texts(), first)
        self.assertEqual(root.writes, [])
        original = before[AUTHORIZATION]
        diagnostic = "    WhitegramSessionDiagnostics.shared.record(.authorizationCommitted, datacenter: Int(account.masterDatacenterId))\n"
        self.assertEqual(root.text(AUTHORIZATION).replace(diagnostic, ""), original)
        for name, errors in parse_sources(first).items():
            self.assertEqual(errors, parse_sources({name: before[name]})[name], name)

    def test_missing_last_anchor_aborts_before_any_write(self):
        root = self.root()
        root.files[APPLICATION] = root.files[APPLICATION].replace(b"self.serviceNotificationEventsDisposable?.dispose()", b"changedDispose()")
        before = root.texts()
        root.writes.clear()
        with self.assertRaises(ValueError):
            apply_session_patches(root)
        self.assertEqual(root.texts(), before)
        self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
