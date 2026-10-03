"""Exact Telegram 12.9.2 voice-message PCM hooks; runtime copying is parent-owned."""

from pathlib import Path

from source_patches import SourcePatches


VOICE_RUNTIME_FILES = {
    "WhitegramVoiceSettings.swift": "submodules/TelegramCore/Sources/WhitegramVoiceSettings.swift",
    "WhitegramVoiceDSP.swift": "submodules/TelegramCore/Sources/WhitegramVoiceDSP.swift",
    "WhitegramVoiceBleep.swift": "submodules/TelegramCore/Sources/WhitegramVoiceBleep.swift",
    "WhitegramVoiceProfanityStore.swift": "submodules/TelegramCore/Sources/WhitegramVoiceProfanityStore.swift",
    "WhitegramVoiceCredentials.swift": "submodules/TelegramCore/Sources/WhitegramVoiceCredentials.swift",
    "WhitegramVoiceRemote.swift": "submodules/TelegramCore/Sources/WhitegramVoiceRemote.swift",
    "WhitegramVoiceHTTP.swift": "submodules/TelegramCore/Sources/WhitegramVoiceHTTP.swift",
    "WhitegramVoiceAudioFile.swift": "submodules/TelegramCore/Sources/WhitegramVoiceAudioFile.swift",
    "WhitegramVoiceSpeech.swift": "submodules/TelegramCore/Sources/WhitegramVoiceSpeech.swift",
    "WhitegramVoicePostprocessor.swift": "submodules/TelegramCore/Sources/WhitegramVoicePostprocessor.swift",
    "WhitegramVoiceVideo.swift": "submodules/TelegramCore/Sources/WhitegramVoiceVideo.swift",
    "WhitegramVoiceChat.swift": "submodules/TelegramUI/Sources/WhitegramVoiceChat.swift",
    "WhitegramVoiceCallProcessor.swift": "submodules/TelegramVoip/Sources/WhitegramVoiceCallProcessor.swift",
    "WhitegramVoiceSliderItem.swift": "submodules/SettingsUI/Sources/WhitegramVoiceSliderItem.swift",
    "WhitegramVoiceSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramVoiceSettingsController.swift",
    "WhitegramVoiceRemoteSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramVoiceRemoteSettingsController.swift",
    "WhitegramVoiceFileController.swift": "submodules/SettingsUI/Sources/WhitegramVoiceFileController.swift",
}

VOICE_REQUIRED_DEPENDENCIES = {
    "TelegramCore": ["//submodules/OpusBinding:OpusBinding", "//submodules/AudioWaveform:AudioWaveform"],
    "TelegramVoip": ["//submodules/TelegramCore:TelegramCore"],
    "TelegramUI": ["//submodules/PresentationDataUtils:PresentationDataUtils"],
    "SettingsUI": ["//submodules/PresentationDataUtils:PresentationDataUtils"],
}

RECORDER = "submodules/TelegramUI/Sources/ManagedAudioRecorder.swift"
ENCODER = "submodules/OpusBinding/Sources/opusenc/opusenc.m"
CHAT = "submodules/TelegramUI/Sources/Chat/ChatControllerMediaRecording.swift"
FEATURE = "voice-message-local-pcm"
OPUS_HEADER = "submodules/OpusBinding/PublicHeaders/OpusBinding/OggOpusReader.h"
OPUS_READER = "submodules/OpusBinding/Sources/OggOpusReader.m"
CALL = "submodules/TelegramVoip/Sources/OngoingCallContext.swift"
CALL_HEADER = "submodules/TgVoipWebrtc/PublicHeaders/TgVoipWebrtc/OngoingCallThreadLocalContext.h"
CALL_NATIVE = "submodules/TgVoipWebrtc/Sources/OngoingCallThreadLocalContext.mm"
VIDEO = "submodules/TelegramUI/Components/VideoMessageCameraScreen/Sources/VideoMessageCameraScreen.swift"

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


