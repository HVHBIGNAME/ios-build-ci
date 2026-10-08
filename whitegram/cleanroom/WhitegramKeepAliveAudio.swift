import AVFoundation
import Foundation
import SwiftSignalKit
import TelegramAudio
import UIKit

final class WhitegramKeepAliveAudio: WhitegramKeepAliveEnvironment {
    let audioSession: ManagedAudioSession
    var managedAudioActive = true

    init(audioSession: ManagedAudioSession) {
        self.audioSession = audioSession
    }

    var otherAudioPlaying: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.isOtherAudioPlaying || session.secondaryAudioShouldBeSilencedHint
    }

    func requestManagedAudio(mixWithOthers: Bool, activated: @escaping () -> Void,
                             deactivated: @escaping () -> Void) -> () -> Void {
        let activationGeneration = Atomic<UInt64>(value: 0)
        let disposable = self.audioSession.push(audioSessionType: .play(mixWithOthers: mixWithOthers),
            activateImmediately: true, manualActivate: { control in
                let generation = activationGeneration.modify { $0 &+ 1 }
                control.setupAndActivate { _ in
                    DispatchQueue.main.async {
                        if activationGeneration.with({ $0 }) == generation { activated() }
                    }
                }
            }, deactivate: { _ in
                let _ = activationGeneration.modify { $0 &+ 1 }
                return Signal { subscriber in
                    DispatchQueue.main.async {
                        deactivated()
                        subscriber.putCompletion()
                    }
                    return EmptyDisposable
                }
            })
        return {
            let _ = activationGeneration.modify { $0 &+ 1 }
            disposable.dispose()
        }
    }

    func activateDirectAudio(mixWithOthers: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: mixWithOthers ? [.mixWithOthers] : [])
        try session.setActive(true)
    }

    func deactivateDirectAudio() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            NSLog("Whitegram: background audio could not deactivate (%ld)", (error as NSError).code)
        }
    }

    func makePlayer(volume: Float, stopped: @escaping () -> Void) throws -> WhitegramKeepAlivePlayer {
        return try SilentPlayer(volume: volume, stopped: stopped)
    }

    func schedule(after seconds: TimeInterval, repeating: Bool, _ action: @escaping () -> Void) -> () -> Void {
        let timer = Foundation.Timer(timeInterval: seconds, repeats: repeating) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    func beginBackgroundTask(expired: @escaping () -> Void) -> (() -> Void)? {
        let task = UIApplication.shared.beginBackgroundTask(withName: "WhitegramPersistentNotifications", expirationHandler: expired)
        guard task != .invalid else { return nil }
        return { UIApplication.shared.endBackgroundTask(task) }
    }
}

private final class SilentPlayer: NSObject, WhitegramKeepAlivePlayer, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private let stopped: () -> Void

    init(volume: Float, stopped: @escaping () -> Void) throws {
        self.player = try AVAudioPlayer(data: WhitegramSilentAudio.waveData(), fileTypeHint: AVFileType.wav.rawValue)
        self.stopped = stopped
        super.init()
        self.player.delegate = self
        self.player.numberOfLoops = -1
        self.player.volume = volume
        guard self.player.prepareToPlay() else { throw NSError(domain: "WhitegramKeepAlive", code: 2) }
    }

    var isPlaying: Bool { return self.player.isPlaying }
    func play() -> Bool { return self.player.play() }
    func pause() { self.player.pause() }
    func stop() { self.player.delegate = nil; self.player.stop() }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async(execute: self.stopped)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async(execute: self.stopped)
    }
}
