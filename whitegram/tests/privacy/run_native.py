"""Compile production Foundation privacy/state/storage code and its regression tests."""

from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> int:
    swift = shutil.which("swift")
    if swift is None:
        raise SystemExit("Swift is required for native privacy tests")
    here = Path(__file__).resolve().parent
    overlay = here.parents[1]
    with tempfile.TemporaryDirectory(prefix="whitegram-privacy-") as temporary:
        root = Path(temporary)
        core = root / "Sources/TelegramCore"
        prefs = root / "Sources/TelegramUIPreferences"
        tests = root / "Tests/PrivacyTests"
        for path in (core, prefs, tests):
            path.mkdir(parents=True)
        (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhitegramPrivacyChecks", platforms: [.macOS(.v12)], targets: [
    .target(name: "TelegramCore"),
    .target(name: "TelegramUIPreferences", dependencies: ["TelegramCore"]),
    .testTarget(name: "PrivacyTests", dependencies: ["TelegramCore", "TelegramUIPreferences"])
])
''', encoding="utf-8")
        for name in ("WhitegramPreferences.swift", "WhitegramContentSettings.swift", "WhitegramContentLocation.swift", "WhitegramContentMediaStore.swift", "WhitegramReadActionState.swift"):
            shutil.copyfile(overlay / "cleanroom" / name, core / name)
        shutil.copyfile(overlay / "cleanroom/WhitegramPrivacySettings.swift", prefs / "WhitegramPrivacySettings.swift")
        for path in here.glob("*Tests.swift"):
            shutil.copyfile(path, tests / path.name)
        return subprocess.run([swift, "test", "--package-path", str(root)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