def _patch_pcm(patches: SourcePatches) -> None:
    _validate_pcm_contract(patches)
    patches.replace(FEATURE, RECORDER, PROCESSOR_ANCHOR, PROCESSOR_ANCHOR + PROCESSOR_PROPERTY, count=1)
    patches.replace(FEATURE, RECORDER, FRAME_ANCHOR, FRAME_HOOK + FRAME_ANCHOR, count=1)
    patches.replace(FEATURE, RECORDER, RESUME_ANCHOR, RESUME_ANCHOR + RESUME_HOOK, count=1)


def _patch_postprocessing(patches: SourcePatches) -> None:
    feature = "voice-selective-bleep-and-remote-send"
    patches.replace(feature, OPUS_HEADER, "- (int32_t)read:(void *)pcmData bufSize:(int)bufSize;\n", "- (int32_t)read:(void *)pcmData bufSize:(int)bufSize;\n@property (nonatomic, readonly) int32_t whitegramChannelCount;\n")
    patches.replace(feature, OPUS_READER, "+ (NSArray<OggOpusFrame *> * _Nullable)extractFrames:(NSData *)data {\n", """- (int32_t)whitegramChannelCount {
    return op_channel_count(_opusFile, -1);
}

+ (NSArray<OggOpusFrame *> * _Nullable)extractFrames:(NSData *)data {
""")
    patches.replace(feature, CHAT, """                self.recorderDataDisposable.set((audioRecorderValue.takenRecordedData()
                |> deliverOnMainQueue).startStrict(next: { [weak self] data in
""", """                self.recorderDataDisposable.set((audioRecorderValue.takenRecordedData()
                |> deliverOnMainQueue
                |> mapToSignal { [weak self] data -> Signal<RecordedAudioData?, NoError> in
                    guard let self else { return .single(nil) }
                    return self.whitegramPrepareRecordedAudio(data)
                }
                |> deliverOnMainQueue).startStrict(next: { [weak self] data in
""")
    patches.replace(feature, CHAT, """        postpone: Bool = false
    ) {
""", """        postpone: Bool = false,
        whitegramProcessedAudio: ChatInterfaceMediaDraftState.Audio? = nil
    ) {
""")
    patches.replace(feature, CHAT, "        switch recordedMediaPreview {\n", """        let effectivePreview: ChatInterfaceMediaDraftState = whitegramProcessedAudio.map { .audio($0) } ?? recordedMediaPreview
        switch effectivePreview {
""")
    patches.replace(feature, CHAT, """                    self.interfaceInteraction?.displaySlowmodeTooltip(self.chatDisplayNode.view, rect)
                }
                return
            }
""", """                    self.interfaceInteraction?.displaySlowmodeTooltip(self.chatDisplayNode.view, rect)
                }
                return
            }
            if whitegramProcessedAudio == nil && self.whitegramPrepareAudioDraft(audio, completion: { [weak self] processed in
                self?.sendMediaRecording(silentPosting: silentPosting, scheduleTime: scheduleTime, repeatPeriod: repeatPeriod, viewOnce: viewOnce, messageEffect: messageEffect, postpone: postpone, whitegramProcessedAudio: processed)
            }) {
                return
            }
""")


def apply_voice_pcm_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    _patch_pcm(patches)
    return patches.write()


