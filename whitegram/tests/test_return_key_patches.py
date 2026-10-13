"""Return-key adapters, IME ordering, and atomic installation on both source trees."""

from collections import Counter
import os
from pathlib import Path
import subprocess
import sys
import unittest

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))

from formatting_toolbar_patches import apply_formatting_toolbar_patches
from return_key_patches import CAPTION, CANVAS, EDITOR, INPUT, INSERT, LEGACY_KEYS, NATIVE, PANEL, PATHS, SEAM, apply_return_key_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class ReturnKeyPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        cls.assembled = {path: (source / path).read_text(encoding="utf-8") for path in PATHS}
        cls.pristine = {path: subprocess.check_output(["git", "-C", str(source), "show", f"{PIN}:{path}"]).decode("utf-8") for path in PATHS}

    def test_all_adapters_install_and_replay_without_writes(self):
        for files in (self.pristine, self.assembled):
            with self.subTest(pristine=files is self.pristine):
                root = MemoryRoot(files)
                report = apply_return_key_patches(root)
                self.assertEqual(report, {"sendOnReturnKey": sorted(PATHS)})
                self.assertEqual(set(root.writes), set(PATHS) if files is self.pristine else {path for path in PATHS if root.text(path) != files[path]})
                first = root.texts()
                root.writes.clear()
                self.assertEqual(apply_return_key_patches(root), report)
                self.assertEqual(root.texts(), first)
                self.assertEqual(root.writes, [])

    def test_toolbar_and_return_lifecycle_hooks_survive_either_order(self):
        for order in ((apply_return_key_patches, apply_formatting_toolbar_patches), (apply_formatting_toolbar_patches, apply_return_key_patches)):
            root = MemoryRoot(self.pristine)
            for patcher in order:
                patcher(root)
            first = root.texts()
            root.writes.clear()
            for patcher in order:
                patcher(root)
            self.assertEqual(root.texts(), first)
            self.assertEqual(root.writes, [])
            panel = root.text(PANEL)
            self.assertEqual(panel.count("self.whitegramReturnKeyObserver = NotificationCenter.default.addObserver"), 1)
            self.assertEqual(panel.count("self.whitegramFormattingObservers.append(NotificationCenter.default.addObserver"), 1)
            self.assertEqual(panel.count("override public func didLoad()"), 1)

    def test_ime_commit_and_selection_replace_precede_native_software_send(self):
        root = MemoryRoot(self.pristine)
        apply_return_key_patches(root)
        insertion = root.text(INSERT).split("    func insertText(_ text: String) {", 1)[1].split("    func deleteBackward", 1)[0]
        self.assertLess(insertion.index("if let m = markedRange"), insertion.index("onSoftwareReturn?()"))
        self.assertIn('if text == "\\n", selFrom == selTo, !handlingHardwareReturn, onSoftwareReturn?() == false { return }', insertion)
        self.assertLess(insertion.index("onSoftwareReturn?()"), insertion.index("clearStructuralSelections()"))
        self.assertIn("onSoftwareReturn: (() -> Bool)?", root.text(EDITOR))
        self.assertIn("guard WhitegramTextSettings.current.sendOnReturnKey else { return true }", root.text(NATIVE))

    def test_hardware_newline_cannot_reenter_software_send_and_shift_is_bound(self):
        root = MemoryRoot(self.pristine)
        apply_return_key_patches(root)
        for path, prefix in ((CANVAS, "handlingHardwareReturn"), (INPUT, "self.whitegramHandlingHardwareReturn")):
            text = root.text(path)
            start = text.index(prefix + " = true")
            block = text[start:text.index('insertText("\\n")', start)]
            self.assertIn("defer { " + prefix + " = false }", block)
            self.assertIn("marked", block)
        self.assertIn('modifierFlags: .shift, action: #selector(handleReturnKey(_:)))', root.text(CANVAS))
        self.assertIn('modifierFlags:UIKeyModifierShift action:@selector(handleReturn:)', root.text(LEGACY_KEYS))
        for path in (PANEL, CAPTION):
            self.assertIn("hasMarkedText:", root.text(path))
            self.assertIn("handlingHardwareReturn:", root.text(path))

    def test_keyboard_traits_reach_both_backends_before_engine_replacement(self):
        root = MemoryRoot(self.pristine)
        apply_return_key_patches(root)
        self.assertIn("var returnKeyType: UIReturnKeyType { get set }", root.text(SEAM))
        self.assertIn("self.textInputNodeImpl.textView.returnKeyType = newValue", root.text(SEAM))
        self.assertIn("self.editorView.returnKeyType = newValue", root.text(NATIVE))
        self.assertIn("if canvas.isFirstResponder { canvas.reloadInputViews() }", root.text(EDITOR))
        for path, node in ((PANEL, "richTextInputNode"), (CAPTION, "textInputNode.textView")):
            self.assertEqual(root.text(path).count(f"{node}.returnKeyType = WhitegramTextSettings.current.sendOnReturnKey ? .send : .default"), 1)
            self.assertIn("if self.whitegramReturnKeyObserver == nil", root.text(path))

    def test_missing_late_anchor_or_duplicate_installed_callback_aborts_all_writes(self):
        damaged = dict(self.pristine)
        damaged[CAPTION] = damaged[CAPTION].replace("    public func loadTextInputNodeIfNeeded() {", "    public func changedInputLifecycle() {")
        installed = MemoryRoot(self.pristine)
        apply_return_key_patches(installed)
        duplicate = installed.texts()
        declaration = "    var onSoftwareReturn: (() -> Bool)?\n"
        duplicate[CANVAS] = duplicate[CANVAS].replace(declaration, declaration * 2)
        for files in (damaged, duplicate):
            root = MemoryRoot(files)
            with self.assertRaisesRegex(ValueError, "sendOnReturnKey"):
                apply_return_key_patches(root)
            self.assertEqual(root.texts(), files)
            self.assertEqual(root.writes, [])

    def test_adapters_introduce_no_new_swift_syntax_errors(self):
        root = MemoryRoot(self.assembled)
        apply_return_key_patches(root)
        before = {path: text for path, text in self.assembled.items() if path.endswith(".swift")}
        after = {path: root.text(path) for path in before}
        baseline, current = parse_sources(before), parse_sources(after)
        for path in before:
            with self.subTest(path=path):
                self.assertEqual(Counter(item["text"] for item in baseline[path]), Counter(item["text"] for item in current[path]))


if __name__ == "__main__":
    unittest.main()
