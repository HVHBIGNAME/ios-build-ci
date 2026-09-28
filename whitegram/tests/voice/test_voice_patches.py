"""Run with -B. Source trees are read-only; SourcePatches writes to MemoryRoot.

WHITEGRAM_VOICE_SOURCE selects the assembled 12.9.2 tree.
WHITEGRAM_VOICE_PUBLIC_SOURCE optionally checks the public fork as well.
These are patch/API/syntax checks, not execution of the Swift DSP.
"""

import os
from pathlib import Path
import re
import sys
import unittest

sys.dont_write_bytecode = True
WHITEGRAM = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(WHITEGRAM))

import voice_patches as voice

try:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
except ImportError:
    Parser = None


RECORDER_FIXTURE = """import Foundation
import TelegramCore

private func audioRecorderNativeStreamDescription(sampleRate: Double) -> AudioStreamBasicDescription {
    var canonicalBasicStreamDescription = AudioStreamBasicDescription()
    canonicalBasicStreamDescription.mChannelsPerFrame = 1
    canonicalBasicStreamDescription.mBitsPerChannel = 16
    canonicalBasicStreamDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
    return canonicalBasicStreamDescription
}

final class ManagedAudioRecorderContext {
    private var audioBuffer = Data()

    private func setupAudioUnit() {
        var audioStreamDescription = audioRecorderNativeStreamDescription(sampleRate: 48000)
    }

    func resume() {
        assert(self.queue.isCurrent())
        if let trimRange = self.trimRange {
            self.trimRange = nil
        }
        self.start()
    }

    func processAndDisposeAudioBuffer(_ buffer: AudioBuffer) {
        assert(self.queue.isCurrent())
        defer { free(buffer.mData) }
        if !self.processSamples { return }
        let millisecondsPerPacket = 60
        let encoderPacketSizeInBytes = 16000 / 1000 * millisecondsPerPacket * 2
        let currentEncoderPacket = malloc(encoderPacketSizeInBytes)!
        defer { free(currentEncoderPacket) }
        while true {
            let currentEncoderPacketSize = encoderPacketSizeInBytes
            if currentEncoderPacketSize < encoderPacketSizeInBytes {
                self.audioBuffer.append(currentEncoderPacket.assumingMemoryBound(to: UInt8.self), count: currentEncoderPacketSize)
                break
            } else {
                self.processWaveformPreview(samples: currentEncoderPacket.assumingMemoryBound(to: Int16.self), count: currentEncoderPacketSize / 2)
                self.oggWriter.writeFrame(currentEncoderPacket.assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(currentEncoderPacketSize))
            }
        }
    }
}
"""

ENCODER_FIXTURE = """- (instancetype)init {
        rate = 48000;
        coding_rate = 48000;
        frame_size = 960;
}
- (bool)writeFrame:(uint8_t *)framePcmBytes frameByteCount:(NSUInteger)frameByteCount {
        nb_samples = (opus_int32)(frameByteCount / 2);
        nbBytes = opus_encode(_encoder, (opus_int16 *)paddedFrameBytes, cur_frame_size, _packet, max_frame_bytes / 10);
}
"""

CHAT_FIXTURE = """func requestAudioRecorder() {
                self.context.sharedContext.mediaManager.audioRecorder(
                    resumeData: resumeData,
                    beginWithTone: beginWithTone
                )
}
func preview() { storeResourceData(id: resource.id, data: data.compressedData) }
func send() { storeResourceData(id: resource.id, data: data.compressedData) }
"""


class MemoryFile:
    def __init__(self, root, path):
        self.root = root
        self.path = path

    def read_text(self, encoding):
        if self.path not in self.root.files:
            raise FileNotFoundError(self.path)
        return self.root.files[self.path].decode(encoding).replace("\r\n", "\n").replace("\r", "\n")

    def write_bytes(self, value):
        self.root.files[self.path] = value
        self.root.writes.append(self.path)
        return len(value)


class MemoryRoot:
    def __init__(self, files=None):
        self.files = files if files is not None else {
            voice.RECORDER: RECORDER_FIXTURE.encode(),
            voice.ENCODER: ENCODER_FIXTURE.encode(),
            voice.CHAT: CHAT_FIXTURE.encode(),
            "submodules/SettingsUI/Sources/MainMenu.swift": b"// Parent-owned.\n",
        }
        self.writes = []

    def __truediv__(self, path):
        return MemoryFile(self, path)

    def text(self, path=voice.RECORDER):
        return self.files[path].decode("utf-8")

    def change(self, path, before, after):
        self.files[path] = self.files[path].replace(before.encode(), after.encode())


def remove_hooks(source):
    for insertion in (voice.PROCESSOR_PROPERTY, voice.FRAME_HOOK, voice.RESUME_HOOK):
        source = source.replace(insertion, "")
    return source


def source_roots():
    return [Path(value) for name in ("WHITEGRAM_VOICE_SOURCE", "WHITEGRAM_VOICE_PUBLIC_SOURCE") if (value := os.environ.get(name))]


