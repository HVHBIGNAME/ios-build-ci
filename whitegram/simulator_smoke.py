"""Observe two launches of a simulator app on a newly created, disposable iPhone."""

import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
import uuid


def run(*arguments, timeout=60):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(f"{' '.join(arguments)} failed ({result.returncode}): {result.stderr.strip()} {result.stdout.strip()}")
    return result.stdout.strip()


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"Invalid OS version: {value!r}")
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def select_device(inventory, minimum_os, sdk_version):
    candidates = []
    for runtime in inventory["runtimes"]:
        identifier = runtime["identifier"]
        if not runtime.get("isAvailable") or not identifier.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
            continue
        os_version = version(runtime["version"])
        if os_version < version(minimum_os) or os_version[:2] != version(sdk_version)[:2]:
            continue
        for device in inventory["devices"].get(identifier, []):
            device_type = device.get("deviceTypeIdentifier", "")
            if device.get("isAvailable") and device_type.startswith("com.apple.CoreSimulator.SimDeviceType.iPhone-"):
                candidates.append((os_version, device_type, identifier))
    if not candidates:
        raise RuntimeError("No available iPhone simulator runtime matches the selected Xcode SDK and app's minimum OS version")
    os_version, device_type, runtime = sorted(candidates, key=lambda item: (item[0], item[1]))[-1]
    return {"runtime": runtime, "device_type": device_type, "os_version": ".".join(map(str, os_version))}


def simulator_platform(build_info):
    platforms = re.findall(r"^\s*platform\s+(\S+)\s*$", build_info, re.MULTILINE)
    return bool(platforms) and all(value == "IOSSIMULATOR" for value in platforms)


def launch_pid(output, bundle):
    match = re.fullmatch(re.escape(bundle) + r": ([1-9][0-9]*)", output.strip())
    if not match:
        raise RuntimeError(f"simctl did not return a process ID for {bundle}: {output!r}")
    return int(match.group(1))


def process_identity(pid):
    result = subprocess.run(["ps", "-ww", "-p", str(pid), "-o", "lstart=", "-o", "comm="],
                            capture_output=True, text=True, timeout=10, check=False)
    if result.returncode == 1 and not result.stdout.strip():
        return None
    if result.returncode:
        raise RuntimeError(f"Could not inspect launched process {pid}: {result.stderr.strip()}")
    return result.stdout.strip() or None


def observe_process(pid, seconds):
    identity = process_identity(pid)
    if identity is None:
        raise RuntimeError(f"App process {pid} exited immediately after launch")
    deadline = time.monotonic() + seconds
    while True:
        if process_identity(pid) != identity:
            raise RuntimeError(f"App process {pid} exited or was replaced during startup observation")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return identity
        time.sleep(min(1.0, remaining))


def screenshot(device, destination):
    run("xcrun", "simctl", "io", device, "screenshot", str(destination), timeout=180)
    with destination.open("rb") as image:
        if image.read(8) != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError("Simulator screenshot is missing or invalid")


def capture_startup_failure(device, output, report):
    errors = []
    try:
        screenshot(device, output / "failure.png")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        errors.append(str(error))
    try:
        logs = run("xcrun", "simctl", "spawn", device, "log", "show", "--style", "compact", "--last", "5m",
                   "--predicate", 'process == "Telegram" OR process == "SpringBoard" OR process == "runningboardd"')
        (output / "startup-system.log").write_text(logs, encoding="utf-8")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        errors.append(str(error))
    if errors:
        report["startup_capture_errors"] = errors


def wait_for_boot(device, output):
    log = ""
    try:
        log = run("xcrun", "simctl", "bootstatus", device, "-b", timeout=600)
    except subprocess.TimeoutExpired as error:
        log = error.stdout or ""
        if isinstance(log, bytes):
            log = log.decode("utf-8", errors="replace")
        raise
    finally:
        (output / "bootstatus.log").write_text(log, encoding="utf-8")


