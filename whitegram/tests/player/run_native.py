"""Compile the actual player policy, fade envelope and bass meter on a Swift host."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-swift", action="store_true")
    args = parser.parse_args()
    compiler = shutil.which("swiftc")
    if compiler is None:
        print("SKIP: swiftc is unavailable. Native player assertions were NOT executed.")
        return 1 if args.require_swift else 0
    directory = Path(__file__).resolve().parent
    cleanroom = directory.parents[1] / "cleanroom"
    output = directory / ".native"
    output.mkdir(exist_ok=True)
    executable = output / ("WhitegramPlayerTests.exe" if sys.platform == "win32" else "WhitegramPlayerTests")
    command = [compiler, "-parse-as-library", "-O", "-warnings-as-errors"]
    command += [str(cleanroom / name) for name in ("WhitegramPlayerSettings.swift", "WhitegramPlayerFadeEnvelope.swift", "WhitegramPlayerBassMeter.swift")]
    command += [str(directory / "WhitegramPlayerTests.swift"), "-o", str(executable)]
    subprocess.run(command, check=True, cwd=directory)
    subprocess.run([str(executable), str(directory.parent / "voice/original_audio_fixture.json")], check=True, cwd=directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