class VoicePatchTests(unittest.TestCase):
    def test_only_owned_pcm_packet_is_processed_before_waveform_and_encode(self):
        root = MemoryRoot()
        report = voice.apply_voice_patches(root)
        self.assertEqual(report, {voice.FEATURE: [voice.RECORDER]})
        result = root.text()
        self.assertEqual(remove_hooks(result), RECORDER_FIXTURE)
        self.assertLess(result.index("if !self.processSamples"), result.index(voice.FRAME_HOOK))
        self.assertLess(result.index("if currentEncoderPacketSize <"), result.index(voice.FRAME_HOOK))
        self.assertLess(result.index(voice.FRAME_HOOK), result.index(voice.FRAME_ANCHOR))
        self.assertLess(result.index(voice.FRAME_ANCHOR), result.index("self.oggWriter.writeFrame"))
        self.assertEqual(result.count("WhitegramPreferences.values()"), 1)
        self.assertLess(result.index(voice.PROCESSOR_PROPERTY), result.index("func processAndDisposeAudioBuffer"))

    def test_resume_resets_before_trim_and_start(self):
        root = MemoryRoot()
        voice.apply_voice_patches(root)
        result = root.text()
        self.assertLess(result.index(voice.RESUME_HOOK), result.index("if let trimRange"))
        self.assertLess(result.index(voice.RESUME_HOOK), result.index("self.start()"))
        self.assertEqual(result.count("whitegramVoiceProcessor.reset()"), 1)

    def test_repeated_application_is_byte_identical_and_does_not_write(self):
        root = MemoryRoot()
        first_report = voice.apply_voice_patches(root)
        first = dict(root.files)
        root.writes.clear()
        self.assertEqual(voice.apply_voice_patches(root), first_report)
        self.assertEqual(root.files, first)
        self.assertEqual(root.writes, [])

    def test_no_encoder_chat_menu_or_other_source_is_written(self):
        root = MemoryRoot()
        other = {path: data for path, data in root.files.items() if path != voice.RECORDER}
        voice.apply_voice_patches(root)
        self.assertEqual(root.writes, [voice.RECORDER])
        self.assertEqual({path: data for path, data in root.files.items() if path != voice.RECORDER}, other)

    def test_missing_or_ambiguous_insertion_anchor_aborts_all_writes(self):
        for anchor in (voice.PROCESSOR_ANCHOR, voice.FRAME_ANCHOR, voice.RESUME_ANCHOR):
            for replacement in ("", anchor + anchor):
                with self.subTest(anchor=anchor, duplicate=bool(replacement)):
                    root = MemoryRoot()
                    root.change(voice.RECORDER, anchor, replacement)
                    before = dict(root.files)
                    with self.assertRaisesRegex(ValueError, "expected 1 anchors"):
                        voice.apply_voice_patches(root)
                    self.assertEqual(root.files, before)
                    self.assertEqual(root.writes, [])

    def test_pcm_format_encoder_and_send_path_drift_abort_before_write(self):
        changes = (
            (voice.RECORDER, "sampleRate: 48000)", "sampleRate: 44100)"),
            (voice.RECORDER, "mChannelsPerFrame = 1", "mChannelsPerFrame = 2"),
            (voice.RECORDER, "mBitsPerChannel = 16", "mBitsPerChannel = 32"),
            (voice.RECORDER, "kAudioFormatFlagIsSignedInteger", "kAudioFormatFlagIsFloat"),
            (voice.RECORDER, "millisecondsPerPacket = 60", "millisecondsPerPacket = 40"),
            (voice.ENCODER, "coding_rate = 48000", "coding_rate = 16000"),
            (voice.ENCODER, "frame_size = 960", "frame_size = 1920"),
            (voice.ENCODER, "frameByteCount / 2", "frameByteCount / 4"),
            (voice.ENCODER, "opus_encode(", "opus_encode_float("),
            (voice.CHAT, "mediaManager.audioRecorder(", "mediaManager.newAudioRecorder("),
            (voice.CHAT, "data: data.compressedData)", "data: reencodedData)"),
        )
        for path, before, after in changes:
            with self.subTest(path=path, change=before):
                root = MemoryRoot()
                root.change(path, before, after)
                original = dict(root.files)
                with self.assertRaisesRegex(ValueError, "PCM contract"):
                    voice.apply_voice_patches(root)
                self.assertEqual(root.files, original)
                self.assertEqual(root.writes, [])

    def test_missing_source_does_not_create_a_stub(self):
        for path in (voice.RECORDER, voice.ENCODER, voice.CHAT):
            with self.subTest(path=path):
                root = MemoryRoot()
                del root.files[path]
                with self.assertRaises(FileNotFoundError):
                    voice.apply_voice_patches(root)
                self.assertNotIn(path, root.files)
                self.assertEqual(root.writes, [])

    def test_crlf_uses_parent_source_patches_normalization(self):
        root = MemoryRoot()
        root.files = {path: data.replace(b"\n", b"\r\n") for path, data in root.files.items()}
        voice.apply_voice_patches(root)
        self.assertEqual(remove_hooks(root.text()), RECORDER_FIXTURE)


