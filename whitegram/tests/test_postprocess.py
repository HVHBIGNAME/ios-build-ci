"""Exercise private build-key injection against an isolated app payload."""

import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest


POSTPROCESS = Path(__file__).resolve().parents[1] / "postprocess.py"
KEY_NAME = "WhitegramBackendApplicationKey"
ENV_NAME = "WHITEGRAM_BACKEND_APPLICATION_KEY"
SYNTHETIC_KEY = base64.b64encode(bytes(range(32, 64))).decode("ascii")


class PostprocessSigningConfigurationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="whitegram-postprocess-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "Payload/Telegram.app"
        self.extension = self.app / "PlugIns/Share.appex"
        self.extension.mkdir(parents=True)
        for directory, identifier in ((self.app, "ph.telegra.Telegraph"), (self.extension, "ph.telegra.Telegraph.Share")):
            (directory / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        signature = self.app / "_CodeSignature"
        signature.mkdir()
        (signature / "CodeResources").write_bytes(b"synthetic signature")

    def run_postprocess(self, key):
        environment = dict(os.environ)
        environment.pop(ENV_NAME, None)
        for name in ("WHITEGRAM_DIAGNOSTICS_URL", "WHITEGRAM_DIAGNOSTICS_UPLOAD_KEY"):
            environment.pop(name, None)
        if key is not None:
            environment[ENV_NAME] = key
        return subprocess.run([sys.executable, "-B", str(POSTPROCESS), str(self.root)], env=environment,
                              capture_output=True, text=True, check=False)

    def test_valid_key_is_packaged_only_in_main_app_and_is_not_logged(self):
        result = self.run_postprocess(SYNTHETIC_KEY)
        self.assertEqual(result.returncode, 0, result.stderr)
        main = plistlib.loads((self.app / "Info.plist").read_bytes())
        extension = plistlib.loads((self.extension / "Info.plist").read_bytes())
        self.assertEqual(main[KEY_NAME], SYNTHETIC_KEY)
        self.assertEqual(main["CFBundleIdentifier"], "whitegram.telegra.Telegraph")
        self.assertEqual(extension["CFBundleIdentifier"], "whitegram.telegra.Telegraph.Share")
        self.assertNotIn(KEY_NAME, extension)
        self.assertNotIn(SYNTHETIC_KEY, result.stdout + result.stderr)

    def test_absent_configuration_cannot_reuse_a_stale_packaged_key(self):
        main = self.app / "Info.plist"
        values = plistlib.loads(main.read_bytes())
        values[KEY_NAME] = SYNTHETIC_KEY
        main.write_bytes(plistlib.dumps(values))
        result = self.run_postprocess(None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(KEY_NAME, plistlib.loads(main.read_bytes()))

    def test_diagnostics_configuration_is_main_app_only_and_secrets_are_not_logged(self):
        environment = dict(os.environ, WHITEGRAM_DIAGNOSTICS_URL="https://diagnostics.invalid/v1/reports",
                           WHITEGRAM_DIAGNOSTICS_UPLOAD_KEY="b" * 64, GITHUB_SHA="a" * 40)
        environment.pop(ENV_NAME, None)
        result = subprocess.run([sys.executable, "-B", str(POSTPROCESS), str(self.root)], env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        main = plistlib.loads((self.app / "Info.plist").read_bytes())
        extension = plistlib.loads((self.extension / "Info.plist").read_bytes())
        self.assertEqual(main["WhitegramSourceRevision"], "a" * 40)
        self.assertEqual(main["WhitegramDiagnosticsUploadKey"], "b" * 64)
        self.assertNotIn("WhitegramDiagnosticsUploadKey", extension)
        self.assertNotIn("b" * 64, result.stdout + result.stderr)

    def test_invalid_diagnostics_configuration_is_atomic(self):
        before = (self.app / "Info.plist").read_bytes()
        environment = dict(os.environ, WHITEGRAM_DIAGNOSTICS_URL="http://diagnostics.invalid/v1/reports",
                           WHITEGRAM_DIAGNOSTICS_UPLOAD_KEY="b" * 64, GITHUB_SHA="a" * 40)
        environment.pop(ENV_NAME, None)
        result = subprocess.run([sys.executable, "-B", str(POSTPROCESS), str(self.root)], env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.app / "Info.plist").read_bytes(), before)

    def test_invalid_keys_fail_before_modifying_the_payload_and_are_not_logged(self):
        before = {path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}
        invalid = ["invalid-private-key", SYNTHETIC_KEY + "\n",
                   base64.b64encode(bytes(31)).decode("ascii"), base64.b64encode(bytes(33)).decode("ascii")]
        for key in invalid:
            with self.subTest(length=len(key)):
                result = self.run_postprocess(key)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("must be canonical base64 for exactly 32 bytes", result.stderr)
                self.assertNotIn(key, result.stdout + result.stderr)
                self.assertEqual({path: path.read_bytes() for path in self.root.rglob("*") if path.is_file()}, before)


if __name__ == "__main__":
    unittest.main()
