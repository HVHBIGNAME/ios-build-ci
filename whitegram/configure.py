#!/usr/bin/env python3
import json
import os
import re
import sys
from pathlib import Path
from primary_icon import install_primary_icon

root = Path(sys.argv[1]).resolve()
build_bundle_id = "ph.telegra.Telegraph"
url_scheme = "whitegram"
app_name = "WhiteGram"

config_path = root / "build-system" / "appstore-configuration.json"
config = json.loads(config_path.read_text())
api_id = os.environ.get("WHITEGRAM_TELEGRAM_API_ID", "")
api_hash = os.environ.get("WHITEGRAM_TELEGRAM_API_HASH", "")
if api_id or api_hash:
    if not re.fullmatch(r"[1-9][0-9]{0,9}", api_id) or int(api_id) > 2147483647:
        raise SystemExit("WHITEGRAM_TELEGRAM_API_ID must be a positive 32-bit integer; configure both Telegram API secrets")
    if not re.fullmatch(r"[a-fA-F0-9]{32}", api_hash):
        raise SystemExit("WHITEGRAM_TELEGRAM_API_HASH must contain 32 hexadecimal characters; configure both Telegram API secrets")
    config["api_id"] = api_id
    config["api_hash"] = api_hash
config["bundle_id"] = build_bundle_id
config["app_specific_url_scheme"] = url_scheme
# The unsigned distribution has no provisioned Telegram iCloud container.
# CKContainer.default() throws an Objective-C exception after sideloading.
config["enable_icloud"] = False
config_path.write_text(json.dumps(config, indent="\t") + "\n")

for relative in (
    Path("Telegram/Telegram-iOS/Config-AppStoreLLC.xcconfig"),
    Path("Telegram/Telegram-iOS/Config-Fork.xcconfig"),
):
    path = root / relative
    text = path.read_text()
    text = re.sub(r"^APP_NAME=.*$", f"APP_NAME={app_name}", text, flags=re.MULTILINE)
    text = re.sub(r"^APP_BUNDLE_ID=.*$", f"APP_BUNDLE_ID={build_bundle_id}", text, flags=re.MULTILINE)
    text = re.sub(r"^APP_SPECIFIC_URL_SCHEME=.*$", f"APP_SPECIFIC_URL_SCHEME={url_scheme}", text, flags=re.MULTILINE)
    path.write_text(text)

build_path = root / "Telegram" / "BUILD"
text = build_path.read_text()
text, count = re.subn(
    r"(<key>CFBundleDisplayName</key>\s*<string>)Telegram(</string>)",
    rf"\g<1>{app_name}\g<2>",
    text,
)
if count == 0 and f"<string>{app_name}</string>" not in text:
    raise SystemExit("CFBundleDisplayName was not found in Telegram/BUILD")
text, count = re.subn(
    r'(name = "disableProvisioningProfiles",\s*build_setting_default = )True',
    r'\1False',
    text,
)
if count == 0 and 'name = "disableProvisioningProfiles"' not in text:
    raise SystemExit("disableProvisioningProfiles flag was not found in Telegram/BUILD")
build_path.write_text(text)

versions_path = root / "versions.json"
versions = json.loads(versions_path.read_text())

install_primary_icon(root)

print(f"Configured {app_name} build identity {build_bundle_id} on Telegram {versions['app']}")
