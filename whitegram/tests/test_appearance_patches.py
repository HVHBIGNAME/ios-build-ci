"""Patch regression tests with an in-memory filesystem; source checkouts stay read-only.

Set WHITEGRAM_APPEARANCE_SOURCE to the assembled Telegram tree for full-source tests.
Install tree-sitter and tree-sitter-swift to enable the syntax checks. Run with -B
to avoid Python bytecode writes when working in an isolated porting slice.
"""

import os
from pathlib import Path
import re
import sys
import unittest

WHITEGRAM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WHITEGRAM))

from appearance_patches import apply_appearance_patches

try:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
except ImportError:
    Parser = None


FONT_PATH = "submodules/Display/Source/Font.swift"
SIGNATURE = "    public static func with(size: CGFloat, design: Design = .regular, weight: Weight = .regular, width: Width = .standard, traits: Traits = []) -> UIFont {\n"
HOOK = (
    "        if let customFont = WhitegramFontRegistry.shared.font(size: size, design: design, weight: weight, width: width, traits: traits) {\n"
    "            return customFont\n"
    "        }\n"
)
CONVENIENCE_SOURCE = """    public static func regular(_ size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size)
    }

    public static func medium(_ size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: UIFont.Weight.medium)
    }

    public static func semibold(_ size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: UIFont.Weight.semibold)
    }

    public static func bold(_ size: CGFloat) -> UIFont {
        if #available(iOS 8.2, *) {
            return UIFont.boldSystemFont(ofSize: size)
        } else {
            return CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        }
    }

    public static func heavy(_ size: CGFloat) -> UIFont {
        return self.with(size: size, design: .regular, weight: .heavy, traits: [])
    }

    public static func light(_ size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: UIFont.Weight.light)
    }

    public static func semiboldItalic(_ size: CGFloat) -> UIFont {
        if let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
            return UIFont(descriptor: descriptor, size: size)
        } else {
            return UIFont.italicSystemFont(ofSize: size)
        }
    }

    public static func monospace(_ size: CGFloat) -> UIFont {
        return UIFont(name: "Menlo-Regular", size: size - 1.0) ?? UIFont.systemFont(ofSize: size)
    }

    public static func semiboldMonospace(_ size: CGFloat) -> UIFont {
        return UIFont(name: "Menlo-Bold", size: size - 1.0) ?? UIFont.systemFont(ofSize: size)
    }

    public static func italicMonospace(_ size: CGFloat) -> UIFont {
        return UIFont(name: "Menlo-Italic", size: size - 1.0) ?? UIFont.systemFont(ofSize: size)
    }

    public static func semiboldItalicMonospace(_ size: CGFloat) -> UIFont {
        return UIFont(name: "Menlo-BoldItalic", size: size - 1.0) ?? UIFont.systemFont(ofSize: size)
    }

    public static func italic(_ size: CGFloat) -> UIFont {
        return UIFont.italicSystemFont(ofSize: size)
    }
"""
# Independent expectations: do not import the production hook table into this fixture.
EXPECTED_CONVENIENCE = {
    "regular": ("regular", "[]"),
    "medium": ("medium", "[]"),
    "semibold": ("semibold", "[]"),
    "bold": ("bold", "[]"),
    "light": ("light", "[]"),
    "semiboldItalic": ("semibold", "[.italic]"),
    "italic": ("regular", "[.italic]"),
}
EXPECTED_INSERTIONS = {SIGNATURE: HOOK}
for name, (weight, traits) in EXPECTED_CONVENIENCE.items():
    EXPECTED_INSERTIONS[f"    public static func {name}(_ size: CGFloat) -> UIFont {{\n"] = (
        "        if let customFont = WhitegramFontRegistry.shared.font(size: size, design: .regular, "
        f"weight: .{weight}, width: .standard, traits: {traits}) {{\n"
        "            return customFont\n"
        "        }\n"
    )

ORIGINAL = (
    "import UIKit\n\npublic struct Font {\n"
    + SIGNATURE
    + '        let key = "\\(size)_\\(design.key)_\\(weight.key)_\\(width.key)_\\(traits.rawValue)"\n'
    + "        if let cachedFont = self.cache.get(key) {\n"
    + "            return cachedFont\n"
    + "        }\n"
    + "        return UIFont.systemFont(ofSize: size)\n"
    + "    }\n"
    + CONVENIENCE_SOURCE
    + "}\n"
)
SOURCE = os.environ.get("WHITEGRAM_APPEARANCE_SOURCE")
SWIFT_FILES = (
    "WhitegramFontRegistry.swift",
    "WhitegramFontHistory.swift",
    "WhitegramFontArchivePlan.swift",
    "WhitegramFontArchiveImport.swift",
    "WhitegramFontsController.swift",
    "WhitegramIconsController.swift",
)


