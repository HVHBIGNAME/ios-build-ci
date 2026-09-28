"""Exact Telegram 12.9.2 voice-message PCM hooks; runtime copying is parent-owned."""

from pathlib import Path

from source_patches import SourcePatches


VOICE_RUNTIME_FILES = {
    "WhitegramVoiceSettings.swift": "submodules/TelegramCore/Sources/WhitegramVoiceSettings.swift",
    "WhitegramVoiceDSP.swift": "submodules/TelegramCore/Sources/WhitegramVoiceDSP.swift",
    "WhitegramVoiceSliderItem.swift": "submodules/SettingsUI/Sources/WhitegramVoiceSliderItem.swift",
    "WhitegramVoiceSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramVoiceSettingsController.swift",
}

RECORDER = "submodules/TelegramUI/Sources/ManagedAudioRecorder.swift"
ENCODER = "submodules/OpusBinding/Sources/opusenc/opusenc.m"
CHAT = "submodules/TelegramUI/Sources/Chat/ChatControllerMediaRecording.swift"
FEATURE = "voice-message-local-pcm"

PROCESSOR_ANCHOR = "    private var audioBuffer = Data()\n"
PROCESSOR_PROPERTY = (
    "    private let whitegramVoiceProcessor = WhitegramVoiceProcessor(\n"
    "        settings: WhitegramVoiceSettings(values: WhitegramPreferences.values()),\n"
    "        sampleRate: 48000.0\n"
    "    )\n"
)
FRAME_ANCHOR = (
    "                self.processWaveformPreview(samples: currentEncoderPacket.assumingMemoryBound(to: Int16.self), count: currentEncoderPacketSize / 2)\n"
)
FRAME_HOOK = (
    "                self.whitegramVoiceProcessor.process(UnsafeMutableBufferPointer(\n"
    "                    start: currentEncoderPacket.assumingMemoryBound(to: Int16.self),\n"
    "                    count: currentEncoderPacketSize / MemoryLayout<Int16>.size\n"
    "                ))\n"
)
RESUME_ANCHOR = "    func resume() {\n        assert(self.queue.isCurrent())\n"
RESUME_HOOK = "        self.whitegramVoiceProcessor.reset()\n"


def _validate_pcm_contract(patches: SourcePatches) -> None:
    """Reject source drift before writing, including encoder/sample-rate drift."""
    contracts = {
        RECORDER: (
            "import TelegramCore\n",
            "    canonicalBasicStreamDescription.mChannelsPerFrame = 1\n",
            "    canonicalBasicStreamDescription.mBitsPerChannel = 16\n",
            "    canonicalBasicStreamDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked\n",
            "        var audioStreamDescription = audioRecorderNativeStreamDescription(sampleRate: 48000)\n",
            "        let millisecondsPerPacket = 60\n        let encoderPacketSizeInBytes = 16000 / 1000 * millisecondsPerPacket * 2\n",
            "                self.oggWriter.writeFrame(currentEncoderPacket.assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(currentEncoderPacketSize))\n",
        ),
        ENCODER: (
            "        rate = 48000;\n        coding_rate = 48000;\n        frame_size = 960;\n",
            "        nb_samples = (opus_int32)(frameByteCount / 2);\n",
            "        nbBytes = opus_encode(_encoder, (opus_int16 *)paddedFrameBytes, cur_frame_size, _packet, max_frame_bytes / 10);\n",
        ),
        CHAT: (
            "                self.context.sharedContext.mediaManager.audioRecorder(\n",
            "data: data.compressedData)",
        ),
    }
    for path, anchors in contracts.items():
        value = patches.read(path)
        for anchor in anchors:
            expected = 2 if path == CHAT and anchor == "data: data.compressedData)" else 1
            found = value.count(anchor)
            if found != expected:
                raise ValueError(f"{FEATURE}: {path}: PCM contract expected {expected} anchors, found {found}: {anchor!r}")


def apply_voice_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    _validate_pcm_contract(patches)
    patches.replace(FEATURE, RECORDER, PROCESSOR_ANCHOR, PROCESSOR_ANCHOR + PROCESSOR_PROPERTY, count=1)
    patches.replace(FEATURE, RECORDER, FRAME_ANCHOR, FRAME_HOOK + FRAME_ANCHOR, count=1)
    patches.replace(FEATURE, RECORDER, RESUME_ANCHOR, RESUME_ANCHOR + RESUME_HOOK, count=1)
    return patches.write()
