"""Install the recovered WGPrimary appearance variants into the app-icon target."""
import hashlib
import json
from pathlib import Path
import shutil

RESOURCES = Path(__file__).resolve().parent / "resources/primary-icon"
CATALOG = Path("Telegram/Telegram-iOS/DefaultAppIcon.xcassets")


def install_primary_icon(source: Path) -> None:
    manifest = json.loads((RESOURCES / "manifest.json").read_text(encoding="utf-8"))
    images = []
    for entry in manifest["images"]:
        name = entry["file"]
        if Path(name).name != name or hashlib.sha256((RESOURCES / name).read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("Original primary-icon resource identity mismatch")
        image = {"filename": name, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if entry["appearance"] != "light":
            image["appearances"] = [{"appearance": "luminosity", "value": entry["appearance"]}]
        images.append(image)
    catalog = source / CATALOG
    previous = catalog / "AppIconLLC.appiconset"
    destination = catalog / "WGPrimary.appiconset"
    if previous.exists():
        if destination.exists():
            raise ValueError("Both primary icon sets exist; refusing an ambiguous build")
        previous.rename(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for entry in manifest["images"]:
        shutil.copyfile(RESOURCES / entry["file"], destination / entry["file"])
    contents = {"images": images, "info": {"author": "xcode", "version": 1}}
    (destination / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")
