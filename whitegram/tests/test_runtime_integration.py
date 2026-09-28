"""Read-only patch integration against WHITEGRAM_ASSEMBLED_SOURCE."""

import collections
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from history_patches import apply_history_patches
from build_patches import apply_build_patches
from runtime_patches import CORE, apply_fork_bindings, apply_privacy
from source_patches import SourcePatches


SOURCE = os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE")
OVERLAY = Path(__file__).resolve().parents[1]


def in_memory(root, files):
    patches = SourcePatches(root)
    patches.original.update(files)
    patches.pending.update(files)
    return patches


@unittest.skipUnless(SOURCE, "set WHITEGRAM_ASSEMBLED_SOURCE for source integration")
class PrivacyIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(SOURCE)
        cls.patches = SourcePatches(cls.root)
        apply_privacy(cls.patches)
        apply_fork_bindings(cls.patches)

    def test_pristine_target_accepts_privacy_hooks(self):
        # Privacy targets are stock Telegram files, unlike the added fork settings.
        discovered = SourcePatches(self.root)
        apply_privacy(discovered)
        originals = {
            path: subprocess.check_output(["git", "-C", str(self.root), "show", f"HEAD:{path}"]).decode("utf-8")
            for path in discovered.pending
        }
        fresh = in_memory(self.root, originals)
        apply_privacy(fresh)
        self.assertEqual(fresh.pending, discovered.pending)

    def test_second_pass_is_idempotent_without_writes(self):
        repeated = in_memory(self.root, self.patches.pending)
        apply_privacy(repeated)
        apply_fork_bindings(repeated)
        with patch.object(Path, "write_bytes") as writes:
            repeated.write()
        writes.assert_not_called()
        self.assertEqual(repeated.features, self.patches.features)

    def test_every_receipt_rpc_has_a_reviewed_owner(self):
        expression = re.compile(r"Api\.functions\.(messages|channels|stories)\.(read\w+|incrementStoryViews)\(")
        files = {path.relative_to(self.root).as_posix(): path.read_text(encoding="utf-8") for path in (self.root / CORE).rglob("*.swift")}
        files.update(self.patches.pending)
        files[CORE + "WhitegramGhost.swift"] = (OVERLAY / "cleanroom/WhitegramGhost.swift").read_text(encoding="utf-8")
        inventory = collections.Counter()
        for path, value in files.items():
            for _, method in expression.findall(value):
                if method != "readFeaturedStickers":
                    inventory[path.removeprefix(CORE)] += 1
        self.assertEqual(dict(inventory), {
            "State/AccountViewTracker.swift": 2,
            "State/ManagedSynchronizeConsumeMessageContentsOperations.swift": 2,
            "State/ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations.swift": 4,
            "State/ManagedSynchronizeViewStoriesOperations.swift": 1,
            "State/SynchronizePeerReadState.swift": 3,
            "TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift": 6,
            "TelegramEngine/Messages/MarkAllChatsAsRead.swift": 2,
            "TelegramEngine/Messages/ReplyThreadHistory.swift": 2,
            "TelegramEngine/Messages/Stories.swift": 1,
            "WhitegramGhost.swift": 2,
        })

    def test_both_personal_message_paths_keep_local_completion(self):
        value = self.patches.pending[CORE + "State/ManagedConsumePersonalMessagesActions.swift"]
        self.assertEqual(value.count("return WhitegramGhost.messageContentsRequest("), 2)
        self.assertEqual(value.count("return WhitegramGhost.channelContentsRequest("), 2)
        self.assertNotIn("network.request(Api.functions.messages.readMessageContents", value)
        self.assertNotIn("network.request(Api.functions.channels.readMessageContents", value)
        for action in ("consumeUnseenPersonalMessage", "readReactionOrPollVote"):
            self.assertEqual(value.count(f"transaction.setPendingMessageAction(type: .{action}, id: id, action: nil)"), 2)
        self.assertEqual(value.count("if let result = result {"), self.patches.original[CORE + "State/ManagedConsumePersonalMessagesActions.swift"].count("if let result = result {"))

    def test_discussion_and_saved_history_requests_are_individually_gated(self):
        value = self.patches.pending[CORE + "TelegramEngine/Messages/ApplyMaxReadIndexInteractively.swift"]
        lines = value.splitlines()
        for index, line in enumerate(lines):
            if "network.request(Api.functions.messages.read" in line:
                self.assertEqual(lines[index - 1].strip(), "if !WhitegramGhost.suppressReadReceipts {")
                self.assertEqual(lines[index + 1].strip(), "}")

    def test_bulk_loops_recheck_privacy_and_keep_operation_cleanup(self):
        path = CORE + "State/ManagedSynchronizeMarkAllUnseenPersonalMessagesOperations.swift"
        value = self.patches.pending[path]
        self.assertIn("if WhitegramGhost.suppressReadReceipts { return .single(nil) }\n            let filteredIds", value)
        self.assertEqual(value.count("let signal = deferred { () -> Signal<Api.messages.AffectedHistory?, MTRpcError> in\n        if WhitegramGhost.suppressReadReceipts { return .single(nil) }"), 2)
        self.assertEqual(value.count("transaction.operationLogRemoveEntry("), self.patches.original[path].count("transaction.operationLogRemoveEntry("))
        self.assertEqual(value.count("return (signal |> restart)"), 2)

    def test_secret_chat_receipts_preserve_protocol_sequence_slots(self):
        path = CORE + "State/ManagedSecretChatOutgoingOperations.swift"
        value = self.patches.pending[path]
        for layer in (46, 73, 101, 144):
            self.assertIn(f"return .layer{layer}(.decryptedMessageService(randomId: actionGloballyUniqueId, action: WhitegramGhost.suppressReadReceipts ? .decryptedMessageActionNoop :", value)
        self.assertIn("randomIds: WhitegramGhost.suppressReadReceipts ? [] : globallyUniqueIds", value)
        self.assertEqual(value.count("transaction.operationLogRemoveEntry("), self.patches.original[path].count("transaction.operationLogRemoveEntry("))
        enqueue = self.patches.pending[CORE + "TelegramEngine/Messages/MarkMessageContentAsConsumedInteractively.swift"]
        self.assertEqual(enqueue.count("!WhitegramGhost.suppressReadReceipts"), 3)
        self.assertIn("AutoremoveTimeoutMessageAttribute(timeout: timeout, countdownBeginTime: timestamp)", enqueue)
        self.assertIn("AutoclearTimeoutMessageAttribute(timeout: timeout, countdownBeginTime: timestamp)", enqueue)

    def test_changed_late_anchor_rejects_patch_without_writing(self):
        files = dict(self.patches.pending)
        path = CORE + "TelegramEngine/Messages/MarkMessageContentAsConsumedInteractively.swift"
        files[path] = files[path].replace("let layer = layer, !WhitegramGhost.suppressReadReceipts", "let layer = unexpectedLayer", 1)
        patches = in_memory(self.root, files)
        with patch.object(Path, "write_bytes") as writes:
            with self.assertRaisesRegex(ValueError, "secret-content-receipts"):
                apply_privacy(patches)
        writes.assert_not_called()

    def test_fork_preferences_initialize_before_application_ui(self):
        value = self.patches.pending["submodules/TelegramUI/Sources/AppDelegate.swift"]
        self.assertLess(value.index("WhitegramForkBridge.migrate()"), value.index("let (window, hostView) = nativeWindowHostView()"))
        self.assertIn("DispatchQueue.global(qos: .utility).async {\n            let _ = whitegramMigrateServiceCredentials()", value)


