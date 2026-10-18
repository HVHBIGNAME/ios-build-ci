"""Reproduce stock-launcher-icons from original audit-full-3.1.1 (stdlib only)."""

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import sqlite3

from launcher_icon_patches import (
    FEATURE, IPA_SHA256, MANIFEST_SHA256, PLIST_SHA256, RESOURCE_SPECS, RULES_APPLE_PIN,
    STOCK_ICONS, png_identity, stock_alternate_icon_entries,
)


def _audited_file(audit, connection, member):
    rows = connection.execute("SELECT resource_path, sha256, size FROM files WHERE path = ?", (member,)).fetchall()
    if len(rows) != 1 or rows[0][0] != "resources/" + member:
        raise ValueError(f"Missing or ambiguous original audit entry: {member}")
    relative, sha256, size = rows[0]
    path = audit / relative
    if path.resolve() != path or not path.is_file():
        raise ValueError(f"Missing original audit resource: {member}")
    data = path.read_bytes()
    if len(data) != size or hashlib.sha256(data).hexdigest() != sha256:
        raise ValueError(f"Original audit hash mismatch: {member}")
    return data, {"source_member": member, "sha256": sha256, "bytes": size}


def recover_launcher_icons(audit: Path, output: Path) -> dict:
    audit = Path(audit).resolve(strict=True)
    audit_manifest = (audit / "manifest.json").read_bytes()
    if json.loads(audit_manifest).get("ipa_sha256") != IPA_SHA256:
        raise ValueError("Expected the original Whitegram 3.1.1 audit")
    database = audit / "audit.sqlite3"
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
    connection.execute("PRAGMA query_only = ON")
    images, payloads = [], {}
    try:
        data, source_plist = _audited_file(audit, connection, "Payload/Telegram.app/Info.plist")
        if source_plist["sha256"] != PLIST_SHA256:
            raise ValueError("Original launcher Info.plist identity mismatch")
        info = plistlib.loads(data)
        original = {family: {name: info[family]["CFBundleAlternateIcons"][name] for name, _ in STOCK_ICONS}
                    for family in ("CFBundleIcons", "CFBundleIcons~ipad")}
        for name, (owner, size) in RESOURCE_SPECS.items():
            data, entry = _audited_file(audit, connection, "Payload/Telegram.app/" + name)
            identity = png_identity(data)
            if identity["width"] != size:
                raise ValueError(f"Unexpected original launcher dimensions: {name}")
            images.append({"file": name, "selection_name": owner, "bundle_path": name,
                           "install_path": f"{owner}.alticon/{name}", **entry, **identity})
            payloads[name] = data
    finally:
        connection.close()
    # Keep the broken old names as evidence, never as new packaging instructions.
    new_mapping = {}
    for name in ("New1", "New2"):
        new_mapping[name] = {
            stem: [file for file, (owner, size) in RESOURCE_SPECS.items()
                   if owner == name and size == int(stem.split("_")[1].split("x")[0])]
            for stem in original["CFBundleIcons"][name]["CFBundleIconFiles"]
        }
    with database.open("rb") as stream:
        database_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    manifest = {
        "schema": 1, "feature": FEATURE, "source_ipa_sha256": IPA_SHA256,
        "source_plist": source_plist,
        "audit_database_sha256": database_hash,
        "audit_manifest_sha256": hashlib.sha256(audit_manifest).hexdigest(),
        "recovery": "python -B whitegram/recover_launcher_icons.py <audit-full-3.1.1> <output-directory>",
        "conversion": "none; original CgBI PNG bytes and loose filenames preserved",
        "evidence": {"ui_getter_consumer": "0x3ee70", "default": False,
                     "isDefault": False, "isPremium": False},
        "stock_icons": [list(icon) for icon in STOCK_ICONS],
        "original_alternatives": original,
        "new_icon_original_reference_to_physical_files_by_pixels": new_mapping,
        "bundle_alternatives": stock_alternate_icon_entries(),
        "packaging": {"rules_apple_commit": RULES_APPLE_PIN,
                      "tool": "tools/alticonstool/alticonstool.py",
                      "rule": "apple/internal/partials/support/resources_support.bzl",
                      "families": ["iphone", "ipad"],
                      "references": "sorted unique filename stems with @scale removed; same union for both families",
                      "placement": "Bundle.main root; Xcode may losslessly recompress PNGs"},
        "images": images,
    }
    payloads["manifest.json"] = (json.dumps(manifest, indent=2, ensure_ascii=True) + "\n").encode()
    if hashlib.sha256(payloads["manifest.json"]).hexdigest() != MANIFEST_SHA256:
        raise ValueError("Recovered launcher provenance differs from the pinned original audit")
    output = Path(output).absolute()
    if not output.parent.is_dir() or output.resolve() != output:
        raise ValueError("Recovery output must have an existing parent and no symlink")
    if output.exists():
        extra = {path.name for path in output.iterdir()} - set(payloads) - {"README.md", ".gitattributes"}
        if extra:
            raise ValueError("Unexpected files in recovery destination")
        for name, data in payloads.items():
            path = output / name
            if path.exists() and (path.is_symlink() or not path.is_file() or path.read_bytes() != data):
                raise ValueError(f"Recovery destination differs: {name}")
    output.mkdir(exist_ok=True)
    for name, data in payloads.items():
        path = output / name
        if not path.exists():
            with path.open("xb") as stream:
                stream.write(data)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    manifest = recover_launcher_icons(args.audit, args.output)
    print(json.dumps({"images": len(manifest["images"]), "output": str(args.output.resolve()),
                      "source_ipa_sha256": manifest["source_ipa_sha256"]}, indent=2))


if __name__ == "__main__":
    main()
