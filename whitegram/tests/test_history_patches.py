"""Read-only history patch/API/syntax checks; run native archive tests separately.

Set WHITEGRAM_ASSEMBLED_SOURCE to the assembled, pinned 12.9.2 checkout.
All patch writes go to MemoryRoot, never to either source worktree.
"""

import collections
import difflib
import os
from pathlib import Path
import subprocess
import sys
import threading
import unittest

sys.dont_write_bytecode = True
OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))

from history_patches import apply_history_patches
from validate_port import errors


SOURCE = os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE")
PIN = "6ad963e5b62d354da79040f388ae2b9132fb17b8"
STATE = "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift"
DELETE = "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessagesInteractively.swift"
EDIT = "submodules/TelegramCore/Sources/PendingMessages/RequestEditMessage.swift"
MENU = "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
PATHS = (STATE, DELETE, EDIT, MENU)
MEDIA_GUARD = " || WhitegramHistoryStore.hasMediaChanges(previousMessage.media, updatedMedia)"


class MemoryFile:
    def __init__(self, root, path):
        self.root, self.path = root, path

    def read_text(self, encoding):
        return self.root.files[self.path].decode(encoding).replace("\r\n", "\n")

    def write_bytes(self, data):
        self.root.files[self.path] = data
        self.root.writes.append(self.path)
        return len(data)


class MemoryRoot:
    def __init__(self, files):
        self.files = {path: value.encode("utf-8") for path, value in files.items()}
        self.writes = []

    def __truediv__(self, path):
        return MemoryFile(self, path)

    def text(self, path):
        return self.files[path].decode("utf-8")

    def texts(self):
        return {path: self.text(path) for path in self.files}


def parse_sources(sources):
    """The native parser needs a larger stack for Telegram's generated functions."""
    from tree_sitter import Language, Parser
    import tree_sitter_swift

    result, failures = {}, []

    def parse():
        try:
            parser = Parser(Language(tree_sitter_swift.language()))
            result.update({name: errors(parser, text.encode("utf-8")) for name, text in sources.items()})
        except Exception as error:
            failures.append(error)

    threading.stack_size(64 * 1024 * 1024)
    worker = threading.Thread(target=parse)
    worker.start()
    worker.join()
    if failures:
        raise failures[0]
    return result


