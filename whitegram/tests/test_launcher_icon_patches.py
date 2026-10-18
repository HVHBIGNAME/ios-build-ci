"""Audited recovery, real-candidate hooks, patch composition and packaging checks.

Optional integration inputs: WHITEGRAM_ASSEMBLED_SOURCE,
WHITEGRAM_ORIGINAL_AUDIT, WHITEGRAM_ALTICON_TOOL. Source checkouts stay read-only.
"""

from collections import Counter
from contextlib import closing
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import runpy
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))

from appearance_details_patches import apply_appearance_details_patches, HEADER, BUTTON
import launcher_icon_patches as icons
from primary_icon import install_primary_icon
from recover_launcher_icons import recover_launcher_icons
from test_history_patches import MemoryRoot, PIN, parse_sources

SOURCE = os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE")
AUDIT = os.environ.get("WHITEGRAM_ORIGINAL_AUDIT")
ALTICON_TOOL = os.environ.get("WHITEGRAM_ALTICON_TOOL")
EXPECTED_STOCK = [
    ("Blue", "BlueIcon"), ("New2", "New2"), ("New1", "New1"), ("Black", "BlackIcon"),
    ("BlueClassic", "BlueClassicIcon"), ("BlackClassic", "BlackClassicIcon"),
    ("BlueFilled", "BlueFilledIcon"), ("BlackFilled", "BlackFilledIcon"),
]
EXPECTED_WG = ["Aqua", "Azure", "MonoDark", "MonoLite", "Aura", "Depth", "Steel",
               "Chrome", "NeonWawe", "Glow", "Frost", "Obsidian", "Crystal"]
TOOL_HASH = "831d2b43bfadd8f250e5208b2d8e11132fd85c6b571af430af65291b81d2b8fb"


def snapshot(root):
    return {path.relative_to(root).as_posix(): path.read_bytes() for path in root.rglob("*") if path.is_file()}


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


