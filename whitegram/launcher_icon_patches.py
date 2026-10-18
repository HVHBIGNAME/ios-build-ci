"""Restore the opt-in Whitegram stock launcher list and audited main-app rasters.

The parent installs TelegramCore.WhitegramIconSettings (default false) and its
ordered stockIcons tuples. Call install_launcher_icon_resources during assembly
and apply_launcher_icon_patches after the public overlay. The latter commutes
with appearance_details_patches, including its Default preview substitution.
"""

import ast
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import zlib

from source_patches import SourcePatches

FEATURE = "showOriginalTelegramIcons"
APP = "submodules/TelegramUI/Sources/AppDelegate.swift"
BUILD = "Telegram/BUILD"
RESOURCE_PATH = "Telegram/WhitegramStockLauncherIcons"
RESOURCES = Path(__file__).resolve().parent / "resources/stock-launcher-icons"
IPA_SHA256 = "bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837"
PLIST_SHA256 = "74d3a5e3d05c6ac1a0c6a0e592777b900f7cea0d284a74da2d9a0ca9fc775c97"
MANIFEST_SHA256 = "099d4198acdb85e7e11c129551c1854077875cb0145cce93fc321f3345a6bbbe"
RULES_APPLE_PIN = "1791d916de4083388f22e20248d8b010d23f0d6b"

# Original TelegramUI consumer 0x3ee70; tuple order is observable in the picker.
STOCK_ICONS = (
    ("Blue", "BlueIcon"), ("New2", "New2"), ("New1", "New1"),
    ("Black", "BlackIcon"), ("BlueClassic", "BlueClassicIcon"),
    ("BlackClassic", "BlackClassicIcon"), ("BlueFilled", "BlueFilledIcon"),
    ("BlackFilled", "BlackFilledIcon"),
)
WG_ICONS = (
    "Aqua", "Azure", "MonoDark", "MonoLite", "Aura", "Depth", "Steel",
    "Chrome", "NeonWawe", "Glow", "Frost", "Obsidian", "Crystal",
)
HOOK = '''                if WhitegramIconSettings.current.showOriginalTelegramIcons {
                    icons.append(contentsOf: WhitegramIconSettings.stockIcons.map { icon in
                        PresentationAppIcon(name: icon.name, imageName: icon.imageName, isDefault: false, isPremium: false)
                    })
                }

'''


def stock_resource_specs() -> dict[str, tuple[str, int]]:
    """Original loose filename -> (selection name, square pixel size)."""
    specs = {}
    for name, image in STOCK_ICONS:
        if name.startswith("New"):
            suffixes = [("@2x", 120), ("@3x", 180), ("-76", 76),
                        ("-76@2x", 152), ("-83.5@2x", 167),
                        ("_notification", 20), ("_notification@3x", 60)]
            if name == "New1":
                suffixes += [("_notification@2x", 40)] + [(f"_{n}x{n}", n) for n in (29, 58, 80, 87)]
            else:
                suffixes += [("-Small", 29), ("-Small@2x", 58), ("-Small@3x", 87),
                             ("-Small-40", 40), ("-Small-40@2x", 80)]
            specs.update({image + suffix + ".png": (name, size) for suffix, size in suffixes})
        else:
            specs.update({image + suffix + ".png": (name, size) for suffix, size in
                          (("@2x", 120), ("@3x", 180), ("Ipad", 76), ("Ipad@2x", 152), ("LargeIpad@2x", 167))})
            if not name.endswith("Filled"):
                specs.update({name + "NotificationIcon" + suffix + ".png": (name, size)
                              for suffix, size in (("", 20), ("@2x", 40), ("@3x", 60))})
    return dict(sorted(specs.items()))


RESOURCE_SPECS = stock_resource_specs()


def stock_alternate_icon_entries() -> dict:
    """The pinned alticonstool emits this same filename-derived table for both families."""
    return {name: {"CFBundleIconFiles": sorted({Path(file).stem.split("@")[0]
                                              for file, (owner, _) in RESOURCE_SPECS.items() if owner == name})}
            for name, _ in STOCK_ICONS}


