"""Compile and execute the real Foundation-only Swift DSP, with no DSP substitute."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-swift", action="store_true", help="Fail rather than skip if swiftc is missing (use in CI)")
    parser.add_argument("--sanitize-address", action="store_true", help="Enable Swift's address sanitizer")
    args = parser.parse_args()
    compiler = shutil.which("swiftc")
    if compiler is None:
        print("SKIP: swiftc is unavailable. Native DSP assertions were NOT executed.")
        return 1 if args.require_swift else 0

    directory = Path(__file__).resolve().parent
    cleanroom = directory.parents[1] / "cleanroom"
    output = directory / ".native"
    output.mkdir(exist_ok=True)
    executable = output / ("WhitegramVoiceDSPTests.exe" if sys.platform == "win32" else "WhitegramVoiceDSPTests")
    command = [compiler, "-parse-as-library", "-O", "-warnings-as-errors"]
    if args.sanitize_address:
        command.append("-sanitize=address")
    command += [
        str(cleanroom / "WhitegramVoiceSettings.swift"),
        str(cleanroom / "WhitegramVoiceDSP.swift"),
        str(directory / "WhitegramVoiceDSPTests.swift"),
        "-o", str(executable),
    ]
    subprocess.run(command, check=True, cwd=directory)
    subprocess.run([str(executable), str(directory / "original_audio_fixture.json")], check=True, cwd=directory)
    protocol_executable = output / ("WhitegramVoiceProtocolTests.exe" if sys.platform == "win32" else "WhitegramVoiceProtocolTests")
    protocol_command = [compiler, "-parse-as-library", "-O", "-warnings-as-errors"]
    if args.sanitize_address:
        protocol_command.append("-sanitize=address")
    protocol_command += [
        str(cleanroom / "WhitegramVoiceSettings.swift"),
        str(cleanroom / "WhitegramVoiceBleep.swift"),
        str(cleanroom / "WhitegramVoiceProfanityStore.swift"),
        str(cleanroom / "WhitegramVoiceRemote.swift"),
        str(cleanroom / "WhitegramVoiceHTTP.swift"),
        str(directory / "WhitegramVoiceProtocolTests.swift"),
        "-o", str(protocol_executable),
    ]
    subprocess.run(protocol_command, check=True, cwd=directory)
    subprocess.run([str(protocol_executable)], check=True, cwd=directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
