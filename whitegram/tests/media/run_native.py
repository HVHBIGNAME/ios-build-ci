"""Run production media settings and ImageIO metadata cleaning on an Apple host."""

from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> int:
    swift = shutil.which("swift")
    if swift is None:
        raise SystemExit("Swift is required for native media tests")
    here = Path(__file__).resolve().parent
    overlay = here.parents[1]
    with tempfile.TemporaryDirectory(prefix="whitegram-media-") as temporary:
        root = Path(temporary)
        core = root / "Sources/TelegramCore"
        resources = root / "Sources/LocalMediaResources"
        tests = root / "Tests/MediaTests"
        for path in (core, resources, tests):
            path.mkdir(parents=True)
        (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhitegramMediaChecks", platforms: [.macOS(.v12)], targets: [
    .target(name: "TelegramCore"), .target(name: "LocalMediaResources"),
    .testTarget(name: "MediaTests", dependencies: ["TelegramCore", "LocalMediaResources"])
])
''', encoding="utf-8")
        for name in ("WhitegramPreferences.swift", "WhitegramMediaSettings.swift"):
            shutil.copyfile(overlay / "cleanroom" / name, core / name)
        shutil.copyfile(overlay / "generated/WhitegramSettingsState.swift", core / "WhitegramSettingsState.swift")
        shutil.copyfile(overlay / "cleanroom/WhitegramPhotoMetadata.swift", resources / "WhitegramPhotoMetadata.swift")
        shutil.copyfile(here / "WhitegramMediaTests.swift", tests / "WhitegramMediaTests.swift")
        return subprocess.run([swift, "test", "--package-path", str(root)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
