"""Exercise system hooks without mutating the pinned, assembled Telegram tree."""

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from tree_sitter import Language, Parser
import tree_sitter_swift


OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))
from source_patches import SourcePatches
from system_patches import (
    APPLICATION_CONTEXT, APP_DELEGATE, SYSTEM_RUNTIME_FILES, WAKEUP, WINDOW,
    apply_system_patches, background_patches, notification_patches, ram_patches,
)


def syntax_errors(text, *, locations=False):
    parser = Parser(Language(tree_sitter_swift.language()))
    data = text.encode("utf-8")
    pending = [parser.parse(data).root_node]
    errors = []
    while pending:
        node = pending.pop()
        if node.type == "ERROR" or node.is_missing:
            location = f" at {node.start_point.row + 1}:{node.start_point.column + 1}" if locations else ""
            errors.append((node.type + location, data[node.start_byte:node.end_byte]))
        pending.extend(node.children)
    return errors


def stage(patches):
    ram_patches(patches)
    notification_patches(patches)
    background_patches(patches)


class SystemSourceTests(unittest.TestCase):
    def test_production_and_native_test_sources_parse(self):
        paths = [OVERLAY / "cleanroom" / name for name in SYSTEM_RUNTIME_FILES]
        paths += list((OVERLAY / "tests/system").glob("*Tests.swift"))
        for path in paths:
            with self.subTest(source=path.name):
                self.assertEqual([], syntax_errors(path.read_text(encoding="utf-8"), locations=True))

    def test_ram_and_foundation_policy_do_not_introduce_ui_dependency_cycles(self):
        for name, destination in SYSTEM_RUNTIME_FILES.items():
            text = (OVERLAY / "cleanroom" / name).read_text(encoding="utf-8")
            with self.subTest(source=name):
                if destination.startswith("submodules/TelegramCore/"):
                    self.assertNotIn("import UIKit", text)
                    self.assertNotIn("import Display", text)
                    self.assertNotIn("import TelegramUI", text)
                if destination.startswith("submodules/Display/"):
                    self.assertNotIn("import TelegramCore", text)
                    self.assertNotIn("UIApplication.shared", text)

    def test_system_controls_are_connected_to_original_keys_and_localized_information(self):
        capabilities = (OVERLAY / "cleanroom/WhitegramPortCapabilities.swift").read_text(encoding="utf-8")
        for row, key in (("showRAMUsage", "showRAMUsage"), ("whitegramNotifications", "whitegramNotificationsEnabled"),
                         ("persistentNotifications", "persistentNotificationsEnabled"), ("backgroundKeepAlive", "backgroundKeepAlive")):
            self.assertIn(f'"{row}": "{key}"', capabilities)
        self.assertIn('"persistentNotificationsInfo": "info.persistentNotifications"', capabilities)
        menu = (OVERLAY / "cleanroom/WhitegramMainMenuController.swift").read_text(encoding="utf-8")
        self.assertIn('"notifications": [11]', menu)
        state = (OVERLAY / "generated/WhitegramSettingsState.swift").read_text(encoding="utf-8")
        self.assertIn("public var backgroundKeepAlive: Bool = true", state)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE to the immutable baseline")
class SystemCompositionTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])

    def test_hooks_apply_and_replay_without_writing_the_reference(self):
        staged = SourcePatches(self.root)
        stage(staged)
        first = dict(staged.pending)
        stage(staged)
        self.assertEqual(first, staged.pending)
        for name, original in staged.original.items():
            self.assertEqual(original, (self.root / name).read_text(encoding="utf-8"))
        self.assertEqual(staged.pending[WINDOW].count("self.whitegramRAMUsage = WhitegramRAMUsageOverlay("), 1)
        self.assertEqual(staged.pending[APPLICATION_CONTEXT].count("self.whitegramLocalNotifications = WhitegramLocalNotifications("), 1)
        self.assertEqual(staged.pending[APP_DELEGATE].count("self.whitegramBackgroundKeepAlive = WhitegramBackgroundKeepAlive("), 1)

    def test_composed_swift_introduces_no_parser_errors(self):
        staged = SourcePatches(self.root)
        stage(staged)
        for name, text in staged.pending.items():
            with self.subTest(source=name):
                self.assertEqual(syntax_errors(staged.original[name]), syntax_errors(text))

    def test_background_network_work_is_scoped_to_primary_without_online_presence(self):
        staged = SourcePatches(self.root)
        stage(staged)
        result = staged.pending[WAKEUP]
        self.assertIn("((self.inForeground || self.whitegramKeepAlive) && primary)", result)
        self.assertIn("(self.whitegramKeepAlive && primary) || tasks.backgroundAudio", result)
        presence = [line.strip() for line in result.splitlines() if "shouldKeepOnlinePresence.set" in line]
        original = [line.strip() for line in staged.original[WAKEUP].splitlines() if "shouldKeepOnlinePresence.set" in line]
        self.assertEqual(presence, original)

    def test_notification_hook_reaches_each_received_batch_before_foreground_filter(self):
        staged = SourcePatches(self.root)
        notification_patches(staged)
        text = staged.pending[APPLICATION_CONTEXT]
        self.assertIn("for (messages, _, notify, threadData) in messageList", text)
        self.assertLess(text.index("whitegramLocalNotifications.enqueue("), text.index("if UIApplication.shared.applicationState == .active"))
        self.assertEqual(text.count("whitegramLocalNotifications.clearReadMessages(ids)"), 1)

    def test_late_missing_anchor_fails_before_any_source_is_written(self):
        staged = SourcePatches(self.root)
        text = staged.read(WAKEUP)
        staged.pending[WAKEUP] = text.replace("account.shouldExplicitelyKeepWorkerConnections.set", "changedUpstream.set")
        with patch("system_patches.SourcePatches", return_value=staged), patch.object(Path, "write_bytes") as writes:
            with self.assertRaisesRegex(ValueError, "backgroundKeepAlive"):
                apply_system_patches(self.root)
        writes.assert_not_called()

    def test_duplicate_layout_anchor_is_rejected(self):
        staged = SourcePatches(self.root)
        text = staged.read(WINDOW)
        staged.pending[WINDOW] = text + "\n                self.updatedContainerLayout = childLayout\n"
        with patch("system_patches.SourcePatches", return_value=staged), patch.object(Path, "write_bytes") as writes:
            with self.assertRaisesRegex(ValueError, "showRAMUsage"):
                apply_system_patches(self.root)
        writes.assert_not_called()


if __name__ == "__main__":
    unittest.main()
