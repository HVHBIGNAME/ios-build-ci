"""Compose all appearance passes against the ready reference without writing it."""

import ast
import os
from pathlib import Path
import re
import sys
import unittest

WHITEGRAM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WHITEGRAM))

import appearance_patches as fonts
import appearance_extension_patches as extensions
import appearance_parity_patches as parity
import appearance_glass_patches as glass
import appearance_icon_pack_patches as icons
from test_appearance_extensions import MemoryRoot, syntax_errors, TARGETS as EXTENSION_TARGETS
from test_appearance_parity import TARGETS as PARITY_TARGETS
from test_appearance_glass import TARGETS as GLASS_TARGETS
from test_appearance_icon_packs import TARGETS as ICON_TARGETS

SOURCE = os.environ.get("WHITEGRAM_APPEARANCE_SOURCE")
PASSES = (
    fonts.apply_appearance_patches,
    extensions.apply_appearance_extensions,
    parity.apply_appearance_parity_patches,
    icons.apply_appearance_icon_pack_patches,
    glass.apply_appearance_glass_patches,
)
MAPS = (
    fonts.APPEARANCE_RUNTIME_FILES,
    extensions.APPEARANCE_EXTENSION_RUNTIME_FILES,
    parity.APPEARANCE_PARITY_RUNTIME_FILES,
    glass.APPEARANCE_GLASS_RUNTIME_FILES,
    icons.APPEARANCE_ICON_PACK_RUNTIME_FILES,
)


class AppearanceCompositionSourceTests(unittest.TestCase):
    def test_runtime_maps_are_complete_unique_and_parse(self):
        names = [name for mapping in MAPS for name in mapping]
        destinations = [path for mapping in MAPS for path in mapping.values()]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(len(destinations), len(set(destinations)))
        for name in names:
            with self.subTest(name=name):
                self.assertEqual(syntax_errors((WHITEGRAM / "cleanroom" / name).read_bytes()), [])

    def test_all_owned_python_modules_and_native_runner_parse(self):
        paths = list(WHITEGRAM.glob("appearance*_patches.py"))
        paths += list((WHITEGRAM / "tests" / "appearance_parity").glob("*.py"))
        for path in paths:
            with self.subTest(path=path.name):
                ast.parse(path.read_text(encoding="utf-8"))

    def test_known_localized_controls_use_recovered_dictionary_entries(self):
        table = (WHITEGRAM / "generated" / "WhitegramLocalizationStrings.swift").read_text(encoding="utf-8")
        keys = set(re.findall(r'^\s*"([^"]+)": \[', table, re.M))
        for mapping in MAPS:
            for name in mapping:
                if not name.endswith("Controller.swift") or name == "WhitegramIconsController.swift":
                    continue
                source = (WHITEGRAM / "cleanroom" / name).read_text(encoding="utf-8")
                used = re.findall(r'"((?:s\.|wh\.|common\.|auto\.WhitegramSettingsController\.)[^"\n]+)"', source)
                for key in used:
                    if key in ("s.",):
                        continue
                    with self.subTest(name=name, key=key):
                        self.assertIn(key, keys)

    def test_font_family_import_is_coordinated_and_committed_after_registration(self):
        registry = (WHITEGRAM / "cleanroom" / "WhitegramFontRegistry.swift").read_text(encoding="utf-8")
        controller = (WHITEGRAM / "cleanroom" / "WhitegramFontsController.swift").read_text(encoding="utf-8")
        importer = (WHITEGRAM / "cleanroom" / "WhitegramFontArchiveImport.swift").read_text(encoding="utf-8")
        self.assertIn("[.font, .zip]", controller)
        self.assertIn("NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt:", controller)
        self.assertIn("WhitegramFontArchiveImport.read(coordinatedURL)", controller)
        start = registry.index("public func importFonts(")
        end = registry.index("public func removeFont(", start)
        batch = registry[start:end]
        self.assertLess(batch.index("try self.register(entry.url)"), batch.index("self.files[entry.url.lastPathComponent] = entry.records"))
        self.assertIn("for url in registered.reversed()", batch)
        self.assertIn("for url in copied", batch)
        self.assertIn("CTFontManagerUnregisterFontsForURL", batch)
        self.assertIn("WhitegramFontArchivePlan.fonts(in:", importer)
        self.assertIn("UInt64(size) == entry.size", importer)
        self.assertIn("importFonts(from: sources)", importer)


@unittest.skipUnless(SOURCE, "Set WHITEGRAM_APPEARANCE_SOURCE to the ready assembled 12.9.2 reference")
class AppearanceCompositionTests(unittest.TestCase):
    def test_complete_sequence_is_idempotent_and_all_patched_swift_parses(self):
        paths = {fonts.FONT_PATH, *EXTENSION_TARGETS, *PARITY_TARGETS, *GLASS_TARGETS, *ICON_TARGETS}
        files = {name: (Path(SOURCE) / name).read_text(encoding="utf-8") for name in paths}
        root = MemoryRoot({**files, "unrelated.swift": "// Another role's work\r\n"})
        reports = [apply(root) for apply in PASSES]
        first = dict(root.files)
        root.writes.clear()
        self.assertEqual([apply(root) for apply in PASSES], reports)
        self.assertEqual(root.files, first)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.files["unrelated.swift"], b"// Another role's work\r\n")
        for path in paths:
            if path.endswith(".swift"):
                with self.subTest(path=path):
                    self.assertEqual(syntax_errors(root.files[path]), [])


if __name__ == "__main__":
    unittest.main()