def without_hooks(source):
    for hook in EXPECTED_INSERTIONS.values():
        source = source.replace(hook, "")
    return source


def function_body(source, name):
    match = re.search(
        r"^    public static func " + re.escape(name) + r"\([^\n]*\) -> UIFont \{\n(.*?)^    \}",
        source,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"Missing function in fixture: {name}")
    return match.group(1)


class MemoryFile:
    def __init__(self, root, path):
        self.root = root
        self.path = path

    def read_text(self, encoding):
        if self.path not in self.root.files:
            raise FileNotFoundError(self.path)
        return self.root.files[self.path].decode(encoding).replace("\r\n", "\n").replace("\r", "\n")

    def write_bytes(self, value):
        self.root.writes.append(self.path)
        self.root.files[self.path] = value
        return len(value)


class MemoryRoot:
    def __init__(self, content=ORIGINAL):
        self.files = {
            FONT_PATH: content.encode("utf-8"),
            "submodules/Display/Source/Other.swift": b"// Leave unrelated source alone.\n",
            "Telegram/Telegram-iOS/Info.plist": b"<dict/>\n",
        }
        self.writes = []

    def __truediv__(self, path):
        return MemoryFile(self, path)

    def font(self):
        return self.files[FONT_PATH].decode("utf-8")


