"""Original resource identity, main-settings-only hooks and main-bundle placement."""

from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

OVERLAY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(OVERLAY))

import appearance_icon_pack_patches as packs
from interface_patches import apply_interface_patches
from plugin_resources import install_plugin_resources
from recover_settings_icons import recover_settings_icons
import settings_icon_patches as icons
from test_history_patches import MemoryRoot, PIN, parse_sources


class SettingsIconResourceTests(unittest.TestCase):
    def test_original_manifest_and_all_40_pngs_validate(self):
        images = icons.load_settings_icon_resources()
        self.assertEqual(len(images), 40)
        self.assertEqual(len(icons.ICON_MAPPING), 20)
        manifest = json.loads((icons.RESOURCES / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["conversion"], "none; original CgBI PNG bytes preserved")
        self.assertEqual(manifest["evidence"]["helper"], "0x8f0d64")
        self.assertEqual(manifest["evidence"]["selector"], "imageNamed:")
        for entry in manifest["images"]:
            self.assertEqual(hashlib.sha256(images[entry["file"]]).hexdigest(), entry["sha256"])
            self.assertTrue(entry["cgbi"])
            self.assertEqual(entry["bundle_path"], entry["file"])

    def test_helper_uses_parent_policy_main_bundle_and_unmodified_fallback(self):
        path = OVERLAY / "cleanroom/WhitegramSettingsIcons.swift"
        source = path.read_text(encoding="utf-8")
        self.assertEqual(parse_sources({path.name: source}), {path.name: []})
        self.assertIn("guard WhitegramIconSettings.current.customSettingsIcons else {\n        return fallback\n    }", source)
        self.assertIn("return UIImage(named: name, in: Bundle.main, compatibleWith: nil) ?? fallback", source)
        self.assertNotIn("systemName:", source)
        self.assertNotIn("WhitegramIconPackPresentationCache", source)
        self.assertEqual(icons.SETTINGS_ICON_RUNTIME_FILES, {
            "WhitegramSettingsIcons.swift": "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/WhitegramSettingsIcons.swift",
        })

    def test_main_bundle_verifier_rejects_nested_missing_and_changed_files(self):
        images = icons.load_settings_icon_resources()
        with tempfile.TemporaryDirectory(prefix="settings-icons-bundle-") as directory:
            app = Path(directory) / "Telegram.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundlePackageType": "APPL"}))
            nested = app / "WhitegramSettingsIcons"
            nested.mkdir()
            for name, data in images.items():
                (nested / name).write_bytes(data)
            with self.assertRaisesRegex(ValueError, "Bundle.main"):
                icons.verify_settings_icon_bundle(app)
            for name in images:
                (nested / name).rename(app / name)
            nested.rmdir()
            self.assertEqual(icons.verify_settings_icon_bundle(app), list(icons.RESOURCE_FILES))
            name = icons.RESOURCE_FILES[-1]
            (app / name).write_bytes(images[name] + b"changed")
            with self.assertRaisesRegex(ValueError, "changed original icon"):
                icons.verify_settings_icon_bundle(app)
            (app / name).unlink()
            with self.assertRaisesRegex(ValueError, "Missing"):
                icons.verify_settings_icon_bundle(app)
            with self.assertRaisesRegex(ValueError, "main Telegram .app"):
                icons.verify_settings_icon_bundle(Path(directory))

    def test_absent_changed_extra_and_path_escaping_resources_are_rejected(self):
        for mutation in ("missing", "changed", "extra", "escape"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory(prefix="settings-icons-invalid-") as directory:
                resources = Path(directory) / "resources"
                shutil.copytree(icons.RESOURCES, resources)
                name = icons.RESOURCE_FILES[-1]
                if mutation == "missing":
                    (resources / name).unlink()
                elif mutation == "changed":
                    (resources / name).write_bytes(b"not the original PNG")
                elif mutation == "extra":
                    (resources / "unexpected.png").write_bytes(b"extra")
                else:
                    manifest = json.loads((resources / "manifest.json").read_text(encoding="utf-8"))
                    manifest["images"][0]["file"] = "../outside.png"
                    (resources / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
                with self.assertRaises(ValueError):
                    icons.load_settings_icon_resources(resources)


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class SettingsIconPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"])
        paths = {icons.SETTINGS, icons.BUILD, packs.SETTINGS, packs.HEADER, packs.IMPLEMENTATION,
                 packs.ROOT, packs.ANIMATION, packs.MANAGED,
                 "submodules/AvatarNode/Sources/AvatarNode.swift",
                 "submodules/TelegramUI/Components/Chat/ChatMessageDateAndStatusNode/Sources/ChatMessageDateAndStatusNode.swift",
                 "submodules/TelegramCore/Sources/TelegramEngine/Messages/AdMessages.swift",
                 "submodules/TelegramCore/Sources/TelegramEngine/Peers/AdPeers.swift"}
        cls.assembled = {path: (source / path).read_text(encoding="utf-8") for path in paths}
        cls.pristine = {path: subprocess.check_output(["git", "-C", str(source), "show", f"{PIN}:{path}"]).decode("utf-8") for path in (icons.SETTINGS, icons.BUILD)}

    def test_exact_main_row_mapping_and_editing_scope_preservation(self):
        for files in (self.pristine, self.assembled):
            with self.subTest(pristine=files is self.pristine):
                root = MemoryRoot(files)
                report = icons.apply_settings_icon_patches(root)
                self.assertEqual(report, {"customSettingsIcons": [icons.SETTINGS]})
                before, after = files[icons.SETTINGS], root.text(icons.SETTINGS)
                main, editing = after.split("func settingsEditingItems(", 1)
                self.assertEqual(editing, before.split("func settingsEditingItems(", 1)[1])
                before_main = before.split("func settingsEditingItems(", 1)[0]
                expected = {member: name for member, name, _ in icons.ICON_MAPPING
                            if member != "ton" or "PresentationResourcesSettings.ton" in before_main}
                found = re.findall(r'icon: whitegramSettingsIcon\("([^"]+)", fallback: PresentationResourcesSettings\.(\w+)\),', main)
                self.assertEqual({member: name for name, member in found}, expected)
                self.assertEqual(len(found), len(expected))
                normalized = re.sub(r'whitegramSettingsIcon\("[^"]+", fallback: (PresentationResourcesSettings\.\w+)\)', r'\1', after)
                original = re.sub(r'whitegramSettingsIcon\("[^"]+", fallback: (PresentationResourcesSettings\.\w+)\)', r'\1', before)
                self.assertEqual(normalized, original)
                self.assertEqual(set(root.writes), {icons.SETTINGS} if before != after else set())
                first = root.texts()
                root.writes.clear()
                self.assertEqual(icons.apply_settings_icon_patches(root), report)
                self.assertEqual(root.texts(), first)
                self.assertEqual(root.writes, [])

    def test_ton_is_only_wrapped_when_a_real_ton_row_exists(self):
        for files in (self.pristine, self.assembled):
            root = MemoryRoot(files)
            count = files[icons.SETTINGS].split("func settingsEditingItems(", 1)[0].count("PresentationResourcesSettings.ton")
            icons.apply_settings_icon_patches(root)
            self.assertEqual(root.text(icons.SETTINGS).count('whitegramSettingsIcon("whitegramwallet", fallback: PresentationResourcesSettings.ton)'), count)
            self.assertEqual(root.text(icons.SETTINGS).count("whitegramSettingsIcon("), 19 + count)

    def test_missing_duplicate_wrong_asset_and_out_of_scope_hooks_abort_without_writes(self):
        source = self.pristine[icons.SETTINGS]
        installed = MemoryRoot(self.pristine)
        icons.apply_settings_icon_patches(installed)
        mutations = [
            source.replace("func settingsItems(", "func renamedSettings("),
            source.replace("icon: PresentationResourcesSettings.tips,", "icon: nil,"),
            source.replace("icon: PresentationResourcesSettings.tips,", "icon: PresentationResourcesSettings.tips, icon: PresentationResourcesSettings.tips,"),
            installed.text(icons.SETTINGS).replace('"whitegramhow"', '"unrelated"'),
            installed.text(icons.SETTINGS) + '\nlet wrong = whitegramSettingsIcon("whitegramcalls", fallback: nil)\n',
        ]
        for index, text in enumerate(mutations):
            with self.subTest(mutation=index):
                root = MemoryRoot({icons.SETTINGS: text})
                with self.assertRaisesRegex(ValueError, "customSettingsIcons"):
                    icons.apply_settings_icon_patches(root)
                self.assertEqual(root.text(icons.SETTINGS), text)
                self.assertEqual(root.writes, [])

    def test_composes_with_appearance_filters_and_settings_icon_cache(self):
        outcomes = []
        for order in ((icons.apply_settings_icon_patches, apply_interface_patches, packs.apply_appearance_icon_pack_patches),
                      (packs.apply_appearance_icon_pack_patches, apply_interface_patches, icons.apply_settings_icon_patches)):
            root = MemoryRoot(self.assembled)
            for patcher in order:
                patcher(root)
            first = root.texts()
            root.writes.clear()
            for patcher in order:
                patcher(root)
            self.assertEqual(root.texts(), first)
            self.assertEqual(root.writes, [])
            self.assertIn("let whitegramHiddenRows:", root.text(icons.SETTINGS))
            self.assertEqual(root.text(packs.SETTINGS), self.assembled[packs.SETTINGS])
            outcomes.append(first)
        self.assertEqual(outcomes[0], outcomes[1])

    def test_patched_settings_introduce_no_swift_syntax_errors(self):
        for files in (self.pristine, self.assembled):
            root = MemoryRoot(files)
            icons.apply_settings_icon_patches(root)
            before = parse_sources({icons.SETTINGS: files[icons.SETTINGS]})[icons.SETTINGS]
            after = parse_sources({icons.SETTINGS: root.text(icons.SETTINGS)})[icons.SETTINGS]
            self.assertEqual(Counter(item["text"] for item in before), Counter(item["text"] for item in after))

    def make_source_root(self, directory, build=None):
        root = Path(directory) / "source"
        (root / "Telegram").mkdir(parents=True)
        (root / icons.BUILD).write_text(build or self.pristine[icons.BUILD], encoding="utf-8")
        return root

    def test_resource_installer_selects_exact_files_in_main_app_and_replays_without_writes(self):
        for build in (self.pristine[icons.BUILD], self.assembled[icons.BUILD]):
            with tempfile.TemporaryDirectory(prefix="settings-icons-install-") as directory:
                root = self.make_source_root(directory, build)
                report = icons.install_settings_icon_resources(root)
                expected = [icons.BUILD] + [f"{icons.RESOURCE_PATH}/{name}" for name in icons.RESOURCE_FILES]
                self.assertEqual(report, {"customSettingsIcons-resources": expected})
                text = (root / icons.BUILD).read_text(encoding="utf-8")
                group = text.split('name = "WhitegramSettingsIcons",', 1)[1].split("\n)\n", 1)[0]
                declared = re.findall(r'"(WhitegramSettingsIcons/[^"]+)"', group)
                self.assertEqual(declared, ["WhitegramSettingsIcons/" + name for name in icons.RESOURCE_FILES])
                app = text.split('ios_application(\n    name = "Telegram",', 1)[1]
                self.assertEqual(text.count('\":WhitegramSettingsIcons\"'), 1)
                self.assertIn('\":WhitegramSettingsIcons\"', app.split("    resources = [", 1)[1].split("    ],", 1)[0])
                for relative in declared:
                    self.assertEqual((root / "Telegram" / relative).read_bytes(), (icons.RESOURCES / Path(relative).name).read_bytes())
                self.assertNotIn("manifest.json", group)
                self.assertNotIn("apple_resource_bundle", group)
                with patch.object(Path, "write_bytes", side_effect=AssertionError("Replay wrote bytes")), patch.object(Path, "open", autospec=True, side_effect=Path.open) as opened:
                    self.assertEqual(icons.install_settings_icon_resources(root), report)
                    self.assertFalse(any(any(flag in str(call.args[1:]) for flag in ("'w", "'x", "'a")) for call in opened.call_args_list))

    def test_build_resources_compose_with_existing_plugin_bundle_installer(self):
        outcomes = []
        for ours_first in (True, False):
            with tempfile.TemporaryDirectory(prefix="settings-icons-compose-") as directory:
                root = self.make_source_root(directory)
                operations = (lambda: icons.install_settings_icon_resources(root), lambda: install_plugin_resources(root, OVERLAY))
                if not ours_first:
                    operations = operations[::-1]
                for operation in operations:
                    operation()
                first = (root / icons.BUILD).read_bytes()
                for operation in operations:
                    operation()
                self.assertEqual((root / icons.BUILD).read_bytes(), first)
                outcomes.append(first)
        self.assertEqual(outcomes[0], outcomes[1])

    def test_invalid_resource_or_build_does_not_write_selected_root(self):
        for invalid in ("source", "build", "duplicate"):
            with self.subTest(invalid=invalid), tempfile.TemporaryDirectory(prefix="settings-icons-reject-") as directory:
                root = self.make_source_root(directory)
                resources = Path(directory) / "resources"
                shutil.copytree(icons.RESOURCES, resources)
                if invalid == "source":
                    (resources / icons.RESOURCE_FILES[-1]).write_bytes(b"corrupt")
                elif invalid == "build":
                    (root / icons.BUILD).write_text('ios_application(name="other")', encoding="utf-8")
                else:
                    text = (root / icons.BUILD).read_text(encoding="utf-8")
                    (root / icons.BUILD).write_text(text + '\nfilegroup(name = "WhitegramSettingsIcons")\n', encoding="utf-8")
                before = (root / icons.BUILD).read_bytes()
                with self.assertRaises(ValueError):
                    icons.install_settings_icon_resources(root, resources)
                self.assertEqual((root / icons.BUILD).read_bytes(), before)
                self.assertFalse((root / icons.RESOURCE_PATH).exists())

    def test_changed_installed_resource_is_rejected_without_rewriting_build(self):
        with tempfile.TemporaryDirectory(prefix="settings-icons-installed-") as directory:
            root = self.make_source_root(directory)
            icons.install_settings_icon_resources(root)
            destination = root / icons.RESOURCE_PATH / icons.RESOURCE_FILES[-1]
            destination.write_bytes(b"user change")
            before = (root / icons.BUILD).read_bytes()
            with self.assertRaisesRegex(ValueError, "changed installed resource"):
                icons.install_settings_icon_resources(root)
            self.assertEqual(destination.read_bytes(), b"user change")
            self.assertEqual((root / icons.BUILD).read_bytes(), before)

    def test_nested_source_root_is_rejected_before_resource_installation(self):
        with tempfile.TemporaryDirectory(prefix="settings-icons-root-") as directory:
            root = self.make_source_root(directory)
            with self.assertRaisesRegex(ValueError, "selected Telegram source checkout"):
                icons.install_settings_icon_resources(root / "Telegram")
            self.assertFalse((root / icons.RESOURCE_PATH).exists())


@unittest.skipUnless(os.environ.get("WHITEGRAM_ORIGINAL_AUDIT"), "Set WHITEGRAM_ORIGINAL_AUDIT")
class SettingsIconRecoveryTests(unittest.TestCase):
    def test_recovery_matches_committed_bytes_and_provenance_and_replays(self):
        with tempfile.TemporaryDirectory(prefix="settings-icons-recovery-") as directory:
            output = Path(directory) / "recovered"
            audit = Path(os.environ["WHITEGRAM_ORIGINAL_AUDIT"])
            manifest = recover_settings_icons(audit, output)
            self.assertEqual(manifest, json.loads((icons.RESOURCES / "manifest.json").read_text(encoding="utf-8")))
            for name in (*icons.RESOURCE_FILES, "manifest.json"):
                self.assertEqual((output / name).read_bytes(), (icons.RESOURCES / name).read_bytes())
            stamps = {name: (output / name).stat().st_mtime_ns for name in (*icons.RESOURCE_FILES, "manifest.json")}
            recover_settings_icons(audit, output)
            self.assertEqual(stamps, {name: (output / name).stat().st_mtime_ns for name in stamps})

    def test_absent_or_changed_audited_original_aborts_before_output_creation(self):
        audit = Path(os.environ["WHITEGRAM_ORIGINAL_AUDIT"]).resolve()
        victim = audit / "resources/Payload/Telegram.app" / icons.RESOURCE_FILES[-1]
        read_bytes, is_file = Path.read_bytes, Path.is_file
        for missing in (False, True):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory(prefix="settings-icons-audit-reject-") as directory:
                output = Path(directory) / "recovered"
                def read(path):
                    return b"changed audited image" if path == victim else read_bytes(path)
                def exists(path):
                    return False if missing and path == victim else is_file(path)
                with patch.object(Path, "read_bytes", read), patch.object(Path, "is_file", exists):
                    with self.assertRaisesRegex(ValueError, "Missing original resource|hash mismatch"):
                        recover_settings_icons(audit, output)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
