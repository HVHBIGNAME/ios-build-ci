"""Execute the actual Foundation translation state machine and text rules."""

from pathlib import Path
import shutil
import subprocess
import tempfile


def main() -> int:
    swift = shutil.which("swift")
    if swift is None:
        raise SystemExit("Swift is required for native translation tests")
    here = Path(__file__).resolve().parent
    overlay = here.parents[1]
    with tempfile.TemporaryDirectory(prefix=".whitegram-translation-", dir=here) as temporary:
        root = Path(temporary)
        core = root / "Sources/TelegramCore"
        tests = root / "Tests/TranslationTests"
        core.mkdir(parents=True)
        tests.mkdir(parents=True)
        (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhitegramTranslationChecks", platforms: [.macOS(.v12)], targets: [
    .target(name: "TelegramCore"),
    .testTarget(name: "TranslationTests", dependencies: ["TelegramCore"])
])
''', encoding="utf-8")
        for name in ("WhitegramPreferences.swift", "WhitegramTranslationSettings.swift", "WhitegramTranslationDraftGuard.swift", "WhitegramTranslationTextRules.swift", "WhitegramTranslationGoogle.swift"):
            shutil.copyfile(overlay / "cleanroom" / name, core / name)
        shutil.copyfile(overlay / "generated/WhitegramSettingsState.swift", core / "WhitegramSettingsState.swift")
        for source in here.glob("*Tests.swift"):
            shutil.copyfile(source, tests / source.name)
        return subprocess.run([swift, "test", "--package-path", str(root)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