class AppearancePatchTests(unittest.TestCase):
    def test_hook_precedes_system_cache_and_preserves_the_original_body(self):
        root = MemoryRoot()
        report = apply_appearance_patches(root)
        self.assertEqual(report, {"customFonts": [FONT_PATH]})
        self.assertEqual(function_body(root.font(), "with"), HOOK + function_body(ORIGINAL, "with"))
        self.assertLess(root.font().index(HOOK), root.font().index("let key ="))
        self.assertLess(root.font().index(HOOK), root.font().index("self.cache.get(key)"))
        self.assertEqual(without_hooks(root.font()), ORIGINAL)

    def test_all_convenience_weights_traits_and_disabled_fallbacks_are_preserved(self):
        root = MemoryRoot()
        apply_appearance_patches(root)
        for name in EXPECTED_CONVENIENCE:
            with self.subTest(helper=name):
                signature = f"    public static func {name}(_ size: CGFloat) -> UIFont {{\n"
                hook = EXPECTED_INSERTIONS[signature]
                self.assertEqual(function_body(root.font(), name), hook + function_body(ORIGINAL, name))
                self.assertEqual(root.font().count(signature + hook), 1)
        self.assertEqual(root.font().count("WhitegramFontRegistry.shared.font("), 8)

    def test_heavy_delegation_and_all_monospace_helpers_are_preserved(self):
        root = MemoryRoot()
        apply_appearance_patches(root)
        for name in ("heavy", "monospace", "semiboldMonospace", "italicMonospace", "semiboldItalicMonospace"):
            with self.subTest(helper=name):
                self.assertEqual(function_body(root.font(), name), function_body(ORIGINAL, name))
                self.assertNotIn("WhitegramFontRegistry", function_body(root.font(), name))
        self.assertIn("return self.with(size: size, design: .regular, weight: .heavy, traits: [])", function_body(root.font(), "heavy"))

    def test_with_only_patch_upgrades_without_duplicate_hooks(self):
        root = MemoryRoot(ORIGINAL.replace(SIGNATURE, SIGNATURE + HOOK))
        apply_appearance_patches(root)
        for signature, hook in EXPECTED_INSERTIONS.items():
            self.assertEqual(root.font().count(signature + hook), 1)
        self.assertEqual(without_hooks(root.font()), ORIGINAL)
        self.assertEqual(root.writes, [FONT_PATH])
        root.writes.clear()
        apply_appearance_patches(root)
        self.assertEqual(root.writes, [])

    def test_mixed_original_and_applied_font_anchors_fail_before_writes(self):
        root = MemoryRoot()
        apply_appearance_patches(root)
        root.files[FONT_PATH] += (SIGNATURE + "        return UIFont.systemFont(ofSize: size)\n    }\n").encode()
        before = dict(root.files)
        root.writes.clear()
        with self.assertRaises(ValueError):
            apply_appearance_patches(root)
        self.assertEqual(root.files, before)
        self.assertEqual(root.writes, [])

    def test_second_application_does_not_write_or_duplicate_the_hook(self):
        root = MemoryRoot()
        first_report = apply_appearance_patches(root)
        first_result = dict(root.files)
        root.writes.clear()
        self.assertEqual(apply_appearance_patches(root), first_report)
        self.assertEqual(root.files, first_result)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.font().count("WhitegramFontRegistry.shared.font("), 8)

    def test_only_display_font_is_written(self):
        root = MemoryRoot()
        other_files = {path: value for path, value in root.files.items() if path != FONT_PATH}
        apply_appearance_patches(root)
        self.assertEqual(root.writes, [FONT_PATH])
        self.assertEqual({path: value for path, value in root.files.items() if path != FONT_PATH}, other_files)

    def test_changed_signature_fails_before_any_write(self):
        root = MemoryRoot(ORIGINAL.replace("width: Width = .standard", "width: Width"))
        before = dict(root.files)
        with self.assertRaisesRegex(ValueError, "expected 1 anchors, found 0"):
            apply_appearance_patches(root)
        self.assertEqual(root.files, before)
        self.assertEqual(root.writes, [])

    def test_ambiguous_signature_fails_before_any_write(self):
        root = MemoryRoot(ORIGINAL + ORIGINAL)
        before = dict(root.files)
        with self.assertRaisesRegex(ValueError, "expected 1 anchors, found 2"):
            apply_appearance_patches(root)
        self.assertEqual(root.files, before)
        self.assertEqual(root.writes, [])

    def test_missing_late_convenience_anchor_refuses_all_pending_writes(self):
        root = MemoryRoot(ORIGINAL.replace("func italic(_", "func renamedItalic(_"))
        before = dict(root.files)
        with self.assertRaisesRegex(ValueError, "expected 1 anchors, found 0"):
            apply_appearance_patches(root)
        self.assertEqual(root.files, before)
        self.assertEqual(root.writes, [])

    def test_missing_source_does_not_create_a_stub(self):
        root = MemoryRoot()
        del root.files[FONT_PATH]
        with self.assertRaises(FileNotFoundError):
            apply_appearance_patches(root)
        self.assertNotIn(FONT_PATH, root.files)
        self.assertEqual(root.writes, [])

    def test_crlf_checkout_uses_source_patches_text_normalization(self):
        root = MemoryRoot(ORIGINAL.replace("\n", "\r\n"))
        apply_appearance_patches(root)
        self.assertEqual(without_hooks(root.font()), ORIGINAL)

    @unittest.skipUnless(SOURCE, "WHITEGRAM_APPEARANCE_SOURCE is not set")
    def test_full_telegram_source_patch_is_exact_and_idempotent(self):
        original = (Path(SOURCE) / FONT_PATH).read_text(encoding="utf-8")
        pristine = without_hooks(original)
        inputs = {
            "pristine": pristine,
            "with_only": pristine.replace(SIGNATURE, SIGNATURE + HOOK),
            "assembled": original,
        }
        for stage, source in inputs.items():
            with self.subTest(stage=stage):
                root = MemoryRoot(source)
                apply_appearance_patches(root)
                self.assertEqual(without_hooks(root.font()), pristine)
                for signature, hook in EXPECTED_INSERTIONS.items():
                    self.assertEqual(root.font().count(signature + hook), 1)
                for name in ("with", *EXPECTED_CONVENIENCE):
                    self.assertEqual(without_hooks(function_body(root.font(), name)), function_body(pristine, name))
                self.assertEqual(root.font().count("WhitegramFontRegistry.shared.font("), 8)
                expected_writes = [] if all(signature + hook in source for signature, hook in EXPECTED_INSERTIONS.items()) else [FONT_PATH]
                self.assertEqual(root.writes, expected_writes)
                root.writes.clear()
                apply_appearance_patches(root)
                self.assertEqual(root.writes, [])


@unittest.skipIf(Parser is None, "tree-sitter and tree-sitter-swift are not installed")
class AppearanceSwiftSyntaxTests(unittest.TestCase):
    def assert_swift_parses(self, name, source):
        parser = Parser(Language(tree_sitter_swift.language()))
        root = parser.parse(source).root_node
        errors = []
        pending = [root]
        while pending:
            node = pending.pop()
            if node.type == "ERROR" or node.is_missing:
                errors.append(f"{name}:{node.start_point.row + 1}:{node.start_point.column + 1}: {node.type}")
            pending.extend(reversed(node.children))
        self.assertFalse(root.has_error, "\n".join(errors))
        self.assertEqual(errors, [])

    def test_cleanroom_swift_syntax(self):
        for name in SWIFT_FILES:
            with self.subTest(file=name):
                self.assert_swift_parses(name, (WHITEGRAM / "cleanroom" / name).read_bytes())

    def test_patched_font_syntax(self):
        original = (Path(SOURCE) / FONT_PATH).read_text(encoding="utf-8") if SOURCE else ORIGINAL
        root = MemoryRoot(original)
        apply_appearance_patches(root)
        self.assert_swift_parses(FONT_PATH, root.files[FONT_PATH])


if __name__ == "__main__":
    unittest.main()
