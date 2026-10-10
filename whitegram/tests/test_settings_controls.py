"""Verify settings bindings, new runtime syntax and original localization references."""

import json
from pathlib import Path
import re
import unittest

from test_history_patches import parse_sources

ROOT = Path(__file__).resolve().parents[1]


class SettingsControlsTests(unittest.TestCase):
    def test_new_runtime_and_native_fixtures_parse(self):
        files = [ROOT / "cleanroom" / name for name in (
            "WhitegramSettingsList.swift", "WhitegramSettingsNumber.swift", "WhitegramAppearanceSliderItem.swift",
            "WhitegramStickerSettings.swift", "WhitegramMessageShortening.swift", "WhitegramDiagnosticsController.swift",
            "WhitegramHistoryMessageAttribute.swift", "WhitegramHistoryRuntime.swift",
        )]
        files += [ROOT / "tests/localization/WhitegramSettingsListTests.swift", ROOT / "tests/history/WhitegramMessageShorteningTests.swift"]
        errors = parse_sources({str(path): path.read_text(encoding="utf-8") for path in files})
        for path, errors in errors.items():
            with self.subTest(path=path):
                self.assertEqual(errors, [])

    def test_explicit_row_titles_and_help_exist_in_recovered_dictionary(self):
        table = (ROOT / "generated/WhitegramLocalizationStrings.swift").read_text(encoding="utf-8")
        entries = {json.loads(key) for key in re.findall(r'^\s*("(?:[^"\\]|\\.)+"):\s*\[', table, re.M)}
        capabilities = (ROOT / "cleanroom/WhitegramPortCapabilities.swift").read_text(encoding="utf-8")
        for name in ("informationKeys", "titleKeys"):
            block = capabilities.split(f"static let {name}:", 1)[1].split("\n    ]", 1)[0]
            pairs = re.findall(r'"([^"]+)": "([^"]+)"', block)
            self.assertEqual(len(pairs), len(dict(pairs)), name)
            for row, key in pairs:
                with self.subTest(row=row, key=key):
                    self.assertIn(key, entries)

    def test_every_screen_destination_has_a_dispatch_branch(self):
        capabilities = (ROOT / "cleanroom/WhitegramPortCapabilities.swift").read_text(encoding="utf-8")
        block = capabilities.split("static let screens:", 1)[1].split("\n    ]", 1)[0]
        targets = {value for _, value in re.findall(r'"([^"]+)": "([^"]+)"', block)}
        renderer = (ROOT / "cleanroom/WhitegramGeneratedSettingsScreen.swift").read_text(encoding="utf-8")
        dispatch = renderer.split("switch screen {", 1)[1].split("default: return", 1)[0]
        self.assertFalse(targets - set(re.findall(r'case "([^"]+)":', dispatch)))

    def test_mutually_exclusive_settings_use_the_existing_atomic_change_builders(self):
        renderer = (ROOT / "cleanroom/WhitegramGeneratedSettingsScreen.swift").read_text(encoding="utf-8")
        self.assertIn("WhitegramGlassSettings.changes(for: toggle, enabled: value)", renderer)
        self.assertIn("WhitegramAppearanceSettings.changes(for: toggle, enabled: value)", renderer)
        self.assertIn("WhitegramPreferences.update(changes)", renderer)
        self.assertIn("registerForNotifications", renderer)
        numeric = (ROOT / "cleanroom/WhitegramSettingsNumber.swift").read_text(encoding="utf-8")
        self.assertIn('"voiceChangerPreset": WhitegramVoicePreset.custom.rawValue', numeric)
        self.assertIn("self.range.contains(value)", numeric)


if __name__ == "__main__":
    unittest.main()
