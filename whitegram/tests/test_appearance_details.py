"""Profile geometry installation, metadata-based emphasis and icon-preview wiring."""
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import appearance_details_patches as details
from appearance_details_patches import APP, BUTTON, HEADER, apply_appearance_details_patches
from test_history_patches import MemoryRoot, parse_sources


class AppearanceDetailsSourceTests(unittest.TestCase):
    def test_runtime_and_native_semantic_sources_parse(self):
        names = ["cleanroom/WhitegramAppearancePolicy.swift", "cleanroom/WhitegramHistoryRuntime.swift", "tests/appearance_parity/main.swift"]
        for name, errors in parse_sources({name: (ROOT / name).read_text(encoding="utf-8") for name in names}).items():
            self.assertEqual(errors, [], name)

    def test_emphasis_uses_personal_metadata_and_retains_deleted_message_precedence(self):
        source = (ROOT / "cleanroom/WhitegramHistoryRuntime.swift").read_text(encoding="utf-8")
        opacity = source.split("public static func displayOpacity(", 1)[1].split("public static func originalForDisplay(", 1)[0]
        self.assertLess(opacity.index("return self.policy.deletedOpacity"), opacity.index('appearance.isEnabled("highlightMentions")'))
        self.assertIn("message.flags.contains(.Incoming)", opacity)
        self.assertIn("attribute is ConsumablePersonalMentionMessageAttribute", opacity)
        self.assertIn("peerId == accountPeerId", opacity)
        self.assertNotIn("message.text", opacity)
        version = source.split("public static func displayMessage(", 1)[1].split("public static func setShortened(", 1)[0]
        self.assertIn('isEnabled("highlightMentions")', version)
        self.assertIn("withUpdatedStableVersion", version)
        self.assertNotIn("transaction", version)

    def test_new_controls_have_runtime_routes_and_installer(self):
        caps = (ROOT / "cleanroom/WhitegramPortCapabilities.swift").read_text(encoding="utf-8")
        for key in ("highlightMentions", "roundProfileActionButtons"):
            self.assertIn(f'"{key}": "{key}"', caps)
        self.assertIn("apply_profile_appearance_patches, apply_appearance_details_patches,", (ROOT / "compat-12.9.4.py").read_text(encoding="utf-8"))


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class AppearanceDetailsPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        cls.assembled = {path: (source / path).read_text(encoding="utf-8") for path in (APP, HEADER, BUTTON)}
        edits = []
        original_replace = details.replace

        def recorded(patches, feature, path, before, after, count=1):
            original_replace(patches, feature, path, before, after, count)
            edits.append((path, before, after, count))

        with patch.object(details, "replace", recorded):
            apply_appearance_details_patches(MemoryRoot(cls.assembled))
        cls.base = dict(cls.assembled)
        for path, before, after, count in reversed(edits):
            if cls.base[path].count(after) == count:
                cls.base[path] = cls.base[path].replace(after, before)

    def test_assembled_installation_and_repeat_preserve_handlers(self):
        root = MemoryRoot(self.assembled)
        report = apply_appearance_details_patches(root)
        first = root.texts()
        root.writes.clear()
        self.assertEqual(apply_appearance_details_patches(root), report)
        self.assertEqual(first, root.texts())
        self.assertEqual(root.writes, [])
        self.assertEqual(parse_sources(self.assembled), parse_sources(first))
        for path, before in self.assembled.items():
            for marker in ("self.action(self, nil)", "strongSelf.action(strongSelf, gesture)", "buttonPressed(buttonNode", "case .call:", "case .videoCall:"):
                self.assertEqual(root.text(path).count(marker), before.count(marker))
        self.assertIn('imageName: "WhitegramPrimaryPreview", isDefault: true', root.text(APP))
        self.assertIn('let actionRowHeight: CGFloat = roundActionButtons ? 72.0 : 58.0', root.text(HEADER))
        self.assertIn("cornerRadius: geometry.cornerRadius", root.text(BUTTON))

    def test_missing_late_anchor_is_atomic(self):
        source = dict(self.base)
        source[HEADER] = source[HEADER].replace("let buttonSize = CGSize(width: buttonWidth, height: 58.0)", "let buttonSize = changed")
        root = MemoryRoot(source)
        with self.assertRaises(ValueError):
            apply_appearance_details_patches(root)
        self.assertEqual(root.texts(), source)
        self.assertEqual(root.writes, [])

    def test_duplicate_icon_anchor_is_rejected(self):
        source = dict(self.base)
        anchor = 'PresentationAppIcon(name: "Default", imageName: "BlueIcon", isDefault: true)'
        source[APP] += "\n" + anchor
        root = MemoryRoot(source)
        with self.assertRaises(ValueError):
            apply_appearance_details_patches(root)
        self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
