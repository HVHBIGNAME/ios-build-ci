import Foundation
import QuartzCore
import SwiftSignalKit
import TelegramCore
import UniversalMediaPlayer

/// Main-queue confined. Retains the outgoing decoder until its audible fade ends.
final class WhitegramPlayerCrossfade {
    private var outgoing: MediaPlayer?
    private var incoming: MediaPlayer?
    private var statusDisposable: Disposable?
    private var outgoingStatusDisposable: Disposable?
    private var timer: SwiftSignalKit.Timer?
    private var envelope = WhitegramPlayerFadeEnvelope(duration: 0)
    private var completion: (() -> Void)?

    var isActive: Bool { return self.incoming != nil }

    func setBaseRate(_ rate: Double) {
        self.outgoing?.setBaseRate(rate)
        self.incoming?.setBaseRate(rate)
    }

    deinit {
        self.cancel()
    }

    func start(outgoing: MediaPlayer, incoming: MediaPlayer, duration: Double, completion: @escaping () -> Void) {
        self.cancel()
        guard outgoing !== incoming, duration.isFinite, duration > 0 else {
            if outgoing !== incoming { outgoing.pause() }
            incoming.setVolume(1)
            completion()
            return
        }
        self.outgoing = outgoing
        self.incoming = incoming
        self.completion = completion
        self.envelope = WhitegramPlayerFadeEnvelope(duration: duration)
        incoming.setVolume(0)
        let timer = SwiftSignalKit.Timer(timeout: 0.02, repeat: true, completion: { [weak self] in
            guard let self else { return }
            let gains = self.envelope.gains(at: CACurrentMediaTime())
            self.outgoing?.setVolume(gains.outgoing)
            self.incoming?.setVolume(gains.incoming)
            if gains.incoming >= 1 { self.finish() }
        }, queue: .mainQueue())
        self.timer = timer
        timer.start()
        self.outgoingStatusDisposable = (outgoing.status |> deliverOnMainQueue).start(next: { [weak self] status in
            if case .paused = status.status { self?.finish() }
        })
        self.statusDisposable = (incoming.status |> deliverOnMainQueue).start(next: { [weak self] status in
            guard let self else { return }
            switch status.status {
            case .playing:
                self.envelope.setPlaying(true, at: CACurrentMediaTime())
            case .buffering:
                self.envelope.setPlaying(false, at: CACurrentMediaTime())
                self.outgoing?.setVolume(1)
            case .paused:
                if self.envelope.hasStarted { self.finish() }
            }
        })
    }

    private func finish() {
        let completion = self.completion
        self.cancel()
        completion?()
    }

    func cancel() {
        self.timer?.invalidate()
        self.timer = nil
        self.statusDisposable?.dispose()
        self.statusDisposable = nil
        self.outgoingStatusDisposable?.dispose()
        self.outgoingStatusDisposable = nil
        self.outgoing?.pause()
        self.outgoing = nil
        self.incoming?.setVolume(1)
        self.incoming = nil
        self.envelope = WhitegramPlayerFadeEnvelope(duration: 0)
        self.completion = nil
    }
}