def _patch_calls(patches: SourcePatches) -> None:
    feature = "voice-outgoing-call-pcm"
    patches.replace(feature, CALL, """    public final class AudioDevice {
        let impl: SharedCallAudioDevice
""", """    public final class AudioDevice {
        let impl: SharedCallAudioDevice
        private let whitegramVoiceEffects = WhitegramVoiceCallProcessor()
""")
    patches.replace(feature, CALL, """        private init(impl: SharedCallAudioDevice) {
            self.impl = impl
""", """        private init(impl: SharedCallAudioDevice) {
            self.impl = impl
            impl.setWhitegramAudioInputProcessor { [processor = self.whitegramVoiceEffects] samples, frames, channels, sampleRate in
                processor.process(samples, frames: frames, channels: channels, sampleRate: sampleRate)
            }
""")
    patches.replace(feature, CALL, """        public func setIsAudioSessionActive(_ isActive: Bool) {
            self.impl.setManualAudioSessionIsActive(isActive)
""", """        public func setIsAudioSessionActive(_ isActive: Bool) {
            if !isActive { self.whitegramVoiceEffects.reset() }
            self.impl.setManualAudioSessionIsActive(isActive)
""")
    patches.replace(feature, CALL_HEADER, """@interface SharedCallAudioDevice : NSObject

""", """@interface SharedCallAudioDevice : NSObject

- (void)setWhitegramAudioInputProcessor:(void (^ _Nullable)(int16_t * _Nonnull samples, int32_t frames, int32_t channels, int32_t sampleRate))processor;

""")
    patches.replace(feature, CALL_NATIVE, """    virtual ~WrappedAudioDeviceModuleIOS() {
        ActualStop();
    }
""", """    virtual ~WrappedAudioDeviceModuleIOS() {
        ActualStop();
    }

    void SetWhitegramAudioInputProcessor(void (^processor)(int16_t *, int32_t, int32_t, int32_t)) {
        _mutex.Lock();
        _whitegramAudioInputProcessor = [processor copy];
        _mutex.Unlock();
    }

    const void *ProcessWhitegramInput(const void *samples, size_t frames, size_t bytesPerSample, size_t channels, uint32_t rate) {
        if (!_whitegramAudioInputProcessor || !samples || frames == 0 || frames > 3840 || channels < 1 || channels > 2 ||
            (bytesPerSample != sizeof(int16_t) && bytesPerSample != sizeof(int16_t) * channels)) {
            return samples;
        }
        memcpy(_whitegramInputSamples, samples, frames * channels * sizeof(int16_t));
        _whitegramAudioInputProcessor(_whitegramInputSamples, (int32_t)frames, (int32_t)channels, (int32_t)rate);
        return _whitegramInputSamples;
    }
""")
    patches.replace(feature, CALL_NATIVE, """        _mutex.Lock();
        if (!_audioTransports.empty()) {
            for (size_t i = 0; i < _audioTransports.size(); i++) {
                _audioTransports[i].first->RecordedDataIsAvailable(
                    audioSamples,
""", """        _mutex.Lock();
        const void *whitegramSamples = ProcessWhitegramInput(audioSamples, nSamples, nBytesPerSample, nChannels, samplesPerSec);
        if (!_audioTransports.empty()) {
            for (size_t i = 0; i < _audioTransports.size(); i++) {
                _audioTransports[i].first->RecordedDataIsAvailable(
                    whitegramSamples,
""", count=2)
    patches.replace(feature, CALL_NATIVE, "    std::vector<std::pair<webrtc::AudioTransport *, bool>> _audioTransports;\n", """    std::vector<std::pair<webrtc::AudioTransport *, bool>> _audioTransports;
    void (^_whitegramAudioInputProcessor)(int16_t *, int32_t, int32_t, int32_t) = nil;
    int16_t _whitegramInputSamples[3840 * 2];
""")
    patches.replace(feature, CALL_NATIVE, """- (std::shared_ptr<tgcalls::ThreadLocalObject<tgcalls::SharedAudioDeviceModule>>)getAudioDeviceModule {
""", """- (void)setWhitegramAudioInputProcessor:(void (^)(int16_t *, int32_t, int32_t, int32_t))processor {
    _audioDeviceModule->perform([processor](tgcalls::SharedAudioDeviceModule *audioDeviceModule) {
        #ifdef WEBRTC_IOS
        WrappedAudioDeviceModuleIOS *deviceModule = (WrappedAudioDeviceModuleIOS *)audioDeviceModule->audioDeviceModule().get();
        deviceModule->SetWhitegramAudioInputProcessor(processor);
        #endif
    });
}

- (std::shared_ptr<tgcalls::ThreadLocalObject<tgcalls::SharedAudioDeviceModule>>)getAudioDeviceModule {
""")


