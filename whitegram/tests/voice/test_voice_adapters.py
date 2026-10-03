"""Full voice adapters and real privacy/camera composition, using read-only inputs."""
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

import test_voice_patches as fixtures

sys.path.insert(0, str(fixtures.WHITEGRAM))
import voice_patches as voice
import content_control_patches as privacy
import media_camera_patches as camera
from source_patches import SourcePatches

SOURCE = os.environ.get("WHITEGRAM_VOICE_SOURCE")
PATHS = (voice.RECORDER, voice.ENCODER, voice.CHAT, voice.OPUS_HEADER, voice.OPUS_READER,
         voice.CALL, voice.CALL_HEADER, voice.CALL_NATIVE, voice.VIDEO)
PRIVACY_PATHS = (privacy.CORE + "TelegramEngine/Messages/MarkMessageContentAsConsumedInteractively.swift",
                 privacy.UI + "AppDelegate.swift")


class VoiceManifestTests(unittest.TestCase):
    def test_every_voice_runtime_is_mapped_and_referenced_screens_exist(self):
        sources = {path.name for path in (fixtures.WHITEGRAM / "cleanroom").glob("WhitegramVoice*.swift")}
        self.assertEqual(sources, set(voice.VOICE_RUNTIME_FILES))
        self.assertEqual(len(set(voice.VOICE_RUNTIME_FILES.values())), len(sources))
        remote = (fixtures.WHITEGRAM / "cleanroom/WhitegramVoiceRemoteSettingsController.swift").read_text(encoding="utf-8")
        self.assertIn("public func whitegramVoiceRemoteSettingsController(context: AccountContext)", remote)
        self.assertIn("import PresentationDataUtils", remote)
        file_controller = (fixtures.WHITEGRAM / "cleanroom/WhitegramVoiceFileController.swift").read_text(encoding="utf-8")
        self.assertIn("public final class WhitegramVoiceFileController:", file_controller)


