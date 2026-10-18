"""Verify the assembled resource inputs and the packaged icon verification gate."""

import copy
import io
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import launcher_icon_patches as launcher
import settings_icon_patches as settings
from test_history_patches import parse_sources
from verify_ipa import verify_restored_icon_archive


class IconIntegrationTests(unittest.TestCase):
    def test_swift_policy_picker_and_native_tests_parse(self):
        names = ["cleanroom/WhitegramIconSettings.swift", "cleanroom/WhitegramIconsController.swift",
                 "tests/localization/WhitegramIconSettingsTests.swift"]
        sources = {name: (ROOT / name).read_text(encoding="utf-8") for name in names}
        self.assertEqual(parse_sources(sources), {name: [] for name in names})
        picker = sources[names[1]]
        self.assertIn("for binding in bindings where !binding.isDefault", picker)
        self.assertIn("guard let metadata = alternates[name]", picker)
        self.assertIn("WhitegramPreferences.updatedNotification", picker)
        compat = (ROOT / "compat-12.9.4.py").read_text(encoding="utf-8")
        for symbol in ("SETTINGS_ICON_RUNTIME_FILES", "apply_settings_icon_patches", "apply_launcher_icon_patches",
                       "install_settings_icon_resources", "install_launcher_icon_resources"):
            self.assertGreaterEqual(compat.count(symbol), 2)

    def test_archive_gate_checks_flat_images_both_families_and_lossless_reencoding(self):
        files = {**launcher.load_launcher_icon_resources(), **settings.load_settings_icon_resources()}
        alternatives = launcher.stock_alternate_icon_entries()
        for name in launcher.WG_ICONS:
            alternatives[name] = {"CFBundleIconFiles": [name]}
            files[name + "@2x.png"] = b"retained WG fixture"
        files["WGPrimary@2x.png"] = b"retained primary fixture"
        info = {"CFBundlePackageType": "APPL"}
        for family in ("CFBundleIcons", "CFBundleIcons~ipad"):
            info[family] = {"CFBundlePrimaryIcon": {"CFBundleIconName": "WGPrimary", "CFBundleIconFiles": ["WGPrimary"]},
                            "CFBundleAlternateIcons": copy.deepcopy(alternatives)}
        for mutation in (None, "lossless", "nested-settings", "missing-stock", "broken-ipad"):
            with self.subTest(mutation=mutation):
                images, metadata = files.copy(), copy.deepcopy(info)
                glyph = settings.RESOURCE_FILES[0]
                if mutation == "lossless":
                    payload = b"Fixture\x00Lossless metadata change"
                    chunk = struct.pack(">I", len(payload)) + b"tEXt" + payload + struct.pack(">I", zlib.crc32(b"tEXt" + payload))
                    images[glyph] = images[glyph][:-12] + chunk + images[glyph][-12:]
                elif mutation == "nested-settings":
                    images["Nested/" + glyph] = images.pop(glyph)
                elif mutation == "missing-stock":
                    del images["New2@3x.png"]
                elif mutation == "broken-ipad":
                    del metadata["CFBundleIcons~ipad"]["CFBundleAlternateIcons"]["New1"]
                data = io.BytesIO()
                with zipfile.ZipFile(data, "w") as archive:
                    archive.writestr("Payload/Telegram.app/Info.plist", plistlib.dumps(metadata))
                    for name, contents in images.items():
                        archive.writestr("Payload/Telegram.app/" + name, contents)
                with zipfile.ZipFile(data) as archive:
                    if mutation in (None, "lossless"):
                        report = verify_restored_icon_archive(archive)
                        self.assertEqual(len(report["settings"]), 40)
                        self.assertEqual(len(report["launcher"]["files"]), 66)
                    else:
                        with self.assertRaises(ValueError):
                            verify_restored_icon_archive(archive)

    @unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
    def test_resource_installers_compose_and_replay_together(self):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        for order in ((settings.install_settings_icon_resources, launcher.install_launcher_icon_resources),
                      (launcher.install_launcher_icon_resources, settings.install_settings_icon_resources)):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "Telegram").mkdir()
                (root / "Telegram/BUILD").write_bytes((source / "Telegram/BUILD").read_bytes())
                for install in order:
                    install(root)
                first = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
                for install in reversed(order):
                    install(root)
                self.assertEqual(first, {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()})


if __name__ == "__main__":
    unittest.main()