def _patch_video(patches: SourcePatches) -> None:
    feature = "voice-video-note-audio"
    patches.replace(feature, VIDEO, "    fileprivate var didSend = false\n", """    private let whitegramVoiceSettings = WhitegramVoiceSettings(values: WhitegramPreferences.values())
    private var whitegramVoiceTask: WhitegramVoiceTask?
    fileprivate var didSend = false
""")
    patches.replace(feature, VIDEO, "        self.allowLiveUpload = allowLiveUpload\n", "        self.allowLiveUpload = allowLiveUpload && !self.whitegramVoiceSettings.requiresVideoProcessing\n")
    patches.replace(feature, VIDEO, "    deinit {\n        self.audioSessionDisposable?.dispose()\n", "    deinit {\n        self.whitegramVoiceTask?.cancel()\n        self.audioSessionDisposable?.dispose()\n")
    patches.replace(feature, VIDEO, "    public func discardVideo() {\n", "    public func discardVideo() {\n        self.whitegramVoiceTask?.cancel()\n        self.whitegramVoiceTask = nil\n")
    patches.replace(feature, VIDEO, """            let _ = (thumbnailImage
            |> deliverOnMainQueue).startStandalone(next: { [weak self] thumbnailImage in
""", """            let whitegramFinish: (WhitegramVoiceProcessedVideo?) -> Void = { [weak self] whitegramVideo in
            let _ = (thumbnailImage
            |> deliverOnMainQueue).startStandalone(next: { [weak self] thumbnailImage in
""")
    patches.replace(feature, VIDEO, """                if !hasAdjustments, let liveUploadData, let data = try? Data(contentsOf: URL(fileURLWithPath: video.videoPath)) {
""", """                if let whitegramVideo {
                    resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max), size: Int64(whitegramVideo.data.count))
                    self.context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: whitegramVideo.data, synchronous: true)
                } else if !hasAdjustments, let liveUploadData, let data = try? Data(contentsOf: URL(fileURLWithPath: video.videoPath)) {
""")
    patches.replace(feature, VIDEO, """                ), silentPosting, scheduleTime, repeatPeriod)
            })
        })
    }
""", """                ), silentPosting, scheduleTime, repeatPeriod)
            })
            }
            if self.whitegramVoiceSettings.requiresVideoProcessing {
                self.whitegramVoiceTask = WhitegramVoiceVideo.process(urls: videoPaths.map { URL(fileURLWithPath: $0) }, settings: self.whitegramVoiceSettings, locale: self.context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }, trimRange: self.node.previewState?.trimRange) { [weak self] result in
                    guard let self else { return }
                    self.whitegramVoiceTask = nil
                    switch result {
                    case let .success(video):
                        whitegramFinish(video)
                    case let .failure(error):
                        self.didSend = false
                        self.isSendingImmediately = false
                        self.waitingForNextResult = false
                        self.node.transitioningToPreview = true
                        self.node.requestUpdateLayout(transition: .spring(duration: 0.3))
                        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
                        self.present(textAlertController(context: self.context, title: WhitegramLocalization.string("voice.failedTitle", baseLanguage: presentationData.strings.baseLanguageCode), text: error.localizedDescription, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})]), in: .window(.root))
                    }
                }
            } else {
                whitegramFinish(nil)
            }
        })
    }
""")


def voice_patches(patches: SourcePatches) -> None:
    _patch_pcm(patches)
    _patch_postprocessing(patches)
    _patch_calls(patches)
    _patch_video(patches)


def apply_voice_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    voice_patches(patches)
    return patches.write()
