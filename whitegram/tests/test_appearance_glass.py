"""Exercise glass integration on the complete pinned source files in memory."""

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import appearance_extension_patches as extensions
import appearance_glass_patches as glass
import appearance_glass_runtime_patches as runtime
from test_appearance_extensions import MemoryRoot, TARGETS as EXTENSION_TARGETS, syntax_errors


SOURCE = os.environ.get("WHITEGRAM_APPEARANCE_SOURCE")
WHITEGRAM = Path(__file__).resolve().parents[1]
TARGETS = (
    glass.BACKGROUND, glass.GRAPHICS, glass.GLASS, glass.INLINE,
    glass.PEER + "PeerInfoScreenItemSectionContainerNode.swift",
    glass.PEER + "PeerInfoScreen.swift", glass.GIFT, runtime.LENS,
)


def apply_recorded(root):
    edits = []
    original = glass.replace

    def record(patches, feature, path, before, after, count=1):
        original(patches, feature, path, before, after, count)
        edits.append((path, before, after, count))

    with patch.object(glass, "replace", record), patch.object(runtime, "replace", record):
        report = glass.apply_appearance_glass_patches(root)
    return report, edits


class GlassSourceTests(unittest.TestCase):
    def test_runtime_sources_parse(self):
        for name in glass.APPEARANCE_GLASS_RUNTIME_FILES:
            with self.subTest(name=name):
                self.assertEqual(syntax_errors((WHITEGRAM / "cleanroom" / name).read_bytes()), [])


@unittest.skipUnless(SOURCE, "Set WHITEGRAM_APPEARANCE_SOURCE to assembled 12.9.2")
class GlassPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = {
            name: (Path(SOURCE) / name).read_text(encoding="utf-8")
            for name in set(TARGETS) | set(EXTENSION_TARGETS)
        }
        cls.report, cls.edits = apply_recorded(MemoryRoot(cls.files))
        for path, before, after, count in reversed(cls.edits):
            if cls.files[path].count(after) == count:
                cls.files[path] = cls.files[path].replace(after, before)

    def test_all_consumers_patch_parse_and_repeat_without_writes(self):
        root = MemoryRoot(self.files)
        report = glass.apply_appearance_glass_patches(root)
        self.assertEqual({path for paths in report.values() for path in paths}, set(TARGETS))
        first = dict(root.files)
        root.writes.clear()
        self.assertEqual(glass.apply_appearance_glass_patches(root), report)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.files, first)
        for path in TARGETS:
            with self.subTest(path=path):
                self.assertEqual(syntax_errors(root.files[path]), [])

    def test_every_missing_or_ambiguous_anchor_is_atomic(self):
        for path, before, _, count in self.edits:
            for substitute in ("/* missing anchor */", before + before):
                with self.subTest(path=path, anchor=before[:70], duplicate=substitute != "/* missing anchor */"):
                    root = MemoryRoot(self.files)
                    self.assertEqual(root.text(path).count(before), count)
                    root.files[path] = root.text(path).replace(before, substitute, 1).encode()
                    initial = dict(root.files)
                    with self.assertRaises(ValueError):
                        glass.apply_appearance_glass_patches(root)
                    self.assertEqual(root.files, initial)
                    self.assertEqual(root.writes, [])

    def test_missing_last_target_and_mixed_application_are_atomic(self):
        for mixed in (False, True):
            root = MemoryRoot(self.files)
            if mixed:
                glass.apply_appearance_glass_patches(root)
                path, before, _, _ = self.edits[0]
                root.files[path] += before.encode()
            else:
                del root.files[glass.GIFT]
            root.writes.clear()
            initial = dict(root.files)
            with self.assertRaises(ValueError if mixed else FileNotFoundError):
                glass.apply_appearance_glass_patches(root)
            self.assertEqual(root.files, initial)
            self.assertEqual(root.writes, [])

    def test_reversibility_and_crlf_isolation(self):
        root = MemoryRoot({**self.files, "untouched.swift": "// unrelated work\r\n"})
        glass.apply_appearance_glass_patches(root)
        normal = dict(root.files)
        for path, before, after, count in reversed(self.edits):
            self.assertEqual(root.text(path).count(after), count)
            root.files[path] = root.text(path).replace(after, before).encode()
        self.assertEqual(root.files, MemoryRoot({**self.files, "untouched.swift": "// unrelated work\r\n"}).files)
        crlf = MemoryRoot({name: text.replace("\n", "\r\n") for name, text in self.files.items()})
        glass.apply_appearance_glass_patches(crlf)
        for path in TARGETS:
            self.assertEqual(crlf.files[path], normal[path])
        self.assertNotIn("untouched.swift", root.writes)

    def test_repeated_parent_pass_keeps_extension_anchors_intact(self):
        root = MemoryRoot(self.files)
        extensions.apply_appearance_extensions(root)
        glass.apply_appearance_glass_patches(root)
        first = dict(root.files)
        root.writes.clear()
        extensions.apply_appearance_extensions(root)
        glass.apply_appearance_glass_patches(root)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.files, first)

    def test_material_changes_preserve_native_content_getters_and_hit_testing(self):
        root = MemoryRoot(self.files)
        glass.apply_appearance_glass_patches(root)
        original = self.files[glass.GLASS]
        result = root.text(glass.GLASS)
        for signature in ("    public var contentView: UIView {", "    override public func hitTest("):
            offset = 0
            while (start := original.find(signature, offset)) != -1:
                opening = original.index("{", start)
                depth = 1
                end = opening + 1
                while depth:
                    depth += (original[end] == "{") - (original[end] == "}")
                    end += 1
                self.assertIn(original[start:end], result)
                offset = end
        for path, token, end_token in (
            (glass.BACKGROUND, "public func bubbleMaskForType(", "public final class ChatMessageBubbleBackdrop"),
            (glass.INLINE, "    @objc func buttonPressed()", "    private func updateIsLoading("),
            (glass.GIFT, "        @objc private func buttonPressed()", "        func update(component:"),
        ):
            before = self.files[path]
            self.assertIn(before[before.index(token):before.index(end_token, before.index(token))], root.text(path))

    def test_native_lens_switches_materials_without_replacing_content_views(self):
        root = MemoryRoot(self.files)
        glass.apply_appearance_glass_patches(root)
        source = root.text(runtime.LENS)
        self.assertIn("self.whitegramNativeLensView = self.lensView", source)
        self.assertIn("self.lensView = usesLegacy ? nil : self.whitegramNativeLensView", source)
        self.assertIn("self.contentView.mask = usesLegacy ? self.legacyContentMaskView : nil", source)
        self.assertIn("self.liftedContainerView.mask = usesLegacy ? self.legacyLiftedContentBlobMaskView : nil", source)
        self.assertIn("if self.lensView != nil && params.isLifted", source)
        for assignment in ("self.contentView = UIView()", "self.liftedContainerView = UIView()"):
            self.assertEqual(source.count(assignment), 1)
        self.assertIn("UIAccessibility.reduceMotionStatusDidChangeNotification", source)
        self.assertIn("self.update(params: params, transition: .immediate)", source)
        self.assertIn("self.liftedDisplayLink?.invalidate()", source)


if __name__ == "__main__":
    unittest.main()
