import Foundation
import SwiftSignalKit
import TelegramAudio

/// A music playlist owns one underlying audio-session holder. Its two players
/// can overlap without interrupting each other or mixing with another app.
final class WhitegramPlayerAudioSession: ManagedAudioSession {
    private let base: ManagedAudioSession
    private let queue = Queue.mainQueue()
    private var clients: [UUID: ManagedAudioSessionClientParams] = [:]
    private var holder: Disposable?
    private var control: ManagedAudioSessionControl?

    init(base: ManagedAudioSession) {
        self.base = base
    }

    deinit {
        self.holder?.dispose()
    }

    func push(params: ManagedAudioSessionClientParams) -> Disposable {
        let id = UUID()
        self.queue.async {
            self.clients[id] = params
            if let control = self.control {
                params.manualActivate(control)
            } else if self.holder == nil {
                self.acquire(params)
            }
        }
        return ActionDisposable { [weak self] in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.clients.removeValue(forKey: id)
                if self.clients.isEmpty {
                    self.control = nil
                    self.holder?.dispose()
                    self.holder = nil
                }
            }
        }
    }

    private func acquire(_ params: ManagedAudioSessionClientParams) {
        self.holder = self.base.push(params: ManagedAudioSessionClientParams(
            audioSessionType: params.audioSessionType,
            outputMode: params.outputMode,
            once: false,
            activateImmediately: params.activateImmediately,
            manualActivate: { [weak self] control in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.control = control
                    for client in Array(self.clients.values) { client.manualActivate(control) }
                }
            },
            deactivate: { [weak self] temporary in
                return Signal { subscriber in
                    let disposable = MetaDisposable()
                    guard let self else {
                        subscriber.putCompletion()
                        return disposable
                    }
                    self.queue.async {
                        self.control = nil
                        let signals = self.clients.values.map { $0.deactivate(temporary) }
                        if signals.isEmpty {
                            subscriber.putCompletion()
                        } else {
                            disposable.set(combineLatest(signals).start(completed: { subscriber.putCompletion() }))
                        }
                    }
                    return disposable
                }
            },
            headsetConnectionStatusChanged: { [weak self] value in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    for client in Array(self.clients.values) { client.headsetConnectionStatusChanged(value) }
                }
            },
            availableOutputsChanged: { [weak self] outputs, current in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    for client in Array(self.clients.values) { client.availableOutputsChanged(outputs, current) }
                }
            }
        ))
    }

    func getIsHeadsetPluggedIn() -> Bool { return self.base.getIsHeadsetPluggedIn() }
    func headsetConnected() -> Signal<Bool, NoError> { return self.base.headsetConnected() }
    func isActive() -> Signal<Bool, NoError> { return self.base.isActive() }
    func isPlaybackActive() -> Signal<Bool, NoError> { return self.base.isPlaybackActive() }
    func isOtherAudioPlaying() -> Bool { return self.base.isOtherAudioPlaying() }
    func didActivateWithZeroVolume() -> Signal<Void, NoError> { return self.base.didActivateWithZeroVolume() }
    func dropAll() { self.base.dropAll() }
    func applyVoiceChatOutputModeInCurrentAudioSession(outputMode: AudioSessionOutputMode) { self.base.applyVoiceChatOutputModeInCurrentAudioSession(outputMode: outputMode) }
    func callKitActivatedAudioSession() { self.base.callKitActivatedAudioSession() }
    func callKitDeactivatedAudioSession() { self.base.callKitDeactivatedAudioSession() }
}