def synthetic_png(kind, *, cgbi=False):
    # Deliberately use different rows/channels; Paeth ties and edge predictors matter.
    rows = [bytes([20, 80, 240, 255, 2, 40, 99, 255]), bytes([70, 160, 210, 255, 3, 61, 101, 255])]
    encoded = bytearray()
    previous = bytes(8)
    for row in rows:
        native = bytes(v for x in (0, 4) for v in (row[x + 2], row[x + 1], row[x], row[x + 3])) if cgbi else row
        encoded.append(kind)
        for x, value in enumerate(native):
            a, b, c = native[x - 4] if x >= 4 else 0, previous[x], previous[x - 4] if x >= 4 else 0
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            paeth = a if pa <= pb and pa <= pc else b if pb <= pc else c
            encoded.append((value - (0, a, b, (a + b) // 2, paeth)[kind]) & 255)
        previous = native
    compressor = zlib.compressobj(wbits=-15 if cgbi else 15)
    png = b"\x89PNG\r\n\x1a\n"
    if cgbi:
        png += chunk(b"CgBI", b"\x40\xa0\x60\x82")
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", compressor.compress(encoded) + compressor.flush()) + chunk(b"IEND", b"")
    return png, hashlib.sha256(b"".join(rows)).hexdigest()


class LauncherResourcesTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.images = icons.load_launcher_icon_resources()
        cls.manifest = json.loads((icons.RESOURCES / "manifest.json").read_bytes())

    def test_original_order_flags_and_provenance(self):
        self.assertEqual(list(icons.STOCK_ICONS), EXPECTED_STOCK)
        self.assertEqual(len(self.images), 66)
        self.assertEqual(self.manifest["evidence"], {"ui_getter_consumer": "0x3ee70", "default": False,
                                                     "isDefault": False, "isPremium": False})
        self.assertEqual(self.manifest["source_plist"]["sha256"],
                         "74d3a5e3d05c6ac1a0c6a0e592777b900f7cea0d284a74da2d9a0ca9fc775c97")
        for entry in self.manifest["images"]:
            self.assertEqual(hashlib.sha256(self.images[entry["file"]]).hexdigest(), entry["sha256"])
        self.assertNotIn("New2_notification@2x.png", self.images)

    def test_new_icon_mapping_uses_real_names_for_each_original_pixel_size(self):
        expected = {
            "New1": ["New1_notification.png", "New1_29x29.png", "New1_notification@2x.png", "New1_58x58.png",
                     "New1_notification@3x.png", "New1-76.png", "New1_80x80.png", "New1_87x87.png",
                     "New1@2x.png", "New1-76@2x.png", "New1-83.5@2x.png", "New1@3x.png"],
            "New2": ["New2_notification.png", "New2-Small.png", "New2-Small-40.png", "New2-Small@2x.png",
                     "New2_notification@3x.png", "New2-76.png", "New2-Small-40@2x.png", "New2-Small@3x.png",
                     "New2@2x.png", "New2-76@2x.png", "New2-83.5@2x.png", "New2@3x.png"],
        }
        for name, files in expected.items():
            mapping = self.manifest["new_icon_original_reference_to_physical_files_by_pixels"][name]
            for size, filename in zip((20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180), files):
                self.assertEqual(mapping[f"{name}_{size}x{size}"], [filename])
                self.assertEqual(icons.png_identity(self.images[filename])["width"], size)

    def test_every_selection_has_phone_ipad_and_original_preview_images(self):
        entries = icons.stock_alternate_icon_entries()
        for name, image in EXPECTED_STOCK:
            sizes = {entry["width"] for entry in self.manifest["images"] if entry["selection_name"] == name}
            self.assertTrue({120, 180, 76, 152, 167}.issubset(sizes))
            self.assertIn(image + "@2x.png", self.images)
            self.assertIn(image + "@3x.png", self.images)
            for stem in entries[name]["CFBundleIconFiles"]:
                self.assertTrue(any(stem + suffix + ".png" in self.images for suffix in ("", "@2x", "@3x")))
        self.assertEqual(entries["New2"]["CFBundleIconFiles"],
                         ["New2", "New2-76", "New2-83.5", "New2-Small", "New2-Small-40", "New2_notification"])

    def test_resources_and_manifest_cannot_be_replaced_together(self):
        for mutation in ("missing", "changed", "extra", "manifest", "self-consistent-replacement"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                resources = Path(directory) / "icons"
                shutil.copytree(icons.RESOURCES, resources)
                name = next(iter(self.images))
                if mutation == "missing":
                    (resources / name).unlink()
                elif mutation == "extra":
                    (resources / "unverified.png").write_bytes(b"x")
                elif mutation == "manifest":
                    manifest = copy.deepcopy(self.manifest)
                    manifest["images"][0]["file"] = "../escape.png"
                    (resources / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
                else:
                    data = synthetic_png(0)[0]
                    (resources / name).write_bytes(data)
                    if mutation == "self-consistent-replacement":
                        manifest = copy.deepcopy(self.manifest)
                        manifest["images"][0].update(sha256=hashlib.sha256(data).hexdigest(), bytes=len(data), **icons.png_identity(data))
                        (resources / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
                with self.assertRaises((ValueError, FileNotFoundError)):
                    icons.load_launcher_icon_resources(resources)

    def test_png_filters_cgbi_channels_and_crc(self):
        for cgbi in (False, True):
            for kind in range(5):
                data, expected = synthetic_png(kind, cgbi=cgbi)
                identity = icons.png_identity(data)
                self.assertEqual(identity["premultiplied_rgba_sha256"], expected)
                self.assertEqual(identity["cgbi"], cgbi)
                with self.assertRaisesRegex(ValueError, "CRC"):
                    icons.png_identity(data[:-1] + bytes([data[-1] ^ 1]))
        for invalid in (b"", synthetic_png(0)[0][:-12], synthetic_png(0)[0] + b"tail"):
            with self.assertRaises(ValueError):
                icons.png_identity(invalid)

    def test_original_palette_pixels_agree_with_pillow(self):
        from PIL import Image
        data = self.images["BlueFilledIconIpad.png"]
        image = Image.open(io.BytesIO(data)).convert("RGBA")
        rgba = bytearray()
        for r, g, b, a in image.getdata():
            rgba.extend(((r * a + 127) // 255, (g * a + 127) // 255, (b * a + 127) // 255, a))
        self.assertEqual(icons.png_identity(data)["premultiplied_rgba_sha256"], hashlib.sha256(rgba).hexdigest())

    @unittest.skipUnless(AUDIT, "Set WHITEGRAM_ORIGINAL_AUDIT")
    def test_actual_original_audit_recovery_is_reproducible_and_read_only(self):
        audit = Path(AUDIT)
        before = hashlib.sha256((audit / "audit.sqlite3").read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "recovered"
            manifest = recover_launcher_icons(audit, output)
            self.assertEqual(manifest, self.manifest)
            self.assertEqual(icons.load_launcher_icon_resources(output), self.images)
            with patch.object(Path, "write_bytes", side_effect=AssertionError("Recovery replay wrote bytes")), \
                    patch.object(Path, "open", autospec=True, side_effect=Path.open) as opened:
                recover_launcher_icons(audit, output)
                self.assertFalse(any(any(flag in str(call.args[1:]) for flag in ("'w", "'x", "'a")) for call in opened.call_args_list))
        self.assertEqual(hashlib.sha256((audit / "audit.sqlite3").read_bytes()).hexdigest(), before)

    @unittest.skipUnless(AUDIT, "Set WHITEGRAM_ORIGINAL_AUDIT")
    def test_recovery_rejects_a_changed_original_before_creating_output(self):
        with tempfile.TemporaryDirectory() as directory:
            audit = Path(directory) / "audit"
            resources = audit / "resources/Payload/Telegram.app"
            resources.mkdir(parents=True)
            original = Path(AUDIT)
            shutil.copyfile(original / "manifest.json", audit / "manifest.json")
            shutil.copyfile(original / "resources/Payload/Telegram.app/Info.plist", resources / "Info.plist")
            database = audit / "audit.sqlite3"
            with closing(sqlite3.connect(database)) as connection:
                connection.execute("CREATE TABLE files (path TEXT, resource_path TEXT, sha256 TEXT, size INTEGER)")
                for entry in (self.manifest["source_plist"], self.manifest["images"][0]):
                    member = entry["source_member"]
                    connection.execute("INSERT INTO files VALUES (?, ?, ?, ?)",
                                       (member, "resources/" + member, entry["sha256"], entry["bytes"]))
                connection.commit()
            (resources / self.manifest["images"][0]["file"]).write_bytes(b"corrupted source")
            with self.assertRaisesRegex(ValueError, "audit hash mismatch"):
                recover_launcher_icons(audit, Path(directory) / "output")
            self.assertFalse((Path(directory) / "output").exists())


@unittest.skipUnless(SOURCE, "Set WHITEGRAM_ASSEMBLED_SOURCE to the pinned public candidate")
class LauncherCandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = Path(SOURCE)
        cls.files = {path: (cls.source / path).read_text(encoding="utf-8") for path in (icons.APP, icons.BUILD, HEADER, BUTTON)}
        cls.images = icons.load_launcher_icon_resources()

    def test_actual_candidate_is_pinned(self):
        head = subprocess.check_output(["git", "-C", str(self.source), "rev-parse", "HEAD"], text=True).strip()
        self.assertEqual(head, PIN)

    def test_runtime_hook_is_scoped_opt_in_and_preserves_every_existing_icon(self):
        root = MemoryRoot(self.files)
        report = icons.apply_launcher_icon_patches(root)
        self.assertEqual(report, {"showOriginalTelegramIcons": [icons.APP]})
        result = root.text(icons.APP)
        self.assertIn("if WhitegramIconSettings.current.showOriginalTelegramIcons {", result)
        self.assertIn("WhitegramIconSettings.stockIcons.map { icon in", result)
        self.assertIn("isDefault: false, isPremium: false", result)
        restored = result.replace(icons.HOOK, "").replace("                var icons = [\n", "                let icons = [\n")
        original = self.files[icons.APP].replace(icons.HOOK, "").replace("                var icons = [\n", "                let icons = [\n")
        self.assertEqual(restored, original)
        first = root.texts()
        root.writes.clear()
        self.assertEqual(icons.apply_launcher_icon_patches(root), report)
        self.assertEqual(root.texts(), first)
        self.assertEqual(root.writes, [])

    def test_both_appearance_details_orders_and_replays_match(self):
        results = []
        for operations in ((icons.apply_launcher_icon_patches, apply_appearance_details_patches),
                           (apply_appearance_details_patches, icons.apply_launcher_icon_patches)):
            root = MemoryRoot(self.files)
            for apply in operations:
                apply(root)
            first = root.texts()
            root.writes.clear()
            for apply in reversed(operations):
                apply(root)
            self.assertEqual(root.texts(), first)
            self.assertEqual(root.writes, [])
            self.assertIn('PresentationAppIcon(name: "Default", imageName: "WhitegramPrimaryPreview", isDefault: true)', root.text(icons.APP))
            self.assertEqual(root.text(icons.APP).count(icons.HOOK), 1)
            results.append(first)
        self.assertEqual(results[0], results[1])

    def test_duplicate_changed_partial_and_misplaced_getters_fail_before_writes(self):
        installed = MemoryRoot(self.files)
        icons.apply_launcher_icon_patches(installed)
        original = installed.text(icons.APP).replace(icons.HOOK, "").replace("                var icons = [\n", "                let icons = [\n")
        changed = [original.replace('imageName: "Aqua"', 'imageName: "Other"'),
                   original.replace("getAvailableAlternateIcons:", "missingGetter:"),
                   original.replace("                let icons = [\n", "                var icons = [\n"),
                   original + "\n        }, getAvailableAlternateIcons: {\n",
                   original.replace("import TelegramCore\n", ""),
                   installed.text(icons.APP).replace(icons.HOOK, icons.HOOK * 2),
                   installed.text(icons.APP).replace("isPremium: false", "isPremium: true"),
                   installed.text(icons.APP) + icons.HOOK]
        for text in changed:
            root = MemoryRoot({**self.files, icons.APP: text})
            with self.assertRaisesRegex(ValueError, "showOriginalTelegramIcons"):
                icons.apply_launcher_icon_patches(root)
            self.assertEqual(root.text(icons.APP), text)
            self.assertEqual(root.writes, [])

    def test_full_appdelegate_has_no_new_swift_syntax_diagnostics(self):
        root = MemoryRoot(self.files)
        icons.apply_launcher_icon_patches(root)
        apply_appearance_details_patches(root)
        before = parse_sources({icons.APP: self.files[icons.APP]})[icons.APP]
        after = parse_sources({icons.APP: root.text(icons.APP)})[icons.APP]
        self.assertEqual(Counter(item["text"] for item in before), Counter(item["text"] for item in after))

    def make_root(self, directory, *, original_assets=False):
        root = Path(directory) / "source"
        (root / "Telegram/Telegram-iOS").mkdir(parents=True)
        (root / icons.BUILD).write_text(self.files[icons.BUILD], encoding="utf-8")
        if original_assets:
            for path in (self.source / "Telegram/Telegram-iOS").glob("*.alticon"):
                shutil.copytree(path, root / "Telegram/Telegram-iOS" / path.name)
            shutil.copyfile(self.source / "Telegram/Telegram-iOS/Info.plist", root / "Telegram/Telegram-iOS/Info.plist")
            install_primary_icon(root)
        return root

    def test_installer_bundles_only_recovered_stock_and_preserves_existing_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_root(directory, original_assets=True)
            before = snapshot(root)
            report = icons.install_launcher_icon_resources(root)
            build = (root / icons.BUILD).read_text(encoding="utf-8")
            groups = re.findall(r'filegroup\(\n    name = "WhitegramStockLauncherIcon_(\w+)",\n    srcs = \[\n(.*?)    \],\n\)', build, re.DOTALL)
            self.assertEqual([name for name, _ in groups], [name for name, _ in EXPECTED_STOCK])
            for name, body in groups:
                paths = re.findall(r'"([^"]+)"', body)
                self.assertGreaterEqual(len(paths), 5)
                for path in paths:
                    self.assertTrue(path.startswith(f"WhitegramStockLauncherIcons/{name}.alticon/"))
                    self.assertEqual((root / "Telegram" / path).read_bytes(), self.images[Path(path).name])
            app = build.split('ios_application(\n    name = "Telegram",', 1)[1].split("\n)\n", 1)[0]
            self.assertIn('app_icons = [":DefaultAppIcon"]', app)
            self.assertIn('for name in alternate_icon_folders\n    ] + [', app)
            self.assertEqual(app.count('":WhitegramStockLauncherIcon_'), 8)
            for relative, data in before.items():
                if relative != icons.BUILD:
                    self.assertEqual((root / relative).read_bytes(), data, relative)
            self.assertEqual(len(report["showOriginalTelegramIcons-resources"]), 67)
            after = snapshot(root)
            with patch.object(Path, "write_bytes", side_effect=AssertionError("Installer replay wrote bytes")), \
                    patch.object(Path, "open", autospec=True, side_effect=Path.open) as opened:
                self.assertEqual(icons.install_launcher_icon_resources(root), report)
                self.assertFalse(any(any(flag in str(call.args[1:]) for flag in ("'w", "'x", "'a")) for call in opened.call_args_list))
            self.assertEqual(snapshot(root), after)

    def test_changed_build_or_installed_resources_fail_without_any_writes(self):
        for mutation in ("wrong-wg", "duplicate-group", "changed-reference", "duplicate-target", "changed-png", "extra-png", "directory-as-png"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root = self.make_root(directory)
                icons.install_launcher_icon_resources(root)
                build_path = root / icons.BUILD
                build = build_path.read_text(encoding="utf-8")
                path = root / icons.RESOURCE_PATH / "Blue.alticon/BlueIcon@2x.png"
                if mutation == "wrong-wg":
                    build_path.write_text(build.replace('    "Aqua",', '    "Other",'), encoding="utf-8")
                elif mutation == "duplicate-group":
                    build_path.write_text(build + '\nfilegroup(name = "WhitegramStockLauncherIcon_Blue")\n', encoding="utf-8")
                elif mutation == "changed-reference":
                    build_path.write_text(build.replace('":WhitegramStockLauncherIcon_Blue",', '":Other",'), encoding="utf-8")
                elif mutation == "duplicate-target":
                    build_path.write_text(build + '\nios_application(\n    name = "Telegram",\n)\n', encoding="utf-8")
                elif mutation == "changed-png":
                    path.write_bytes(b"unverified replacement")
                elif mutation == "extra-png":
                    path.with_name("extra.png").write_bytes(b"extra")
                else:
                    path.unlink()
                    path.mkdir()
                before = snapshot(root)
                with self.assertRaises(ValueError):
                    icons.install_launcher_icon_resources(root)
                self.assertEqual(snapshot(root), before)

    def test_invalid_initial_build_cannot_leave_partial_resource_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_root(directory)
            path = root / icons.BUILD
            path.write_text(path.read_text(encoding="utf-8").replace('name = "Telegram",', 'name = "OtherApp",'), encoding="utf-8")
            before = snapshot(root)
            with self.assertRaises(ValueError):
                icons.install_launcher_icon_resources(root)
            self.assertEqual(snapshot(root), before)
            self.assertFalse((root / icons.RESOURCE_PATH).exists())

    @unittest.skipUnless(ALTICON_TOOL, "Set WHITEGRAM_ALTICON_TOOL to the pinned upstream Python tool")
    def test_real_pinned_alticon_tool_generates_resolving_phone_and_ipad_tables(self):
        tool = Path(ALTICON_TOOL)
        self.assertEqual(hashlib.sha256(tool.read_bytes()).hexdigest(), TOOL_HASH)
        insert = runpy.run_path(str(tool))["insert_alticons"]
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_root(directory, original_assets=True)
            icons.install_launcher_icon_resources(root)
            info = {"CFBundlePackageType": "APPL"}
            for family in ("CFBundleIcons", "CFBundleIcons~ipad"):
                info[family] = {"CFBundlePrimaryIcon": {"CFBundleIconName": "WGPrimary", "CFBundleIconFiles": ["WGPrimaryLight"]}}
            wg_dirs = [root / "Telegram/Telegram-iOS" / (name + ".alticon") for name in EXPECTED_WG]
            insert(info, [str(path) for path in wg_dirs], ["iphone", "ipad"])
            baseline = copy.deepcopy(info)
            stock_dirs = [root / icons.RESOURCE_PATH / (name + ".alticon") for name, _ in EXPECTED_STOCK]
            insert(info, [str(path) for path in wg_dirs + stock_dirs], ["iphone", "ipad"])
            for family in ("CFBundleIcons", "CFBundleIcons~ipad"):
                alternatives = info[family]["CFBundleAlternateIcons"]
                self.assertEqual(len(alternatives), 21)
                for name in EXPECTED_WG:
                    self.assertEqual(alternatives[name], baseline[family]["CFBundleAlternateIcons"][name])
                for name, entry in icons.stock_alternate_icon_entries().items():
                    self.assertEqual(alternatives[name], entry)
            app = Path(directory) / "Telegram.app"
            app.mkdir()
            shutil.copyfile(root / "Telegram/Telegram-iOS/DefaultAppIcon.xcassets/WGPrimary.appiconset/WGPrimaryLight.png", app / "WGPrimaryLight.png")
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            for folder in wg_dirs + stock_dirs:
                for path in folder.glob("*.png"):
                    shutil.copyfile(path, app / path.name)
            report = icons.verify_launcher_icon_bundle(app, baseline_info=baseline)
            self.assertEqual(report["losslessly_reencoded"], [])
            self.assertEqual(report["families"], ["iphone", "ipad"])
            self.assertEqual(len(report["files"]), 66)
            # Standard indexed PNG -> RGBA encoder changes bytes, not displayed pixels.
            from PIL import Image
            png = app / "BlueFilledIconIpad.png"
            image = Image.open(io.BytesIO(png.read_bytes())).convert("RGBA")
            image.save(png)
            self.assertEqual(icons.verify_launcher_icon_bundle(app)["losslessly_reencoded"], [png.name])
            image.putpixel((0, 0), (255, 0, 0, 255))
            image.save(png)
            with self.assertRaisesRegex(ValueError, "Changed original launcher pixels"):
                icons.verify_launcher_icon_bundle(app)
            png.write_bytes(self.images[png.name])
            for mutation in ("broken-new2", "missing-ipad", "wrong-primary", "lost-wg", "nested-png", "changed-baseline", "stock-catalog-override"):
                with self.subTest(mutation=mutation):
                    broken = copy.deepcopy(info)
                    if mutation == "broken-new2":
                        broken["CFBundleIcons"]["CFBundleAlternateIcons"]["New2"]["CFBundleIconFiles"] = ["New2_180x180"]
                    elif mutation == "missing-ipad":
                        del broken["CFBundleIcons~ipad"]["CFBundleAlternateIcons"]["New1"]
                    elif mutation == "wrong-primary":
                        broken["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconName"] = "Blue"
                    elif mutation == "lost-wg":
                        del broken["CFBundleIcons"]["CFBundleAlternateIcons"]["Aqua"]
                    elif mutation == "changed-baseline":
                        broken["CFBundleIcons"]["CFBundleAlternateIcons"]["Aqua"]["UIPrerenderedIcon"] = True
                    elif mutation == "stock-catalog-override":
                        broken["CFBundleIcons"]["CFBundleAlternateIcons"]["Blue"]["CFBundleIconName"] = "WGPrimary"
                    else:
                        nested = app / "Nested"
                        nested.mkdir()
                        png.rename(nested / png.name)
                    (app / "Info.plist").write_bytes(plistlib.dumps(broken))
                    with self.assertRaises(ValueError):
                        icons.verify_launcher_icon_bundle(app, baseline_info=baseline)
                    if mutation == "nested-png":
                        (nested / png.name).rename(png)


if __name__ == "__main__":
    unittest.main()
