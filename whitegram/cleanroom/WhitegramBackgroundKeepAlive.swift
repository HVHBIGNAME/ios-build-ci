import AVFoundation
import Foundation
import SwiftSignalKit
import TelegramAudio
import TelegramCore
import UIKit

final class WhitegramBackgroundKeepAlive {
    private enum AudioOwnership { case none, requested, active, yielded, releasing }
    private let audioSession: ManagedAudioSession
    private let activityUpdated: (Bool) -> Void
    private let activeDisposable = MetaDisposable()
    private var observers: [NSObjectProtocol] = []
    private var sessionDisposable: Disposable?
    private var player: AVAudioPlayer?
    private var timer: Foundation.Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var inBackground: Bool
    private var interrupted = false
    private var expired = false
    private var audioActive = true
    private var audioOwnership: AudioOwnership = .none
    private var retryAfter: TimeInterval = 0
    private var generation: UInt64 = 0
    private var activity = false

    init(audioSession: ManagedAudioSession, activityUpdated: @escaping (Bool) -> Void) {
        self.audioSession = audioSession
        self.activityUpdated = activityUpdated
        self.inBackground = UIApplication.shared.applicationState != .active
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            self.observe(name) { owner, _ in owner.inBackground = true; owner.refresh() }
        }
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification] {
            self.observe(name) { owner, _ in
                owner.inBackground = false
                owner.interrupted = false
                owner.expired = false
                owner.retryAfter = 0
                owner.refresh()
            }
        }
        self.observe(UIApplication.willTerminateNotification) { owner, _ in owner.inBackground = false; owner.refresh() }
        self.observe(WhitegramPreferences.updatedNotification) { owner, _ in owner.refresh() }
        self.observe(AVAudioSession.interruptionNotification) { owner, notification in owner.interruption(notification) }
        self.observe(AVAudioSession.mediaServicesWereResetNotification) { owner, _ in owner.releaseAudio(); owner.refresh() }
        self.observe(AVAudioSession.routeChangeNotification) { owner, _ in owner.refresh() }
        self.activeDisposable.set((audioSession.isActive() |> deliverOnMainQueue).start(next: { [weak self] active in
            guard let self else { return }
            self.audioActive = active
            if !active && self.audioOwnership == .releasing { self.audioOwnership = .none }
            self.refresh()
        }))
    }

    deinit {
        self.activeDisposable.dispose()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        self.timer?.invalidate()
        self.player?.stop()
        self.sessionDisposable?.dispose()
        if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask) }
        if self.activity { self.activityUpdated(false) }
    }

    private var enabled: Bool {
        return WhitegramNotificationSettings.current.keepAlive(isInBackground: self.inBackground) && !self.interrupted && !self.expired
    }

    private func observe(_ name: Notification.Name, action: @escaping (WhitegramBackgroundKeepAlive, Notification) -> Void) {
        self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            if let self { action(self, notification) }
        })
    }

    private func refresh() {
        if !self.enabled {
            self.timer?.invalidate()
            self.timer = nil
            self.releaseAudio()
            self.updateActivity()
            return
        }
        if self.timer == nil {
            let timer = Foundation.Timer(timeInterval: 15.0, repeats: true) { [weak self] _ in self?.refresh() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if self.sessionDisposable == nil {
            if !self.audioActive && Date.timeIntervalSinceReferenceDate >= self.retryAfter { self.acquireAudio() }
        } else if self.audioOwnership == .active && self.player?.isPlaying != true {
            self.startPlayer()
        }
        self.updateActivity()
    }

    private func acquireAudio() {
        self.audioOwnership = .requested
        self.generation &+= 1
        let generation = self.generation
        self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WhitegramNotifications") { [weak self] in
            guard let self, self.generation == generation else { return }
            self.expired = true
            self.refresh()
        }
        self.sessionDisposable = self.audioSession.push(audioSessionType: .play(mixWithOthers: true),
            activateImmediately: true, manualActivate: { [weak self] control in
                control.setupAndActivate { _ in
                    DispatchQueue.main.async {
                        guard let self, self.generation == generation, self.enabled else { return }
                        self.audioOwnership = .active
                        self.startPlayer()
                        self.updateActivity()
                    }
                }
            }, deactivate: { [weak self] _ in
                return Signal { subscriber in
                    DispatchQueue.main.async {
                        if let self, self.generation == generation {
                            self.audioOwnership = .yielded
                            self.player?.stop()
                            self.player = nil
                            self.endBackgroundTask()
                            self.updateActivity()
                        }
                        subscriber.putCompletion()
                    }
                    return EmptyDisposable
                }
            })
    }

    private func startPlayer() {
        do {
            let player = try AVAudioPlayer(data: WhitegramSilentAudio.waveData(), fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0.0
            guard player.prepareToPlay(), player.play() else {
                throw NSError(domain: "WhitegramBackgroundKeepAlive", code: 1)
            }
            self.player = player
            self.endBackgroundTask()
        } catch {
            NSLog("Whitegram: background audio could not start (%ld)", (error as NSError).code)
            self.retryAfter = Date.timeIntervalSinceReferenceDate + 15.0
            self.releaseAudio()
        }
    }

    private func releaseAudio() {
        self.generation &+= 1
        self.player?.stop()
        self.player = nil
        if self.sessionDisposable != nil { self.audioOwnership = self.audioActive ? .releasing : .none }
        let disposable = self.sessionDisposable
        self.sessionDisposable = nil
        disposable?.dispose()
        self.endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard self.backgroundTask != .invalid else { return }
        let task = self.backgroundTask
        self.backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func updateActivity() {
        let hasAudio: Bool
        switch self.audioOwnership {
        case .active: hasAudio = self.player?.isPlaying == true
        case .none, .yielded: hasAudio = self.audioActive
        case .requested, .releasing: hasAudio = false
        }
        let active = self.enabled && hasAudio
        if active != self.activity {
            self.activity = active
            self.activityUpdated(active)
        }
    }

    private func interruption(_ notification: Notification) {
        guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            self.interrupted = true
        } else {
            let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            self.interrupted = !AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
        }
        self.refresh()
    }
}
