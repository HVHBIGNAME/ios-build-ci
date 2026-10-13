"""Toolbar installation, native API/label availability, and rich-content boundaries."""

import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))

from formatting_toolbar_patches import FORMATTING_TOOLBAR_RUNTIME_FILES, PANEL, apply_formatting_toolbar_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


class FormattingToolbarRuntimeTests(unittest.TestCase):
    def test_toolbar_runtime_parses(self):
        sources = {name: (OVERLAY / "cleanroom" / name).read_text(encoding="utf-8") for name in FORMATTING_TOOLBAR_RUNTIME_FILES}
        self.assertEqual(parse_sources(sources), {name: [] for name in sources})


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class FormattingToolbarPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        cls.assembled = {PANEL: (cls.source / PANEL).read_text(encoding="utf-8")}
        cls.pristine = {PANEL: subprocess.check_output(["git", "-C", str(cls.source), "show", f"{PIN}:{PANEL}"]).decode("utf-8")}

    def test_both_sources_install_and_replay_without_writes(self):
        for files in (self.pristine, self.assembled):
            root = MemoryRoot(files)
            report = apply_formatting_toolbar_patches(root)
            first = root.texts()
            root.writes.clear()
            self.assertEqual(apply_formatting_toolbar_patches(root), report)
            self.assertEqual(root.texts(), first)
            self.assertEqual(root.writes, [])
            self.assertEqual(parse_sources(files), parse_sources(first))

    def test_system_labels_exist_in_the_pinned_telegram_catalogue(self):
        toolbar = (OVERLAY / "cleanroom/WhitegramFormattingToolbar.swift").read_text(encoding="utf-8")
        strings = (self.source / "Telegram/Telegram-iOS/en.lproj/Localizable.strings").read_text(encoding="utf-8")
        available = {key.replace(".", "_") for key in re.findall(r'^"([^"]+)"\s*=', strings, re.MULTILINE)}
        references = set(re.findall(r"strings\.([A-Z]\w+)", toolbar))
        self.assertTrue(references)
        self.assertEqual(references - available, set())
        composer = (OVERLAY / "cleanroom/WhitegramComposerStrings.swift").read_text(encoding="utf-8")
        for key in re.findall(r'WhitegramComposerStrings\.string\("([^"]+)"', toolbar):
            self.assertIn('"' + key + '":', composer)

    def test_native_toolbar_routes_structural_content_to_editor_commands(self):
        root = MemoryRoot(self.pristine)
        apply_formatting_toolbar_patches(root)
        text = root.text(PANEL)
        action = text.split("    private func whitegramFormattingAction", 1)[1].split("    @objc private func slowModeButtonPressed", 1)[0]
        self.assertLess(action.index("node.performFormatAction(format)"), action.index("guard input.content.isEntityExpressible()"))
        self.assertIn("node.selectedRichText()", action)
        self.assertIn("editor.selectAll()\n                editor.deleteBackward()", action)
        self.assertIn("editor.undo()", action)
        self.assertIn("editor.redo()", action)
        self.assertIn("WhitegramTextSettings.current.formattingToolbar", action)
        self.assertIn("node.isInputFirstResponder", action)
        self.assertIn("self.whitegramFormattingToolbar?.isHidden == false", action)
        self.assertIn("Namespaces.Peer.SecretChat", text)

    def test_missing_height_anchor_aborts_without_writing(self):
        files = {PANEL: self.pristine[PANEL].replace("if !self.bounds.size.height.isEqual(to: panelHeight)", "if upstreamHeightChanged")}
        root = MemoryRoot(files)
        with self.assertRaisesRegex(ValueError, "formattingToolbarEnabled"):
            apply_formatting_toolbar_patches(root)
        self.assertEqual(root.texts(), files)
        self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
