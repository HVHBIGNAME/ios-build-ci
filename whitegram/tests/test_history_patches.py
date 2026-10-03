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
from history_patches import HISTORY_RUNTIME_FILES, DELETE_CORE, POSTBOX, ACCOUNT, ENTRIES, LIST, ITEM, STATUS, TEXT, _capture_patches, _message_menu_patch
from source_patches import SourcePatches
from validate_port import errors


SOURCE = os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE")
PIN = "6ad963e5b62d354da79040f388ae2b9132fb17b8"
STATE = "submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift"
DELETE = "submodules/TelegramCore/Sources/TelegramEngine/Messages/DeleteMessagesInteractively.swift"
EDIT = "submodules/TelegramCore/Sources/PendingMessages/RequestEditMessage.swift"
MENU = "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
PATHS = (STATE, DELETE, EDIT, MENU, DELETE_CORE, POSTBOX, ACCOUNT, ENTRIES, LIST, ITEM, STATUS, TEXT)
MEDIA_GUARD = " || WhitegramHistoryStore.hasMediaChanges(previousMessage.media, updatedMedia)"
ENTITY_GUARD = " || WhitegramHistoryRuntime.hasEntityChanges(previousMessage, message.attributes)"


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
        legacy_root = MemoryRoot(self.pristine)
        patches = SourcePatches(legacy_root)
        _capture_patches(patches)
        _message_menu_patch(patches)
        patches.write()
        legacy = legacy_root.texts()
        for path, media_box, expression in (
            (STATE, "mediaBox.basePath", "message.withUpdatedLocalTags(updatedLocalTags).withUpdatedFlags(updatedFlags).withUpdatedAttributes(updatedAttributes).withUpdatedMedia(updatedMedia)"),
            (EDIT, "postbox.mediaBox.basePath", "message.withUpdatedLocalTags(updatedLocalTags).withUpdatedFlags(updatedFlags).withUpdatedMedia(updatedMedia)"),
        ):
            wrapper = f"WhitegramHistoryRuntime.recordEdit(previous: previousMessage, updated: {expression}, accountPeerId: accountPeerId, mediaBoxPath: {media_box})"
            legacy[path] = legacy[path].replace(wrapper, expression).replace(MEDIA_GUARD, "").replace(ENTITY_GUARD, "")
        upgraded = MemoryRoot(legacy)
        apply_history_patches(upgraded)
        self.assertEqual(upgraded.files, root.files)
        self.assertEqual(set(upgraded.writes), set(PATHS) - {MENU})
        assembled = MemoryRoot(self.assembled)
        apply_history_patches(assembled)
        self.assertEqual(assembled.text(EDIT).count("capture(previousMessage, event: .edited"), 4)

    def test_upstream_mutation_and_resource_cleanup_code_is_preserved(self):
        root = MemoryRoot(self.pristine)
        apply_history_patches(root)
        for path in (STATE, DELETE, EDIT, DELETE_CORE):
            with self.subTest(path=path):
                for operation in ("mediaBox.removeCachedResources", "cloudChatAddRemoveMessagesOperation", "notifyDeletedMessages(", "transaction.setState(", "transaction.setPeerChatState("):
                    self.assertEqual(root.text(path).count(operation), self.pristine[path].count(operation))
        state = root.text(STATE)
        deletion = state.split("case let .DeleteMessages(ids):", 1)[1].split("case let .DeleteMessagesWithGlobalIds(ids):", 1)[0]
        self.assertLess(deletion.index("WhitegramHistoryStore.capture"), deletion.index("_internal_deleteMessages("))
        global_deletion = state.split("case let .DeleteMessagesWithGlobalIds(ids):", 1)[1]
        self.assertLess(global_deletion.index("WhitegramHistoryStore.capture"), global_deletion.index("WhitegramHistoryRuntime.prepareGlobalDeletion"))
        self.assertLess(global_deletion.index("WhitegramHistoryRuntime.prepareGlobalDeletion"), global_deletion.index("transaction.deleteMessagesWithGlobalIds"))
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
                self.assertIn(ENTITY_GUARD, block)
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
        with self.assertRaisesRegex(ValueError, "unrecognized or partial native edit hooks"):
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
            POSTBOX: ("public func withAllMessages(peerId: PeerId, namespace: MessageId.Namespace? = nil", "public func chatListGetAllPeerIds() -> [PeerId]", "public func getPreferencesEntry(key: ValueBoxKey)", "public func setPreferencesEntry(key: ValueBoxKey, value: PreferencesEntry?)"),
            "submodules/Postbox/Sources/Message.swift": ("public func withUpdatedStableVersion(stableVersion: UInt32) -> Message", "public init(_ info: MessageForwardInfo)", "public protocol MessageAttribute: AnyObject, PostboxCoding"),
            "submodules/Postbox/Sources/ValueBoxKey.swift": ("public init(_ value: String)",),
            "submodules/TelegramCore/Sources/SyncCore/SyncCore_AuthorizedAccountState.swift": ("public let peerId: PeerId",),
            "submodules/ItemListUI/Sources/ItemListController.swift": ("public var didAppear: ((Bool) -> Void)?",),
        }
        for path, signatures in paths.items():
            value = (self.source / path).read_text(encoding="utf-8")
            for signature in signatures:
                with self.subTest(path=path, signature=signature):
                    self.assertIn(signature, value)

    def test_retention_uses_native_ids_and_keeps_plugin_event_anchors(self):
        root = MemoryRoot(self.pristine)
        apply_history_patches(root)
        core = root.text(DELETE_CORE)
        self.assertIn("serverInitiated: Bool = true", core)
        self.assertLess(core.index("WhitegramHistoryRuntime.deletableIds"), core.index("var resourceIds: [MediaResourceId]"))
        self.assertIn("serverInitiated: false)", root.text(DELETE))
        self.assertIn("transaction.deleteMessagesWithGlobalIds(ids, forEachMedia:", root.text(STATE))
        self.assertIn("let removable = whitegramHistoryDeletableGlobalMessageIds(transaction: self, ids: messageIds)", root.text(POSTBOX))
        self.assertIn("postbox.deleteMessages(removable, forEachMedia: forEachMedia)", root.text(POSTBOX))
        self.assertEqual(core.count("WhitegramHistoryRuntime.observeBeforeClear("), 2)
        self.assertIn("message.forwardInfo?.author?.id == forwardAuthorId", core)
        self.assertIn("WhitegramHistoryRuntime.preserveMinimumAvailable(", root.text(STATE))

    def test_history_and_plugin_hooks_compose_in_both_orders_and_replay(self):
        from plugin_hook_patches import apply_plugin_hook_patches
        files = dict(self.pristine)
        for path in (
            "submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift",
            "submodules/TelegramCore/Sources/State/ApplyUpdateMessage.swift",
            "submodules/TelegramCore/Sources/Network/Network.swift",
            "submodules/TelegramUI/Sources/ChatController.swift",
            "submodules/TelegramUI/Sources/TelegramRootController.swift",
        ):
            files[path] = subprocess.check_output(["git", "-C", str(self.source), "show", f"{PIN}:{path}"]).decode("utf-8")
        outputs = []
        for functions in ((apply_history_patches, apply_plugin_hook_patches), (apply_plugin_hook_patches, apply_history_patches)):
            root = MemoryRoot(files)
            for function in functions: function(root)
            before = dict(root.files)
            root.writes.clear()
            for function in functions: function(root)
            self.assertEqual(root.files, before)
            self.assertEqual(root.writes, [])
            state = root.text(STATE)
            self.assertLess(state.index("WhitegramPluginHooks.deletingIds("), state.index("deletedMessageIds.append(contentsOf: ids.map { .messageId"))
            self.assertEqual(state.count("WhitegramPluginHooks.deleted(postbox:"), 1)
            outputs.append(before)
        self.assertEqual(outputs[0], outputs[1])

    def test_last_native_anchor_drift_aborts_all_source_writes(self):
        files = dict(self.pristine)
        anchor = "                var customTruncationToken: ((UIFont, Bool) -> NSAttributedString?)?\n"
        files[TEXT] = files[TEXT].replace(anchor, "")
        root = MemoryRoot(files)
        before = dict(root.files)
        with self.assertRaisesRegex(ValueError, "showEditedOriginalText"):
            apply_history_patches(root)
        self.assertEqual(root.files, before)
        self.assertEqual(root.writes, [])

    def test_inline_history_preserves_identity_and_refreshes_preferences(self):
        root = MemoryRoot(self.pristine)
        apply_history_patches(root)
        entries = root.text(ENTRIES)
        self.assertLess(entries.index("capture(entry.message"), entries.index("displayMessage(entry.message)"))
        self.assertLess(entries.index("shouldDisplay(entry.message"), entries.index("if groupMessages || reverseGroupedMessages"))
        self.assertIn("whitegramHistorySettingsSignal()", root.text(LIST))
        self.assertIn("didSet {", root.text(ITEM))
        self.assertIn("self.alpha = 1.0", root.text(ITEM))
        self.assertIn("WhitegramTranslationTextRules.validRange($0.range, in: original.text)", root.text(TEXT))
        self.assertIn("WhitegramTranslationTextRules.validRange(entity.range, in: originalText.string)", root.text(TEXT))
        self.assertNotIn("withUpdatedText", root.text(TEXT))


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
        clear = controller.split("private func clear()", 1)[1].split("private func export(", 1)[0]
        self.assertLess(clear.index("let query = self.query"), clear.index("UIAlertController("))
        self.assertNotIn("self?.query", clear)
        self.assertNotIn("self.limit", clear)
        self.assertIn("whitegramMessageHistoryController(context: AccountContext, messageId: EngineMessage.Id)", controller)
        self.assertIn("whitegramNativeMessageHistoryController(context: context, messageId: messageId)", controller)

    def test_all_runtime_files_and_menu_action_routes_are_owned_and_installable(self):
        for name, target in HISTORY_RUNTIME_FILES.items():
            self.assertTrue((OVERLAY / "cleanroom" / name).is_file(), name)
            self.assertTrue(target.startswith("submodules/"), target)
        controller = (OVERLAY / "cleanroom/WhitegramHistoryController.swift").read_text(encoding="utf-8")
        for action in ("clearDeletedCache", "clearEditedCache", "clearSavedChatHistory", "restoreChatsView", "exportDeletedBackup", "importDeletedBackup"):
            self.assertIn('"' + action + '"', controller)
        self.assertIn("whitegramHistoryActionController(", controller)

    def test_restore_has_account_validation_collision_checks_and_cancellation(self):
        value = (OVERLAY / "cleanroom/WhitegramHistoryOperations.swift").read_text(encoding="utf-8")
        self.assertIn("(transaction.getState() as? AuthorizedAccountState)?.peerId == accountPeerId", value)
        self.assertIn('entry.textTruncated != true', value)
        self.assertIn("if let current = transaction.getMessage(id)", value)
        self.assertIn("result.skippedLive += 1", value)
        self.assertIn("result.skippedExisting += 1", value)
        self.assertIn("result.skippedUnavailable += 1", value)
        self.assertIn("cancelled.swap(true); disposable.dispose()", value)
        self.assertNotIn("network.request", value)
        self.assertNotIn(".Unsent", value)
        self.assertNotIn("enqueueMessage", value)


if __name__ == "__main__":
    unittest.main()
