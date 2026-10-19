"""Extract the three original welcome PNGs from the selected Whitegram 3.2 IPA."""

import argparse
import hashlib
import json
from pathlib import Path
import zipfile

from branding_patches import LOGO_FILES


IPA_SHA256 = "5cf287812de7707dd21256281e645c29a9a5c0da3f66910746254842fce5ffbf"


def recover(ipa: Path, output: Path) -> None:
    if output.exists() or not output.parent.is_dir():
        raise ValueError("Use a new output directory with an existing parent")
    with ipa.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != IPA_SHA256:
            raise ValueError("Source does not match the selected original Whitegram 3.2 IPA")
    payloads = {}
    with zipfile.ZipFile(ipa) as archive:
        for name, digest in LOGO_FILES.items():
            member = "Payload/Telegram.app/" + name
            data = archive.read(member)
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError(f"Original welcome artwork differs: {member}")
            payloads[name] = data
    output.mkdir()
    for name, data in payloads.items():
        (output / name).write_bytes(data)
    manifest = {
        "source_ipa_sha256": IPA_SHA256,
        "version": "Whitegram Beta 3.2 (13.0)",
        "conversion": "none; original PNG and CgBI bytes retained",
        "images": [{"file": name, "source_member": "Payload/Telegram.app/" + name,
                    "sha256": LOGO_FILES[name], "bytes": len(data)} for name, data in payloads.items()],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    recover(args.ipa, args.output)
