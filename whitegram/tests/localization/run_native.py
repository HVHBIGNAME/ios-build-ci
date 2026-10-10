"""Run the original-format localization and persistent-store XCTest suite."""

from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> int:
    swift = shutil.which("swift")
    if swift is None:
        raise SystemExit("Swift is required for native localization tests")
    here = Path(__file__).resolve().parent
    overlay = here.parents[1]
    with tempfile.TemporaryDirectory(prefix="whitegram-localization-") as temporary:
        root = Path(temporary)
        core = root / "Sources/TelegramCore"
        settings = root / "Sources/SettingsUI"
        tests = root / "Tests/LocalizationTests"
        core.mkdir(parents=True)
        settings.mkdir(parents=True)
        tests.mkdir(parents=True)
        (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhitegramLocalizationChecks", platforms: [.macOS(.v12)], targets: [
    .target(name: "TelegramCore"),
    .target(name: "SettingsUI", dependencies: ["TelegramCore"]),
    .testTarget(name: "LocalizationTests", dependencies: ["TelegramCore", "SettingsUI"])
])
''', encoding="utf-8")
        for name in ("WhitegramPreferences.swift", "WhitegramLocalizationPack.swift", "WhitegramLocalizationStore.swift", "WhitegramLocalization.swift"):
            shutil.copyfile(overlay / "cleanroom" / name, core / name)
        for name in ("WhitegramSettingsState.swift", "WhitegramLocalizationStrings.swift"):
            shutil.copyfile(overlay / "generated" / name, core / name)
        shutil.copyfile(overlay / "generated/WhitegramSettingsCatalog.swift", settings / "WhitegramSettingsCatalog.swift")
        shutil.copyfile(overlay / "cleanroom/WhitegramPortCapabilities.swift", settings / "WhitegramPortCapabilities.swift")
        shutil.copyfile(overlay / "cleanroom/WhitegramSettingsList.swift", settings / "WhitegramSettingsList.swift")
        shutil.copyfile(here / "WhitegramSettingsListTests.swift", tests / "WhitegramSettingsListTests.swift")
        shutil.copyfile(here / "WhitegramLocalizationTests.swift", tests / "WhitegramLocalizationTests.swift")
        return subprocess.run([swift, "test", "--package-path", str(root)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
