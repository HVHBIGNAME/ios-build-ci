#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
bundle_id = "whitegram.telegra.Telegraph"
url_scheme = "whitegram"
app_name = "WhiteGram"

config_path = root / "build-system" / "appstore-configuration.json"
config = json.loads(config_path.read_text())
config["bundle_id"] = bundle_id
config["app_specific_url_scheme"] = url_scheme
config_path.write_text(json.dumps(config, indent="\t") + "\n")

for relative in (
    Path("Telegram/Telegram-iOS/Config-AppStoreLLC.xcconfig"),
    Path("Telegram/Telegram-iOS/Config-Fork.xcconfig"),
):
    path = root / relative
    text = path.read_text()
    text = re.sub(r"^APP_NAME=.*$", f"APP_NAME={app_name}", text, flags=re.MULTILINE)
    text = re.sub(r"^APP_BUNDLE_ID=.*$", f"APP_BUNDLE_ID={bundle_id}", text, flags=re.MULTILINE)
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
    r'(name = "disableProvisioningProfiles",\s*build_setting_default = )False',
    r'\1True',
    text,
)
if count != 1:
    raise SystemExit("disableProvisioningProfiles flag was not found in Telegram/BUILD")
build_path.write_text(text)

versions_path = root / "versions.json"
versions = json.loads(versions_path.read_text())
versions["app"] = "12.9.4"
versions_path.write_text(json.dumps(versions, indent=4) + "\n")

print(f"Configured {app_name} ({bundle_id}) on Telegram 12.9.4")
