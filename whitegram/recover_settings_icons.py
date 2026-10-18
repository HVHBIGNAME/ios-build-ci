"""Recover the exact loose 3.1.1 Settings PNGs from the read-only original audit."""

import argparse
import hashlib
import json
from pathlib import Path
import sqlite3

from settings_icon_patches import ICON_MAPPING, IPA_SHA256, RESOURCE_FILES, png_metadata


def recover_settings_icons(audit: Path, output: Path) -> dict:
    audit = Path(audit).resolve(strict=True)
    audit_manifest = (audit / "manifest.json").read_bytes()
    if json.loads(audit_manifest).get("ipa_sha256") != IPA_SHA256:
        raise ValueError("The audit is not the pinned original Whitegram 3.1.1")
    database = audit / "audit.sqlite3"
    images, payloads = [], {}
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True)
    connection.execute("PRAGMA query_only = ON")
    try:
        for name in RESOURCE_FILES:
            member = "Payload/Telegram.app/" + name
            rows = connection.execute("SELECT resource_path, sha256, size FROM files WHERE path = ?", (member,)).fetchall()
            if len(rows) != 1 or rows[0][0] != "resources/" + member:
                raise ValueError(f"Missing or invalid original audit resource: {member}")
            relative, expected_hash, size = rows[0]
            path = audit / relative
            if path.resolve() != path or not path.is_file():
                raise ValueError(f"Missing original resource: {member}")
            data = path.read_bytes()
            if len(data) != size or hashlib.sha256(data).hexdigest() != expected_hash:
                raise ValueError(f"Original audit resource hash mismatch: {member}")
            images.append({"file": name, "source_member": member, "bundle_path": name,
                           "bytes": size, "sha256": expected_hash, **png_metadata(data)})
            payloads[name] = data
    finally:
        connection.close()
    with database.open("rb") as stream:
        database_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    manifest = {
        "schema": 1, "feature": "customSettingsIcons", "source_ipa_sha256": IPA_SHA256,
        "audit_manifest_sha256": hashlib.sha256(audit_manifest).hexdigest(),
        "audit_database_sha256": database_hash,
        "recovery": "python -B whitegram/recover_settings_icons.py <audit-full-3.1.1> <output-directory>",
        "conversion": "none; original CgBI PNG bytes preserved",
        "evidence": {"core_image": 46, "getter": "0x203018", "setter": "0x20307c",
                     "storage_key": "wg_customSettingsIcons", "default": False,
                     "ui_image": 55, "helper": "0x8f0d64", "image_loader": "0x78429c", "selector": "imageNamed:"},
        "mapping": [{"stock_member": member, "asset_name": name, "ui_call_site": site} for member, name, site in ICON_MAPPING],
        "images": images,
    }
    payloads["manifest.json"] = (json.dumps(manifest, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    output = Path(output).absolute()
    if not output.parent.is_dir() or output.resolve() != output:
        raise ValueError("Recovery output parent must exist and the destination must not be a symlink")
    if output.exists():
        if not output.is_dir() or {path.name for path in output.iterdir()} != set(payloads):
            raise ValueError("Recovery destination is not the exact previously recovered set")
        for name, data in payloads.items():
            path = output / name
            if path.is_symlink() or not path.is_file() or path.read_bytes() != data:
                raise ValueError(f"Recovery destination differs: {name}")
    else:
        output.mkdir()
        for name, data in payloads.items():
            with (output / name).open("xb") as stream:
                stream.write(data)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audit", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    manifest = recover_settings_icons(args.audit, args.output)
    print(json.dumps({"output": str(args.output.resolve()), "images": len(manifest["images"]),
                      "source_ipa_sha256": manifest["source_ipa_sha256"]}, indent=2))


if __name__ == "__main__":
    main()
