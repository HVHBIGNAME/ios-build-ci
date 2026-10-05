import json
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from history_patches import _message_menu_patch
from service_patches import ACTION, LEGACY_ACTION, MENU, SERVICES_RUNTIME_FILES, service_patches
from source_patches import SourcePatches


class ServiceRuntimeManifestTests(unittest.TestCase):
    def test_all_service_runtime_sources_have_an_explicit_destination(self):
        files = {path.name for path in (ROOT / "cleanroom").glob("*.swift") if path.name.startswith(("WhitegramAI", "WhitegramService", "WhitegramVirusTotal"))}
        self.assertEqual(files, set(SERVICES_RUNTIME_FILES))
        self.assertTrue(all(path.startswith("submodules/SettingsUI/Sources/") for path in SERVICES_RUNTIME_FILES.values()))
        handoff = json.loads((ROOT / "parity/services.json").read_text(encoding="utf-8"))
        service_files = {name: destination for name, destination in handoff["runtime_files"].items() if name.startswith(("WhitegramAI", "WhitegramService", "WhitegramVirusTotal"))}
        self.assertEqual(SERVICES_RUNTIME_FILES, service_files)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class ServiceMenuIntegrationTests(unittest.TestCase):
    def test_history_and_indicator_actions_compose_without_duplicate_or_implicit_request(self):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        patches = SourcePatches(root)
        _message_menu_patch(patches)
        service_patches(patches)
        once = dict(patches.pending)
        _message_menu_patch(patches)
        service_patches(patches)
        self.assertEqual(once, patches.pending)
        text = patches.pending[MENU]
        self.assertEqual(text.count("whitegramVirusTotalTargets(text:"), 1)
        self.assertEqual(text.count("whitegramMessageHistoryController("), 1)
        self.assertIn("targets: whitegramTargets", text)
        self.assertIn("message: EngineMessage(message)", text)
        self.assertIn("whitegramHasFile || !whitegramTargets.isEmpty", text)
        self.assertIn('WhitegramPreferences.bool("virusTotalEnabled") && !isAction', text)
        self.assertNotIn("whitegramLookupVirusTotalTarget(", text)
        self.assertEqual((root / MENU).read_text(encoding="utf-8"), patches.original[MENU])

    def test_missing_duplicate_and_partial_actions_fail_before_any_write(self):
        root = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        base = SourcePatches(root)
        service_patches(base)
        anchor = "        let isMigrated: Bool\n"
        unpatched = base.original[MENU].replace(LEGACY_ACTION, "").replace(ACTION, "")
        for broken in (unpatched.replace(anchor, ""), unpatched + anchor, unpatched + ACTION, base.pending[MENU] + ACTION, base.pending[MENU] + LEGACY_ACTION):
            patches = SourcePatches(root)
            patches.read(MENU)
            patches.pending[MENU] = broken
            with self.assertRaises(ValueError):
                service_patches(patches)
            self.assertEqual((root / MENU).read_text(encoding="utf-8"), base.original[MENU])
