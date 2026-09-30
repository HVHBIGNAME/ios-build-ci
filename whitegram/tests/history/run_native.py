"""Run the actual Foundation history store/models in a disposable SwiftPM package.

This does not compile the TelegramCore capture adapter or the UIKit controllers.
No source worktree is written and no replacement implementation is tested.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


PACKAGE = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WhitegramHistoryChecks", platforms: [.macOS(.v12)], targets: [
    .target(name: "WhitegramHistory"),
    .testTarget(name: "WhitegramHistoryTests", dependencies: ["WhitegramHistory"])
])
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift")
    parser.add_argument("--temp-root", type=Path)
    parser.add_argument("--filter")
    options = parser.parse_args()
    swift = shutil.which(options.swift)
    if swift is None:
        print("Swift is unavailable. History runtime tests and native type checking were not performed.")
        return 2
    if options.temp_root is not None and not options.temp_root.is_dir():
        parser.error("--temp-root must be an existing directory")
    here = Path(__file__).resolve().parent
    overlay = here.parents[1]
    with tempfile.TemporaryDirectory(prefix="whitegram-history-", dir=options.temp_root) as temporary:
        root = Path(temporary)
        source = root / "Sources/WhitegramHistory"
        tests = root / "Tests/WhitegramHistoryTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        (root / "Package.swift").write_text(PACKAGE, encoding="utf-8")
        for name in ("WhitegramHistoryModels.swift", "WhitegramHistoryStore.swift"):
            shutil.copyfile(overlay / "cleanroom" / name, source / name)
        for path in here.glob("*Tests.swift"):
            shutil.copyfile(path, tests / path.name)
        paths = {name: root / name for name in ("build", "cache", "config", "security", "temp", "modules")}
        for path in paths.values():
            path.mkdir()
        environment = os.environ.copy()
        environment.update({name: str(paths["temp"]) for name in ("TMP", "TEMP", "TMPDIR")})
        environment.update({name: str(paths["modules"]) for name in ("CLANG_MODULE_CACHE_PATH", "SWIFTPM_MODULECACHE_OVERRIDE")})
        command = [swift, "test", "--package-path", str(root)]
        for flag, name in (("--scratch-path", "build"), ("--cache-path", "cache"), ("--config-path", "config"), ("--security-path", "security")):
            command.extend([flag, str(paths[name])])
        if options.filter:
            command.extend(["--filter", options.filter])
        return subprocess.run(command, cwd=root, env=environment, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
