"""Check settings API migration and replay against both list protocol generations."""

import os
from pathlib import Path
import re
import unittest

from test_history_patches import MemoryRoot, parse_sources
from settings_api_patches import SETTINGS, SLIDER_FILES, apply_settings_api_patches


OVERLAY = Path(__file__).resolve().parents[1]
PROTOCOL = "submodules/Display/Source/ListViewItem.swift"
PROXY_TYPE = "submodules/TelegramCore/Sources/SyncCore/SyncCore_ProxySettings.swift"
PROXY_UI = SETTINGS + "Data and Storage/ProxyListSettingsController.swift"
LEGACY_NEIGHBORS = "previousItem: ListViewItem?, nextItem: ListViewItem?,"
NEIGHBORS = "neighbors: ListViewItemNeighbors,"
PROXY_STATUS = """private func proxySettingsDisplayStatus(strings: PresentationStrings, server: ProxyServerSettings, status: ProxyServerStatus) -> DisplayProxyServerStatus {
    var text: String
    switch server.connection {
        case .socks5:
            text = strings.ChatSettings_ConnectionType_UseSocks5
        case .mtp:
            text = strings.SocksProxySetup_ProxyTelegram
    }
    switch status {
        case .checking:
            return DisplayProxyServerStatus(activity: false, text: text, textActive: false)
    }
}
"""


def fixture():
    row = (OVERLAY / "cleanroom/WhitegramAppearanceSliderItem.swift").read_text(encoding="utf-8")
    files = {SETTINGS + name: row for name in SLIDER_FILES}
    files[PROTOCOL] = "func nodeConfiguredForParams(neighbors: ListViewItemNeighbors)"
    files[PROXY_TYPE] = "case web(secret: Data, path: String)"
    files[PROXY_UI] = PROXY_STATUS
    return MemoryRoot(files)


class SettingsAPIPatchTests(unittest.TestCase):
    def test_rows_migrate_together_and_replay_without_writes(self):
        root = fixture()
        report = apply_settings_api_patches(root)
        self.assertEqual(len(root.writes), 5)
        for name in SLIDER_FILES:
            self.assertNotIn(LEGACY_NEIGHBORS, root.text(SETTINGS + name))
            self.assertEqual(root.text(SETTINGS + name).count(NEIGHBORS), 2)
        self.assertIn("case .web:\n            text = strings.SocksProxySetup_ProxyWeb", root.text(PROXY_UI))
        root.writes.clear()
        self.assertEqual(apply_settings_api_patches(root), report)
        self.assertEqual(root.writes, [])

    def test_older_protocol_and_proxy_enum_do_not_gain_unknown_types(self):
        root = fixture()
        root.files[PROTOCOL] = LEGACY_NEIGHBORS.encode()
        root.files[PROXY_TYPE] = b"case socks5\ncase mtp"
        before = root.texts()
        self.assertEqual(apply_settings_api_patches(root), {})
        self.assertEqual(root.texts(), before)
        self.assertEqual(root.writes, [])

    def test_incomplete_or_duplicate_signature_migration_is_rejected(self):
        for malformed in (NEIGHBORS + LEGACY_NEIGHBORS, LEGACY_NEIGHBORS * 3):
            with self.subTest(source=malformed):
                root = fixture()
                root.files[SETTINGS + SLIDER_FILES[-1]] = malformed.encode()
                before = root.texts()
                with self.assertRaises(ValueError):
                    apply_settings_api_patches(root)
                self.assertEqual(root.texts(), before)
                self.assertEqual(root.writes, [])

    def test_late_proxy_anchor_failure_does_not_write_any_rows(self):
        root = fixture()
        root.files[PROXY_UI] = b"changed upstream proxy layout"
        before = root.texts()
        with self.assertRaises(ValueError):
            apply_settings_api_patches(root)
        self.assertEqual(root.texts(), before)
        self.assertEqual(root.writes, [])


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class SettingsAPIIntegrationTests(unittest.TestCase):
    def test_all_four_row_signatures_match_the_actual_target_protocol(self):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        paths = [PROTOCOL, PROXY_TYPE, PROXY_UI, *(SETTINGS + name for name in SLIDER_FILES)]
        root = MemoryRoot({path: (source / path).read_text(encoding="utf-8") for path in paths})
        apply_settings_api_patches(root)
        for method in ("nodeConfiguredForParams", "updateNode"):
            declaration = next(line.strip() for line in root.text(PROTOCOL).splitlines() if line.strip().startswith("func " + method + "("))
            for name in SLIDER_FILES:
                with self.subTest(method=method, source=name):
                    self.assertIn(declaration + " {", root.text(SETTINGS + name))
        if "case web(" in root.text(PROXY_TYPE):
            status = root.text(PROXY_UI).split("private func proxySettingsDisplayStatus", 1)[1].split("    switch status {", 1)[0]
            self.assertEqual(set(re.findall(r"case \.(\w+)", status)), {"socks5", "mtp", "web"})
        for path, diagnostics in parse_sources({path: root.text(path) for path in paths if path.startswith(SETTINGS)}).items():
            with self.subTest(source=path):
                self.assertEqual(diagnostics, [])


if __name__ == "__main__":
    unittest.main()
