"""Prevent missing runtimes, dead processes and reused PIDs from producing green launch checks."""

import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import simulator_smoke as smoke


class SimulatorSmokeTests(unittest.TestCase):
    def inventory(self):
        old = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
        current = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
        return {
            "runtimes": [{"identifier": old, "version": "18.0", "isAvailable": True},
                         {"identifier": current, "version": "26.2", "isAvailable": True}],
            "devices": {old: [{"deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16", "isAvailable": True}],
                        current: [{"deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "isAvailable": True},
                                  {"deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro", "isAvailable": True}]},
        }

    def test_selects_available_iphone_matching_xcode_sdk(self):
        chosen = smoke.select_device(self.inventory(), "18.0.0", "26.2")
        self.assertEqual(chosen["device_type"], "com.apple.CoreSimulator.SimDeviceType.iPhone-17")
        self.assertEqual(chosen["os_version"], "26.2.0")
        self.assertEqual(smoke.select_device(self.inventory(), "13", "18.0")["os_version"], "18.0.0")

    def test_no_compatible_runtime_is_failure(self):
        with self.assertRaisesRegex(RuntimeError, "No available iPhone"):
            smoke.select_device(self.inventory(), "27.0", "26.2")
        with self.assertRaisesRegex(RuntimeError, "matches the selected Xcode SDK"):
            smoke.select_device(self.inventory(), "13.0", "26.3")
        inventory = self.inventory()
        inventory["runtimes"][1]["isAvailable"] = False
        self.assertEqual(smoke.select_device(inventory, "13", "18.0")["os_version"], "18.0.0")
        for devices in inventory["devices"].values():
            for device in devices:
                device["isAvailable"] = False
        with self.assertRaises(RuntimeError):
            smoke.select_device(inventory, "13", "18.0")

    def test_device_ipa_and_mixed_platform_binaries_are_rejected(self):
        self.assertTrue(smoke.simulator_platform("Load command 1\n  platform IOSSIMULATOR\n"))
        for value in ("", "  platform IOS\n", "  platform MACOS\n", "  platform IOS\n  platform IOSSIMULATOR\n"):
            self.assertFalse(smoke.simulator_platform(value))

    def test_launch_pid_must_belong_to_requested_bundle(self):
        bundle = "whitegram.telegra.Telegraph"
        self.assertEqual(smoke.launch_pid(bundle + ": 4123\n", bundle), 4123)
        for value in (bundle + ": 0", "different.app: 4123", "launch failed", bundle + ": 1\nextra"):
            with self.assertRaises(RuntimeError):
                smoke.launch_pid(value, bundle)

    def test_process_exit_or_replacement_fails_observation(self):
        for identities in ([None], ["original", None], ["original", "replacement"]):
            with patch.object(smoke, "process_identity", side_effect=identities):
                with self.assertRaisesRegex(RuntimeError, "exited"):
                    smoke.observe_process(4123, 5)

    def test_observes_full_window_including_final_process_check(self):
        with patch.object(smoke, "process_identity", return_value="original") as identity, \
             patch.object(smoke.time, "monotonic", side_effect=[0, 0, 1, 2]), \
             patch.object(smoke.time, "sleep") as sleep:
            smoke.observe_process(4123, 2)
            self.assertEqual(identity.call_count, 4)
            self.assertEqual(sleep.call_count, 2)

    def test_process_failure_at_end_of_window_is_not_success(self):
        with patch.object(smoke, "process_identity", side_effect=["original", "original", None]), \
             patch.object(smoke.time, "monotonic", side_effect=[0, 0]), \
             patch.object(smoke.time, "sleep"):
            with self.assertRaises(RuntimeError):
                smoke.observe_process(4123, 1)

    def test_unsupported_host_records_failure_without_invoking_simctl(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(smoke.sys, "platform", "win32"), \
             patch.object(smoke, "run") as run:
            output = Path(directory) / "result"
            report = smoke.smoke(Path(directory) / "missing.app", output, "a" * 40, "34644", 5)
            self.assertEqual(report["status"], "failed")
            self.assertIn("macOS", report["error"])
            self.assertEqual(json.loads((output / "launch-report.json").read_text()), report)
            run.assert_not_called()

    def simulated_run(self, directory, *, failure=None, log_failure=False, cleanup_failure=False, display_failure=False,
                      readiness_timeout=False):
        app = Path(directory) / "Telegram.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "whitegram.telegra.Telegraph", "CFBundleExecutable": "Telegram",
            "CFBundleVersion": "34644", "CFBundleShortVersionString": "12.9.4", "WhitegramSourceRevision": "a" * 40,
        }))
        owned_device = "A5F8DD15-D6C9-4D22-BEB7-18CC802B38EF"

        def command(*args, **kwargs):
            if args[0] == "xcode-select":
                return "/Applications/Xcode.app/Contents/Developer"
            if args[0] in ("open", "sample"):
                return ""
            if args[1] == "--sdk":
                return "26.2"
            if args[1] == "vtool":
                return "  platform IOSSIMULATOR\n"
            action = args[2]
            if action == "list":
                return json.dumps(self.inventory())
            if action == "create":
                return owned_device
            if action == "launch":
                if args[-1] == "com.apple.Preferences":
                    self.assertEqual(kwargs["timeout"], 180)
                    if readiness_timeout:
                        raise subprocess.TimeoutExpired(args, 180)
                return f"{args[-1]}: 4123"
            if action == "io":
                if display_failure:
                    raise RuntimeError("simulator display failed")
                Path(args[-1]).write_bytes(b"\x89PNG\r\n\x1a\n")
            if action == "spawn" and log_failure:
                raise RuntimeError("log capture failed")
            if action == "shutdown" and cleanup_failure:
                raise RuntimeError("shutdown failed")
            return ""

        with patch.object(smoke.sys, "platform", "darwin"), patch.object(smoke, "run", side_effect=command) as calls, \
             patch.object(smoke, "observe_process", side_effect=failure, return_value="original"), \
             patch.object(smoke, "process_identity", return_value="original"):
            report = smoke.smoke(app, Path(directory) / "result", "a" * 40, "34644", 5)
        cleanup = [call.args for call in calls.call_args_list if call.args[:2] == ("xcrun", "simctl") and call.args[2] in ("shutdown", "delete")]
        self.assertEqual(cleanup, [("xcrun", "simctl", "shutdown", owned_device), ("xcrun", "simctl", "delete", owned_device)])
        if display_failure or readiness_timeout:
            self.assertFalse(any(call.args[:3] == ("xcrun", "simctl", "install") for call in calls.call_args_list))
        if not (display_failure or readiness_timeout):
            launches = [call.args[-1] for call in calls.call_args_list if call.args[:3] == ("xcrun", "simctl", "launch")]
            self.assertEqual(launches[0], "com.apple.Preferences")
            self.assertEqual(launches[1], "whitegram.telegra.Telegraph")
        if report["status"] == "failed" and report["phase"] != "complete":
            if not display_failure:
                self.assertTrue((Path(directory) / "result/failure.png").is_file())
            if not log_failure:
                self.assertTrue((Path(directory) / "result/startup-system.log").is_file())
        return report

    def test_success_requires_both_launches_and_screenshots(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.simulated_run(directory)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["simulator_udid"], "A5F8DD15-D6C9-4D22-BEB7-18CC802B38EF")
        self.assertEqual([item["name"] for item in report["launches"]], ["fresh-install", "relaunch"])
        self.assertTrue(all(item["status"] == "passed" and item["screenshot"] for item in report["launches"]))

    def test_crash_is_preserved_when_log_capture_also_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.simulated_run(directory, failure=RuntimeError("app exited"), log_failure=True)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["error"], "app exited")
        self.assertEqual(report["launches"][0]["log_error"], "log capture failed")

    def test_second_launch_failure_does_not_inherit_first_success(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.simulated_run(directory, failure=["original", RuntimeError("second launch exited")])
        self.assertEqual(report["status"], "failed")
        self.assertEqual([item["status"] for item in report["launches"]], ["passed", "failed"])

    def test_cleanup_failure_is_reported_and_delete_is_still_attempted(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.simulated_run(directory, cleanup_failure=True)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["cleanup_errors"], ["shutdown failed"])

    def test_display_failure_is_detected_before_app_install_or_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.simulated_run(directory, display_failure=True)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["phase"], "simulator-display")
        self.assertEqual(report["launches"], [])

    def test_unresponsive_springboard_is_reported_before_installing_whitegram(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.simulated_run(directory, readiness_timeout=True)
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["phase"], "simulator-readiness")
        self.assertIn("timed out after 180 seconds", report["error"])
        self.assertEqual(report["launches"], [])

    def test_failure_capture_errors_do_not_replace_the_original_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            report = self.simulated_run(directory, readiness_timeout=True, display_failure=True, log_failure=True)
        self.assertIn("timed out after 180 seconds", report["error"])
        self.assertEqual(report["startup_capture_errors"], ["simulator display failed", "log capture failed"])


if __name__ == "__main__":
    unittest.main()