@unittest.skipUnless(SOURCE, "set WHITEGRAM_ASSEMBLED_SOURCE for native source integration")
class HistoryPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(SOURCE)
        cls.pristine = {
            path: subprocess.check_output(["git", "-C", str(cls.source), "show", f"{PIN}:{path}"]).decode("utf-8")
            for path in PATHS
        }
        cls.assembled = {path: (cls.source / path).read_text(encoding="utf-8") for path in PATHS}

    def test_pristine_native_sources_accept_every_hook(self):
        root = MemoryRoot(self.pristine)
        report = apply_history_patches(root)
        self.assertEqual(set(root.writes), set(PATHS))
        self.assertEqual(report["messageHistoryContextMenu"], [MENU])
        self.assertEqual(root.text(STATE).count(MEDIA_GUARD), 1)
        self.assertEqual(root.text(EDIT).count(MEDIA_GUARD), 4)

    def test_second_pass_is_byte_identical_without_writes(self):
        for files in (self.pristine, self.assembled):
            with self.subTest(source="pristine" if files is self.pristine else "assembled"):
                root = MemoryRoot(files)
                report = apply_history_patches(root)
                first = dict(root.files)
                root.writes.clear()
                self.assertEqual(apply_history_patches(root), report)
                self.assertEqual(root.files, first)
                self.assertEqual(root.writes, [])

    def test_legacy_text_only_hooks_upgrade_without_duplicate_capture(self):
        root = MemoryRoot(self.pristine)
        apply_history_patches(root)
        legacy = root.texts()
        for path in (STATE, EDIT):
            legacy[path] = legacy[path].replace(MEDIA_GUARD, "")
        upgraded = MemoryRoot(legacy)
        apply_history_patches(upgraded)
        self.assertEqual(upgraded.files, root.files)
        self.assertEqual(set(upgraded.writes), {STATE, EDIT})
        assembled = MemoryRoot(self.assembled)
        apply_history_patches(assembled)
        self.assertEqual(assembled.text(EDIT).count("capture(previousMessage, event: .edited"), 4)

    def test_upstream_mutation_and_resource_cleanup_code_is_preserved(self):
        root = MemoryRoot(self.pristine)
        apply_history_patches(root)
        for path in PATHS:
            with self.subTest(path=path):
                diff = difflib.SequenceMatcher(a=self.pristine[path].splitlines(), b=root.text(path).splitlines(), autojunk=False)
                self.assertFalse([tag for tag, *_ in diff.get_opcodes() if tag in ("replace", "delete")])
        state = root.text(STATE)
        deletion = state.split("case let .DeleteMessages(ids):", 1)[1].split("case let .DeleteMessagesWithGlobalIds(ids):", 1)[0]
        self.assertLess(deletion.index("WhitegramHistoryStore.capture"), deletion.index("_internal_deleteMessages("))
        global_deletion = state.split("case let .DeleteMessagesWithGlobalIds(ids):", 1)[1]
        self.assertLess(global_deletion.index("WhitegramHistoryStore.capture"), global_deletion.index("var resourceIds"))
        local = root.text(DELETE)
        self.assertLess(local.index("WhitegramHistoryStore.capture"), local.index("_internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: messageIds.map"))

    def test_all_four_edit_response_variants_compare_media_before_update(self):
        root = MemoryRoot(self.pristine)
        apply_history_patches(root)
        value = root.text(EDIT)
        for name in ("updateEditMessage", "updateNewMessage", "updateEditChannelMessage", "updateNewChannelMessage"):
            with self.subTest(response=name):
                block = value.split(f"case .{name}(let data):", 1)[1].split("return .update(", 1)[0]
                self.assertIn(MEDIA_GUARD, block)
                self.assertIn("capture(previousMessage, event: .edited", block)
                self.assertLess(block.index("updatedMedia = previousMessage.media"), block.index("capture(previousMessage, event: .edited"))

    def test_context_menu_targets_clicked_message_and_dismisses_before_navigation(self):
        root = MemoryRoot(self.pristine)
        apply_history_patches(root)
        value = root.text(MENU)
        self.assertIn("import SettingsUI\n", value)
        block = value.split("let historyTitle =", 1)[1].split("let isMigrated:", 1)[0]
        self.assertIn("messageId: message.id", block)
        self.assertLess(block.index("dismiss(completion:"), block.index("pushViewController("))
        self.assertNotIn("snapshot(", block)
        self.assertNotIn("WhitegramPreferences", block)
        self.assertIn("message.id.namespace == Namespaces.Message.Cloud && message.id.peerId.namespace != Namespaces.Peer.SecretChat && !isAction && !isEmbeddedMode", value)
        opened = (self.source / "submodules/TelegramUI/Sources/Chat/ChatControllerOpenMessageContextMenu.swift").read_text(encoding="utf-8")
        self.assertIn("updatedMessages.insert(message, at: 0)", opened)
        self.assertIn("messages: updatedMessages", opened)

    def test_missing_or_ambiguous_final_menu_anchor_aborts_all_writes(self):
        anchor = "        let isMigrated: Bool\n"
        for replacement in ("", anchor + anchor):
            files = dict(self.pristine)
            files[MENU] = files[MENU].replace(anchor, replacement)
            root = MemoryRoot(files)
            before = dict(root.files)
            with self.assertRaisesRegex(ValueError, "messageHistoryContextMenu"):
                apply_history_patches(root)
            self.assertEqual(root.files, before)
            self.assertEqual(root.writes, [])

    def test_partial_legacy_upgrade_is_rejected_without_writing(self):
        root = MemoryRoot(self.pristine)
        apply_history_patches(root)
        files = root.texts()
        files[EDIT] = files[EDIT].replace(MEDIA_GUARD, "", 1)
        root = MemoryRoot(files)
        with self.assertRaisesRegex(ValueError, "expected 4 anchors"):
            apply_history_patches(root)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.texts(), files)

    def test_drifted_installed_capture_is_not_duplicated(self):
        root = MemoryRoot(self.pristine)
        apply_history_patches(root)
        files = root.texts()
        for path, before, after in (
            (STATE, 'if WhitegramPreferences.bool("saveChatHistory")', 'if WhitegramPreferences.bool("unexpectedKey")'),
            (EDIT, "mediaBoxPath: postbox.mediaBox.basePath", "mediaBoxPath: unexpectedPath"),
            (MENU, '"Message history"', '"Different history action"'),
        ):
            with self.subTest(path=path):
                drifted = dict(files)
                drifted[path] = drifted[path].replace(before, after)
                attempt = MemoryRoot(drifted)
                with self.assertRaises(ValueError):
                    apply_history_patches(attempt)
                self.assertEqual(attempt.writes, [])
                self.assertEqual(attempt.texts(), drifted)

    def test_crlf_and_unrelated_source_are_preserved_on_replay(self):
        files = {path: text.replace("\n", "\r\n") for path, text in self.pristine.items()}
        files["submodules/SettingsUI/Sources/ParentOwned.swift"] = "// Unrelated source\r\n"
        root = MemoryRoot(files)
        apply_history_patches(root)
        root.writes.clear()
        self.assertEqual(root.text("submodules/SettingsUI/Sources/ParentOwned.swift"), files["submodules/SettingsUI/Sources/ParentOwned.swift"])
        apply_history_patches(root)
        self.assertEqual(root.writes, [])

    def test_patched_native_sources_introduce_no_swift_parser_diagnostics(self):
        root = MemoryRoot(self.assembled)
        apply_history_patches(root)
        sources = {f"before:{path}": value for path, value in self.assembled.items()}
        sources.update({f"after:{path}": root.text(path) for path in PATHS})
        parsed = parse_sources(sources)
        for path in PATHS:
            baseline = collections.Counter(item["text"] for item in parsed[f"before:{path}"])
            current = collections.Counter(item["text"] for item in parsed[f"after:{path}"])
            self.assertFalse(current - baseline, f"{path}: {current - baseline}")

    def test_media_and_list_apis_match_inspected_upstream_signatures(self):
        paths = {
            "submodules/TelegramCore/Sources/TelegramEngine/Utils/EnginePostboxCoding.swift": ("public typealias EngineRawMedia = Media", "public typealias EngineRawMessage = Message"),
            "submodules/TelegramCore/Sources/SyncCore/SyncCore_Namespaces.swift": ("public static let Cloud: Int32 = 0",),
            "submodules/TelegramCore/Sources/SyncCore/SyncCore_EditedMessageAttribute.swift": ("public let date: Int32", "var editedTime: Int32?"),
            "submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramMediaFile.swift": ("public let size: Int64?", "public var fileName: String?", "case Video(duration: Double, size: PixelDimensions, flags: TelegramMediaVideoFlags, preloadSize: Int32?, coverTime: Double?, videoCodec: String?)", "case Audio(isVoice: Bool, duration: Int, title: String?, performer: String?, waveform: Data?)", "case ImageSize(size: PixelDimensions)"),
            "submodules/TelegramCore/Sources/TelegramEngine/Peers/Peer.swift": ("public extension EnginePeer", "var debugDisplayTitle: String"),
            "submodules/ItemListUI/Sources/Items/ItemListDisclosureItem.swift": ("case multilineDetailText", "additionalDetailLabel: String? = nil"),
        }
        for path, signatures in paths.items():
            value = (self.source / path).read_text(encoding="utf-8")
            for signature in signatures:
                with self.subTest(path=path, signature=signature):
                    self.assertIn(signature, value)


