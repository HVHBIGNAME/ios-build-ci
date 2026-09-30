"""Verify a packaged IPA against the build metadata and committed plugin SDK."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import struct
import subprocess
import zipfile


SDK_FILES = (
    "whitegram-native-bootstrap.js", "whitegram-sdk-core.js", "whitegram-plugin-lifecycle.js",
    "whitegram-sdk-extensions.js", "whitegram-sdk-bridge.js", "whitegram-plugin-host.js",
)
ICONS = {"Aqua", "Aura", "Azure", "Chrome", "Crystal", "Depth", "Frost", "Glow", "MonoDark", "MonoLite", "NeonWawe", "Obsidian", "Steel"}
EXTENSION_SUFFIXES = {"Share", "NotificationService", "NotificationContent", "SiriIntents", "Widget", "BroadcastUpload"}


def verify(ipa: Path, repository: Path, revision: str, version: str, build: str) -> dict:
    app = "Payload/Telegram.app/"
    bundle_id = "whitegram.telegra.Telegraph"
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate archive paths")
        broken = archive.testzip()
        if broken is not None:
            raise ValueError(f"Archive CRC failure: {broken}")
        for name in names:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError(f"Unexpected archive path: {name}")
        info = plistlib.loads(archive.read(app + "Info.plist"))
        for key, expected in (("CFBundleIdentifier", bundle_id), ("CFBundleShortVersionString", version), ("CFBundleVersion", build)):
            if str(info.get(key)) != expected:
                raise ValueError(f"Unexpected {key}: {info.get(key)!r}")
        with archive.open(app + info["CFBundleExecutable"]) as binary:
            magic, cpu, subtype = struct.unpack("<III", binary.read(12))
        if magic != 0xFEEDFACF or cpu != 0x0100000C:
            raise ValueError("Main executable is not a 64-bit ARM Mach-O")
        extensions = {}
        expected_extensions = {bundle_id + "." + suffix for suffix in EXTENSION_SUFFIXES}
        for name in names:
            if not name.startswith(app + "PlugIns/") or not name.endswith(".appex/Info.plist"):
                continue
            product = PurePosixPath(name).parent.stem
            extension = plistlib.loads(archive.read(name))
            identifier = extension.get("CFBundleIdentifier")
            # Bazel product names differ from IDs: WidgetExtension.appex uses .Widget.
            if identifier not in expected_extensions or identifier in extensions.values():
                raise ValueError(f"Unexpected or duplicate extension identity for {product}: {identifier!r}")
            extensions[product] = identifier
        missing = expected_extensions - set(extensions.values())
        if missing:
            raise ValueError(f"Missing extension identities: {sorted(missing)}")
        sdk = app + "WhitegramPluginSDK.bundle/"
        sdk_info = plistlib.loads(archive.read(sdk + "Info.plist"))
        if sdk_info.get("CFBundleIdentifier") != "org.whitegram.PluginSDK":
            raise ValueError("Unexpected plugin SDK bundle identity")
        sdk_hashes = {}
        for name in SDK_FILES:
            expected = subprocess.check_output(["git", "-C", str(repository), "show", f"{revision}:whitegram/cleanroom/pluginsdk/{name}"])
            actual = archive.read(sdk + name)
            if actual != expected:
                raise ValueError(f"Plugin SDK differs from committed source: {name}")
            sdk_hashes[name] = hashlib.sha256(actual).hexdigest()
        icons = set(info.get("CFBundleIcons", {}).get("CFBundleAlternateIcons", {}))
        if not ICONS.issubset(icons):
            raise ValueError(f"Missing alternate icons: {sorted(ICONS - icons)}")
    digest = hashlib.sha256()
    with ipa.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {
        "ipa": str(ipa.resolve()), "sha256": digest.hexdigest(), "bytes": ipa.stat().st_size,
        "source_revision": revision, "bundle_id": bundle_id, "version": version, "build": build,
        "architecture": "arm64", "cpu_subtype": subtype, "extensions": extensions,
        "alternate_icons": sorted(icons), "plugin_sdk_sha256": sdk_hashes,
        "zip_crc": "passed", "device_validation": "not performed",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--version", default="12.9.4")
    parser.add_argument("--build", default="34639")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = verify(args.ipa, args.repository, args.revision, args.version, args.build)
    output = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    args.report.write_text(output, encoding="utf-8")
    print(output, end="")


if __name__ == "__main__":
    main()
