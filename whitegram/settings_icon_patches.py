"""Original main-Settings glyph substitutions and loose main-app resources."""

import hashlib
import json
from pathlib import Path
import plistlib
import struct
import zlib

from launcher_icon_patches import png_identity
from source_patches import SourcePatches


IPA_SHA256 = "bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837"
SETTINGS = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift"
SETTINGS_ICON_RUNTIME_FILES = {
    "WhitegramSettingsIcons.swift": "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/WhitegramSettingsIcons.swift",
}
BUILD = "Telegram/BUILD"
RESOURCE_PATH = "Telegram/WhitegramSettingsIcons"
RESOURCES = Path(__file__).resolve().parent / "resources/settings-icons"

# Stock member, original imageNamed: input, original TelegramUI call site.
ICON_MAPPING = (
    ("myProfile", "whitegramprofile", "0x8eca5c"),
    ("proxy", "whitegramproxy", "0x8ecbfc"),
    ("savedMessages", "whitegramfavorite", "0x8ed164"),
    ("recentCalls", "whitegramcalls", "0x8ed21c"),
    ("devices", "whitegramgadgets", "0x8ed3a0"),
    ("chatFolders", "whitegramfolders", "0x8ed468"),
    ("notifications", "whitegrammessage", "0x8ed5a0"),
    ("security", "whitegramprivacy", "0x8ed688"),
    ("dataAndStorage", "whitegrammemory", "0x8ed74c"),
    ("appearance", "whitegramui", "0x8ed800"),
    ("powerSaving", "whitegrambattery", "0x8ed914"),
    ("language", "whitegramlanguage", "0x8eda84"),
    ("premium", "whitegrampremium", "0x8edbe8"),
    ("stars", "whitegramstars", "0x8ede4c"),
    ("ton", "whitegramwallet", "0x8ee08c"),
    ("business", "whitegrambusiness", "0x8ee1ec"),
    ("premiumGift", "whitegramgifts", "0x8ee33c"),
    ("support", "whitegramhelp", "0x8ee5e0"),
    ("faq", "whitegramfaq", "0x8ee6a0"),
    ("tips", "whitegramhow", "0x8ee75c"),
)
RESOURCE_FILES = tuple(sorted(f"{name}@{scale}x.png" for _, name, _ in ICON_MAPPING for scale in (2, 3)))


def apply_settings_icon_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    text = patches.read(SETTINGS)
    start, end = "func settingsItems(", "func settingsEditingItems("
    if text.count(start) != 1 or text.count(end) != 1 or text.index(end) <= text.index(start):
        raise ValueError("customSettingsIcons: missing or ambiguous main settingsItems scope")
    left, right = text.index(start), text.index(end)
    original = text[left:right]
    updated = original
    marker = "whitegramSettingsIcon("
    if marker in text[:left] or marker in text[right:]:
        raise ValueError("customSettingsIcons: substitution outside main settingsItems")
    expected = 0
    for member, name, _ in ICON_MAPPING:
        before = f"icon: PresentationResourcesSettings.{member},"
        after = f'icon: whitegramSettingsIcon("{name}", fallback: PresentationResourcesSettings.{member}),'
        count = updated.count(before) + updated.count(after)
        if member == "ton" and count == 0:
            continue
        if count != 1:
            raise ValueError(f"customSettingsIcons: missing, duplicate or changed {member} row")
        updated = updated.replace(before, after)
        expected += 1
    if updated.count(marker) != expected:
        raise ValueError("customSettingsIcons: unexpected or partial glyph substitution")
    patches.replace("customSettingsIcons", SETTINGS, original, updated)
    return patches.write()


def png_metadata(data: bytes) -> dict:
    """Read PNG chunks without converting Apple's original CgBI pixel stream."""
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Settings icon is not a PNG")
    offset, dimensions, cgbi, has_pixels = 8, None, False, False
    while offset + 12 <= len(data):
        length, kind = struct.unpack_from(">I4s", data, offset)
        end = offset + 12 + length
        if end > len(data):
            raise ValueError("Truncated settings icon PNG")
        chunk = data[offset + 8:end - 4]
        if zlib.crc32(kind + chunk) != struct.unpack_from(">I", data, end - 4)[0]:
            raise ValueError("Settings icon PNG checksum mismatch")
        if kind == b"CgBI":
            cgbi = True
        elif kind == b"IHDR":
            if dimensions is not None or length != 13:
                raise ValueError("Invalid settings icon PNG header")
            dimensions = struct.unpack_from(">II", chunk)
        elif kind == b"IDAT":
            has_pixels = True
        elif kind == b"IEND":
            if length or end != len(data) or dimensions is None or not has_pixels:
                raise ValueError("Incomplete settings icon PNG")
            return {"width": dimensions[0], "height": dimensions[1], "cgbi": cgbi}
        offset = end
    raise ValueError("Settings icon PNG has no end chunk")


