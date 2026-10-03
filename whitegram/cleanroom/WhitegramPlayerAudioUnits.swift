import Foundation
import AudioToolbox
import TelegramCore

// All calls are made on MediaPlayer's audio renderer queue, outside its render callback.
enum WhitegramPlayerAudioUnits {
    static func configureEqualizer(_ unit: AudioUnit, settings: WhitegramPlayerSettings, initialize: Bool) {
        if initialize {
            var count = UInt32(WhitegramPlayerSettings.frequencies.count)
            self.check(AudioUnitSetProperty(unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &count, UInt32(MemoryLayout<UInt32>.size)))
        }
        for index in WhitegramPlayerSettings.frequencies.indices {
            let offset = AudioUnitParameterID(index)
            self.set(unit, kAUNBandEQParam_BypassBand + offset, settings.equalizerEnabled ? 0 : 1)
            self.set(unit, kAUNBandEQParam_FilterType + offset, Float(kAUNBandEQFilterType_Parametric))
            self.set(unit, kAUNBandEQParam_Frequency + offset, WhitegramPlayerSettings.frequencies[index])
            self.set(unit, kAUNBandEQParam_Bandwidth + offset, 1.0)
            self.set(unit, kAUNBandEQParam_Gain + offset, settings.bands[index])
        }
    }

    static func configurePitch(_ unit: AudioUnit, varispeed: AudioUnit, settings: WhitegramPlayerSettings, rate: Double) {
        let rates = settings.playbackRates(at: rate)
        self.set(unit, kNewTimePitchParam_Rate, rates.timePitch)
        self.set(unit, kNewTimePitchParam_Pitch, rates.cents)
        self.set(varispeed, kVarispeedParam_PlaybackRate, rates.varispeed)
    }

    private static func set(_ unit: AudioUnit, _ parameter: AudioUnitParameterID, _ value: Float) {
        self.check(AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, value, 0))
    }

    private static func check(_ status: OSStatus) {
        if status != noErr {
            Logger.shared.log("WhitegramPlayer", "AudioUnit configuration failed: \(status)")
        }
    }
}
