"""Read-only account integration checks against the pinned and assembled Telegram sources."""

import collections
import os
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from account_patches import (
    ACCOUNT, APPLICATION, CHAT, MANAGER, NETWORK, NOTIFICATIONS, SHARED,
    ACCOUNTS_RUNTIME_FILES, apply_account_patches,
)
from test_history_patches import MemoryRoot, parse_sources


SOURCE = os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE")
PIN = "6ad963e5b62d354da79040f388ae2b9132fb17b8"
PATHS = (ACCOUNT, APPLICATION, CHAT, MANAGER, NETWORK, NOTIFICATIONS, SHARED)


@unittest.skipUnless(SOURCE, "set WHITEGRAM_ASSEMBLED_SOURCE for account integration")
class AccountPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(SOURCE)
        cls.pristine = {path: subprocess.check_output(["git", "-C", str(cls.source), "show", f"{PIN}:{path}"]).decode("utf-8") for path in PATHS}
        cls.assembled = {path: (cls.source / path).read_text(encoding="utf-8") for path in PATHS}

    def test_pristine_and_assembled_hooks_and_replay(self):
        for files in (self.pristine, self.assembled):
            with self.subTest(source="pristine" if files is self.pristine else "assembled"):
                root = MemoryRoot(files)
                report = apply_account_patches(root)
                self.assertEqual(set(report), {"accountTransfer", "keepUnavailableAccounts", "accountSwitcherEnabled"})
                self.assertNotIn("let accountId = context.account.id\n        self.loggedOutDisposable", root.text(APPLICATION))
                changed = {path for path in PATHS if files[path] != root.text(path)}
                self.assertEqual(set(root.writes), changed)
                if files is self.pristine:
                    self.assertEqual(changed, set(PATHS))
                first = dict(root.files)
                root.writes.clear()
                self.assertEqual(apply_account_patches(root), report)
                self.assertEqual(root.files, first)
                self.assertEqual(root.writes, [])

    def test_final_anchor_failure_leaves_every_file_untouched(self):
        anchor = "        if let rightButton = self.rightButton {\n            result.append(rightButton)\n        }\n"
        for replacement in ("", anchor + anchor):
            files = dict(self.pristine)
            files[CHAT] = files[CHAT].replace(anchor, replacement)
            root = MemoryRoot(files)
            with self.assertRaises(ValueError):
                apply_account_patches(root)
            self.assertEqual(root.texts(), files)
            self.assertEqual(root.writes, [])

    def test_drifted_partial_hooks_are_rejected_before_write(self):
        root = MemoryRoot(self.pristine)
        apply_account_patches(root)
        original = root.texts()
        changes = [
            (SHARED, "supplementary: true, isSupportUser: false", "supplementary: false, isSupportUser: false"),
            (APPLICATION, "whitegramHandleUnavailableAccount(account: context.account", "whitegramHandleUnavailableAccount(account: differentAccount"),
            (NETWORK, "whitegramAuthorizationFailure?(error.errorDescription)", 'whitegramAuthorizationFailure?("unknown")'),
            (CHAT, 'AnyHashable("compose")', 'AnyHashable("wrong")'),
        ]
        for path, before, after in changes:
            with self.subTest(path=path):
                files = dict(original)
                files[path] = files[path].replace(before, after, 1)
                attempt = MemoryRoot(files)
                with self.assertRaises(ValueError):
                    apply_account_patches(attempt)
                self.assertEqual(attempt.writes, [])
                self.assertEqual(attempt.texts(), files)

    def test_request_and_response_hooks_compose_with_plugins_in_both_orders(self):
        from plugin_hook_patches import apply_plugin_hook_patches, plugin_hook_patches
        from source_patches import SourcePatches

        discovered = SourcePatches(self.source)
        plugin_hook_patches(discovered)
        files = dict(self.pristine)
        for path in discovered.original:
            files[path] = subprocess.check_output(["git", "-C", str(self.source), "show", f"{PIN}:{path}"]).decode("utf-8")
        outputs = []
        for functions in ((apply_account_patches, apply_plugin_hook_patches), (apply_plugin_hook_patches, apply_account_patches)):
            root = MemoryRoot(files)
            for function in functions:
                function(root)
            first = dict(root.files)
            root.writes.clear()
            for function in functions:
                function(root)
            self.assertEqual(root.files, first)
            self.assertEqual(root.writes, [])
            self.assertEqual(root.text(NETWORK).count("WhitegramPluginNativeInterception.response("), 2)
            self.assertEqual(root.text(NETWORK).count("whitegramAuthorizationFailure?(error.errorDescription)"), 2)
            outputs.append(first)
        self.assertEqual(outputs[0], outputs[1])

    def test_staging_is_excluded_but_not_destroyed(self):
        root = MemoryRoot(self.pristine)
        apply_account_patches(root)
        value = root.text(SHARED)
        block = value.split("for record in view.records {", 1)[1].split("let isLoggedOut", 1)[0]
        self.assertIn("if record.temporarySessionId != nil", block)
        self.assertNotIn("updateRecord", block)
        self.assertIn("rootPath: rootPath", value.split("self.whitegramOpenSessionAccount =", 1)[1].split("\n        }", 1)[0])

    def test_explicit_logout_and_user_account_deletion_remain_functional(self):
        root = MemoryRoot(self.pristine)
        apply_account_patches(root)
        value = root.text(APPLICATION)
        self.assertIn('deleteAccount(reason: "GDPR", password: nil)', value)
        self.assertIn("logoutFromAccount(id: accountId, accountManager: accountManager, alreadyLoggedOutRemotely: true)", value)
        self.assertIn("logoutFromAccount(id: strongSelf.context.account.id", value)
        manager = root.text(MANAGER)
        self.assertIn("WhitegramAccountFrozenStore.shared.clear(accountId: id.int64)", manager)
        self.assertIn("transaction.updateRecord(id", manager)

    def test_switcher_is_root_only_and_does_not_displace_compose(self):
        root = MemoryRoot(self.assembled)
        apply_account_patches(root)
        value = root.text(CHAT)
        self.assertIn('if self.rightButton?.id == AnyHashable("compose")', value)
        self.assertIn("if case .chatList(.root) = location {\n            self.whitegramAccountSwitcher", value)
        self.assertIn("result.append(rightButton)", value)
        self.assertIn("self.whitegramAccountSwitcher?.button", value)
        if "folderButton" in self.assembled[CHAT]:
            self.assertIn("result.append(folderButton)", value)

    def test_patched_swift_has_no_new_parser_diagnostics(self):
        root = MemoryRoot(self.assembled)
        apply_account_patches(root)
        sources = {"before:" + path: value for path, value in self.assembled.items()}
        sources.update({"after:" + path: root.text(path) for path in PATHS})
        parsed = parse_sources(sources)
        for path in PATHS:
            before = collections.Counter(item["text"] for item in parsed["before:" + path])
            after = collections.Counter(item["text"] for item in parsed["after:" + path])
            self.assertFalse(after - before, f"{path}: {after - before}")

    def test_consumed_native_api_signatures(self):
        expected = {
            "submodules/TelegramCore/Sources/Account/Account.swift": ["public func accountBackupData(postbox: Postbox)", "backupData: AccountBackupData?", "shouldKeepAutoConnection: Bool = true", "public let auxiliaryMethods: AccountAuxiliaryMethods"],
            "submodules/TelegramCore/Sources/AccountManager/AccountManagerImpl.swift": ["public let getRecords:", "public let updateRecord:", "public let temporarySessionId: Int64"],
            "submodules/TelegramCore/Sources/TelegramEngine/Auth/AuthTransfer.swift": [".authorization(authorizationData)", "authorizationData.user"],
            "submodules/TelegramApi/Sources/Api42.swift": ["static func importBotAuthorization(flags: Int32, apiId: Int32, apiHash: String, botAuthToken: String)", "static func getUsers(id: [Api.InputUser])"],
            "submodules/TelegramCore/Sources/UpdatePeers.swift": ["func updatePeers(transaction: Transaction, accountPeerId: PeerId, peers: AccumulatedPeers)"],
            "submodules/AccountContext/Sources/AccountContext.swift": ["var activeAccountsWithInfo:", "func switchToAccount(id: AccountRecordId"],
        }
        for path, anchors in expected.items():
            text = (self.source / path).read_text(encoding="utf-8")
            for anchor in anchors:
                with self.subTest(path=path, signature=anchor): self.assertIn(anchor, text)