@unittest.skipUnless(source_roots(), "Set WHITEGRAM_VOICE_SOURCE for real-source compatibility checks")
class VoiceUpstreamTests(unittest.TestCase):
    def test_actual_recording_send_and_encoder_sources_are_compatible_and_untouched(self):
        for source in source_roots():
            with self.subTest(source=source):
                originals = {path: (source / path).read_bytes() for path in (voice.RECORDER, voice.ENCODER, voice.CHAT)}
                root = MemoryRoot(dict(originals))
                voice.apply_voice_patches(root)
                clean_original = originals[voice.RECORDER].decode().replace("\r\n", "\n")
                self.assertEqual(remove_hooks(root.text()), remove_hooks(clean_original))
                for insertion in (voice.PROCESSOR_PROPERTY, voice.FRAME_HOOK, voice.RESUME_HOOK):
                    self.assertEqual(root.text().count(insertion), 1)
                first = dict(root.files)
                root.writes.clear()
                voice.apply_voice_patches(root)
                self.assertEqual(first, root.files)
                self.assertEqual(root.writes, [])
                for path, original in originals.items():
                    self.assertEqual((source / path).read_bytes(), original)

    def test_runtime_imports_are_in_existing_bazel_dependencies(self):
        for source in source_roots():
            for filename, destination in voice.VOICE_RUNTIME_FILES.items():
                with self.subTest(source=source, file=filename):
                    code = (WHITEGRAM / "cleanroom" / filename).read_text(encoding="utf-8")
                    module = Path(destination).parts[1]
                    build = (source / "submodules" / module / "BUILD").read_text(encoding="utf-8")
                    self.assertIn("Sources/**/*.swift", build)
                    imports = set(re.findall(r"^import (\w+)$", code, re.MULTILINE))
                    if module == "TelegramCore":
                        self.assertLessEqual(imports, {"Foundation", "CoreFoundation"})
                    for dependency in imports - {"Foundation", "CoreFoundation", "UIKit"}:
                        self.assertRegex(build, r'"//[^"\n]*(?:/|:)' + re.escape(dependency) + r'"')

    def test_item_list_api_signatures_match_used_controls(self):
        expected = {
            "submodules/ItemListUI/Sources/Items/ItemListSwitchItem.swift": (
                "systemStyle: ItemListSystemStyle = .legacy", "text: String? = nil", "enabled: Bool = true", "updated: @escaping (Bool) -> Void",
            ),
            "submodules/ItemListUI/Sources/Items/ItemListCheckboxItem.swift": (
                "subtitle: String? = nil", "enabled: Bool = true", "style: ItemListCheckboxItemStyle", "action: @escaping () -> Void",
            ),
            "submodules/SettingsUI/Sources/WhiteGramSettingsController.swift": (
                "(Signal<Void, NoError>?, (ListViewItemApply) -> Void)", "params: ListViewItemLayoutParams", "rotated: Bool = false, seeThrough: Bool = false",
            ),
        }
        for source in source_roots():
            for path, signatures in expected.items():
                content = (source / path).read_text(encoding="utf-8")
                for signature in signatures:
                    with self.subTest(source=source, path=path, signature=signature):
                        self.assertIn(signature, content)


@unittest.skipIf(Parser is None, "Install tree-sitter==0.25.2 and tree-sitter-swift==0.7.3")
class VoiceSwiftSyntaxTests(unittest.TestCase):
    def assert_parses(self, name, content):
        parser = Parser(Language(tree_sitter_swift.language()))
        root = parser.parse(content).root_node
        errors = []
        nodes = [root]
        while nodes:
            node = nodes.pop()
            if node.type == "ERROR" or node.is_missing:
                errors.append(f"{name}:{node.start_point.row + 1}:{node.start_point.column + 1}: {node.type}")
            nodes.extend(reversed(node.children))
        self.assertFalse(root.has_error, "\n".join(errors))
        self.assertEqual(errors, [])

    def test_all_runtime_swift_and_native_test_harness_parse(self):
        files = [WHITEGRAM / "cleanroom" / filename for filename in voice.VOICE_RUNTIME_FILES]
        files.append(Path(__file__).with_name("WhitegramVoiceDSPTests.swift"))
        for path in files:
            with self.subTest(file=path.name):
                self.assert_parses(path.name, path.read_bytes())

    def test_patched_fixture_and_actual_recorders_parse(self):
        fixtures = [("fixture", MemoryRoot())]
        for source in source_roots():
            fixtures.append((str(source), MemoryRoot({path: (source / path).read_bytes() for path in (voice.RECORDER, voice.ENCODER, voice.CHAT)})))
        for name, root in fixtures:
            with self.subTest(source=name):
                voice.apply_voice_patches(root)
                self.assert_parses(name, root.files[voice.RECORDER])


if __name__ == "__main__":
    unittest.main()