def apply_launcher_icon_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    text = patches.read(APP)
    start, end = "        }, getAvailableAlternateIcons: {\n", "        }, getAlternateIconName: {\n"
    if text.count(start) != 1 or text.count(end) != 1 or text.index(start) >= text.index(end):
        raise ValueError(f"{FEATURE}: missing or ambiguous alternate-icon getter")
    left, right = text.index(start), text.index(end)
    before = text[left:right]
    base = before.replace(HOOK, "").replace("                var icons = [\n", "                let icons = [\n")
    if text.count(HOOK) > 1 or any(marker in text[:left] + text[right:] + base for marker in
                                ("WhitegramIconSettings.stockIcons", "WhitegramIconSettings.current.showOriginalTelegramIcons")):
        raise ValueError(f"{FEATURE}: partial, duplicate or misplaced stock-icon hook")
    # Require the public Whitegram baseline, preserving either primary-preview spelling.
    entries = re.findall(r'^                    PresentationAppIcon\(([^\n]+)\),?$', base, re.MULTILINE)
    defaults = [f'name: "Default", imageName: "{image}", isDefault: true'
                for image in ("BlueIcon", "WhitegramPrimaryPreview")]
    expected = [f'name: "{name}", imageName: "{name}"' for name in WG_ICONS]
    if not entries or entries[0] not in defaults or entries[1:] != expected:
        raise ValueError(f"{FEATURE}: expected Default and the 13 public Whitegram alternatives")
    array = "\n".join("                    PresentationAppIcon(" + entry + ")" + ("," if i < 13 else "")
                      for i, entry in enumerate(entries))
    pattern = (re.escape(start + "            if #available(iOS 10.3, *) {\n                let icons = [\n" + array)
               + r"\n                \]\n[ \t]*\n"
               + re.escape("                return icons\n            } else {\n                return []\n            }\n"))
    if re.fullmatch(pattern, base) is None or text.count("import TelegramCore\n") != 1:
        raise ValueError(f"{FEATURE}: changed getter body or missing TelegramCore import")
    after = base.replace("                let icons = [\n", "                var icons = [\n")
    after = after.replace("                return icons\n", HOOK + "                return icons\n")
    if before not in (base, after):
        raise ValueError(f"{FEATURE}: partially installed getter")
    patches.replace(FEATURE, APP, before, after)
    return patches.write()


def _png_chunks(data: bytes) -> dict[bytes, list[bytes]]:
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Launcher resource is not a PNG")
    chunks, offset = {}, 8
    while offset + 12 <= len(data):
        size, kind = struct.unpack_from(">I4s", data, offset)
        end = offset + size + 12
        if end > len(data):
            raise ValueError("Truncated launcher PNG")
        payload = data[offset + 8:end - 4]
        if zlib.crc32(kind + payload) != struct.unpack_from(">I", data, end - 4)[0]:
            raise ValueError("Launcher PNG CRC mismatch")
        chunks.setdefault(kind, []).append(payload)
        if kind == b"IEND":
            if size or end != len(data) or len(chunks.get(b"IHDR", [])) != 1 or b"IDAT" not in chunks:
                raise ValueError("Incomplete launcher PNG")
            return chunks
        offset = end
    raise ValueError("Launcher PNG has no IEND")