class HistorySourceTests(unittest.TestCase):
    def test_all_production_and_native_test_swift_sources_parse(self):
        files = sorted((OVERLAY / "cleanroom").glob("WhitegramHistory*.swift")) + sorted((OVERLAY / "tests/history").glob("*.swift"))
        self.assertGreaterEqual(len(files), 7)
        parsed = parse_sources({str(path): path.read_text(encoding="utf-8") for path in files})
        for path, diagnostics in parsed.items():
            with self.subTest(path=path):
                self.assertEqual(diagnostics, [])

    def test_store_is_foundation_only_and_uses_account_scoped_identity_and_files(self):
        store = (OVERLAY / "cleanroom/WhitegramHistoryStore.swift").read_text(encoding="utf-8")
        self.assertNotIn("import Postbox", store)
        self.assertIn("AccountKey(directory: directory.path, accountId: accountId)", store)
        self.assertIn('"whitegram-history-\\(accountId)-v1.json"', store)
        self.assertIn("guard entry.accountId == self.accountId", store)
        self.assertIn("guard archive.accountId == self.accountId", store)
        self.assertIn("Self.maximumArchiveBytes + 1", store)
        capture = (OVERLAY / "cleanroom/WhitegramHistoryCapture.swift").read_text(encoding="utf-8")
        self.assertIn("cloudNamespace: Namespaces.Message.Cloud", capture)
        self.assertNotIn("mediaBox.resourceData", capture)
        self.assertNotIn("storeResourceData", capture)

    def test_scoped_clear_and_export_use_the_same_query_as_visible_entries(self):
        controller = (OVERLAY / "cleanroom/WhitegramHistoryController.swift").read_text(encoding="utf-8")
        self.assertIn("self.query.apply(to: self.records)", controller)
        self.assertIn("self?.store.clear(matching: query)", controller)
        self.assertIn("self.store.export(matching: query)", controller)
        clear = controller.split("private func clear()", 1)[1].split("private func export()", 1)[0]
        self.assertLess(clear.index("let query = self.query"), clear.index("UIAlertController("))
        self.assertNotIn("self?.query", clear)
        self.assertNotIn("self.limit", clear)
        self.assertIn("whitegramMessageHistoryController(context: AccountContext, messageId: EngineMessage.Id)", controller)
        self.assertIn("namespace: messageId.namespace, id: messageId.id", controller)


if __name__ == "__main__":
    unittest.main()
