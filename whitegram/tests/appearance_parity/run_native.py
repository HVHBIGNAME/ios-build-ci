#!/usr/bin/env python3
"""Compile Foundation appearance policies and execute their semantic regressions."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
CLEANROOM = HERE.parents[1] / "cleanroom"
SOURCES = (
    "WhitegramAppearancePolicy.swift",
    "WhitegramLocalStars.swift",
    "WhitegramFontHistory.swift",
    "WhitegramFontArchivePlan.swift",
    "WhitegramIconPackArchive.swift",
    "WhitegramGlassSettings.swift",
    "WhitegramStickerSettings.swift",
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--temp-root", type=Path, help="Existing parent for the isolated compiler output")
    args = parser.parse_args()
    if args.temp_root is not None and not args.temp_root.is_dir():
        parser.error("--temp-root must be an existing directory")
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        print("Native appearance tests require swiftc; no Swift tests were run.", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory(prefix="whitegram-appearance-", dir=args.temp_root) as temporary:
        output = Path(temporary) / ("appearance-tests.exe" if sys.platform == "win32" else "appearance-tests")
        command = [swiftc, "-Onone", "-o", str(output)]
        command.extend(str(CLEANROOM / name) for name in SOURCES)
        command.append(str(HERE / "main.swift"))
        subprocess.run(command, check=True)
        subprocess.run([str(output)], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