def png_identity(data: bytes) -> dict:
    """Fingerprint premultiplied RGBA pixels across PNG/CgBI and Xcode recompression."""
    chunks = _png_chunks(data)
    width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", chunks[b"IHDR"][0])
    if depth != 8 or color not in (2, 3, 6) or compression or filtering or interlace or not 0 < width == height <= 180:
        raise ValueError("Unsupported launcher PNG layout")
    cgbi = b"CgBI" in chunks
    channels = {2: 3, 3: 1, 6: 4}[color]
    palette = b"".join(chunks.get(b"PLTE", []))
    alpha = b"".join(chunks.get(b"tRNS", []))
    if (color == 3 and (cgbi or not palette or len(palette) % 3)) or (color != 3 and alpha):
        raise ValueError("Unsupported launcher PNG palette/transparency")
    stride = width * channels
    decoder = zlib.decompressobj(-15 if cgbi else 15)
    expected = (stride + 1) * height
    raw = decoder.decompress(b"".join(chunks[b"IDAT"]), expected + 1)
    if len(raw) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("Launcher PNG pixel length mismatch")
    previous, rgba = bytearray(stride), bytearray()
    for y in range(height):
        offset = y * (stride + 1)
        kind = raw[offset]
        row = bytearray(raw[offset + 1:offset + 1 + stride])
        if kind > 4:
            raise ValueError("Unknown launcher PNG row filter")
        for x in range(stride):
            a, b = row[x - channels] if x >= channels else 0, previous[x]
            c = previous[x - channels] if x >= channels else 0
            if kind == 1:
                prediction = a
            elif kind == 2:
                prediction = b
            elif kind == 3:
                prediction = (a + b) // 2
            elif kind == 4:
                p = a + b - c
                distances = (abs(p - a), abs(p - b), abs(p - c))
                prediction = (a, b, c)[distances.index(min(distances))]
            else:
                prediction = 0
            row[x] = (row[x] + prediction) & 255
        for x in range(0, stride, channels):
            if color == 3:
                index = row[x]
                if index * 3 + 3 > len(palette):
                    raise ValueError("Invalid launcher palette entry")
                pixel = palette[index * 3:index * 3 + 3]
                opacity = alpha[index] if index < len(alpha) else 255
            else:
                pixel = row[x:x + 3]
                opacity = row[x + 3] if channels == 4 else 255
            rgba.extend(pixel[::-1] if cgbi else bytes((c * opacity + 127) // 255 for c in pixel))
            rgba.append(opacity)
        previous = row
    return {"width": width, "height": height, "cgbi": cgbi,
            "premultiplied_rgba_sha256": hashlib.sha256(rgba).hexdigest()}


def load_launcher_icon_resources(resources: Path = RESOURCES) -> dict[str, bytes]:
    resources = Path(resources).resolve(strict=True)
    manifest_path = resources / "manifest.json"
    data = manifest_path.read_bytes()
    if manifest_path.is_symlink() or hashlib.sha256(data).hexdigest() != MANIFEST_SHA256:
        raise ValueError("Launcher icon original manifest identity mismatch")
    manifest = json.loads(data)
    if (manifest.get("schema") != 1 or manifest.get("feature") != FEATURE
            or manifest.get("source_ipa_sha256") != IPA_SHA256
            or manifest.get("source_plist", {}).get("sha256") != PLIST_SHA256
            or manifest.get("stock_icons") != [list(icon) for icon in STOCK_ICONS]
            or manifest.get("bundle_alternatives") != stock_alternate_icon_entries()):
        raise ValueError("Launcher icon original provenance/mapping mismatch")
    images = manifest.get("images", [])
    if [entry.get("file") for entry in images] != list(RESOURCE_SPECS):
        raise ValueError("Launcher manifest must contain the exact 66 original PNGs")
    if {path.name for path in resources.iterdir()} - {"README.md", ".gitattributes"} != set(RESOURCE_SPECS) | {"manifest.json"}:
        raise ValueError("Missing or unexpected launcher resources")
    payloads = {}
    for entry in images:
        name = entry["file"]
        path = resources / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing original launcher resource: {name}")
        data = path.read_bytes()
        owner, size = RESOURCE_SPECS[name]
        if (hashlib.sha256(data).hexdigest() != entry.get("sha256") or len(data) != entry.get("bytes")
                or entry.get("source_member") != "Payload/Telegram.app/" + name
                or entry.get("install_path") != f"{owner}.alticon/{name}"
                or entry.get("bundle_path") != name
                or any(entry.get(key) != value for key, value in png_identity(data).items())
                or entry.get("width") != size):
            raise ValueError(f"Original launcher resource identity mismatch: {name}")
        payloads[name] = data
    return payloads


def _patch_build(patches: SourcePatches) -> None:
    text = patches.read(BUILD)
    folders = re.findall(r"^alternate_icon_folders = (\[[\s\S]*?^\])", text, re.MULTILINE)
    if len(folders) != 1 or ast.literal_eval(folders[0]) != list(WG_ICONS):
        raise ValueError(f"{FEATURE}: expected the existing 13 Whitegram alternate_icon_folders")
    declaration = ""
    for name, _ in STOCK_ICONS:
        declaration += f'filegroup(\n    name = "WhitegramStockLauncherIcon_{name}",\n    srcs = [\n'
        declaration += "".join(f'        "WhitegramStockLauncherIcons/{name}.alticon/{file}",\n'
                               for file, (owner, _) in RESOURCE_SPECS.items() if owner == name)
        declaration += "    ],\n)\n\n"
    marker = 'name = "WhitegramStockLauncherIcon_'
    if marker in text and (text.count(declaration) != 1 or text.count(marker) != len(STOCK_ICONS)):
        raise ValueError(f"{FEATURE}: changed or duplicate stock filegroups")
    if declaration not in text:
        anchor = 'filegroup(\n    name = "LaunchScreen",'
        patches.replace(FEATURE + "-resources", BUILD, anchor, declaration + anchor)
    text = patches.read(BUILD)
    start = 'ios_application(\n    name = "Telegram",'
    if text.count(start) != 1:
        raise ValueError(f"{FEATURE}: missing or ambiguous main application target")
    left = text.index(start)
    right = text.index("\n)\n", left) + len("\n)\n")
    before = text[left:right]
    anchor = '    alternate_icons = [\n        ":{}".format(name) for name in alternate_icon_folders\n    ],'
    extension = "\n".join(f'        ":WhitegramStockLauncherIcon_{name}",' for name, _ in STOCK_ICONS)
    installed = anchor[:-1] + " + [\n" + extension + "\n    ],"
    if before.count(installed) == 1:
        after = before
    elif before.count(anchor) == 1 and '":WhitegramStockLauncherIcon_' not in before:
        after = before.replace(anchor, installed)
    else:
        raise ValueError(f"{FEATURE}: missing, changed or duplicate alternate_icons expression")
    outside = text[:left] + text[right:]
    if '":WhitegramStockLauncherIcon_' in outside or after.count('":WhitegramStockLauncherIcon_') != 8:
        raise ValueError(f"{FEATURE}: misplaced stock alternate_icons references")
    patches.replace(FEATURE + "-resources", BUILD, before, after)


def install_launcher_icon_resources(root: Path, resources: Path = RESOURCES) -> dict[str, list[str]]:
    """Install original-only .alticon directories and extend the main app's Bazel input."""
    root = Path(root).resolve(strict=True)
    images = load_launcher_icon_resources(resources)
    destination = root / RESOURCE_PATH
    expected = {f"{RESOURCE_SPECS[name][0]}.alticon/{name}": data for name, data in images.items()}
    if (root / BUILD).resolve() != root / BUILD or destination.resolve() != destination:
        raise ValueError("Invalid launcher resource destination")
    if destination.exists() and not destination.is_dir():
        raise ValueError("Launcher resource destination is not a directory")
    if destination.exists():
        known_dirs = {f"{name}.alticon" for name, _ in STOCK_ICONS}
        for path in destination.rglob("*"):
            relative = path.relative_to(destination).as_posix()
            if path.is_symlink() or (path.is_dir() and relative not in known_dirs) or (path.is_file() and relative not in expected):
                raise ValueError(f"Unexpected installed launcher resource: {relative}")
    for relative, data in expected.items():
        path = destination / relative
        if path.resolve() != path or (path.exists() and (not path.is_file() or path.read_bytes() != data)):
            raise ValueError(f"Changed installed launcher resource: {relative}")
    patches = SourcePatches(root)
    _patch_build(patches)
    for relative, data in expected.items():
        path = destination / relative
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as stream:
                stream.write(data)
    report = patches.write()
    report[FEATURE + "-resources"] = [BUILD] + [f"{RESOURCE_PATH}/{relative}" for relative in expected]
    return report


def verify_launcher_icon_bundle(app: Path, resources: Path = RESOURCES, *, baseline_info: dict | None = None) -> dict:
    """Verify an extracted .app after packaging, allowing lossless PNG recompression.

    baseline_info may be a pre-restoration built Info.plist. If supplied, every
    non-stock alternate and the primary declarations must be unchanged exactly.
    """
    app = Path(app).resolve(strict=True)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if app.suffix != ".app" or info.get("CFBundlePackageType") != "APPL":
        raise ValueError("Expected the main Telegram .app")
    images = load_launcher_icon_resources(resources)
    expected = stock_alternate_icon_entries()
    for family in ("CFBundleIcons", "CFBundleIcons~ipad"):
        icons = info.get(family, {})
        if icons.get("CFBundlePrimaryIcon", {}).get("CFBundleIconName") != "WGPrimary":
            raise ValueError(f"WGPrimary is missing from {family}")
        alternatives = icons.get("CFBundleAlternateIcons", {})
        if not set(WG_ICONS).issubset(alternatives):
            raise ValueError(f"Whitegram alternatives are missing from {family}")
        for name, entry in expected.items():
            if alternatives.get(name) != entry:
                raise ValueError(f"Incorrect physical launcher references: {family}/{name}")
        if baseline_info is not None:
            baseline = baseline_info[family]
            nonstock = {k: v for k, v in alternatives.items() if k not in expected}
            prior = {k: v for k, v in baseline.get("CFBundleAlternateIcons", {}).items() if k not in expected}
            if nonstock != prior or icons["CFBundlePrimaryIcon"] != baseline["CFBundlePrimaryIcon"]:
                raise ValueError(f"Existing launcher declarations changed: {family}")
        # Validate primary and alternate stems, including all retained WG entries.
        entries = [("primary", icons["CFBundlePrimaryIcon"]), *alternatives.items()]
        for name, entry in entries:
            stems = entry.get("CFBundleIconFiles", [])
            if not stems:
                raise ValueError(f"Missing launcher file references: {family}/{name}")
            for stem in stems:
                if Path(stem).name != stem or not any((app / (stem + suffix + ".png")).is_file() for suffix in ("", "@2x", "@3x")):
                    raise ValueError(f"Unresolved Bundle.main launcher file: {stem}")
    reencoded = []
    for name, data in images.items():
        path = app / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing original launcher PNG at Bundle.main/{name}")
        bundled = path.read_bytes()
        if bundled != data:
            source, actual = png_identity(data), png_identity(bundled)
            if any(source[key] != actual[key] for key in ("width", "height", "premultiplied_rgba_sha256")):
                raise ValueError(f"Changed original launcher pixels at Bundle.main/{name}")
            reencoded.append(name)
    return {"stock_icons": [name for name, _ in STOCK_ICONS], "files": list(images),
            "losslessly_reencoded": reencoded, "families": ["iphone", "ipad"]}
