import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ChatInterfaceState
import ChatPresentationInterfaceState
import AudioWaveform
import Display
import PresentationDataUtils

extension ChatControllerImpl {
    func whitegramPrepareRecordedAudio(_ data: RecordedAudioData?) -> Signal<RecordedAudioData?, NoError> {
        let settings = WhitegramVoiceSettings(values: WhitegramPreferences.values())
        guard let data, data.duration >= 0.5, settings.requiresPostprocessing else { return .single(data) }
        let locale = self.presentationData.strings.baseLanguageCode
        return Signal { [weak self] subscriber in
            let task = WhitegramVoicePostprocessor.process(data: data.compressedData, settings: settings, locale: locale, trimRange: data.trimRange) { result in
                switch result {
                case let .success(processed):
                    subscriber.putNext(RecordedAudioData(compressedData: processed.data, resumeData: nil, duration: processed.duration, waveform: processed.waveform, trimRange: nil))
                case let .failure(error):
                    if let self {
                        let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
                        self.context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: data.compressedData)
                        let waveform = AudioWaveform(bitstream: data.waveform ?? Data(), bitsPerSample: 5)
                        self.updateChatPresentationInterfaceState(animated: true, interactive: true, {
                            $0.updatedInterfaceState {
                                $0.withUpdatedMediaDraftState(.audio(ChatInterfaceMediaDraftState.Audio(resource: resource, fileSize: Int32(clamping: data.compressedData.count), duration: data.duration, waveform: waveform, trimRange: data.trimRange, resumeData: data.resumeData)))
                            }.updatedInputTextPanelState { $0.withUpdatedMediaRecordingState(nil) }
                        })
                        self.whitegramVoiceProcessingFailed(error)
                    }
                    subscriber.putNext(nil)
                }
                subscriber.putCompletion()
            }
            return ActionDisposable { task.cancel() }
        }
    }

    func whitegramPrepareAudioDraft(_ audio: ChatInterfaceMediaDraftState.Audio, completion: @escaping (ChatInterfaceMediaDraftState.Audio) -> Void) -> Bool {
        let settings = WhitegramVoiceSettings(values: WhitegramPreferences.values())
        guard settings.requiresPostprocessing else { return false }
        guard let path = self.context.engine.resources.completedResourcePath(id: EngineMediaResource.Id(audio.resource.id)) else {
            self.whitegramVoiceProcessingFailed(.invalidAudio)
            return true
        }
        let locale = self.presentationData.strings.baseLanguageCode
        let operation = MetaDisposable()
        self.recorderDataDisposable.set(operation)
        let cancelled = WhitegramVoiceTask()
        operation.set(ActionDisposable { cancelled.cancel() })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try cancelled.check()
                let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                let task = WhitegramVoicePostprocessor.process(data: data, settings: settings, locale: locale, trimRange: audio.trimRange) { [weak self] result in
                    guard !cancelled.isCancelled, let self,
                          case let .audio(current) = self.presentationInterfaceState.interfaceState.mediaDraftState,
                          current == audio else { return }
                    switch result {
                    case let .success(processed):
                        let resource = LocalFileMediaResource(fileId: Int64.random(in: Int64.min ... Int64.max))
                        self.context.engine.resources.storeResourceData(id: EngineMediaResource.Id(resource.id), data: processed.data)
                        completion(ChatInterfaceMediaDraftState.Audio(resource: resource, fileSize: Int32(clamping: processed.data.count), duration: processed.duration, waveform: AudioWaveform(bitstream: processed.waveform, bitsPerSample: 5), trimRange: nil, resumeData: nil))
                    case let .failure(error):
                        self.whitegramVoiceProcessingFailed(error)
                    }
                }
                cancelled.onCancel { task.cancel() }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard !cancelled.isCancelled else { return }
                    self?.whitegramVoiceProcessingFailed(.invalidAudio)
                }
            }
        }
        return true
    }

    private func whitegramVoiceProcessingFailed(_ error: WhitegramVoiceProcessingError) {
        self.recorderFeedback?.error()
        self.present(textAlertController(context: self.context, title: WhitegramLocalization.string("voice.failedTitle", baseLanguage: self.presentationData.strings.baseLanguageCode), text: error.localizedDescription, actions: [TextAlertAction(type: .defaultAction, title: self.presentationData.strings.Common_OK, action: {})]), in: .window(.root))
    }
}
