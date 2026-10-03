import Foundation

/// Pure timing policy, shared by the native overlap adapter and its regressions.
public struct WhitegramPlayerFadeEnvelope {
    private let duration: Double
    private var elapsed = 0.0
    private var playingSince: Double?
    public private(set) var hasStarted = false

    public init(duration: Double) {
        self.duration = duration.isFinite ? max(0, duration) : 0
    }

    public mutating func setPlaying(_ playing: Bool, at time: Double) {
        guard time.isFinite else { return }
        if let since = self.playingSince { self.elapsed += max(0, time - since) }
        self.playingSince = playing ? time : nil
        self.hasStarted = self.hasStarted || playing
    }

    public func gains(at time: Double) -> (outgoing: Double, incoming: Double) {
        guard self.hasStarted else { return (1, 0) }
        let interval = self.playingSince.map { time.isFinite ? max(0, time - $0) : 0 } ?? 0
        let progress = self.duration > 0 ? (self.elapsed + interval) / self.duration : 1
        let gains = WhitegramPlayerSettings.crossfadeGains(progress: progress)
        // Buffering must not leave the still-playing outgoing track attenuated.
        return (self.playingSince == nil ? 1 : gains.outgoing, gains.incoming)
    }
}
