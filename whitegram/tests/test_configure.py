"""Regression for CloudKit initialization in re-signed distributions."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


class SideloadConfigurationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="whitegram-configure-")
        self.addCleanup(temporary.cleanup)
        self.source = Path(temporary.name)
        self.configuration = {
            "bundle_id": "ph.telegra.Telegraph", "api_id": "1", "api_hash": "fixture",
            "team_id": "fixture", "app_center_id": "0", "is_internal_build": "false",
            "is_appstore_build": "true", "appstore_id": "1", "app_specific_url_scheme": "tg",
            "premium_iap_product_id": "fixture", "enable_siri": True, "enable_icloud": True,
        }
        files = {
            "build-system/appstore-configuration.json": json.dumps(self.configuration),
            "versions.json": json.dumps({"app": "12.9.2", "xcode": "26"}),
            "Telegram/BUILD": '<key>CFBundleDisplayName</key>\n<string>Telegram</string>\nname = "disableProvisioningProfiles",\nbuild_setting_default = True',
            "Telegram/Telegram-iOS/Config-AppStoreLLC.xcconfig": "APP_NAME=Telegram\nAPP_BUNDLE_ID=ph.telegra.Telegraph\nAPP_SPECIFIC_URL_SCHEME=tg\n",
            "Telegram/Telegram-iOS/Config-Fork.xcconfig": "APP_NAME=Telegram\nAPP_BUNDLE_ID=ph.telegra.Telegraph\nAPP_SPECIFIC_URL_SCHEME=tg\n",
        }
        for name, value in files.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value, encoding="utf-8")

    def configure(self):
        result = subprocess.run([sys.executable, "-B", str(ROOT / "configure.py"), str(self.source)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads((self.source / "build-system/appstore-configuration.json").read_text())

    def test_sideload_build_disables_unprovisioned_cloudkit_and_is_replayable(self):
        configured = self.configure()
        self.assertIs(configured["enable_icloud"], False)
        for key in ("api_id", "api_hash", "enable_siri", "team_id"):
            self.assertEqual(configured[key], self.configuration[key])
        self.assertEqual(self.configure(), configured)

    def test_original_icon_replaces_public_primary_and_preserves_all_appearances(self):
        catalog = self.source / "Telegram/Telegram-iOS/DefaultAppIcon.xcassets"
        previous = catalog / "AppIconLLC.appiconset"
        previous.mkdir(parents=True)
        (previous / "Contents.json").write_text('{"images": []}')
        (previous / "BlueIcon@2x-1.png").write_bytes(b"unassigned legacy icon")
        self.configure()
        destination = catalog / "WGPrimary.appiconset"
        self.assertFalse(previous.exists())
        contents = json.loads((destination / "Contents.json").read_text())
        self.assertEqual(len(contents["images"]), 3)
        self.assertEqual({path.name for path in destination.glob("*.png")}, {entry["filename"] for entry in contents["images"]})
        self.assertEqual([entry.get("appearances", []) for entry in contents["images"]], [[], [{"appearance": "luminosity", "value": "dark"}], [{"appearance": "luminosity", "value": "tinted"}]])
        manifest = json.loads((ROOT / "resources/primary-icon/manifest.json").read_text())
        for entry in manifest["images"]:
            with Image.open(destination / entry["file"]) as image:
                self.assertEqual(image.size, (1024, 1024))
                self.assertEqual(hashlib.sha256(image.convert("RGBA").tobytes()).hexdigest(), entry["rgba_sha256"])
        before = (destination / "Contents.json").read_bytes()
        self.configure()
        self.assertEqual((destination / "Contents.json").read_bytes(), before)

    @unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
    def test_upstream_generator_propagates_disabled_cloudkit_to_compiler_variables(self):
        self.configure()
        make = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"]) / "build-system/Make"
        output = self.source / "variables.bzl"
        code = (
            "import sys; sys.path.insert(0, sys.argv[1]); "
            "from BuildConfiguration import build_configuration_from_json; "
            "build_configuration_from_json(sys.argv[2]).write_to_variables_file('bazel', False, 'development', sys.argv[3])"
        )
        result = subprocess.run([sys.executable, "-B", "-c", code, str(make), str(self.source / "build-system/appstore-configuration.json"), str(output)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("telegram_enable_icloud = False\n", output.read_text())


if __name__ == "__main__":
    unittest.main()
