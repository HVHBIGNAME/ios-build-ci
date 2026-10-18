"""Verify a packaged IPA against the build metadata and committed plugin SDK."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import subprocess
import tempfile
import zipfile
from urllib.parse import urlsplit


SDK_FILES = (
    "whitegram-native-bootstrap.js", "whitegram-sdk-core.js", "whitegram-plugin-lifecycle.js",
    "whitegram-sdk-extensions.js", "whitegram-sdk-bridge.js", "whitegram-plugin-host.js",
)
ICONS = {"Aqua", "Aura", "Azure", "Chrome", "Crystal", "Depth", "Frost", "Glow", "MonoDark", "MonoLite", "NeonWawe", "Obsidian", "Steel"}
EXTENSION_SUFFIXES = {"Share", "NotificationService", "NotificationContent", "SiriIntents", "Widget", "BroadcastUpload"}


def verify_diagnostics(info: dict, revision: str, required: bool = False) -> bool:
    url = info.get("WhitegramDiagnosticsURL")
    key = info.get("WhitegramDiagnosticsUploadKey")
    if url is None and key is None:
        if required:
            raise ValueError("Automatic diagnostic delivery is missing from this IPA")
        return False
    if not isinstance(url, str) or not isinstance(key, str) or not re.fullmatch(r"[a-f0-9]{64}", key):
        raise ValueError("Invalid diagnostic delivery configuration")
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.path != "/v1/reports" or parsed.query or parsed.fragment):
        raise ValueError("Invalid diagnostic endpoint")
    if info.get("WhitegramSourceRevision") != revision:
        raise ValueError("Packaged diagnostic source revision does not match the requested revision")
    return True


def verify_restored_icon_archive(archive: zipfile.ZipFile) -> dict:
    from launcher_icon_patches import verify_launcher_icon_bundle
    from settings_icon_patches import verify_settings_icon_bundle

    with tempfile.TemporaryDirectory(prefix="whitegram-icon-verification-") as directory:
        app = Path(directory) / "Telegram.app"
        app.mkdir()
        for name in archive.namelist():
            path = PurePosixPath(name)
            if path.parts[:2] == ("Payload", "Telegram.app") and len(path.parts) == 3:
                if path.name == "Info.plist" or path.suffix == ".png":
                    (app / path.name).write_bytes(archive.read(name))
        return {"launcher": verify_launcher_icon_bundle(app), "settings": verify_settings_icon_bundle(app)}


def verify(ipa: Path, repository: Path, revision: str, version: str, build: str, require_diagnostics: bool = False, require_original_icon: bool = False, require_restored_icons: bool = False) -> dict:
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
        diagnostics = verify_diagnostics(info, revision, required=require_diagnostics)
        primary_icons = {key: info.get(key, {}).get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") for key in ("CFBundleIcons", "CFBundleIcons~ipad")}
        if require_original_icon and any(name != "WGPrimary" for name in primary_icons.values()):
            raise ValueError("Original WGPrimary icon is missing from the iPhone/iPad declarations")
        if require_original_icon and not any(name.startswith(app + "WGPrimary") and name.endswith(".png") for name in names):
            raise ValueError("Compiled original primary-icon PNGs are missing")
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
            if "WhitegramDiagnosticsUploadKey" in extension or "WhitegramDiagnosticsURL" in extension:
                raise ValueError("Diagnostic delivery credentials must be confined to the main app")
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
        restored_icons = verify_restored_icon_archive(archive) if require_restored_icons else None
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
        "automatic_diagnostics_configured": diagnostics,
        "primary_icons": primary_icons,
        "restored_icons": restored_icons,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", default="34639")
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--require-diagnostics", action="store_true")
    parser.add_argument("--require-original-icon", action="store_true")
    parser.add_argument("--require-restored-icons", action="store_true")
    args = parser.parse_args()
    report = verify(args.ipa, args.repository, args.revision, args.version, args.build, args.require_diagnostics, args.require_original_icon, args.require_restored_icons)
    output = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    args.report.write_text(output, encoding="utf-8")
    print(output, end="")


if __name__ == "__main__":
    main()
