import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from media_camera_patches import CAMERA, DEVICE, FETCH, MEDIA_RUNTIME_FILES, OUTPUT, PICKER, media_camera_patches
from source_patches import SourcePatches
from test_translation_patches import errors


class MediaSourceTests(unittest.TestCase):
    def test_all_new_sources_parse(self):
        files = [ROOT / "cleanroom" / name for name in MEDIA_RUNTIME_FILES]
        files += list((ROOT / "tests/media").glob("*.swift"))
        for path in files:
            with self.subTest(name=path.name):
                self.assertEqual(errors(path.read_text(encoding="utf-8")), [])


@unittest.skipUnless(os.environ.get("WHITEGRAM_ASSEMBLED_SOURCE"), "Set WHITEGRAM_ASSEMBLED_SOURCE")
class MediaIntegrationTests(unittest.TestCase):
    def patches(self):
        return SourcePatches(Path(os.environ["WHITEGRAM_ASSEMBLED_SOURCE"]))

    def test_real_sources_replay_without_changes_or_new_syntax_errors(self):
        patches = self.patches()
        media_camera_patches(patches)
        once = dict(patches.pending)
        media_camera_patches(patches)
        self.assertEqual(once, patches.pending)
        self.assertEqual(set(once), {PICKER, FETCH, CAMERA, DEVICE, OUTPUT})
        for path, text in once.items():
            with self.subTest(path=path):
                self.assertEqual(errors(text), errors(patches.original[path]))
                self.assertEqual((patches.root / path).read_text(encoding="utf-8"), patches.original[path])

    def test_photo_options_are_stored_in_resources_and_uncleaned_fallback_is_absent(self):
        patches = self.patches()
        media_camera_patches(patches)
        source = patches.pending[PICKER]
        self.assertIn("width: whitegramMedia.sendLargePhotos ? whitegramPhotoSide : nil", source)
        self.assertIn("quality: whitegramMedia.sendLargePhotos ? Int32", source)
        self.assertIn("forceHd: item.forceHd || whitegramMedia.alwaysSendHD", source)
        cleanup = source[source.index("case let .tempFile(originalPath):"):source.index("var previewRepresentations:", source.index("case let .tempFile(originalPath):"))]
        self.assertIn("subscriber.putError(Void())", cleanup)
        self.assertNotIn("try? WhitegramPhotoMetadata", cleanup)
        self.assertIn("isUniquelyReferencedTemporaryFile: path != originalPath", source)
        self.assertIn("if !whitegramPhotosEnqueued", source)
        self.assertIn("if self.exclusive", patches.pending[CAMERA])
        self.assertIn("self.transaction(device)", patches.pending[DEVICE])

    def test_missing_or_duplicate_bitrate_anchor_fails_before_writes(self):
        base = self.patches()
        media_camera_patches(base)
        before = "                AVVideoAverageBitRateKey: 1000 * 1000,\n"
        after = "                AVVideoAverageBitRateKey: WhitegramMediaSettings.current.roundVideoBitrateValue ?? (1000 * 1000),\n"
        original = base.original[OUTPUT].replace(after, before)
        for broken in (original.replace(before, ""), original + before, base.pending[OUTPUT] + before):
            patches = self.patches()
            patches.read(OUTPUT)
            patches.pending[OUTPUT] = broken
            with self.assertRaises(ValueError):
                media_camera_patches(patches)
            self.assertEqual((patches.root / OUTPUT).read_text(encoding="utf-8"), base.original[OUTPUT])
