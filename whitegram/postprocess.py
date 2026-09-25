#!/usr/bin/env python3
import plistlib
import shutil
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
old_prefix = "ph.telegra.Telegraph"
new_prefix = "whitegram.telegra.Telegraph"
old_group = f"group.{old_prefix}"
new_group = f"group.{new_prefix}"

plist_count = 0
url_scheme_count = 0
entitlement_count = 0

for path in sorted(root.rglob("Info.plist")):
    try:
        with path.open("rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException):
        continue

    changed = False
    bundle_id = plist.get("CFBundleIdentifier")
    if isinstance(bundle_id, str) and (bundle_id == old_prefix or bundle_id.startswith(old_prefix + ".")):
        plist["CFBundleIdentifier"] = new_prefix + bundle_id[len(old_prefix):]
        changed = True

    if path.name == "Info.plist" and path.parent.name == "Telegram.app":
        if plist.get("CFBundleDisplayName") != "WhiteGram":
            plist["CFBundleDisplayName"] = "WhiteGram"
            changed = True

    url_types = plist.get("CFBundleURLTypes")
    if isinstance(url_types, list):
        for url_type in url_types:
            if not isinstance(url_type, dict):
                continue
            schemes = url_type.get("CFBundleURLSchemes")
            if not isinstance(schemes, list):
                continue
            replaced = []
            for scheme in schemes:
                if scheme in ("tg", "tgapp"):
                    replaced.append("whitegram")
                    url_scheme_count += 1
                elif scheme not in replaced:
                    replaced.append(scheme)
            if replaced != schemes:
                url_type["CFBundleURLSchemes"] = replaced
                changed = True

    if changed:
        with path.open("wb") as handle:
            plistlib.dump(plist, handle, fmt=plistlib.FMT_BINARY, sort_keys=False)
        plist_count += 1

for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue
    if path.suffix not in (".xcent", ".entitlements") and "entitlement" not in path.name.lower():
        continue
    data = path.read_bytes()
    updated = data.replace(old_group.encode(), new_group.encode()).replace(old_prefix.encode(), new_prefix.encode())
    if updated != data:
        path.write_bytes(updated)
        entitlement_count += 1

signature_dirs = [path for path in root.rglob("_CodeSignature") if path.is_dir()]
for path in signature_dirs:
    shutil.rmtree(path)

profiles = [path for path in root.rglob("embedded.mobileprovision") if path.is_file()]
for path in profiles:
    path.unlink()

if plist_count == 0:
    raise SystemExit("no bundle identifiers were rewritten")

print(f"Rewrote {plist_count} plist file(s), {url_scheme_count} URL scheme(s), {entitlement_count} entitlement file(s)")
print(f"Removed {len(signature_dirs)} code signature(s) and {len(profiles)} embedded profile(s)")
