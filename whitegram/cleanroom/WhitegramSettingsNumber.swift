import Foundation
import TelegramCore

enum WhitegramSettingsNumber: String {
    case stickerSizeSlider, tabBarScaleSlider, tabBarWidthSlider, photoQualitySlider
    case deletedMessagesOpacitySlider, playbackSpeedSlider, localStarsCountSlider
    case voiceChangerPitchSlider, voiceChangerTimbreSlider, voiceChangerEchoSlider, voiceChangerClaritySlider

    var key: String {
        switch self {
        case .stickerSizeSlider: return "stickerSizeScale"
        case .tabBarScaleSlider: return "tabBarScale"
        case .tabBarWidthSlider: return "tabBarWidthScale"
        case .photoQualitySlider: return "photoCompressionQuality"
        case .deletedMessagesOpacitySlider: return "deletedMessagesOpacity"
        case .playbackSpeedSlider: return "musicPlaybackSpeed"
        case .localStarsCountSlider: return "localStarsCount"
        case .voiceChangerPitchSlider: return "voiceChangerPitch"
        case .voiceChangerTimbreSlider: return "voiceChangerTimbre"
        case .voiceChangerEchoSlider: return "voiceChangerEcho"
        case .voiceChangerClaritySlider: return "voiceChangerClarity"
        }
    }

    private var voiceControl: WhitegramVoiceControl? {
        switch self {
        case .voiceChangerPitchSlider: return .pitch
        case .voiceChangerTimbreSlider: return .timbre
        case .voiceChangerEchoSlider: return .echo
        case .voiceChangerClaritySlider: return .clarity
        default: return nil
        }
    }

    var range: ClosedRange<Double> {
        if let control = self.voiceControl { return control.range }
        switch self {
        case .stickerSizeSlider: return WhitegramAppearancePolicy.stickerPercentRange
        case .tabBarScaleSlider, .tabBarWidthSlider: return WhitegramAppearancePolicy.tabPercentRange
        case .photoQualitySlider: return 10 ... 100
        case .deletedMessagesOpacitySlider: return 1 ... 100
        case .playbackSpeedSlider: return WhitegramPlayerSettings.speedRange
        case .localStarsCountSlider: return Double(WhitegramLocalStars.sliderRange.lowerBound) ... Double(WhitegramLocalStars.sliderRange.upperBound)
        default: preconditionFailure("Missing numeric control range")
        }
    }

    var step: Double { return self.voiceControl?.step ?? (self == .playbackSpeedSlider ? 0.1 : 1.0) }
    var fractionDigits: Int { return self.step < 1.0 ? 1 : 0 }
    var suffix: String {
        switch self {
        case .stickerSizeSlider, .tabBarScaleSlider, .tabBarWidthSlider, .photoQualitySlider, .deletedMessagesOpacitySlider: return "%"
        case .playbackSpeedSlider: return "×"
        default: return ""
        }
    }

    var value: Double {
        if let control = self.voiceControl { return WhitegramVoiceSettings(values: WhitegramPreferences.values()).value(for: control) }
        switch self {
        case .stickerSizeSlider: return WhitegramAppearancePolicy.current.stickerScale * 100.0
        case .tabBarScaleSlider: return WhitegramAppearancePolicy.current.tabHeightPercent
        case .tabBarWidthSlider: return WhitegramAppearancePolicy.current.tabWidthPercent
        case .photoQualitySlider: return WhitegramMediaSettings.current.photoCompressionQuality * 100.0
        case .deletedMessagesOpacitySlider: return WhitegramHistoryRuntime.policy.deletedOpacity * 100.0
        case .playbackSpeedSlider: return WhitegramPlayerSettings(values: WhitegramPreferences.values()).speed
        case .localStarsCountSlider: return Double(WhitegramLocalStars.current.count)
        default: preconditionFailure("Missing numeric control value")
        }
    }

    func save(_ value: Double) -> Bool {
        guard value.isFinite, self.range.contains(value) else { return false }
        let value = min(self.range.upperBound, max(self.range.lowerBound, (value / self.step).rounded() * self.step))
        if let control = self.voiceControl {
            return WhitegramPreferences.update([control.key: control.quantized(value), "voiceChangerPreset": WhitegramVoicePreset.custom.rawValue])
        }
        switch self {
        case .stickerSizeSlider, .photoQualitySlider, .deletedMessagesOpacitySlider:
            return WhitegramPreferences.set(value / 100.0, for: self.key)
        case .localStarsCountSlider:
            return WhitegramPreferences.set(Int64(value), for: self.key)
        default:
            return WhitegramPreferences.set(value, for: self.key)
        }
    }
}
