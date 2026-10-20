"""Check simulator destination identity and preserve UI failures alongside RPC evidence."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from login_check import check_login


class LoginRunnerTests(unittest.TestCase):
    def run_login(self, *, exit_code=0, native=True, probe="success"):
        device = "F3A46E35-3FB4-420D-943C-E8A6F742FB1E"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            container = root / "container"
            (container / "Documents").mkdir(parents=True)

            def command(args, **kwargs):
                if args[0] == "xcodegen":
                    project = Path(args[args.index("--project") + 1])
                    source = (project / "UITests/LoginUITests.swift").read_text(encoding="utf-8")
                    self.assertNotIn("__PROBE_TOKEN__", source)
                    token = source.split('app.launchEnvironment["WHITEGRAM_LOGIN_PROBE"] = "')[1].split('"')[0]
                    if native:
                        record = {"schema": 1, "token": token, "probe": probe,
                                  "auth": "rpc-error", "auth_error": "PHONE_NUMBER_INVALID"}
                        (container / "Documents" / f"whitegram-login-{token}.json").write_text(json.dumps(record), encoding="utf-8")
                if args[0] == "xcodebuild":
                    self.assertEqual(args[args.index("-destination") + 1], f"platform=iOS Simulator,id={device}")
                    return subprocess.CompletedProcess(args, exit_code)
                if args[:3] == ["xcrun", "simctl", "get_app_container"]:
                    self.assertEqual(args[3], device)
                    return subprocess.CompletedProcess(args, 0, stdout=str(container))
                return subprocess.CompletedProcess(args, 0)

            with patch("login_check.subprocess.run", side_effect=command):
                report = check_login(device.lower(), root / "login")
            self.assertEqual(json.loads((root / "login/login-report.json").read_text(encoding="utf-8")), report)
            return report

    def test_lowercase_uuid_is_converted_to_xcode_destination_spelling(self):
        report = self.run_login()
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["ui_test"], "passed")
        self.assertEqual(report["native"]["auth_error"], "PHONE_NUMBER_INVALID")

    def test_missing_native_file_does_not_mask_destination_failure(self):
        report = self.run_login(exit_code=70, native=False)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["xcodebuild_exit"], 70)
        self.assertEqual(report["error"], "xcodebuild test failed (exit 70); see xcodebuild.log")
        self.assertIn("whitegram-login-", report["evidence_error"])

    def test_native_success_cannot_override_ui_failure(self):
        report = self.run_login(exit_code=65)
        self.assertEqual(report["status"], "failed")
        self.assertIn("exit 65", report["error"])
        self.assertEqual(report["native"]["probe"], "success")

    def test_ui_success_still_requires_native_evidence_and_successful_probe(self):
        for options in ({"native": False}, {"probe": "timeout"}):
            with self.subTest(options=options):
                report = self.run_login(**options)
                self.assertEqual(report["ui_test"], "passed")
                self.assertEqual(report["status"], "failed")


if __name__ == "__main__":
    unittest.main()
