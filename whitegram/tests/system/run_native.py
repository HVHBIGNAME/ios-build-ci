"""Run offline notification-policy, RAM and silent-audio XCTest against production sources."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[1] / "cleanroom"
SOURCES = {
    "TelegramCore": ("WhitegramPreferences.swift", "WhitegramNotificationSettings.swift", "WhitegramLocalNotificationId.swift"),
    "Display": ("WhitegramRAMUsage.swift",),
    "TelegramUI": ("WhitegramSilentAudio.swift", "WhitegramKeepAliveController.swift"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    options = parser.parse_args()
    if sys.platform != "darwin" or shutil.which(options.swift) is None:
        print("Native system XCTest requires macOS with Swift, Darwin and AVFoundation. No native checks ran.", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix=".host-", dir=HERE) as directory:
        root = Path(directory)
        shutil.copyfile(HERE / "Package.swift.in", root / "Package.swift")
        digests = {}
        for module, names in SOURCES.items():
            destination = root / "Sources" / module
            destination.mkdir(parents=True)
            for name in names:
                shutil.copyfile(SOURCE / name, destination / name)
                digests[name] = hashlib.sha256((SOURCE / name).read_bytes()).hexdigest()
        tests = root / "Tests/WhitegramSystemTests"
        tests.mkdir(parents=True)
        for source in HERE.glob("*Tests.swift"):
            shutil.copyfile(source, tests / source.name)
        print(json.dumps({"production_source_sha256": digests}, indent=2))
        return subprocess.run([options.swift, "test", "--package-path", str(root), "--scratch-path", str(root / ".build")], cwd=HERE, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
