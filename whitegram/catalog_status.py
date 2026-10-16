"""Report catalogue routes and unresolved rows; route presence is not parity proof."""

import argparse
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent


def catalogue_status(root=ROOT):
    catalogue = (root / "generated/WhitegramSettingsCatalog.swift").read_text(encoding="utf-8")
    capabilities = (root / "cleanroom/WhitegramPortCapabilities.swift").read_text(encoding="utf-8")
    numbers = (root / "cleanroom/WhitegramSettingsNumber.swift").read_text(encoding="utf-8")
    routes = {}
    for table, kind in (("booleans", "toggle"), ("screens", "screen"), ("links", "link"), ("informationKeys", "information")):
        block = capabilities.split(f"static let {table}:", 1)[1].split("\n    ]", 1)[0]
        for row, target in re.findall(r'"([^"\n]+)": "([^"\n]+)"', block):
            routes.setdefault(row, {"route": kind, "target": target})
    cases = numbers.split("    var key:", 1)[0]
    for line in re.findall(r"^    case (.+)$", cases, re.MULTILINE):
        for row in line.split(", "):
            routes[row] = {"route": "slider", "target": "WhitegramSettingsNumber." + row}
    routes["messagePreview"] = {"route": "preview", "target": "ThemeSettingsChatPreviewItem"}
    result = []
    for row, order, section, kind in re.findall(r'WhitegramSettingsRowDescriptor\(id: "([^\"]+)", order: (\d+), section: (\d+), kind: \.(\w+)', catalogue):
        result.append({"id": row, "order": int(order), "section": int(section), "kind": kind,
                       **routes.get(row, {"route": "header" if kind == "headerRow" else "unconnected"})})
    if len(result) != 333 or len({row["id"] for row in result}) != 333:
        raise ValueError("Recovered catalogue identity changed; review row parser and baseline")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    rows = catalogue_status()
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return
    counts = {route: sum(row["route"] == route for row in rows) for route in sorted({row["route"] for row in rows})}
    print("Catalogue UI routes (not runtime/parity certification): " + json.dumps(counts))
    for row in rows:
        if row["route"] == "unconnected":
            print(f"{row['order']:3}  section {row['section']:2}  {row['kind']:14}  {row['id']}")


if __name__ == "__main__":
    main()