def load_settings_icon_resources(resources: Path = RESOURCES) -> dict[str, bytes]:
    resources = Path(resources).resolve(strict=True)
    manifest_path = resources / "manifest.json"
    if manifest_path.is_symlink():
        raise ValueError("Settings icon manifest must be a local regular file")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (manifest.get("schema") != 1 or manifest.get("source_ipa_sha256") != IPA_SHA256
            or manifest.get("feature") != "customSettingsIcons"):
        raise ValueError("Settings icon provenance does not match original 3.1.1")
    expected_mapping = [{"stock_member": member, "asset_name": name, "ui_call_site": site} for member, name, site in ICON_MAPPING]
    if manifest.get("mapping") != expected_mapping:
        raise ValueError("Settings icon original mapping changed")
    images = manifest.get("images", [])
    if [entry.get("file") for entry in images] != list(RESOURCE_FILES):
        raise ValueError("Settings icon manifest must contain the exact 40 original files")
    if {path.name for path in resources.iterdir()} != set(RESOURCE_FILES) | {"manifest.json"}:
        raise ValueError("Missing or unexpected settings icon source resources")
    result = {}
    for entry in images:
        name = entry["file"]
        path = resources / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing settings icon source resource: {name}")
        data = path.read_bytes()
        if (hashlib.sha256(data).hexdigest() != entry.get("sha256") or len(data) != entry.get("bytes")
                or entry.get("source_member") != "Payload/Telegram.app/" + name
                or entry.get("bundle_path") != name):
            raise ValueError(f"Settings icon original resource identity mismatch: {name}")
        if any(entry.get(key) != value for key, value in png_metadata(data).items()):
            raise ValueError(f"Settings icon PNG metadata mismatch: {name}")
        result[name] = data
    return result


def _resource_build_patch(patches: SourcePatches):
    text = patches.read(BUILD)
    target = 'ios_application(\n    name = "Telegram",'
    declaration = 'filegroup(\n    name = "WhitegramSettingsIcons",\n    srcs = [\n'
    declaration += "".join(f'        "WhitegramSettingsIcons/{name}",\n' for name in RESOURCE_FILES)
    declaration += "    ],\n)\n\n"
    if text.count(target) != 1:
        raise ValueError("customSettingsIcons: missing or ambiguous main Telegram app target")
    if text.count('name = "WhitegramSettingsIcons"') > 1 or text.count('name = "WhitegramSettingsIcons"') != text.count(declaration):
        raise ValueError("customSettingsIcons: changed or duplicate resource filegroup")
    if declaration not in text:
        anchor = 'filegroup(\n    name = "LaunchScreen",'
        patches.replace("customSettingsIcons-resources", BUILD, anchor, declaration + anchor)
    text = patches.read(BUILD)
    start = text.index(target)
    app = text[start:]
    anchor = "    resources = [\n"
    if app.count(anchor) != 1:
        raise ValueError("customSettingsIcons: missing or ambiguous app resources")
    left = start + app.index(anchor)
    right = text.index("\n    ],", left) + len("\n    ],")
    before = text[left:right]
    entry = '        ":WhitegramSettingsIcons",\n'
    if text.count('":WhitegramSettingsIcons"') != before.count(entry) or before.count(entry) > 1:
        raise ValueError("customSettingsIcons: misplaced or duplicate app resource reference")
    # Append to the resource list so other installers may retain their LaunchScreen anchors.
    after = before if entry in before else before[:-len("    ],")] + entry + "    ],"
    patches.replace("customSettingsIcons-resources", BUILD, before, after)


def install_settings_icon_resources(root: Path, resources: Path = RESOURCES) -> dict[str, list[str]]:
    root = Path(root).resolve(strict=True)
    if not (root / BUILD).is_file() or (root / BUILD).resolve().parent != root / "Telegram":
        raise ValueError("customSettingsIcons: root must be the selected Telegram source checkout")
    images = load_settings_icon_resources(resources)
    destination = root / RESOURCE_PATH
    if destination.resolve() != destination or (destination.exists() and not destination.is_dir()):
        raise ValueError("customSettingsIcons: invalid resource destination")
    if destination.exists() and {path.name for path in destination.iterdir()} - set(images):
        raise ValueError("customSettingsIcons: unexpected destination resources")
    for name, data in images.items():
        path = destination / name
        if path.is_symlink() or (path.exists() and (not path.is_file() or path.read_bytes() != data)):
            raise ValueError(f"customSettingsIcons: changed installed resource: {name}")
    patches = SourcePatches(root)
    _resource_build_patch(patches)
    destination.mkdir(parents=True, exist_ok=True)
    for name, data in images.items():
        path = destination / name
        if not path.exists():
            with path.open("xb") as stream:
                stream.write(data)
    report = patches.write()
    report["customSettingsIcons-resources"] = [BUILD] + [f"{RESOURCE_PATH}/{name}" for name in images]
    return report


def verify_settings_icon_bundle(app: Path, resources: Path = RESOURCES) -> list[str]:
    """Check an extracted/built .app, including Bundle.main's flat image paths."""
    app = Path(app).resolve(strict=True)
    if app.suffix != ".app" or not (app / "Info.plist").is_file():
        raise ValueError("Expected the main Telegram .app root")
    with (app / "Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundlePackageType") != "APPL":
            raise ValueError("Expected an application bundle, not an extension or resource bundle")
    images = load_settings_icon_resources(resources)
    for name, data in images.items():
        path = app / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing or changed original icon at Bundle.main/{name}")
        bundled = path.read_bytes()
        if bundled != data:
            try:
                source, actual = png_identity(data), png_identity(bundled)
                matches = all(source[key] == actual[key] for key in ("width", "height", "premultiplied_rgba_sha256"))
            except ValueError:
                matches = False
            if not matches:
                raise ValueError(f"Missing or changed original icon at Bundle.main/{name}")
    return list(images)
