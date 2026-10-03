import os
from pathlib import Path
import re
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from media_camera_patches import CAMERA, DEVICE, FETCH, MEDIA_PICKER, MEDIA_RUNTIME_FILES, OUTPUT, PICKER, ROUND_SCREEN, _replace, apply_media_camera_patches, media_camera_patches
from source_patches import SourcePatches
from tree_sitter import Language, Parser
import tree_sitter_swift


def errors(text):
    parser = Parser(Language(tree_sitter_swift.language()))
    data = text.encode("utf-8")
    stack = [parser.parse(data).root_node]
    result = []
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            result.append((node.type, data[node.start_byte:node.end_byte]))
        stack.extend(reversed(node.children))
    return result


class MediaSourceTests(unittest.TestCase):
    def test_all_new_sources_parse(self):
        files = [ROOT / "cleanroom" / name for name in MEDIA_RUNTIME_FILES]
        files += list((ROOT / "tests/media").glob("*.swift"))
        for path in files:
            with self.subTest(name=path.name):
                self.assertEqual(errors(path.read_text(encoding="utf-8")), [])

    def test_release_and_previous_patch_upgrade_replay_and_reject_mixed_sources(self):
        before, previous, after = "let value = 0\n", "let value = oldPolicy()\n", "let value = newPolicy()\n"
        for source in (before, previous, after):
            patches = SourcePatches(ROOT)
            patches.original["fixture"] = source
            patches.pending["fixture"] = source
            _replace(patches, "fixture", before, after, previous=previous)
            self.assertEqual(patches.pending["fixture"], after)
            _replace(patches, "fixture", before, after, previous=previous)
            self.assertEqual(patches.pending["fixture"], after)
        for source in ("", before + before, previous + before, after + previous, after + before):
            patches = SourcePatches(ROOT)
            patches.original["fixture"] = source
            patches.pending["fixture"] = source
            with self.subTest(source=source), self.assertRaises(ValueError):
                _replace(patches, "fixture", before, after, previous=previous)

    def test_original_labels_use_the_selected_language_and_refresh_on_pack_change(self):
        controller = (ROOT / "cleanroom/WhitegramMediaSettingsController.swift").read_text(encoding="utf-8")
        localization = (ROOT / "generated/WhitegramLocalizationStrings.swift").read_text(encoding="utf-8")
        keys = set(re.findall(r'(?:localized|(?:self|strings|coordinator\.strings)\.string)\("([^"]+)"\)', controller))
        self.assertTrue({"camera.settings.title", "camera.settings.stock", "camera.settings.bitrate", "s.photoQuality", "s.cleanMetadata", "s.rememberCamera", "s.staticZoom", "s.sendAccel", "s.downloadAccel", "accel.off", "accel.4", "accel.8", "accel.16"}.issubset(keys))
        for key in keys:
            self.assertIn(f'"{key}": [', localization, key)
        self.assertIn("WhitegramLocalization.string(key, baseLanguage: self.baseLanguage)", controller)
        self.assertIn("WhitegramLocalization.selectedLanguage(baseLanguage: self.baseLanguage)", controller)
        self.assertIn("WhitegramLocalizationStore.changedNotification", controller)
        self.assertNotIn('baseLanguageCode.hasPrefix("ru")', controller)

    def test_sensor_choices_and_actual_session_formats_use_distinct_validation(self):
        source = (ROOT / "cleanroom/WhitegramCameraConfiguration.swift").read_text(encoding="utf-8")
        choices = source[source.index("public static func supported("):source.index("public static var wideAngleAvailable")]
        application = source[source.index("static func apply(to device:"):]
        self.assertIn("isUsable(format, multiCam: false)", choices)
        self.assertNotIn("Camera.isDualCameraSupported", choices)
        self.assertIn("isUsable(format, multiCam: multiCam)", application)
        self.assertIn("multiCam && !format.isMultiCamSupported", source)


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
        self.assertEqual(set(once), {PICKER, FETCH, CAMERA, DEVICE, OUTPUT, ROUND_SCREEN, MEDIA_PICKER})
        for path, text in once.items():
            with self.subTest(path=path):
                self.assertEqual(errors(text), errors(patches.original[path]))
                self.assertEqual((patches.root / path).read_text(encoding="utf-8"), patches.original[path])

    def test_pristine_release_source_accepts_and_replays_all_media_hooks(self):
        patches = self.patches()
        paths = (PICKER, FETCH, CAMERA, DEVICE, OUTPUT, ROUND_SCREEN, MEDIA_PICKER)
        for path in paths:
            source = subprocess.check_output(["git", "-C", str(patches.root), "show", f"HEAD:{path}"]).decode("utf-8")
            patches.original[path] = source
            patches.pending[path] = source
        media_camera_patches(patches)
        once = dict(patches.pending)
        media_camera_patches(patches)
        self.assertEqual(once, patches.pending)
        for path, source in once.items():
            self.assertEqual(errors(source), errors(patches.original[path]), path)

    def test_photo_options_are_stored_in_resources_and_uncleaned_fallback_is_absent(self):
        patches = self.patches()
        media_camera_patches(patches)
        source = patches.pending[PICKER]
        self.assertEqual(source.count("width: whitegramPhotoSide, height: whitegramPhotoSide, quality: whitegramMedia.photoQualityPercent"), 2)
        self.assertIn("forceHd: item.forceHd || whitegramMedia.alwaysSendHD", source)
        cleanup = source[source.index("case let .tempFile(originalPath):"):source.index("var previewRepresentations:", source.index("case let .tempFile(originalPath):"))]
        self.assertIn("subscriber.putError(Void())", cleanup)
        self.assertNotIn("try? WhitegramPhotoMetadata", cleanup)
        self.assertIn("cleanedCopyIfSupported(path: originalPath, mimeType: mimeType)", cleanup)
        ownership = source[source.index("let whitegramFileSize = engineFileSize(path)"):source.index("var attributes: [EngineMessage.Attribute]", source.index("let whitegramFileSize = engineFileSize(path)"))]
        self.assertIn("LocalFileMediaResource(fileId: randomId, size: whitegramFileSize)", ownership)
        self.assertIn("moveResourceData(cleanedResource.id, fromTempPath: path)", ownership)
        self.assertIn("whitegramPreparedPhotos.removeAll", ownership)
        self.assertIn("size: whitegramFileSize", ownership)
        self.assertNotIn("removeItem(atPath: originalPath)", source)
        self.assertIn("if !whitegramPhotosEnqueued", source)
        self.assertIn("self.transaction(device)", patches.pending[DEVICE])
        self.assertIn("whitegramMedia.shouldCompressLibraryVideo(asFile: asFile) ? .compress(resourceAdjustments) : .passthrough", source)
        self.assertIn("photoLibraryJPEGQuality(storedQuality: quality)", patches.pending[FETCH])
        self.assertIn("photoLibraryTargetDimensions(width: width, height: height, hd: hd)", patches.pending[FETCH])
        self.assertIn('bool(forKey: "TG_photoHighQuality_v0") || WhitegramMediaSettings.current.alwaysSendHD', patches.pending[MEDIA_PICKER])

    def test_capture_limits_zoom_and_encoder_reach_native_consumers(self):
        patches = self.patches()
        media_camera_patches(patches)
        camera, device, output = (patches.pending[path] for path in (CAMERA, DEVICE, OUTPUT))
        self.assertIn("forRoundVideo && WhitegramMediaSettings.current.requiresSingleCameraForRoundVideo", camera)
        self.assertIn("let enabled = enabled && self.session.supportsDualCam", camera)
        self.assertIn("self.device.resetZoom(neutral: !whitegramWideAngle", camera)
        self.assertEqual(camera.count("self.initialConfiguration.isRoundVideo && self.isDualCameraEnabled == true"), 3)
        self.assertEqual(camera.count("WhitegramMediaSettings.rememberCamera(front:"), 3)
        self.assertIn("self.fps = targetFPS.fps", device)
        self.assertIn("guard zoomDelta.isFinite && zoomDelta > 0.0", device)
        self.assertIn("WhitegramCameraConfiguration.apply(to: device, multiCam: multiCam, policy: policy)", device)
        self.assertIn("self.whitegramCaptureFPS = min(60.0, max(1.0, device.fps))", output)
        self.assertIn("AVVideoExpectedSourceFrameRateKey: self.whitegramCaptureFPS", output)
        self.assertIn("AVVideoAverageBitRateKey: WhitegramMediaSettings.current.roundVideoBitrateValue", output)
        self.assertIn("dimensions = videoMessageDimensions.cgSize", output)
        self.assertIn("if !WhitegramMediaSettings.current.staticZoomEnabled", patches.pending[ROUND_SCREEN])

    def test_initial_back_camera_reaches_compositor_before_recording(self):
        patches = self.patches()
        media_camera_patches(patches)
        self.assertIn("output.startRecording(mode: .roundVideo, position: self.positionValue, orientation:", patches.pending[CAMERA])
        output = patches.pending[OUTPUT]
        start = output[output.index("    func startRecording(mode:"):output.index("    func stopRecording()")]
        self.assertLess(start.index("self.currentPosition = position ?? .front"), start.index("videoRecorder.start()"))
        self.assertIn("self.videoSwitchSampleTimeOffset = nil", start)
        self.assertIn("self.lastSwitchTimestamp = 0.0", start)
        # Both single-camera mirroring and dual-camera selection consume this
        # same initialized position in the real frame-processing method.
        frames = output[output.index("    func processVideoRecording("):]
        self.assertIn("if case .front = self.currentPosition", frames)
        self.assertIn("var additional = self.currentPosition == .front", frames)

    def test_regular_result_uses_encoder_dimensions_and_native_rotation(self):
        patches = self.patches()
        media_camera_patches(patches)
        output = patches.pending[OUTPUT]
        regular = output[output.index("let codecType: AVVideoCodecType"):output.index("let audioSettings =")]
        self.assertIn("settings[AVVideoWidthKey] = Int(captureDimensions.width)", regular)
        self.assertIn("settings[AVVideoHeightKey] = Int(captureDimensions.height)", regular)
        self.assertIn("WhitegramMediaSettings.videoRecordingDimensions(encodedWidth: Int(captureDimensions.width), encodedHeight: Int(captureDimensions.height), portrait: orientation == .portrait || orientation == .portraitUpsideDown)", regular)
        self.assertIn("compressionProperties[AVVideoExpectedSourceFrameRateKey] = self.whitegramCaptureFPS", regular)
        self.assertIn("CGSize(width: CGFloat(whitegramDimensions.width), height: CGFloat(whitegramDimensions.height))", regular)
        self.assertIn("return .fail(.videoRecorderInitializationError)", regular)
        self.assertNotIn("CGSize(width: 1920, height: 1080)", regular)
        self.assertIn("dimensions = videoMessageDimensions.cgSize", output[:output.index("let codecType: AVVideoCodecType")])
        self.assertIn("self.whitegramCaptureDimensions = device.videoDevice.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }", output)
        configuration = patches.pending[CAMERA]
        self.assertLess(configuration.index("self.device.configureWhitegramFormat("), configuration.index("self.output.configure(for: session, device: self.device"))
        recorder = (patches.root / "submodules/Camera/Sources/VideoRecorder.swift").read_text(encoding="utf-8")
        self.assertIn("CGAffineTransform(rotationAngle: .pi / 2.0)", recorder)
        self.assertIn("CGAffineTransform(rotationAngle: -.pi / 2.0)", recorder)
        self.assertIn("videoInput.transform = self.videoTransform", recorder)
        self.assertIn("outputSettings: videoSettings", recorder)

    def test_recorder_initialization_errors_reach_the_public_camera_signal(self):
        patches = self.patches()
        media_camera_patches(patches)
        camera = patches.pending[CAMERA]
        start = camera.rindex("    public func startRecording()")
        public_recording = camera[start:camera.index("    public func stopRecording()", start)]
        self.assertIn("context.startRecording().start(next:", public_recording)
        self.assertIn("}, error: { error in\n                        subscriber.putError(error)", public_recording)
        output = patches.pending[OUTPUT]
        self.assertIn("return .fail(.videoRecorderInitializationError)", output)
        self.assertIn("return .fail(.audioInitializationError)", output)

    def test_missing_or_duplicate_bitrate_anchor_fails_before_writes(self):
        base = self.patches()
        media_camera_patches(base)
        before = "                AVVideoAverageBitRateKey: 1000 * 1000,\n"
        after = "                AVVideoAverageBitRateKey: WhitegramMediaSettings.current.roundVideoBitrateValue ?? (1000 * 1000),\n"
        current = after + "                AVVideoExpectedSourceFrameRateKey: self.whitegramCaptureFPS,\n"
        original = base.original[OUTPUT].replace(current, before).replace(after, before)
        for broken in (original.replace(before, ""), original + before, base.pending[OUTPUT] + before):
            patches = self.patches()
            patches.read(OUTPUT)
            patches.pending[OUTPUT] = broken
            with patch("media_camera_patches.SourcePatches", return_value=patches), patch.object(patches, "write") as write:
                with self.assertRaises(ValueError):
                    apply_media_camera_patches(patches.root)
                write.assert_not_called()
            self.assertEqual((patches.root / OUTPUT).read_text(encoding="utf-8"), base.original[OUTPUT])

    def test_missing_and_mixed_static_zoom_hooks_fail_before_write(self):
        base = self.patches()
        media_camera_patches(base)
        before = "                camera.rampZoom(1.0, rate: 8.0)\n"
        after = "                if !WhitegramMediaSettings.current.staticZoomEnabled {\n                    camera.rampZoom(1.0, rate: 8.0)\n                }\n"
        source = base.original[ROUND_SCREEN].replace(after, before)
        for broken in (source.replace(before, ""), source + before, base.pending[ROUND_SCREEN] + before):
            patches = self.patches()
            patches.read(ROUND_SCREEN)
            patches.pending[ROUND_SCREEN] = broken
            with patch("media_camera_patches.SourcePatches", return_value=patches), patch.object(patches, "write") as write:
                with self.assertRaises(ValueError):
                    apply_media_camera_patches(patches.root)
                write.assert_not_called()
            for path, original in patches.original.items():
                self.assertEqual((patches.root / path).read_text(encoding="utf-8"), original)