@unittest.skipUnless(SOURCE, "set WHITEGRAM_ASSEMBLED_SOURCE for source integration")
class HistoryIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(SOURCE)
        cls.patches = SourcePatches(cls.root)
        with patch("history_patches.SourcePatches", return_value=cls.patches), patch.object(Path, "write_bytes"):
            cls.report = apply_history_patches(cls.root)

    def test_local_and_remote_deletes_capture_before_removal(self):
        value = self.patches.pending[CORE + "State/AccountStateManagementUtils.swift"]
        block = value.split("case let .DeleteMessages(ids):", 1)[1].split("case let .DeleteMessagesWithGlobalIds(ids):", 1)[0]
        self.assertLess(block.index("WhitegramHistoryStore.capture(message, event: .deleted"), block.index("_internal_deleteMessages("))
        local = self.patches.pending[CORE + "TelegramEngine/Messages/DeleteMessagesInteractively.swift"]
        self.assertLess(local.index("WhitegramHistoryStore.capture(message, event: .deleted"), local.index("_internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: messageIds.map"))
        self.assertIn("if let accountPeerId = stateManager?.accountPeerId", local)

    def test_edit_responses_capture_previous_text_for_all_four_variants(self):
        value = self.patches.pending[CORE + "PendingMessages/RequestEditMessage.swift"]
        self.assertEqual(value.count("WhitegramHistoryStore.capture(previousMessage, event: .edited"), 4)
        for name in ("updateEditMessage", "updateNewMessage", "updateEditChannelMessage", "updateNewChannelMessage"):
            block = value.split(f"case .{name}(let data):", 1)[1].split("return .update(", 1)[0]
            self.assertIn("if previousMessage.text != message.text", block)
            self.assertIn("capture(previousMessage, event: .edited", block)

    def test_history_second_pass_does_not_write(self):
        repeated = in_memory(self.root, self.patches.pending)
        with patch("history_patches.SourcePatches", return_value=repeated), patch.object(Path, "write_bytes") as writes:
            report = apply_history_patches(self.root)
        writes.assert_not_called()
        self.assertEqual(report, self.report)


