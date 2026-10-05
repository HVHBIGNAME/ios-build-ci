"""Execute offline XCTest against copied production Foundation/CryptoKit/Security sources on macOS."""

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
SOURCES = (
    "WhitegramBackendProtocol.swift", "WhitegramBackendHTTP.swift", "WhitegramBackendClient.swift",
    "WhitegramBackendCredentials.swift", "WhitegramBackendLifecycle.swift", "WhitegramBackendDecoding.swift",
    "WhitegramBackendAccess.swift", "WhitegramBackendTransport.swift", "WhitegramBackendMessageEvent.swift",
    "WhitegramProfileModels.swift", "WhitegramProfileService.swift", "WhitegramProfilePhotos.swift", "WhitegramProfilePhotoWallStore.swift",
    "WhitegramProfileRegistration.swift", "WhitegramProfileStreakService.swift", "WhitegramProfileStreakSession.swift",
    "WhitegramProfilePresenceService.swift", "WhitegramRadioModels.swift", "WhitegramAPIStatusService.swift",
    "WhitegramScammerDatabase.swift", "WhitegramTrafficPolicy.swift",
    "WhitegramServiceCore.swift", "WhitegramServiceHTTP.swift", "WhitegramServiceProxy.swift",
    "WhitegramAIService.swift", "WhitegramAIModels.swift", "WhitegramAIStreaming.swift",
    "WhitegramVirusTotalService.swift", "WhitegramVirusTotalTargets.swift", "WhitegramVirusTotalFileHasher.swift",
    "WhitegramVirusTotalUpload.swift", "WhitegramVirusTotalScan.swift",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    options = parser.parse_args()
    if sys.platform != "darwin" or shutil.which(options.swift) is None:
        print("Native backend XCTest requires macOS with Swift, CryptoKit and Security. No native Swift checks ran.", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix=".host-", dir=HERE) as directory:
        root = Path(directory)
        production = root / "Sources/WhitegramBackendHost"
        tests = root / "Tests/WhitegramBackendHostTests"
        production.mkdir(parents=True)
        tests.mkdir(parents=True)
        shutil.copyfile(HERE / "Package.swift.in", root / "Package.swift")
        for name in SOURCES:
            shutil.copyfile(SOURCE / name, production / name)
        for test in HERE.glob("*.swift"):
            shutil.copyfile(test, tests / test.name)
        shutil.copyfile(HERE / "protocol-evidence.json", tests / "protocol-evidence.json")
        print(json.dumps({"source_sha256": {name: hashlib.sha256((SOURCE / name).read_bytes()).hexdigest() for name in SOURCES}}, indent=2))
        return subprocess.run([options.swift, "test", "--package-path", str(root), "--scratch-path", str(root / ".build")], cwd=HERE, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
