"""Validate media palette installation, live recoloring and render-only scope."""

import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import media_accent_patches as accent
from test_history_patches import MemoryRoot, PIN, parse_sources


ROOT = Path(__file__).resolve().parents[1]
PATHS = (accent.FILE, accent.FOOTER, accent.STATUS)


class MediaAccentSourceTests(unittest.TestCase):
    def test_palette_parses_and_uses_only_local_theme_copies(self):
        path = ROOT / "cleanroom/WhitegramMediaAccent.swift"
        source = path.read_text(encoding="utf-8")
        self.assertEqual(parse_sources({str(path): source})[str(path)], [])
        self.assertIn('guard WhitegramAppearancePolicy.current.isEnabled("neutralMediaAccent") else { return colors }', source)
        self.assertIn("guard enabled else { return colors }", source)
        self.assertEqual(source.count("return colors.withUpdated("), 2)
        for untouched in ("reactionStars", "accentTextColor:", "linkTextColor:", "fileDescriptionColor:", "fill:"):
            self.assertNotIn(untouched, source)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class MediaAccentPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        cls.pristine = {path: subprocess.check_output(["git", "-C", str(cls.source), "show", f"{PIN}:{path}"]).decode("utf-8")
                        for path in PATHS}
        cls.assembled = {path: (cls.source / path).read_text(encoding="utf-8") for path in PATHS}

    def test_both_source_versions_install_and_replay_without_writes_or_new_syntax_errors(self):
        for sources in (self.pristine, self.assembled):
            with self.subTest(assembled=sources is self.assembled):
                root = MemoryRoot(sources)
                report = accent.apply_media_accent_patches(root)
                self.assertEqual(report, {"neutralMediaAccent": sorted(PATHS)})
                first = root.texts()
                root.writes.clear()
                self.assertEqual(accent.apply_media_accent_patches(root), report)
                self.assertEqual(root.texts(), first)
                self.assertEqual(root.writes, [])
                self.assertEqual(parse_sources(first), parse_sources(sources))

    def test_live_file_recolor_updates_existing_glyphs_and_retains_playback_state_machine(self):
        root = MemoryRoot(self.pristine)
        accent.apply_media_accent_patches(root)
        source = root.text(accent.FILE)
        self.assertEqual(source.count("WhitegramMediaAccent.mediaColors("), 2)
        for node in ("statusNode", "streamingStatusNode"):
            self.assertIn(f"{node}.backgroundNodeColor = backgroundNodeColor\n            {node}.foregroundNodeColor = foregroundNodeColor", source)
        original = self.pristine[accent.FILE]
        start = original.index("        let isViewOnceMessage = isVoice &&", original.index("    private func updateStatus("))
        end = original.index("        let backgroundNodeColor: UIColor", start)
        self.assertTrue(original[start:end] in source, "Playback/download state selection must remain unchanged")
        for value in ("messageTheme.mediaActiveControlColor", "messageTheme.mediaInactiveControlColor", "messageTheme.fileTitleColor", "arguments.customTintColor ??"):
            self.assertEqual(source.count(value), original.count(value))
        native = (self.source / "submodules/SemanticStatusNode/Sources/SemanticStatusNode.swift").read_text(encoding="utf-8")
        self.assertIn("public var foregroundNodeColor: UIColor", native)

    def test_reactions_keep_stars_context_menu_and_freeform_colors(self):
        root = MemoryRoot(self.pristine)
        accent.apply_media_accent_patches(root)
        for path in (accent.FOOTER, accent.STATUS):
            original = self.pristine[path]
            source = root.text(path)
            for line in original.splitlines():
                if any(field in line for field in ("StarsBackground:", "StarsForeground:", "extractedBackground:", "extractedForeground:", "extractedSelectedForeground:", "selectedIconTintColor:")):
                    self.assertIn(line, source)
            self.assertIn("chat.message.incoming.primaryTextColor, enabled: whitegramNeutralMediaAccent)", source)
            self.assertIn("chat.message.outgoing.primaryTextColor, enabled: whitegramNeutralMediaAccent)", source)
        footer = root.text(accent.FOOTER)
        self.assertIn("let whitegramReactionColors = themeColors\n            reactionColors =", footer)
        self.assertIn("deselectedBackground: selectReactionFillStaticColor(", footer)
        status = root.text(accent.STATUS)
        self.assertIn("case .BubbleIncoming, .BubbleOutgoing:\n                whitegramNeutralMediaAccent", status)
        self.assertIn("default:\n                whitegramNeutralMediaAccent = false", status)

    def test_each_anchor_is_atomic_and_exactly_reversible(self):
        edits = []
        original_replace = accent.replace

        def record(patches, feature, path, before, after, count=1):
            original_replace(patches, feature, path, before, after, count=count)
            edits.append((path, before, after, count))

        root = MemoryRoot({**self.pristine, "unrelated.swift": "// user work\r\n"})
        with patch.object(accent, "replace", record):
            accent.apply_media_accent_patches(root)
        for path, before, after, count in reversed(edits):
            self.assertEqual(root.text(path).count(after), count)
            root.files[path] = root.text(path).replace(after, before).encode("utf-8")
        self.assertEqual(root.files, MemoryRoot({**self.pristine, "unrelated.swift": "// user work\r\n"}).files)
        for path, before, _, _ in edits:
            with self.subTest(path=path, anchor=before[:80]):
                broken = MemoryRoot(self.pristine)
                broken.files[path] = broken.text(path).replace(before, "/* missing anchor */", 1).encode("utf-8")
                initial = dict(broken.files)
                with self.assertRaises(ValueError):
                    accent.apply_media_accent_patches(broken)
                self.assertEqual(broken.files, initial)
                self.assertEqual(broken.writes, [])

    def test_duplicate_and_partially_applied_colors_fail_before_writing(self):
        for extra in (
            "                let messageTheme = arguments.incoming ? arguments.presentationData.theme.theme.chat.message.incoming : arguments.presentationData.theme.theme.chat.message.outgoing\n",
            "                let messageTheme = WhitegramMediaAccent.mediaColors(arguments.incoming ? arguments.presentationData.theme.theme.chat.message.incoming : arguments.presentationData.theme.theme.chat.message.outgoing)\n",
        ):
            root = MemoryRoot(self.pristine)
            accent.apply_media_accent_patches(root)
            root.files[accent.FILE] += extra.encode("utf-8")
            root.writes.clear()
            initial = dict(root.files)
            with self.assertRaises(ValueError):
                accent.apply_media_accent_patches(root)
            self.assertEqual(root.files, initial)
            self.assertEqual(root.writes, [])


if __name__ == "__main__":
    unittest.main()