class AccountSourceTests(unittest.TestCase):
    def test_runtime_files_exist_and_swift_sources_parse(self):
        paths = [OVERLAY / "cleanroom" / name for name in ACCOUNTS_RUNTIME_FILES]
        paths += sorted((OVERLAY / "tests/accounts").glob("*Tests.swift"))
        parsed = parse_sources({str(path): path.read_text(encoding="utf-8") for path in paths})
        for path, diagnostics in parsed.items():
            with self.subTest(path=path): self.assertEqual(diagnostics, [])

    def test_credentials_never_enter_log_or_analytics_calls(self):
        for name in ACCOUNTS_RUNTIME_FILES:
            value = (OVERLAY / "cleanroom" / name).read_text(encoding="utf-8")
            self.assertNotRegex(value, r"\b(?:print|NSLog|os_log|URLSession)\s*\(", name)
        native = (OVERLAY / "cleanroom/WhitegramAccountImport.swift").read_text(encoding="utf-8")
        self.assertIn("account.network.request((redacted.0, request.1, request.2)", native)
        self.assertNotIn("transaction.setCurrentId", native)
        self.assertNotIn("transaction.removeAuth", native)

    def test_no_auth_key_surrogate_or_unconditional_import_success(self):
        native = (OVERLAY / "cleanroom/WhitegramAccountImport.swift").read_text(encoding="utf-8")
        self.assertIn("Api.functions.users.getUsers(id: [.inputUserSelf])", native)
        self.assertIn("data.id == identity.userId", native)
        self.assertIn("data.flags & (1 << 14)", native)
        self.assertIn("record.temporarySessionId == accountManager.temporarySessionId", native)
        self.assertIn("whitegramRecordIdentity($0) == identity", native)
        self.assertIn("whitegramRollbackAccount", native)
        self.assertNotIn("Data(repeating: 0, count: 256)", native)


if __name__ == "__main__":
    unittest.main()