class MenuIntegrationTests(unittest.TestCase):
    def test_every_list_controller_imports_its_convenience_initializer(self):
        for path in (OVERLAY / "cleanroom").glob("*.swift"):
            value = path.read_text(encoding="utf-8")
            if "ItemListController(context:" in value:
                with self.subTest(path=path.name):
                    self.assertIn("import PresentationDataUtils\n", value)

    def test_implemented_menu_items_have_routes_and_visible_entries(self):
        catalog = (OVERLAY / "cleanroom/WhitegramMenuSection.swift").read_text(encoding="utf-8")
        menu = (OVERLAY / "cleanroom/WhitegramMainMenuController.swift").read_text(encoding="utf-8")
        implemented = set(re.findall(r'"(\w+)"', catalog.split("static let implemented:", 1)[1]))
        routes = set()
        for cases in re.findall(r'case ((?:"\w+"(?:, )?)+):', menu):
            routes.update(re.findall(r'"(\w+)"', cases))
        routes.update(re.findall(r'"(\w+)": \[\d', menu))
        self.assertEqual(routes, implemented)
        entries = set(re.findall(r'"(\w+)"', menu.split("private let whitegramAboutIds", 1)[1].split("private func whitegramSection", 1)[0]))
        entries.update(re.findall(r'"(\w+)"', menu.split('for id in ["publicSettings"', 1)[1].split("]", 1)[0]))
        entries.add("publicSettings")
        self.assertFalse(implemented - entries)
        self.assertIn("where WhitegramMenuCatalog.implemented.contains(id)", menu)
        self.assertNotIn("whitegramNotPortedController", menu)


@unittest.skipUnless(SOURCE, "set WHITEGRAM_ASSEMBLED_SOURCE for source integration")
class BuildIntegrationTests(unittest.TestCase):
    def test_native_rules_match_target_without_changing_rule_invocations(self):
        root = Path(SOURCE)
        patches = SourcePatches(root)
        with patch("build_patches.SourcePatches", return_value=patches), patch.object(Path, "write_bytes"):
            apply_build_patches(root)
        value = patches.pending["Telegram/BUILD"]
        original = patches.original["Telegram/BUILD"]
        upstream = subprocess.check_output(["git", "-C", str(root), "show", "HEAD:Telegram/BUILD"]).decode("utf-8")
        for repository, rule in (("rules_cc", "objc_library"), ("rules_shell", "sh_binary")):
            self.assertNotIn(f"@{repository}//", value)
            self.assertNotIn(f"@{repository}//", upstream)
            self.assertGreater(upstream.count(rule + "("), 0)
            self.assertEqual(value.count(rule + "("), original.count(rule + "("))
        repeated = in_memory(root, patches.pending)
        with patch("build_patches.SourcePatches", return_value=repeated), patch.object(Path, "write_bytes") as writes:
            apply_build_patches(root)
        writes.assert_not_called()


if __name__ == "__main__":
    unittest.main()
