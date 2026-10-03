import CoreFoundation
import Foundation

public enum WhitegramVoiceMode: Int {
    case remote = 0
    case local = 1
}

public enum WhitegramVoicePreset: Int, CaseIterable {
    case custom = 0
    case echo = 1
    case child = 2
    case adult = 3
    case robot = 4
    case helium = 5
    case monster = 6
    case radio = 7
    case whisper = 8
    case alien = 9
    case cavern = 10
}

public enum WhitegramVoiceBleepMode: Int, CaseIterable {
    case beep = 0
    case silence = 1
}

public enum WhitegramVoiceControl: CaseIterable, Equatable {
    case pitch
    case timbre
    case echo
    case clarity

    public var key: String {
        switch self {
        case .pitch: return "voiceChangerPitch"
        case .timbre: return "voiceChangerTimbre"
        case .echo: return "voiceChangerEcho"
        case .clarity: return "voiceChangerClarity"
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .pitch: return -12.0 ... 12.0
        case .echo: return 0.0 ... 100.0
        case .timbre, .clarity: return -100.0 ... 100.0
        }
    }

    public var step: Double {
        return self == .pitch ? 0.5 : 1.0
    }

    public func constrained(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(self.range.upperBound, max(self.range.lowerBound, value))
    }

    public func quantized(_ value: Double) -> Double {
        return self.constrained((self.constrained(value) / self.step).rounded() * self.step)
    }
}

/// An immutable per-recording snapshot. Unknown enum values do not enable effects.
public struct WhitegramVoiceSettings: Equatable {
    public let enabled: Bool
    public let mode: WhitegramVoiceMode?
    public let preset: WhitegramVoicePreset?
    public let pitch: Double
    public let timbre: Double
    public let echo: Double
    public let clarity: Double
    public let bleepEnabled: Bool
    public let bleepMode: WhitegramVoiceBleepMode?
    public let bleepWholeRecording: Bool
    public let callsRequested: Bool
    public let voiceId: String
    public let useProxy: Bool

    /// The original bleep toggle meant transcription-based word censoring. A
    /// separate opt-in prevents importing it as destructive whole-message masking.
    public static let wholeRecordingBleepKey = "voiceBleepWholeRecording"

    public init(values: [String: Any]) {
        self.enabled = Self.boolean(values["voiceChangerEnabled"])
        self.mode = Self.index(values["voiceChangerMode"], default: 0).flatMap(WhitegramVoiceMode.init(rawValue:))
        self.preset = Self.index(values["voiceChangerPreset"], default: 0).flatMap(WhitegramVoicePreset.init(rawValue:))
        self.pitch = WhitegramVoiceControl.pitch.constrained(Self.number(values["voiceChangerPitch"]))
        self.timbre = WhitegramVoiceControl.timbre.constrained(Self.number(values["voiceChangerTimbre"]))
        self.echo = WhitegramVoiceControl.echo.constrained(Self.number(values["voiceChangerEcho"]))
        self.clarity = WhitegramVoiceControl.clarity.constrained(Self.number(values["voiceChangerClarity"]))
        self.bleepEnabled = Self.boolean(values["voiceBleepEnabled"])
        self.bleepMode = Self.index(values["voiceBleepMode"], default: 0).flatMap(WhitegramVoiceBleepMode.init(rawValue:))
        self.bleepWholeRecording = Self.boolean(values[Self.wholeRecordingBleepKey])
        self.callsRequested = Self.boolean(values["voiceChangerInCalls"])
        let voiceId = values["voiceChangerVoiceId"] as? String
        self.voiceId = (voiceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.useProxy = values["voiceChangerUseProxy"] == nil ? true : Self.boolean(values["voiceChangerUseProxy"])
    }

    public var localEnabled: Bool {
        return self.enabled && self.mode == .local && self.preset != nil
    }

    public var hasLocalEffect: Bool {
        return self.parameters != nil
    }

    public var activeBleepMode: WhitegramVoiceBleepMode? {
        return self.bleepEnabled && self.bleepWholeRecording ? self.bleepMode : nil
    }

    public var requiresPostprocessing: Bool {
        return (self.bleepEnabled && !self.bleepWholeRecording && self.bleepMode != nil) || (self.enabled && self.mode == .remote)
    }

    public var requiresVideoProcessing: Bool {
        return self.hasLocalEffect || self.activeBleepMode != nil || self.requiresPostprocessing
    }

    public func value(for control: WhitegramVoiceControl) -> Double {
        switch control {
        case .pitch: return self.pitch
        case .timbre: return self.timbre
        case .echo: return self.echo
        case .clarity: return self.clarity
        }
    }

    private static func boolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue
    }

    private static func numeric(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func number(_ value: Any?) -> Double {
        return Self.numeric(value) ?? 0.0
    }

    private static func index(_ value: Any?, default defaultValue: Int) -> Int? {
        guard let value else { return defaultValue }
        guard let number = Self.numeric(value) else { return nil }
        return Int(exactly: number)
    }

    var parameters: WhitegramVoiceParameters? {
        guard self.localEnabled, let preset = self.preset else { return nil }
        let result: WhitegramVoiceParameters
        switch preset {
        case .custom:
            result = WhitegramVoiceParameters(pitch: self.pitch, timbre: self.timbre, echo: self.echo, clarity: self.clarity)
        case .echo:
            result = WhitegramVoiceParameters(echo: 72.0, clarity: 12.0)
        case .child:
            result = WhitegramVoiceParameters(pitch: 6.2, timbre: 56.0, echo: 4.0, clarity: 35.0)
        case .adult:
            result = WhitegramVoiceParameters(pitch: -3.8, timbre: -34.0, echo: 3.0, clarity: -8.0)
        case .robot:
            result = WhitegramVoiceParameters(pitch: -0.7, timbre: 24.0, echo: 10.0, clarity: 36.0, ringFrequency: 74.0, distortion: 0.34)
        case .helium:
            result = WhitegramVoiceParameters(pitch: 9.0, timbre: 72.0, echo: 2.0, clarity: 44.0)
        case .monster:
            result = WhitegramVoiceParameters(pitch: -8.0, timbre: -76.0, echo: 18.0, clarity: -32.0, distortion: 0.27)
        case .radio:
            result = WhitegramVoiceParameters(timbre: 78.0, echo: 2.0, clarity: 70.0, distortion: 0.18)
        case .whisper:
            result = WhitegramVoiceParameters(timbre: 62.0, echo: 3.0, clarity: 40.0, noiseMix: 0.82)
        case .alien:
            result = WhitegramVoiceParameters(pitch: 4.8, timbre: 38.0, echo: 28.0, clarity: 20.0, ringFrequency: 31.0, distortion: 0.12)
        case .cavern:
            result = WhitegramVoiceParameters(pitch: -1.3, timbre: -25.0, echo: 90.0, clarity: -20.0)
        }
        return result.isActive ? result : nil
    }
}

// Recovered from TelegramCore 0x2d672c and constant tables 0xd688b0...0xd68a50.
struct WhitegramVoiceParameters {
    var pitch: Double = 0.0
    var timbre: Double = 0.0
    var echo: Double = 0.0
    var clarity: Double = 0.0
    var ringFrequency: Double = 0.0
    var distortion: Double = 0.0
    var noiseMix: Double = 0.0

    var isActive: Bool {
        return self.pitch != 0.0 || self.timbre != 0.0 || self.echo != 0.0 || self.clarity != 0.0 || self.ringFrequency != 0.0 || self.distortion != 0.0 || self.noiseMix != 0.0
    }
}
