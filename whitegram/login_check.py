"""Exercise the installed simulator's phone-entry UI and verify native RPC evidence."""

import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid


def evaluate(record, token):
    if not isinstance(record, dict) or record.get("schema") != 1 or record.get("token") != token:
        raise ValueError("Missing or stale simulator login evidence")
    if record.get("probe") != "success":
        raise ValueError(f"Telegram help.getNearestDc did not succeed: {record}")
    if record.get("auth") == "pending":
        verification = [event for event in record.get("events", []) if isinstance(event, dict)
                        and event.get("name") in ("recaptcha-execute-error", "recaptcha-execute-success")]
        if verification and verification[-1].get("name") == "recaptcha-execute-error" and verification[-1].get("code") == 4:
            raise ValueError("reCAPTCHA rejected the app's package name (errorInvalidPackageName, code 4); "
                             "configure project-owned WHITEGRAM_TELEGRAM_API_ID and WHITEGRAM_TELEGRAM_API_HASH, then verify login again")
    if record.get("auth_flow") == "timeout":
        raise ValueError(f"The login flow timed out: {record}")
    if record.get("auth") == "success":
        return "Telegram accepted auth.sendCode; delivery to a real account is not tested"
    if record.get("auth") == "rpc-error" and record.get("auth_error") in ("PHONE_NUMBER_INVALID", "PHONE_NUMBER_BANNED"):
        return "Telegram rejected the reserved fictional number; the login RPC reached the server"
    raise ValueError(f"Login request did not produce the expected Telegram response: {record}")


def check_login(device, output):
    output.mkdir()
    token = uuid.uuid4().hex
    report = {"status": "failed", "token": token, "number": "+12025550147", "server": "production", "ui_test": "not-started"}
    fixture = Path(__file__).parent / "tests/login"
    try:
        device = str(uuid.UUID(device)).upper()
        with tempfile.TemporaryDirectory(prefix="whitegram-login-ui-") as directory:
            project = Path(directory)
            shutil.copytree(fixture, project, dirs_exist_ok=True)
            test = project / "UITests/LoginUITests.swift"
            test.write_text(test.read_text(encoding="utf-8").replace("__PROBE_TOKEN__", token), encoding="utf-8")
            subprocess.run(["xcodegen", "generate", "--spec", str(project / "project.yml"), "--project", str(project)], check=True, timeout=60)
            with (output / "xcodebuild.log").open("w", encoding="utf-8") as log:
                result = subprocess.run([
                    "xcodebuild", "test", "-project", str(project / "WhitegramLoginChecks.xcodeproj"),
                    "-scheme", "WhitegramLogin", "-destination", f"platform=iOS Simulator,id={device}",
                    "-derivedDataPath", str(project / "DerivedData"), "-resultBundlePath", str(output / "Login.xcresult"),
                    "-parallel-testing-enabled", "NO", "-maximum-concurrent-test-simulator-destinations", "1",
                ], stdout=log, stderr=subprocess.STDOUT, timeout=420, check=False)
            report["ui_test"] = "passed" if result.returncode == 0 else "failed"
            report["xcodebuild_exit"] = result.returncode
            if result.returncode != 0:
                report["error"] = f"xcodebuild test failed (exit {result.returncode}); see xcodebuild.log"
        container = subprocess.run(["xcrun", "simctl", "get_app_container", device, "whitegram.telegra.Telegraph", "data"],
                                   capture_output=True, text=True, check=True, timeout=30).stdout.strip()
        record = json.loads((Path(container) / "Documents" / f"whitegram-login-{token}.json").read_text(encoding="utf-8"))
        report["native"] = record
        report["result"] = evaluate(record, token)
        if report["ui_test"] != "passed":
            raise ValueError("The UI test did not complete successfully")
        report["status"] = "passed"
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        if "error" in report:
            report["evidence_error"] = str(error)
        else:
            report["error"] = str(error)
    finally:
        try:
            subprocess.run(["xcrun", "simctl", "io", device, "screenshot", str(output / "login-result.png")], check=True, timeout=30)
            with (output / "system.log").open("w", encoding="utf-8") as log:
                subprocess.run(["xcrun", "simctl", "spawn", device, "log", "show", "--style", "compact", "--last", "5m", "--predicate", 'process == "Telegram"'],
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=60)
        except (OSError, subprocess.SubprocessError) as error:
            report["capture_error"] = str(error)
            report["status"] = "failed"
        (output / "login-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report
