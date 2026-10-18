"""Send-button placement and write-free replay on pinned and assembled sources."""

from collections import Counter
import os
from pathlib import Path
import subprocess
import sys
import unittest

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))

from feedback_patches import PANEL, apply_feedback_patches
from return_key_patches import PATHS, apply_return_key_patches
from test_history_patches import MemoryRoot, PIN, parse_sources


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class FeedbackPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        cls.assembled = {path: (source / path).read_text(encoding="utf-8") for path in PATHS}
        cls.pristine = {path: subprocess.check_output(["git", "-C", str(source), "show", f"{PIN}:{path}"]).decode("utf-8") for path in PATHS}

    def test_installs_once_and_replays_without_writes(self):
        for files in (self.pristine, self.assembled):
            with self.subTest(pristine=files is self.pristine):
                root = MemoryRoot(files)
                report = apply_feedback_patches(root)
                self.assertEqual(report, {"inAppVibration": [PANEL]})
                self.assertEqual(root.writes, [PANEL] if root.text(PANEL) != files[PANEL] else [])
                first = root.texts()
                root.writes.clear()
                self.assertEqual(apply_feedback_patches(root), report)
                self.assertEqual(root.texts(), first)
                self.assertEqual(root.writes, [])

    def test_medium_impact_only_precedes_ordinary_send_after_validation(self):
        for files in (self.pristine, self.assembled):
            with self.subTest(pristine=files is self.pristine):
                root = MemoryRoot(files)
                apply_feedback_patches(root)
                before = files[PANEL]
                after = root.text(PANEL)
                start = after.index("    @objc func sendButtonPressed() {")
                end = after.index("    @objc func sendAsAvatarButtonPressed() {")
                method = after[start:end]
                media = method.index("        if let presentationInterfaceState = self.presentationInterfaceState, presentationInterfaceState.interfaceState.mediaDraftState != nil {")
                self.assertLess(method.index("if remainingCount < 0 {"), media)
                self.assertIn("self.hapticFeedback.error()\n                return", method[:media])
                recorded, ordinary = method[media:].split("        } else {", 1)
                self.assertIn("self.interfaceInteraction?.sendRecordedMedia(false, self.viewOnce)", recorded)
                self.assertIn("self.viewOnce = false", recorded)
                self.assertNotIn("hapticFeedback", recorded)
                self.assertEqual(ordinary, "\n"
                    "            if WhitegramTextSettings.current.inAppVibrationEnabled {\n"
                    "                self.hapticFeedback.impact(.medium)\n"
                    "            }\n"
                    "            self.sendMessage()\n"
                    "        }\n"
                    "    }\n"
                    "    \n")
                insertion = ("            if WhitegramTextSettings.current.inAppVibrationEnabled {\n"
                             "                self.hapticFeedback.impact(.medium)\n"
                             "            }\n")
                self.assertEqual(after.count(insertion), 1)
                self.assertEqual(after.replace(insertion, ""), before.replace(insertion, ""))
                for path in files.keys() - {PANEL}:
                    self.assertEqual(root.text(path), files[path])

    def test_return_key_hooks_survive_either_installation_order(self):
        results = []
        for order in ((apply_feedback_patches, apply_return_key_patches), (apply_return_key_patches, apply_feedback_patches)):
            root = MemoryRoot(self.pristine)
            for patcher in order:
                patcher(root)
            first = root.texts()
            root.writes.clear()
            for patcher in order:
                patcher(root)
            self.assertEqual(root.texts(), first)
            self.assertEqual(root.writes, [])
            results.append(first)
        self.assertEqual(results[0], results[1])

    def test_missing_and_duplicate_method_or_branch_abort_without_writes(self):
        source = self.pristine[PANEL]
        method_start = "    @objc func sendButtonPressed() {\n"
        method_end = "    @objc func sendAsAvatarButtonPressed() {\n"
        method = source[source.index(method_start):source.index(method_end)]
        branch_start = "        if let presentationInterfaceState = self.presentationInterfaceState, presentationInterfaceState.interfaceState.mediaDraftState != nil {"
        branch = method[method.index(branch_start):method.rindex("    }")]
        mutations = [
            source.replace(method_start, method_start.replace("sendButtonPressed", "renamedSendButton")),
            source.replace(method_start, method_start * 2),
            source.replace(method_end, ""),
            source.replace(method_end, method_end * 2),
            source.replace(branch, ""),
            source.replace(branch, branch * 2),
            source.replace("                self.hapticFeedback.error()\n                return\n", "                return\n"),
        ]
        for text in mutations:
            with self.subTest(mutation=mutations.index(text)):
                root = MemoryRoot({PANEL: text})
                with self.assertRaisesRegex(ValueError, "inAppVibration"):
                    apply_feedback_patches(root)
                self.assertEqual(root.text(PANEL), text)
                self.assertEqual(root.writes, [])

    def test_partial_duplicate_and_misplaced_installed_hooks_abort_without_writes(self):
        installed = MemoryRoot(self.pristine)
        apply_feedback_patches(installed)
        source = installed.text(PANEL)
        hook = ("            if WhitegramTextSettings.current.inAppVibrationEnabled {\n"
                "                self.hapticFeedback.impact(.medium)\n"
                "            }\n")
        mutations = [
            source.replace(hook, hook * 2),
            source.replace("self.hapticFeedback.impact(.medium)", "self.hapticFeedback.impact(.light)"),
            source.replace(hook, "").replace("    @objc func sendButtonPressed() {\n", "    @objc func sendButtonPressed() {\n" + hook),
            source.replace(hook, "").replace("            self.viewOnce = false\n", hook + "            self.viewOnce = false\n"),
            source.replace(hook, "").replace("    @objc func menuButtonPressed() {\n", "    @objc func menuButtonPressed() {\n" + hook),
        ]
        for text in mutations:
            with self.subTest(mutation=mutations.index(text)):
                root = MemoryRoot({PANEL: text})
                with self.assertRaisesRegex(ValueError, "inAppVibration"):
                    apply_feedback_patches(root)
                self.assertEqual(root.text(PANEL), text)
                self.assertEqual(root.writes, [])

    def test_patched_panel_introduces_no_swift_syntax_errors(self):
        for files in (self.pristine, self.assembled):
            with self.subTest(pristine=files is self.pristine):
                root = MemoryRoot(files)
                apply_feedback_patches(root)
                baseline = parse_sources({PANEL: files[PANEL]})[PANEL]
                current = parse_sources({PANEL: root.text(PANEL)})[PANEL]
                self.assertEqual(Counter(item["text"] for item in baseline), Counter(item["text"] for item in current))


class FeedbackNativeSourceTests(unittest.TestCase):
    def test_owned_swift_sources_parse(self):
        paths = ("cleanroom/WhitegramTextSettings.swift", "tests/localization/WhitegramTextSettingsTests.swift")
        sources = {path: (OVERLAY / path).read_text(encoding="utf-8") for path in paths}
        for path, errors in parse_sources(sources).items():
            with self.subTest(path=path):
                self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
