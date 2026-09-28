"""Run native storage/HTTP/preferences tests using only actual production sources."""

from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> int:
    swift = shutil.which("swift")
    if swift is None:
        raise SystemExit("Swift is required for native plugin tests")
    here = Path(__file__).resolve().parent
    overlay = here.parents[1]
    with tempfile.TemporaryDirectory(prefix="whitegram-native-") as temporary:
        root = Path(temporary)
        core = root / "Sources" / "TelegramCore"
        source = root / "Sources" / "SettingsUI"
        tests = root / "Tests" / "SettingsUITests"
        source.mkdir(parents=True)
        core.mkdir(parents=True)
        tests.mkdir(parents=True)
        (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhitegramNativeChecks", platforms: [.macOS(.v12)], targets: [
    .target(name: "TelegramCore"),
    .target(name: "SettingsUI", dependencies: ["TelegramCore"]),
    .testTarget(name: "SettingsUITests", dependencies: ["SettingsUI", "TelegramCore"])
])
''', encoding="utf-8")
        for name in ("WhitegramPluginStorage.swift", "WhitegramPluginHTTP.swift"):
            shutil.copyfile(overlay / "cleanroom" / name, source / name)
        shutil.copyfile(overlay / "cleanroom" / "WhitegramPreferences.swift", core / "WhitegramPreferences.swift")
        shutil.copyfile(overlay / "generated" / "WhitegramSettingsState.swift", core / "WhitegramSettingsState.swift")
        for path in here.glob("*Tests.swift"):
            shutil.copyfile(path, tests / path.name)
        return subprocess.run([swift, "test", "--package-path", str(root)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
