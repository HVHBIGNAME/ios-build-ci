"""Read-only original-IPA contract checks; no ARM64 or Swift code is executed.

Run with the original wgtool environment and WHITEGRAM_ORIGINAL_EVIDENCE pointing
to whitegram-rebuild. The assembled-source suite does not require that environment.
"""

import json
import os
from pathlib import Path
import re
import struct
import sys
import unittest
import zipfile


ORIGINAL = os.environ.get("WHITEGRAM_ORIGINAL_EVIDENCE")
OVERLAY = Path(__file__).resolve().parents[2]
IPA_SHA256 = "bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837"


@unittest.skipUnless(ORIGINAL, "Set WHITEGRAM_ORIGINAL_EVIDENCE for original-IPA checks")
class OriginalPrivacyContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        original = Path(ORIGINAL)
        sys.path.insert(0, str(original))
        from wgtool.binary import MachO
        from wgtool.storage import file_sha256

        manifest = json.loads((original / "audit-full-3.1.1/manifest.json").read_text(encoding="utf-8"))
        if manifest["ipa_sha256"] != IPA_SHA256 or file_sha256(manifest["ipa"]) != IPA_SHA256:
            raise ValueError("Original IPA identity does not match Whitegram 3.1.1 / Telegram 12.9.2 (71)")
        with zipfile.ZipFile(manifest["ipa"]) as archive:
            cls.core = MachO(archive.read("Payload/Telegram.app/Frameworks/TelegramCoreFramework.framework/TelegramCoreFramework"))
            cls.ui = MachO(archive.read("Payload/Telegram.app/Frameworks/TelegramUIFramework.framework/TelegramUIFramework"))
        cls.settings = (OVERLAY / "cleanroom/WhitegramContentSettings.swift").read_text(encoding="utf-8")

    @staticmethod
    def instruction(image, address):
        offset = image.vm_offset(address)
        return next(image.engine.disasm_lite(image.data[offset:offset + 4], address))[2:]

    @staticmethod
    def swift_string(image, first, second):
        if second & (1 << 61):
            return struct.pack("<QQ", first, second)[:(second >> 56) & 15].decode("utf-8")
        length = first & 0xFFFFFFFFFFFF
        if length > 1024:
            raise ValueError("Unexpected original string length")
        offset = image.vm_offset((second & 0x0FFFFFFFFFFFFFFF) + 32)
        return image.data[offset:offset + length].decode("utf-8")

    def static_string_array(self, address):
        offset = self.core.vm_offset(address)
        count, capacity = self.core.unpack("<QQ", offset + 16)
        self.assertEqual((count, capacity), (4, 8))
        return {
            self.swift_string(self.core, *self.core.unpack("<QQ", offset + 32 + index * 16))
            for index in range(count)
        }

    def test_restriction_sets_match_the_original_bound_static_arrays(self):
        for name, address in (
            ("preservedRestrictionReasons", 0x1144768),
            ("alwaysBypassedRestrictionReasons", 0x11447D0),
        ):
            with self.subTest(name=name):
                match = re.search(rf"\b{name}: Set<String> = (\[[^\]]*\])", self.settings)
                self.assertIsNotNone(match)
                self.assertEqual(set(json.loads(match.group(1))), self.static_string_array(address))
        self.assertIn("lowercased", self.core.imports[0xD4D7F4])
        self.assertEqual(self.instruction(self.core, 0x236E94), ("bl", "#0xd4d7f4"))

    def test_per_chat_parser_uses_the_original_comma_and_whitespace_contract(self):
        self.assertEqual(self.instruction(self.core, 0x203530), ("mov", "w8, #0x2c"))
        self.assertIn("whitespaces", self.core.imports[0xD4ADAC])
        self.assertIn("trimmingCharacters", self.core.imports[0xD4DE00])
        self.assertIn('value.split(separator: ",")', self.settings)
        self.assertIn("trimmingCharacters(in: .whitespaces)", self.settings)

    def test_story_enable_callback_writes_only_story_receipt_suppression_before_opening(self):
        self.assertEqual(self.instruction(self.ui, 0x1682D34), ("mov", "w0, #1"))
        self.assertEqual(self.instruction(self.ui, 0x1682D38), ("bl", "#0x491fe00"))
        self.assertIn("disableStoryReadReceiptsSbvsZ", self.ui.imports[0x491FE00])
        self.assertEqual(self.instruction(self.ui, 0x1682D3C), ("blr", "x19"))
        self.assertIn('bool("suggestGhostForStories") && !bool("disableStoryReadReceipts")', self.settings)

    def test_original_map_treats_only_both_zero_coordinates_as_unconfigured(self):
        self.assertEqual(self.instruction(self.ui, 0x22CDF70), ("fcmp", "d8, #0.0"))
        self.assertEqual(self.instruction(self.ui, 0x22CDF74), ("b.ne", "#0x22cdfcc"))
        self.assertEqual(self.instruction(self.ui, 0x22CDF78), ("fcmp", "d9, #0.0"))
        self.assertEqual(self.instruction(self.ui, 0x22CDF7C), ("b.ne", "#0x22cdfcc"))
        location = (OVERLAY / "cleanroom/WhitegramContentLocation.swift").read_text(encoding="utf-8")
        self.assertIn("latitude != 0.0 || longitude != 0.0", location)

    def test_original_channel_ban_transition_inverts_the_keep_setting_for_dismissal(self):
        self.assertEqual(self.instruction(self.ui, 0x201020), ("bl", "#0x491f26c"))
        self.assertIn("keepBannedChatsSbvgZ", self.ui.imports[0x491F26C])
        self.assertEqual(self.instruction(self.ui, 0x201040), ("eor", "w8, w26, #1"))
        self.assertEqual(self.instruction(self.ui, 0x1F9B78), ("cmp", "w20, #2"))


if __name__ == "__main__":
    unittest.main()
