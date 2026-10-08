import AVFoundation
import Foundation
import SwiftSignalKit
import TelegramAudio
import TelegramCore
import UIKit

final class WhitegramBackgroundKeepAlive {
    private let audio: WhitegramKeepAliveAudio
    private let persistent: WhitegramKeepAliveController
    private let recovery: WhitegramKeepAliveController
    private let activityUpdated: (Bool) -> Void
    private let audioDisposable = MetaDisposable()
    private let playbackDisposable = MetaDisposable()
    private let callsDisposable = MetaDisposable()
    private var observers: [NSObjectProtocol] = []
    private var inBackground: Bool
    private var ownAudioActive = false
    private var callsActive = false
    private var activity = false

    init(audioSession: ManagedAudioSession, ownAudioActive: Signal<Bool, NoError>,
         callsActive: Signal<Bool, NoError>, activityUpdated: @escaping (Bool) -> Void) {
        self.audio = WhitegramKeepAliveAudio(audioSession: audioSession)
        self.persistent = WhitegramKeepAliveController(mode: .persistent, environment: self.audio)
        self.recovery = WhitegramKeepAliveController(mode: .recovery, environment: self.audio)
        self.activityUpdated = activityUpdated
        self.inBackground = UIApplication.shared.applicationState != .active
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            self.observe(name) { owner, _ in owner.inBackground = true; owner.refresh() }
        }
        for name in [UIApplication.willEnterForegroundNotification, UIApplication.didBecomeActiveNotification, UIApplication.willTerminateNotification] {
            self.observe(name) { owner, _ in owner.inBackground = false; owner.refresh() }
        }
        self.observe(WhitegramPreferences.updatedNotification) { owner, _ in owner.refresh() }
        self.observe(AVAudioSession.interruptionNotification) { owner, notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                owner.persistent.interruptionBegan()
                owner.recovery.interruptionBegan()
            } else {
                owner.persistent.interruptionEnded()
                owner.recovery.interruptionEnded()
            }
        }
        self.observe(AVAudioSession.mediaServicesWereResetNotification) { owner, _ in
            owner.persistent.mediaServicesReset()
            owner.recovery.mediaServicesReset()
        }
        self.observe(AVAudioSession.silenceSecondaryAudioHintNotification) { owner, _ in owner.persistent.secondaryAudioChanged() }
        self.audioDisposable.set((audioSession.isActive() |> deliverOnMainQueue).start(next: { [weak self] active in
            guard let self else { return }
            self.audio.managedAudioActive = active
            self.refresh()
        }))
        self.playbackDisposable.set((ownAudioActive |> distinctUntilChanged |> deliverOnMainQueue).start(next: { [weak self] active in
            guard let self else { return }
            self.ownAudioActive = active
            self.refresh()
        }))
        self.callsDisposable.set((callsActive |> distinctUntilChanged |> deliverOnMainQueue).start(next: { [weak self] active in
            guard let self else { return }
            self.callsActive = active
            self.refresh()
        }))
        self.refresh()
    }

    deinit {
        self.audioDisposable.dispose()
        self.playbackDisposable.dispose()
        self.callsDisposable.dispose()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
        self.recovery.update(wantsRunning: false, blocked: false)
        self.persistent.update(wantsRunning: false, blocked: false)
        if self.activity { self.activityUpdated(false) }
    }

    private func observe(_ name: Notification.Name, action: @escaping (WhitegramBackgroundKeepAlive, Notification) -> Void) {
        self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            if let self { action(self, notification) }
        })
    }

    private func refresh() {
        let wantsRunning = WhitegramNotificationSettings.current.keepAlive(isInBackground: self.inBackground)
        let ownAudio = self.ownAudioActive || self.callsActive
        self.recovery.update(wantsRunning: wantsRunning, blocked: self.audio.managedAudioActive || ownAudio)
        self.persistent.update(wantsRunning: wantsRunning,
            blocked: ownAudio || (self.audio.managedAudioActive && !self.persistent.hasManagedRequest))
        // The original wgWantsBackgroundConnection follows the settings, including during audio recovery.
        if self.activity != wantsRunning {
            self.activity = wantsRunning
            self.activityUpdated(wantsRunning)
        }
    }
}