@unittest.skipUnless(SOURCE, "Set WHITEGRAM_VOICE_SOURCE to the ready read-only reference")
class VoiceAdapterPatchTests(unittest.TestCase):
    def setUp(self):
        self.source = Path(SOURCE)
        self.original = {path: (self.source / path).read_bytes() for path in PATHS + PRIVACY_PATHS}
        self.root = fixtures.MemoryRoot(dict(self.original))

    def test_complete_transform_replays_and_keeps_reference_unchanged(self):
        report = voice.apply_voice_patches(self.root)
        reported = {path for paths in report.values() for path in paths}
        self.assertTrue((set(PATHS) - {voice.ENCODER, voice.RECORDER}).issubset(reported))
        changed = {path for path in self.original if self.original[path] != self.root.files[path]}
        self.assertEqual(set(self.root.writes), changed)
        self.assertTrue(set(self.root.writes).issubset(set(PATHS) - {voice.ENCODER}))
        self.assertEqual(self.root.text(voice.RECORDER).count(voice.FRAME_HOOK), 1)
        first = dict(self.root.files)
        self.root.writes.clear()
        self.assertEqual(voice.apply_voice_patches(self.root), report)
        self.assertEqual(first, self.root.files)
        self.assertEqual(self.root.writes, [])
        for path, data in self.original.items():
            self.assertEqual((self.source / path).read_bytes(), data)

    def test_voice_and_actual_record_once_transforms_compose_in_both_orders(self):
        outputs = []
        for order in ((privacy.retained_media_patches, voice.voice_patches),
                      (voice.voice_patches, privacy.retained_media_patches)):
            with self.subTest(order=[f.__name__ for f in order]):
                staged = SourcePatches(self.source)
                with patch.object(staged, "write", side_effect=AssertionError("Reference writes are forbidden")):
                    for transform in order:
                        transform(staged)
                    first = dict(staged.pending)
                    for transform in order:
                        transform(staged)
                self.assertEqual(first, staged.pending)
                chat = staged.pending[voice.CHAT]
                signature = chat[chat.index("    func sendMediaRecording("):]
                self.assertEqual(signature.count("whitegramProcessedAudio: ChatInterfaceMediaDraftState.Audio? = nil"), 1)
                self.assertEqual(signature.count("let viewOnce = WhitegramContentPolicy.recordAsViewOnce"), 1)
                self.assertIn("eligible: self.whitegramCanSendViewOnceRecording(scheduleTime: scheduleTime)", signature)
                self.assertIn("whitegramProcessedAudio: processed", signature)
                self.assertIn("switch effectivePreview", signature)
                self.assertLess(signature.index("whitegramPrepareAudioDraft"), signature.index("let resource: TelegramMediaResource"))
                self.assertIn("peer.botInfo == nil", chat)
                self.assertIn("peer.id != self.context.account.peerId", chat)
                self.assertIn("self.presentationInterfaceState.sendPaidMessageStars == nil", chat)
                self.assertIn("self.subject != .scheduledMessages", chat)
                self.assertIn("eligible: self.viewOnceAvailable && scheduleTime == nil", staged.pending[voice.VIDEO])
                if fixtures.Parser is not None:
                    for path in (voice.CHAT, voice.VIDEO):
                        fixtures.VoiceSwiftSyntaxTests().assert_parses(path, staged.pending[path].encode("utf-8"))
                for path, original in staged.original.items():
                    self.assertEqual((self.source / path).read_text(encoding="utf-8"), original)
                outputs.append(staged.pending)
        self.assertEqual(len(outputs), 2)
        self.assertEqual(outputs[0], outputs[1])

    def test_actual_camera_transform_and_video_audio_processing_compose(self):
        outputs = []
        for order in ((camera.media_camera_patches, voice.voice_patches), (voice.voice_patches, camera.media_camera_patches)):
            staged = SourcePatches(self.source)
            for transform in order:
                transform(staged)
            first = dict(staged.pending)
            for transform in order:
                transform(staged)
            self.assertEqual(first, staged.pending)
            video = staged.pending[voice.VIDEO]
            self.assertIn("WhitegramVoiceVideo.process(urls: videoPaths.map", video)
            self.assertIn("allowLiveUpload && !self.whitegramVoiceSettings.requiresVideoProcessing", video)
            self.assertIn("WhitegramMediaSettings.current.roundVideoBitrateValue", staged.pending[camera.OUTPUT])
            for path, original in staged.original.items():
                self.assertEqual((self.source / path).read_text(encoding="utf-8"), original)
            outputs.append(staged.pending)
        self.assertEqual(outputs[0], outputs[1])

    def test_failed_video_anchor_prevents_earlier_recorder_or_call_writes(self):
        self.root.change(voice.VIDEO, "    public func discardVideo() {", "    public func discardChangedVideo() {")
        before = dict(self.root.files)
        with self.assertRaisesRegex(ValueError, "expected 1 anchors"):
            voice.apply_voice_patches(self.root)
        self.assertEqual(self.root.files, before)
        self.assertEqual(self.root.writes, [])

    def test_send_only_postprocessing_preserves_pause_preview_and_recorder_data(self):
        voice.apply_voice_patches(self.root)
        chat = self.root.text(voice.CHAT)
        preview = chat[chat.index("            case .preview, .pause:"):chat.index("            case let .send(viewOnce):")]
        self.assertNotIn("whitegramPrepareRecordedAudio", preview)
        self.assertEqual(chat.count("return self.whitegramPrepareRecordedAudio(data)"), 1)
        self.assertIn("whitegramProcessedAudio == nil && self.whitegramPrepareAudioDraft", chat)
        code = (fixtures.WHITEGRAM / "cleanroom/WhitegramVoiceChat.swift").read_text(encoding="utf-8")
        self.assertIn("trimRange: data.trimRange", code)
        self.assertIn("resumeData: data.resumeData", code)
        self.assertIn("subscriber.putNext(nil)", code)
        self.assertIn("return ActionDisposable { task.cancel() }", code)
        self.assertIn("current == audio", code)
        self.assertLess(chat.index("self.interfaceInteraction?.displaySlowmodeTooltip"), chat.index("self.whitegramPrepareAudioDraft"))

    def test_call_processing_owns_bounded_copy_before_both_transport_overloads(self):
        voice.apply_voice_patches(self.root)
        native = self.root.text(voice.CALL_NATIVE)
        self.assertEqual(native.count("const void *whitegramSamples = ProcessWhitegramInput"), 2)
        self.assertEqual(native.count("                    whitegramSamples,"), 2)
        self.assertIn("memcpy(_whitegramInputSamples, samples, frames * channels * sizeof(int16_t))", native)
        self.assertIn("frames > 3840 || channels < 1 || channels > 2", native)
        self.assertNotIn("const_cast", native)
        self.assertIn("if !isActive { self.whitegramVoiceEffects.reset() }", self.root.text(voice.CALL))

    def test_video_gate_disables_live_upload_and_preserves_view_once_and_schedule(self):
        voice.apply_voice_patches(self.root)
        video = self.root.text(voice.VIDEO)
        self.assertIn("allowLiveUpload && !self.whitegramVoiceSettings.requiresVideoProcessing", video)
        self.assertIn("trimRange: self.node.previewState?.trimRange", video)
        self.assertIn("data: whitegramVideo.data, synchronous: true", video)
        self.assertIn("self.didSend = false", video)
        self.assertIn("self.node.transitioningToPreview = true", video)
        self.assertIn("), silentPosting, scheduleTime, repeatPeriod)", video)
        self.assertIn("if self.cameraState.isViewOnceEnabled", video)

    @unittest.skipIf(fixtures.Parser is None, "Swift parser unavailable")
    def test_all_patched_swift_adapters_parse(self):
        voice.apply_voice_patches(self.root)
        for path in PATHS:
            if path.endswith(".swift"):
                fixtures.VoiceSwiftSyntaxTests().assert_parses(path, self.root.files[path])


if __name__ == "__main__":
    unittest.main()
