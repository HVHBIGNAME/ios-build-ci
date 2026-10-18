"""Patch and parse the pinned assembled candidate in memory; never alter it."""

import ast
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

WHITEGRAM = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(WHITEGRAM))

import appearance_parity_patches as appearance
import profile_appearance_patches as profile
import profile_metadata_patches as metadata
from source_patches import SourcePatches
from test_appearance_extensions import MemoryRoot, syntax_errors


SOURCE = os.environ.get("WHITEGRAM_PROFILE_METADATA_SOURCE") or os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE")
PINNED_UPSTREAM = "6ad963e5b62d354da79040f388ae2b9132fb17b8"
TARGETS = (metadata.ITEMS, metadata.SCREEN)
COMPOSITION_PATHS = tuple(dict.fromkeys((*TARGETS, profile.HEADER, profile.DATA, profile.PANES, metadata.PEER + "PeerInfoSettingsItems.swift")))


def apply_recorded(root):
    edits = []
    replace = metadata._replace

    def record(patches, path, before, after):
        replace(patches, path, before, after)
        edits.append((path, before, after))

    with patch.object(metadata, "_replace", record):
        report = metadata.apply_profile_metadata_patches(root)
    return report, edits


class ProfileMetadataSourceTests(unittest.TestCase):
    def test_swift_sources_and_native_tests_parse(self):
        paths = [WHITEGRAM / "cleanroom" / name for name in metadata.PROFILE_METADATA_RUNTIME_FILES]
        paths += [WHITEGRAM / "tests/profile_metadata/main.swift", WHITEGRAM / "tests/backend/WhitegramProfileMetadataCardTests.swift"]
        for path in paths:
            with self.subTest(path=path.name):
                self.assertEqual(syntax_errors(path.read_bytes()), [])

    def test_python_sources_parse(self):
        for path in (WHITEGRAM / "profile_metadata_patches.py", WHITEGRAM / "tests/profile_metadata/run_native.py"):
            ast.parse(path.read_text(encoding="utf-8"))

    def test_mapping_and_backend_host_sources(self):
        mapping = metadata.PROFILE_METADATA_RUNTIME_FILES
        self.assertEqual(len(mapping), len(set(mapping.values())))
        self.assertTrue(mapping["WhitegramPeerMetadataPolicy.swift"].startswith("submodules/TelegramCore/"))
        self.assertTrue(mapping["WhitegramPeerMetadataCardAdapter.swift"].startswith("submodules/SettingsUI/"))
        runner = (WHITEGRAM / "tests/backend/run_native.py").read_text(encoding="utf-8")
        for name in ("WhitegramPeerMetadataPolicy.swift", "WhitegramPeerMetadataCardAdapter.swift"):
            self.assertIn('"' + name + '"', runner)


@unittest.skipUnless(SOURCE, "Set WHITEGRAM_PROFILE_METADATA_SOURCE to the pinned assembled candidate")
class ProfileMetadataPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=SOURCE, text=True, capture_output=True, check=True).stdout.strip()
        if head != PINNED_UPSTREAM:
            raise AssertionError(f"Unexpected upstream: {head}")
        cls.files = {path: (Path(SOURCE) / path).read_text(encoding="utf-8") for path in COMPOSITION_PATHS}
        _, cls.edits = apply_recorded(MemoryRoot(cls.files))
        # CI supplies a fully assembled tree; undo only this patch's own edits
        # to exercise missing-anchor rejection on the same baseline as local runs.
        for path, before, after in reversed(cls.edits):
            if after in cls.files[path]:
                cls.files[path] = cls.files[path].replace(after, before, 1)

    def test_inline_consumers_parse_and_replay_without_writes(self):
        root = MemoryRoot(self.files)
        report = metadata.apply_profile_metadata_patches(root)
        self.assertEqual(report, {"profile-metadata": sorted(TARGETS)})
        first = dict(root.files)
        root.writes.clear()
        self.assertEqual(metadata.apply_profile_metadata_patches(root), report)
        self.assertEqual(root.files, first)
        self.assertEqual(root.writes, [])
        for path in TARGETS:
            self.assertEqual(syntax_errors(root.files[path]), [])
        screen = root.text(metadata.SCREEN)
        self.assertIn("whitegramRegistrationDate: self.whitegramMetadataCard?.date", screen)
        self.assertIn("whitegramUpdateProfileMetadataCard(adapter, data: data)", screen)
        self.assertIn("self.whitegramMetadataDisposable?.dispose()", screen)
        self.assertIn("DispatchQueue.main.async { adapter.cancel() }", screen)
        self.assertIn("WhitegramPeerMetadataSettings.signal()", screen)
        items = root.text(metadata.ITEMS)
        self.assertIn("case unofficial\n    case wgPeerMetadata\n    case community", items)
        self.assertIn("case peerInfoTrailing\n    case wgPeerInfoTrailing\n    case peerSettings", items)
        self.assertIn("items[.wgPeerMetadata, default: []].append(item)", items)
        self.assertIn("items[.wgPeerInfoTrailing, default: []].append(item)", items)

    def test_missing_duplicate_and_mixed_anchors_never_write(self):
        for path, before, after in self.edits:
            for value in ("/* missing */", before + before, after + before):
                with self.subTest(path=path, anchor=before[:60], replacement=value[:30]):
                    root = MemoryRoot(self.files)
                    root.files[path] = root.text(path).replace(before, value, 1).encode()
                    original = dict(root.files)
                    with self.assertRaises(ValueError):
                        metadata.apply_profile_metadata_patches(root)
                    self.assertEqual(root.files, original)
                    self.assertEqual(root.writes, [])

    def test_staging_is_readonly_and_reversal_preserves_user_work(self):
        root = MemoryRoot({**self.files, "unrelated.swift": "// user work\r\n"})
        staged = SourcePatches(root)
        metadata.profile_metadata_patches(staged)
        self.assertEqual(root.writes, [])
        self.assertEqual(root.files, MemoryRoot({**self.files, "unrelated.swift": "// user work\r\n"}).files)
        staged.write()
        for path, before, after in reversed(self.edits):
            self.assertEqual(root.text(path).count(after), 1)
            root.files[path] = root.text(path).replace(after, before).encode()
        self.assertEqual(root.files, MemoryRoot({**self.files, "unrelated.swift": "// user work\r\n"}).files)

    def test_composes_with_profile_and_information_patches_in_both_orders(self):
        results = []
        for metadata_first in (False, True):
            root = MemoryRoot(self.files)
            if metadata_first:
                metadata.apply_profile_metadata_patches(root)
            staged = SourcePatches(root)
            appearance._information_patches(staged)
            staged.write()
            profile.apply_profile_appearance_patches(root)
            metadata.apply_profile_metadata_patches(root)
            first = dict(root.files)
            root.writes.clear()
            staged = SourcePatches(root)
            appearance._information_patches(staged)
            staged.write()
            profile.apply_profile_appearance_patches(root)
            metadata.apply_profile_metadata_patches(root)
            self.assertEqual(root.files, first)
            self.assertEqual(root.writes, [])
            results.append(root.files)
        self.assertEqual(*results)


if __name__ == "__main__":
    unittest.main()
