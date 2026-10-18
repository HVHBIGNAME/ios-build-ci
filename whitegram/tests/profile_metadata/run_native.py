"""Compile and run the production Foundation-only profile metadata policy."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
CLEANROOM = HERE.parents[1] / "cleanroom"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--temp-root", type=Path)
    args = parser.parse_args()
    if args.temp_root is not None and not args.temp_root.is_dir():
        parser.error("--temp-root must be an existing directory")
    compiler = shutil.which("swiftc")
    if compiler is None:
        print("Native profile metadata tests require swiftc; no native tests ran.", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="whitegram-profile-metadata-", dir=args.temp_root) as directory:
        binary = Path(directory) / ("metadata-tests.exe" if sys.platform == "win32" else "metadata-tests")
        subprocess.run([compiler, "-o", str(binary), str(CLEANROOM / "WhitegramPeerMetadataPolicy.swift"), str(HERE / "main.swift")], check=True)
        subprocess.run([str(binary)], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
