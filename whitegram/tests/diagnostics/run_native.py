"""Run offline XCTest against the production diagnostic codec and uploader."""

from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parents[1] / "cleanroom"


def main():
    if shutil.which("swift") is None:
        raise SystemExit("Swift is required; native diagnostic tests did not run")
    with tempfile.TemporaryDirectory(prefix=".host-", dir=HERE) as temporary:
        root = Path(temporary)
        source = root / "Sources/Diagnostics"
        tests = root / "Tests/DiagnosticsTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        (root / "Package.swift").write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Diagnostics", platforms: [.macOS(.v12)], targets: [
    .target(name: "Diagnostics"), .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics"])
])
''', encoding="utf-8")
        for name in ("WhitegramErrorReport", "WhitegramDiagnosticsUpload", "WhitegramErrorReporter", "WhitegramPreferences"):
            shutil.copyfile(SOURCE / (name + ".swift"), source / (name + ".swift"))
        shutil.copyfile(HERE / "DiagnosticsTests.swift", tests / "DiagnosticsTests.swift")
        return subprocess.run(["swift", "test", "--package-path", str(root)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
