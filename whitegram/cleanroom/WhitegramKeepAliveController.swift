import Foundation

protocol WhitegramKeepAlivePlayer: AnyObject {
    var isPlaying: Bool { get }
    func play() -> Bool
    func pause()
    func stop()
}

protocol WhitegramKeepAliveEnvironment: AnyObject {
    var otherAudioPlaying: Bool { get }
    var managedAudioActive: Bool { get }
    func requestManagedAudio(mixWithOthers: Bool, activated: @escaping () -> Void,
                             deactivated: @escaping () -> Void) -> () -> Void
    func activateDirectAudio(mixWithOthers: Bool) throws
    func deactivateDirectAudio()
    func makePlayer(volume: Float, stopped: @escaping () -> Void) throws -> WhitegramKeepAlivePlayer
    func schedule(after seconds: TimeInterval, repeating: Bool, _ action: @escaping () -> Void) -> () -> Void
    func beginBackgroundTask(expired: @escaping () -> Void) -> (() -> Void)?
}

// WGPersistentNotificationKeepAlive and WGBackgroundKeepAlive have different owners and timers.
final class WhitegramKeepAliveController {
    enum Mode { case persistent, recovery }
    private enum Ownership { case none, requested, active, yielded }
    private let mode: Mode
    private let environment: WhitegramKeepAliveEnvironment
    private var wantsRunning = false
    private var blocked = false
    private var interrupted = false
    private var ownership: Ownership = .none
    private var player: WhitegramKeepAlivePlayer?
    private var cancelSession: (() -> Void)?
    private var cancelTimer: (() -> Void)?
    private var cancelFallback: (() -> Void)?
    private var endBackgroundTask: (() -> Void)?
    private var generation: UInt64 = 0
    private var playerGeneration: UInt64 = 0
    private var backgroundGeneration: UInt64 = 0
    private var usesMixedPlayback = false
    private var directAudioActive = false

    init(mode: Mode, environment: WhitegramKeepAliveEnvironment) {
        self.mode = mode
        self.environment = environment
    }

    deinit {
        self.stop()
    }

    var hasManagedRequest: Bool { return self.cancelSession != nil }

    private var shouldRun: Bool { return self.wantsRunning && !self.blocked && !self.interrupted }

    func update(wantsRunning: Bool, blocked: Bool) {
        self.wantsRunning = wantsRunning
        self.blocked = blocked
        if !wantsRunning { self.interrupted = false }
        guard self.shouldRun else {
            self.stop()
            return
        }
        if self.cancelTimer == nil {
            let generation = self.generation
            self.cancelTimer = self.environment.schedule(after: self.mode == .persistent ? 1.0 : 15.0, repeating: true) { [weak self] in
                guard let self, self.generation == generation else { return }
                self.checkPlayback()
            }
        }
        self.start()
    }

    func interruptionBegan() {
        self.interrupted = true
        self.stop()
    }

    func interruptionEnded() {
        self.interrupted = false
        self.update(wantsRunning: self.wantsRunning, blocked: self.blocked)
    }

    func mediaServicesReset() {
        self.stop()
        self.interrupted = false
        self.update(wantsRunning: self.wantsRunning, blocked: self.blocked)
    }

    func secondaryAudioChanged() {
        guard self.mode == .persistent, self.shouldRun, self.ownership != .yielded,
              self.usesMixedPlayback != self.environment.otherAudioPlaying else { return }
        self.stopPlayer()
        self.startDirect()
    }

    private func start() {
        guard self.shouldRun, self.player?.isPlaying != true else { return }
        if self.mode == .recovery {
            self.startDirect()
            return
        }
        self.ensureBackgroundTask()
        if self.cancelSession == nil {
            self.ownership = .requested
            self.usesMixedPlayback = self.environment.otherAudioPlaying
            let generation = self.generation
            self.cancelSession = self.environment.requestManagedAudio(mixWithOthers: self.usesMixedPlayback, activated: { [weak self] in
                guard let self, self.generation == generation, self.shouldRun else { return }
                self.ownership = .active
                self.startPlayer()
            }, deactivated: { [weak self] in
                guard let self, self.generation == generation else { return }
                self.ownership = .yielded
                self.player?.pause()
            })
        } else if self.ownership == .active {
            self.startPlayer()
        }
        self.ensureFallback()
    }

    private func ensureFallback() {
        guard self.cancelFallback == nil, self.ownership != .yielded, self.player?.isPlaying != true else { return }
        let generation = self.generation
        self.cancelFallback = self.environment.schedule(after: 1.5, repeating: false) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.cancelFallback = nil
            if self.player?.isPlaying != true { self.startDirect() }
        }
    }

    private func checkPlayback() {
        guard self.shouldRun, self.player?.isPlaying != true else { return }
        self.stopPlayer()
        self.start()
    }

    private func startDirect() {
        guard self.shouldRun, self.ownership != .yielded,
              !self.environment.managedAudioActive || self.ownership == .active else { return }
        do {
            let mix = self.mode == .recovery || self.environment.otherAudioPlaying
            try self.environment.activateDirectAudio(mixWithOthers: mix)
            self.directAudioActive = true
            self.usesMixedPlayback = mix
            self.startPlayer()
            if self.mode == .recovery && self.player?.isPlaying != true && !self.environment.managedAudioActive {
                self.environment.deactivateDirectAudio()
                self.directAudioActive = false
            }
        } catch {
            self.log(error)
        }
    }

    private func startPlayer() {
        guard self.shouldRun, self.ownership != .yielded, self.player?.isPlaying != true else { return }
        do {
            if self.player == nil {
                let generation = self.generation
                let playerGeneration = self.playerGeneration
                self.player = try self.environment.makePlayer(volume: self.mode == .persistent ? 0.03 : 0.0, stopped: { [weak self] in
                    guard let self, self.generation == generation, self.playerGeneration == playerGeneration else { return }
                    self.stopPlayer()
                    // Retry on the watchdog rather than recursively from an AVAudioPlayer callback.
                })
            }
            if self.player?.play() != true {
                self.stopPlayer()
                self.log(NSError(domain: "WhitegramKeepAlive", code: 1))
            }
        } catch {
            self.log(error)
        }
    }

    private func ensureBackgroundTask() {
        guard self.endBackgroundTask == nil else { return }
        self.backgroundGeneration &+= 1
        let generation = self.backgroundGeneration
        self.endBackgroundTask = self.environment.beginBackgroundTask { [weak self] in
            guard let self, self.backgroundGeneration == generation else { return }
            self.finishBackgroundTask()
            if self.shouldRun { self.ensureBackgroundTask() }
        }
    }

    private func finishBackgroundTask() {
        self.backgroundGeneration &+= 1
        let end = self.endBackgroundTask
        self.endBackgroundTask = nil
        end?()
    }

    private func stopPlayer() {
        self.playerGeneration &+= 1
        let player = self.player
        self.player = nil
        player?.stop()
    }

    private func stop() {
        self.generation &+= 1
        self.cancelTimer?()
        self.cancelTimer = nil
        self.cancelFallback?()
        self.cancelFallback = nil
        self.stopPlayer()
        let cancelSession = self.cancelSession
        self.cancelSession = nil
        self.ownership = .none
        cancelSession?()
        if self.directAudioActive && cancelSession == nil && !self.environment.managedAudioActive {
            self.environment.deactivateDirectAudio()
        }
        self.directAudioActive = false
        self.finishBackgroundTask()
    }

    private func log(_ error: Error) {
        NSLog("Whitegram: background audio could not start (%ld)", (error as NSError).code)
    }
}
