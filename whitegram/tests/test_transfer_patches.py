"""Check native transfer wiring, all transition anchors, and fail-before-write."""

import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from source_patches import SourcePatches
from transfer_patches import DISPATCH, FETCH, TRANSFER_RUNTIME_FILES, UPLOAD, apply_transfer_patches, transfer_patches
from test_media_camera_patches import errors


class TransferSourceTests(unittest.TestCase):
    def test_runtime_sources_parse(self):
        for name in TRANSFER_RUNTIME_FILES:
            self.assertEqual(errors((ROOT / "cleanroom" / name).read_text(encoding="utf-8")), [])


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class TransferIntegrationTests(unittest.TestCase):
    def patches(self):
        return SourcePatches(Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"]))

    def test_all_native_transitions_replay_without_writes_or_new_parse_errors(self):
        patches = self.patches()
        transfer_patches(patches)
        once = dict(patches.pending)
        transfer_patches(patches)
        self.assertEqual(once, patches.pending)
        self.assertEqual(set(once), {FETCH, DISPATCH, UPLOAD})
        for path, source in once.items():
            with self.subTest(path=path):
                self.assertEqual(errors(source), errors(patches.original[path]))
                self.assertEqual((patches.root / path).read_text(encoding="utf-8"), patches.original[path])

    def test_pristine_release_and_combined_camera_transfer_transaction_replay(self):
        from media_camera_patches import media_camera_patches

        patches = self.patches()
        for path in (FETCH, DISPATCH, UPLOAD):
            source = subprocess.check_output(["git", "-C", str(patches.root), "show", f"HEAD:{path}"]).decode("utf-8")
            patches.original[path] = source
            patches.pending[path] = source
        transfer_patches(patches)
        for path, source in patches.pending.items():
            self.assertEqual(errors(source), errors(patches.original[path]), path)
        media_camera_patches(patches)
        once = dict(patches.pending)
        transfer_patches(patches)
        media_camera_patches(patches)
        self.assertEqual(patches.pending, once)

        reverse = self.patches()
        for path in (FETCH, DISPATCH, UPLOAD):
            reverse.original[path] = patches.original[path]
            reverse.pending[path] = patches.original[path]
        media_camera_patches(reverse)
        transfer_patches(reverse)
        self.assertEqual(reverse.pending, once)

    def test_policies_reach_active_download_and_upload_schedulers(self):
        patches = self.patches()
        transfer_patches(patches)
        fetch = patches.pending[FETCH]
        self.assertEqual(fetch.count("maxPendingParts: WhitegramTransferSettings.current.downloadParallelParts,"), 4)
        self.assertIn("while state.pendingParts.count < state.maxPendingParts", fetch)
        self.assertIn("while state.pendingHashRanges.count < state.maxPendingParts", fetch)
        self.assertIn("network.useExperimentalFeatures || WhitegramTransferSettings.current.usesAcceleratedDownload, let _ = resource as? TelegramCloudMediaResource", patches.pending[DISPATCH])
        upload = patches.pending[UPLOAD]
        self.assertIn("self.parallelParts = WhitegramTransferSettings.current.uploadParallelParts(increaseParallelParts: increaseParallelParts)", upload)
        self.assertIn("while uploadingParts.count < self.parallelParts", upload)
        # Compare the unchanged bodies, rather than reimplementing the network.
        native_fetch = patches.original[FETCH].replace("maxPendingParts: 6,", "maxPendingParts: WhitegramTransferSettings.current.downloadParallelParts,")
        self.assertEqual(fetch, native_fetch)
        start = "    func checkState() {"
        self.assertEqual(upload[upload.index(start):], patches.original[UPLOAD][patches.original[UPLOAD].index(start):])

    def test_transfer_state_machines_and_resource_dispatch_are_otherwise_unchanged(self):
        patches = self.patches()
        for path in (FETCH, DISPATCH, UPLOAD):
            source = subprocess.check_output(["git", "-C", str(patches.root), "show", f"HEAD:{path}"]).decode("utf-8")
            patches.original[path] = source
            patches.pending[path] = source
        transfer_patches(patches)
        self.assertEqual(
            patches.pending[DISPATCH].replace("network.useExperimentalFeatures || WhitegramTransferSettings.current.usesAcceleratedDownload", "network.useExperimentalFeatures"),
            patches.original[DISPATCH],
        )
        self.assertEqual(
            patches.pending[UPLOAD].replace(
                "        self.parallelParts = WhitegramTransferSettings.current.uploadParallelParts(increaseParallelParts: increaseParallelParts)\n",
                "        if increaseParallelParts {\n            self.parallelParts = 30\n        } else {\n            self.parallelParts = 3\n        }\n",
            ),
            patches.original[UPLOAD],
        )
        self.assertEqual(
            patches.pending[FETCH].replace("maxPendingParts: WhitegramTransferSettings.current.downloadParallelParts,", "maxPendingParts: 6,"),
            patches.original[FETCH],
        )

    def test_partial_duplicate_or_missing_transition_is_rejected_before_write(self):
        base = self.patches()
        transfer_patches(base)
        before = "maxPendingParts: 6,"
        after = "maxPendingParts: WhitegramTransferSettings.current.downloadParallelParts,"
        original = base.original[FETCH].replace(after, before)
        for source in (original.replace(before, "", 1), original + before, original.replace(before, after, 1), base.pending[FETCH] + before):
            patches = self.patches()
            patches.read(FETCH)
            patches.pending[FETCH] = source
            with patch("transfer_patches.SourcePatches", return_value=patches), patch.object(patches, "write") as write:
                with self.assertRaises(ValueError):
                    apply_transfer_patches(patches.root)
                write.assert_not_called()
            self.assertEqual((patches.root / FETCH).read_text(encoding="utf-8"), base.original[FETCH])

    def test_missing_upload_anchor_cannot_partially_install_download_edits(self):
        patches = self.patches()
        for path in (FETCH, DISPATCH, UPLOAD):
            patches.read(path)
            patches.pending[path] = subprocess.check_output(["git", "-C", str(patches.root), "show", f"HEAD:{path}"]).decode("utf-8")
        self.assertEqual(patches.pending[UPLOAD].count("self.parallelParts = 30"), 1)
        patches.pending[UPLOAD] = patches.pending[UPLOAD].replace("self.parallelParts = 30", "self.parallelParts = 31")
        with patch("transfer_patches.SourcePatches", return_value=patches), patch.object(patches, "write") as write:
            with self.assertRaises(ValueError):
                apply_transfer_patches(patches.root)
            write.assert_not_called()
        for path, original in patches.original.items():
            self.assertEqual((patches.root / path).read_text(encoding="utf-8"), original)
