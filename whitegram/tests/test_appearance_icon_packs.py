import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import appearance_icon_pack_patches as packs
from port_public import BASE_REF, PUBLIC_REF, merge
from test_appearance_extensions import MemoryRoot, syntax_errors

SOURCE = os.environ.get("WHITEGRAM_APPEARANCE_SOURCE")
PUBLIC_SOURCE = os.environ.get("WHITEGRAM_PUBLIC_SOURCE")
WHITEGRAM = Path(__file__).resolve().parents[1]
TARGETS = (packs.HEADER, packs.IMPLEMENTATION, packs.ROOT, packs.ANIMATION, packs.MANAGED, packs.SETTINGS)


def recorded(root):
    edits = []
    original = packs.replace

    def record(patches, feature, path, before, after, count=1):
        original(patches, feature, path, before, after, count)
        edits.append((path, before, after, count))

    with patch.object(packs, "replace", record):
        report = packs.apply_appearance_icon_pack_patches(root)
    return report, edits


class IconPackSourceTests(unittest.TestCase):
    def test_runtime_sources_parse(self):
        for name in packs.APPEARANCE_ICON_PACK_RUNTIME_FILES:
            with self.subTest(name=name):
                self.assertEqual(syntax_errors((WHITEGRAM / "cleanroom" / name).read_bytes()), [])


@unittest.skipUnless(SOURCE and PUBLIC_SOURCE, "Set WHITEGRAM_APPEARANCE_SOURCE and WHITEGRAM_PUBLIC_SOURCE")
class IconPackPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = {name: (Path(SOURCE) / name).read_text(encoding="utf-8") for name in TARGETS}
        cls.pristine = {name: subprocess.check_output(["git", "-C", SOURCE, "show", f"HEAD:{name}"]).decode("utf-8") for name in TARGETS}
        base, incoming = (
            subprocess.check_output(["git", "-C", PUBLIC_SOURCE, "show", f"{ref}:{packs.SETTINGS}"]).decode("utf-8")
            for ref in (BASE_REF, PUBLIC_REF)
        )
        cls.pristine[packs.SETTINGS], clean = merge(cls.pristine[packs.SETTINGS], base, incoming)
        if not clean:
            raise AssertionError("The pinned public Settings icon overlay no longer merges cleanly")
        _, cls.edits = recorded(MemoryRoot(cls.pristine))

    def test_real_files_apply_idempotently_and_parse(self):
        root = MemoryRoot(self.files)
        report = packs.apply_appearance_icon_pack_patches(root)
        first = dict(root.files)
        root.writes.clear()
        self.assertEqual(packs.apply_appearance_icon_pack_patches(root), report)
        self.assertEqual(root.files, first)
        self.assertEqual(root.writes, [])
        for name in TARGETS:
            if name.endswith(".swift"):
                with self.subTest(name=name):
                    self.assertEqual(syntax_errors(root.files[name]), [])

    def test_missing_late_anchor_has_no_writes(self):
        root = MemoryRoot(self.pristine)
        root.files[packs.SETTINGS] = root.text(packs.SETTINGS).replace("public static let premiumGift", "public static let changedUpstream", 1).encode()
        initial = dict(root.files)
        with self.assertRaises(ValueError):
            packs.apply_appearance_icon_pack_patches(root)
        self.assertEqual(root.files, initial)
        self.assertEqual(root.writes, [])

    def test_original_and_partially_applied_ambiguous_anchors_fail(self):
        for applied in (False, True):
            root = MemoryRoot(self.files)
            if applied:
                packs.apply_appearance_icon_pack_patches(root)
                root.writes.clear()
            path, before, _, _ = self.edits[0]
            root.files[path] += before.encode()
            initial = dict(root.files)
            with self.assertRaises(ValueError):
                packs.apply_appearance_icon_pack_patches(root)
            self.assertEqual(root.files, initial)
            self.assertEqual(root.writes, [])

    def test_all_settings_icon_properties_keep_their_original_renderers(self):
        root = MemoryRoot(self.pristine)
        _, edits = recorded(root)
        before_names = re.findall(r"public static let (\w+) =", self.pristine[packs.SETTINGS])
        after_names = re.findall(r"public static var (\w+): UIImage\?", root.text(packs.SETTINGS))
        self.assertEqual(before_names, after_names)
        self.assertEqual(len(after_names), 92)
        for path, before, after, count in reversed(edits):
            self.assertEqual(root.text(path).count(after), count)
            root.files[path] = root.text(path).replace(after, before).encode()
        self.assertEqual(root.files, MemoryRoot(self.pristine).files)

    def test_bundle_fallback_and_no_unsupported_runtime_swizzling(self):
        root = MemoryRoot(self.files)
        packs.apply_appearance_icon_pack_patches(root)
        source = root.text(packs.IMPLEMENTATION)
        self.assertIn("return replacement ?: original;", source)
        self.assertNotIn("method_exchangeImplementations", source)
        self.assertIn("WGResolveBundleAnimation(self.name)", root.text(packs.ANIMATION))
        self.assertIn("String(WGBundleOverrideRevision())", root.text(packs.MANAGED))
        header = root.text(packs.HEADER)
        for function in ("WGSetBundleImageOverrideResolver", "WGSetBundleAnimationOverrideResolver", "WGResolveBundleAnimation", "WGBundleOverrideRevision", "WGInvalidateBundleOverrides"):
            self.assertIn(function, header)
            self.assertIn(function, source)


if __name__ == "__main__":
    unittest.main()
