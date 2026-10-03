"""Run production settings archive/store/Keychain/document XCTest code on an Apple Swift host."""

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
    "WhitegramPreferences.swift", "WhitegramSettingsArchive.swift", "WhitegramSettingsArchiveJSON.swift",
    "WhitegramSettingsArchiveSchema.swift", "WhitegramSettingsArchiveMirrors.swift", "WhitegramSettingsArchiveStore.swift",
    "WhitegramMediaSettings.swift",
)
FOUNDATION_UI = ("WhitegramSettingsArchiveKeychain.swift", "WhitegramSettingsTransferDocuments.swift")
PUBLIC = (
    "WhiteGramChatSettings.swift", "WhiteGramTabSettings.swift", "WhiteGramStorySettings.swift",
    "WhiteGramChatFolderSettings.swift", "WhiteGramContextMenuSettings.swift", "WhiteGramOtherSettings.swift",
    "WhitegramForkBridge.swift",
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--assembled-source", type=Path, default=os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"))
    parser.add_argument("--filter", help="Optional XCTest filter")
    args = parser.parse_args()
    swift = shutil.which(args.swift)
    if swift is None:
        print("Swift is unavailable. Native settings tests were not executed.", file=sys.stderr)
        return 2
    if sys.platform != "darwin":
        print("An Apple host is required for the Security and coordinated-file assertions.", file=sys.stderr)
        return 2
    if args.assembled_source is None:
        parser.error("--assembled-source is required for actual public-fork settings integration tests")
    public_source = args.assembled_source / "submodules" / "TelegramUIPreferences" / "Sources"
    inputs = [(OVERLAY / "cleanroom" / name, "Sources/TelegramCore") for name in CORE]
    inputs += [(OVERLAY / "generated" / "WhitegramSettingsState.swift", "Sources/TelegramCore")]
    inputs += [(OVERLAY / "cleanroom" / name, "Sources/SettingsUI") for name in FOUNDATION_UI]
    inputs += [(public_source / name, "Sources/TelegramUIPreferences") for name in PUBLIC]
    inputs += [(path, "Tests/SettingsTransferTests") for path in sorted(HERE.glob("*Tests.swift"))]
    missing = [str(source) for source, _ in inputs if not source.is_file()]
    if missing:
        raise SystemExit("Missing production/test sources: " + ", ".join(missing))
    with tempfile.TemporaryDirectory(prefix="whitegram-settings-transfer-") as temporary:
        root = Path(temporary)
        (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhitegramSettingsTransferChecks", platforms: [.macOS(.v12)], targets: [
    .target(name: "TelegramCore"),
    .target(name: "TelegramUIPreferences", dependencies: ["TelegramCore"]),
    .target(name: "SettingsUI", dependencies: ["TelegramCore"]),
    .testTarget(name: "SettingsTransferTests", dependencies: ["TelegramCore", "TelegramUIPreferences", "SettingsUI"])
])
''', encoding="utf-8")
        digests = {}
        for source, destination in inputs:
            target = root / destination / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            digests[str(source)] = hashlib.sha256(source.read_bytes()).hexdigest()
        print(json.dumps({"production_source_sha256": digests}, indent=2), flush=True)
        command = [swift, "test", "--package-path", str(root)]
        if args.filter:
            command += ["--filter", args.filter]
        return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