def smoke(app, output, revision, build, seconds, login=False):
    output.mkdir(parents=True, exist_ok=False)
    report = {"status": "failed", "phase": "prepare", "source_revision": revision, "configuration": "release_sim_arm64",
              "observation_seconds_per_launch": seconds, "launches": [], "cleanup_errors": [],
              "limitations": ["Fresh simulator with no signed-in account; user interaction and UI responsiveness are not verified.",
                              "This is a simulator binary, not an installation of the device IPA. Physical-device signing and crashes remain untested."]}
    device = None
    try:
        if sys.platform != "darwin":
            raise RuntimeError("Simulator launch checks require macOS and Xcode")
        info = plistlib.loads((app / "Info.plist").read_bytes())
        bundle = info["CFBundleIdentifier"]
        executable = info["CFBundleExecutable"]
        if bundle != "whitegram.telegra.Telegraph" or executable != "Telegram":
            raise RuntimeError("Expected the postprocessed WhiteGram simulator app")
        if str(info.get("CFBundleVersion")) != build or info.get("WhitegramSourceRevision") != revision:
            raise RuntimeError("Simulator app build/revision does not match this CI run")
        if not simulator_platform(run("xcrun", "vtool", "-show-build", str(app / executable))):
            raise RuntimeError("The supplied app is not an iOS Simulator binary")
        inventory = json.loads(run("xcrun", "simctl", "list", "--json"))
        (output / "simulators.json").write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")
        sdk_version = run("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")
        report["sdk_version"] = sdk_version
        selected = select_device(inventory, info.get("MinimumOSVersion", "13.0"), sdk_version)
        report.update(selected)
        report.update({"bundle_id": bundle, "app_version": info["CFBundleShortVersionString"], "app_build": build})
        device = str(uuid.UUID(run("xcrun", "simctl", "create", "WhiteGram-Smoke-" + uuid.uuid4().hex[:8],
                                  selected["device_type"], selected["runtime"]))).upper()
        report["simulator_udid"] = device
        report["phase"] = "boot"
        run("xcrun", "simctl", "boot", device)
        developer = Path(run("xcode-select", "-p"))
        run("open", "-a", str(developer / "Applications/Simulator.app"), "--args", "-CurrentDeviceUDID", device)
        wait_for_boot(device, output)
        report["phase"] = "simulator-readiness"
        readiness_bundle = "com.apple.Preferences"
        readiness_pid = launch_pid(run("xcrun", "simctl", "launch", device, readiness_bundle, timeout=180), readiness_bundle)
        if process_identity(readiness_pid) is None:
            raise RuntimeError("Simulator Settings exited during the readiness check")
        report["readiness_pid"] = readiness_pid
        report["phase"] = "simulator-display"
        screenshot(device, output / "simulator-ready.png")
        report["phase"] = "install"
        run("xcrun", "simctl", "install", device, str(app), timeout=180)
        for name in ("fresh-install", "relaunch"):
            report["phase"] = name
            launch = {"name": name, "status": "failed"}
            report["launches"].append(launch)
            pid = launch_pid(run("xcrun", "simctl", "launch", "--terminate-running-process",
                                 f"--stdout={output / (name + '-stdout.log')}",
                                 f"--stderr={output / (name + '-stderr.log')}", device, bundle), bundle)
            launch["pid"] = pid
            try:
                identity = observe_process(pid, seconds)
                launch["process_observation"] = "passed"
                image = output / (name + ".png")
                screenshot(device, image)
                if process_identity(pid) != identity:
                    raise RuntimeError(f"App process {pid} exited or was replaced during screenshot capture")
                launch["screenshot"] = image.name
                run("xcrun", "simctl", "terminate", device, bundle)
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                try:
                    run("sample", str(pid), "3", "-file", str(output / (name + "-sample.txt")), timeout=20)
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    launch["sample_error"] = str(error)
                raise
            finally:
                try:
                    logs = run("xcrun", "simctl", "spawn", device, "log", "show", "--style", "compact", "--last", "2m",
                               "--predicate", f"processIdentifier == {pid}")
                    (output / (name + "-system.log")).write_text(logs, encoding="utf-8")
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    launch["log_error"] = str(error)
            if "log_error" in launch:
                raise RuntimeError(launch["log_error"])
            launch["status"] = "passed"
        if login:
            from login_check import check_login
            report["phase"] = "login-connectivity"
            report["login"] = check_login(device, output / "login")
            if report["login"]["status"] != "passed":
                raise RuntimeError(report["login"].get("error", "Login connectivity check failed"))
        report["phase"] = "complete"
        report["status"] = "passed"
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
    finally:
        if device is not None:
            if report["status"] != "passed":
                capture_startup_failure(device, output, report)
            for action in ("shutdown", "delete"):
                try:
                    run("xcrun", "simctl", action, device, timeout=60)
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    report["cleanup_errors"].append(str(error))
            if report["cleanup_errors"]:
                report["status"] = "failed"
        (output / "launch-report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New directory for reports, screenshots and logs")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--login", action="store_true", help="Run the phone-entry UI and require a real Telegram response")
    args = parser.parse_args()
    if not 5 <= args.seconds <= 120:
        parser.error("--seconds must be between 5 and 120")
    if not re.fullmatch(r"[a-f0-9]{40}", args.revision) or not args.build.isdecimal():
        parser.error("--revision must be a commit SHA and --build must be numeric")
    report = smoke(args.app.resolve(), args.output.resolve(), args.revision, args.build, args.seconds, login=args.login)
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
