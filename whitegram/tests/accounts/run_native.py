"""Run the production account codecs and storage-state XCTest suites on macOS."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
OVERLAY = HERE.parents[1]
CORE = (
    "WhitegramSessionModels.swift", "WhitegramSessionCrypto.swift", "WhitegramSessionFiles.swift",
    "WhitegramSessionTelethon.swift", "WhitegramSessionTData.swift", "WhitegramSessionZip.swift",
    "WhitegramAccountFrozenStore.swift", "WhitegramAccountImportState.swift",
)
SETTINGS = ("WhitegramSessionKeychain.swift", "WhitegramAccountDocuments.swift")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--filter")
    args = parser.parse_args()
    if sys.platform != "darwin" or shutil.which(args.swift) is None:
        print("macOS Swift is required. Native account tests were not executed.", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="whitegram-account-checks-") as temporary:
        root = Path(temporary)
        fixture = root / "fixtures.json"
        subprocess.run([sys.executable, "-B", str(HERE / "generate_fixtures.py"), "--openssl", args.openssl, "--output", str(fixture)], check=True)
        (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhitegramAccountChecks", platforms: [.macOS(.v12)], targets: [
    .target(name: "TelegramCore", linkerSettings: [.linkedLibrary("sqlite3"), .linkedLibrary("z")]),
    .target(name: "SettingsUI", dependencies: ["TelegramCore"]),
    .testTarget(name: "AccountsTests", dependencies: ["TelegramCore", "SettingsUI"])
])
''', encoding="utf-8")
        inputs = [(OVERLAY / "cleanroom" / name, "Sources/TelegramCore") for name in CORE]
        inputs += [(OVERLAY / "cleanroom" / name, "Sources/SettingsUI") for name in SETTINGS]
        inputs += [(path, "Tests/AccountsTests") for path in sorted(HERE.glob("*Tests.swift"))]
        digests = {}
        for source, directory in inputs:
            target = root / directory / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            digests[source.name] = hashlib.sha256(source.read_bytes()).hexdigest()
        print(json.dumps({"production_source_sha256": digests}, indent=2), flush=True)
        environment = dict(os.environ, WHITEGRAM_ACCOUNTS_FIXTURES=str(fixture))
        command = [args.swift, "test", "--package-path", str(root)]
        if args.filter:
            command += ["--filter", args.filter]
        return subprocess.run(command, env=environment, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
