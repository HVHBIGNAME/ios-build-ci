import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from history_patches import _message_menu_patch
from message_actions_patches import ACTION, ANCHOR, MENU, message_action_patches
from service_patches import service_patches
from source_patches import SourcePatches
from test_translation_patches import errors


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class MessageActionTests(unittest.TestCase):
    def test_message_actions_compose_and_preserve_native_permission_checks(self):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        patches = SourcePatches(root)
        for apply in (_message_menu_patch, service_patches, message_action_patches):
            apply(patches)
        once = dict(patches.pending)
        for apply in (_message_menu_patch, service_patches, message_action_patches):
            apply(patches)
        self.assertEqual(once, patches.pending)
        self.assertEqual(errors(once[MENU]), errors(patches.original[MENU]))
        self.assertIn("data.messageActions.options.contains(.forward)", ACTION)
        self.assertIn("!isCopyProtected && !message.containsSecretMedia", ACTION)
        self.assertIn("performPersonalChatDoubleTapAction(message, .savedMessages)", ACTION)
        controller = (root / "submodules/TelegramUI/Sources/ChatController.swift").read_text(encoding="utf-8")
        self.assertIn("self.forwardMessagesToSavedMessages(messages: [message])", controller)

    def test_missing_or_duplicate_action_anchor_aborts_before_write(self):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        original = (root / MENU).read_text(encoding="utf-8").replace(ACTION + ANCHOR, ANCHOR)
        for text in (original.replace(ANCHOR, ""), original + ANCHOR):
            patches = SourcePatches(root)
            patches.read(MENU)
            patches.pending[MENU] = text
            with self.assertRaises(ValueError):
                message_action_patches(patches)
