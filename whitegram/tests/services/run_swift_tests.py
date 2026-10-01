"""Build and run the actual Foundation service sources in an isolated, dependency-free SwiftPM host."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[1] / "cleanroom"
CORE = (
    "WhitegramServiceCore.swift",
    "WhitegramServiceHTTP.swift",
    "WhitegramServiceCredentials.swift",
    "WhitegramAIService.swift",
    "WhitegramAIConversation.swift",
    "WhitegramVirusTotalService.swift",
    "WhitegramVirusTotalTargets.swift",
    "WhitegramVirusTotalFileHasher.swift",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift", help="Swift toolchain executable (Swift 5.7+)")
    parser.add_argument("--filter", help="Optional XCTest filter")
    options = parser.parse_args()
    swift = shutil.which(options.swift)
    if swift is None:
        print("Swift is unavailable. No Swift type checking or runtime tests were performed.", file=sys.stderr)
        return 2

    stage = HERE / ".host-package"
    marker = stage / "whitegram-test-host.json"
    if stage.exists() and not marker.exists():
        raise RuntimeError(f"Refusing to replace an unrecognized test host: {stage}")
    stage.mkdir(exist_ok=True)
    # Mark ownership before staging files so an interrupted staging run can be retried.
    marker.write_text('{"owner":"Whitegram service tests"}\n', encoding="utf-8")
    package_sources = stage / "Sources" / "WhitegramServiceHost"
    package_tests = stage / "Tests" / "WhitegramServiceHostTests"
    package_sources.mkdir(parents=True, exist_ok=True)
    package_tests.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(HERE / "Package.swift.in", stage / "Package.swift")
    manifest = {}
    for name in CORE:
        source = SOURCE / name
        shutil.copyfile(source, package_sources / name)
        manifest[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    for source in HERE.glob("*Tests.swift"):
        shutil.copyfile(source, package_tests / source.name)
    marker.write_text(json.dumps({"owner": "Whitegram service tests", "source_sha256": manifest}, indent=2) + "\n", encoding="utf-8")

    artifacts = HERE / ".host-artifacts"
    directories = {name: artifacts / name for name in ("build", "cache", "config", "security", "temp", "modules")}
    for directory in directories.values():
        directory.mkdir(parents=True, exist_ok=True)
    environment = os.environ.copy()
    environment.update({
        "TMPDIR": str(directories["temp"]),
        "TEMP": str(directories["temp"]),
        "TMP": str(directories["temp"]),
        "CLANG_MODULE_CACHE_PATH": str(directories["modules"]),
        "SWIFTPM_MODULECACHE_OVERRIDE": str(directories["modules"]),
    })
    command = [swift, "test", "--package-path", str(stage)]
    for flag, key in (("--scratch-path", "build"), ("--cache-path", "cache"), ("--config-path", "config"), ("--security-path", "security")):
        command.extend([flag, str(directories[key])])
    if options.filter:
        command.extend(["--filter", options.filter])
    print("Testing copied production sources; source digests are in", marker)
    return subprocess.run(command, cwd=HERE, env=environment, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
