import CoreFoundation
import Foundation

public enum WhitegramPlayerEqualizerPreset: String, CaseIterable {
    case neutral, bass, treble, pop, rock, jazz, classical

    public var gains: [Float] {
        // TelegramUI 0xcb0d30; static Float arrays at 0x5e47ab8...0x5e47c48.
        switch self {
        case .neutral: return Array(repeating: 0, count: 10)
        case .bass: return [8, 6, 4, 2, 0, 0, 0, 0, 0, 0]
        case .treble: return [-2, -2, 0, 0, 0, 2, 4, 6, 6, 6]
        case .pop: return [-2, 0, 2, 4, 4, 2, 0, -2, -2, -2]
        case .rock: return [4, 2, -2, -4, -2, 2, 4, 6, 6, 4]
        case .jazz: return [2, 2, 0, -2, -2, 0, 2, 4, 4, 4]
        case .classical: return [0, 0, 0, 0, 0, 0, -2, -4, -4, -4]
        }
    }
}

public struct WhitegramPlayerSettings: Equatable {
    public static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let speedRange = 0.1 ... 3.0
    public static let gainRange = -12.0 ... 12.0

    public let speed: Double
    public let pitchFollowsSpeed: Bool
    public let crossfadeEnabled: Bool
    public let crossfadeDuration: Double
    public let equalizerEnabled: Bool
    public let bands: [Float]
    public let stopAfterVoiceMessage: Bool
    public let bassEffect: Bool
    public let customMusicCard: Bool

    public init(values: [String: Any]) {
        self.speed = Self.clamp(Self.number(values["musicPlaybackSpeed"]) ?? 1.0, to: Self.speedRange)
        self.pitchFollowsSpeed = Self.boolean(values["musicPlaybackPitchFollowsSpeed"], default: false)
        self.crossfadeEnabled = Self.boolean(values["musicCrossfadeEnabled"], default: true)
        let duration = Self.number(values["musicCrossfadeDuration"]) ?? 3.0
        self.crossfadeDuration = max(0.0, duration.rounded(.towardZero))
        self.equalizerEnabled = Self.boolean(values["musicEqualizerEnabled"], default: false)
        if let bands = values["musicEqualizerBands"] as? [Any], bands.count == Self.frequencies.count,
           bands.allSatisfy({ Self.number($0) != nil }) {
            self.bands = bands.map { Float(Self.clamp(Self.number($0) ?? 0, to: Self.gainRange)) }
        } else {
            self.bands = Array(repeating: 0, count: Self.frequencies.count)
        }
        self.stopAfterVoiceMessage = Self.boolean(values["stopAfterVoiceMessage"], default: false)
        self.bassEffect = Self.boolean(values["bassEffect"] ?? values["bassEffectEnabled"], default: false)
        self.customMusicCard = Self.boolean(values["wgCustomMusicCard"] ?? values["customMusicCard"], default: false)
    }

    public func pitchCents(at rate: Double) -> Float {
        guard self.pitchFollowsSpeed, rate.isFinite else { return 0 }
        return Float(1200.0 * log2(Self.clamp(rate, to: Self.speedRange)))
    }

    public func playbackRates(at rate: Double) -> (timePitch: Float, varispeed: Float, cents: Float) {
        let rate = rate.isFinite ? Self.clamp(rate, to: Self.speedRange) : 1.0
        if self.pitchFollowsSpeed {
            // Split the ratio to stay inside NewTimePitch's ±2400-cent range
            // and Varispeed's 0.25...4 range, including 0.1x playback.
            let part = sqrt(rate)
            return (Float(part), Float(part), Float(1200 * log2(part)))
        }
        return (Float(rate), 1, 0)
    }

    public func crossfadeDelay(duration: Double, timestamp: Double, rate: Double) -> Double? {
        guard self.crossfadeEnabled, self.crossfadeDuration > 0,
              duration.isFinite, timestamp.isFinite, rate.isFinite, rate > 0,
              duration > 0, timestamp >= 0, timestamp < duration,
              duration / rate > self.crossfadeDuration else { return nil }
        let delay = (duration - timestamp) / rate - self.crossfadeDuration
        return delay.isFinite ? max(0, delay) : nil
    }

    public static func crossfadeGains(progress: Double) -> (outgoing: Double, incoming: Double) {
        let progress = progress.isFinite ? Self.clamp(progress, to: 0 ... 1) : 0
        return (1 - progress, progress)
    }

    public static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func boolean(_ value: Any?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return defaultValue }
        return number.boolValue
    }
}
