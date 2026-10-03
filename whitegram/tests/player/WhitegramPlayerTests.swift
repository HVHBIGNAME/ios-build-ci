import Foundation

private struct PlayerFailure: Error { let message: String }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PlayerFailure(message: message) }
}

private func settingsAndOriginalPresets() throws {
    let settings = WhitegramPlayerSettings(values: [:])
    try check(settings.speed == 1 && settings.crossfadeEnabled && settings.crossfadeDuration == 3, "Recovered playback defaults changed")
    try check(!settings.pitchFollowsSpeed && !settings.equalizerEnabled && !settings.stopAfterVoiceMessage && !settings.bassEffect, "Default-off playback flags changed")
    try check(settings.bands == [Float](repeating: 0, count: 10), "Default equalizer must have exactly ten neutral bands")
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
    let presets = fixture["equalizer_presets"] as! [String: [Double]]
    for preset in WhitegramPlayerEqualizerPreset.allCases where preset != .neutral {
        try check(preset.gains == presets[preset.rawValue]!.map(Float.init), "Original IPA equalizer preset differs: \(preset)")
    }
    let extremes = WhitegramPlayerSettings(values: ["musicPlaybackSpeed": 1000, "musicCrossfadeDuration": -2, "musicEqualizerBands": [-100, -13, -12, -1, 0, 1, 11, 12, 13, 100]])
    try check(extremes.speed == 3 && extremes.crossfadeDuration == 0 && extremes.bands == [-12, -12, -12, -1, 0, 1, 11, 12, 12, 12], "Numeric bounds changed")
    let malformedRates: [Any] = [true, "2", Double.nan, Double.infinity]
    for malformed in malformedRates {
        try check(WhitegramPlayerSettings(values: ["musicPlaybackSpeed": malformed]).speed == 1, "Invalid rate accepted")
    }
    let malformedBands: [Any] = [[0, 0], Array(repeating: Double.nan, count: 10), Array(repeating: true, count: 10), "0,0"]
    for malformed in malformedBands {
        try check(WhitegramPlayerSettings(values: ["musicEqualizerBands": malformed]).bands == settings.bands, "Malformed band data was partially applied")
    }
}

private func pitchAndTiming() throws {
    for follows in [false, true] {
        let settings = WhitegramPlayerSettings(values: ["musicPlaybackPitchFollowsSpeed": follows])
        for speed in [0.1, 0.125, 0.25, 0.5, 1, 1.5, 2, 3] {
            let rates = settings.playbackRates(at: speed)
            try check(abs(Double(rates.timePitch * rates.varispeed) - speed) < 0.00001, "Audio graph rate does not match the timebase")
            try check((0.25 ... 4).contains(rates.varispeed) && (-2400 ... 2400).contains(rates.cents), "Pitch graph exceeds AudioUnit bounds at \(speed)x")
            let pitchRatio = pow(2, Double(rates.cents) / 1200) * Double(rates.varispeed)
            try check(abs(pitchRatio - (follows ? speed : 1)) < 0.00001, "Pitch follows-speed policy is wrong")
        }
    }
    let settings = WhitegramPlayerSettings(values: [:])
    try check(settings.crossfadeDelay(duration: 100, timestamp: 90, rate: 2) == 2, "Crossfade was scheduled in media seconds instead of wall time")
    try check(settings.crossfadeDelay(duration: 100, timestamp: 99, rate: 1) == 0, "Late scheduling did not start immediately")
    try check(settings.crossfadeDelay(duration: 3, timestamp: 0, rate: 1) == nil, "A track shorter than the fade was advanced immediately")
    try check(settings.crossfadeDelay(duration: .infinity, timestamp: 0, rate: 1) == nil, "Invalid duration created a timer")
    try check(settings.crossfadeDelay(duration: .greatestFiniteMagnitude, timestamp: 0, rate: 0.1) == nil, "Overflowing duration created an infinite timer")
    try check(WhitegramPlayerSettings(values: ["musicCrossfadeEnabled": false]).crossfadeDelay(duration: 100, timestamp: 0, rate: 1) == nil, "Disabled crossfade scheduled work")
}

private func fadeLifecycle() throws {
    var fade = WhitegramPlayerFadeEnvelope(duration: 3)
    try check(fade.gains(at: 500).outgoing == 1 && fade.gains(at: 500).incoming == 0, "Unready incoming audio attenuated the outgoing track")
    fade.setPlaying(true, at: 10)
    var gains = fade.gains(at: 11.5)
    try check(gains.outgoing == 0.5 && gains.incoming == 0.5, "Original linear gains changed")
    fade.setPlaying(false, at: 11.5)
    gains = fade.gains(at: 100)
    try check(gains.outgoing == 1 && gains.incoming == 0.5, "Buffering consumed fade time or attenuated the remaining audio")
    fade.setPlaying(true, at: 100)
    gains = fade.gains(at: 101.5)
    try check(gains.outgoing == 0 && gains.incoming == 1, "Resuming a fade did not complete at unity gain")
    try check(fade.gains(at: .nan).incoming.isFinite, "Invalid clock poisoned gains")
    fade = WhitegramPlayerFadeEnvelope(duration: 3)
    try check(!fade.hasStarted && fade.gains(at: 100).incoming == 0, "A new transition reused old state")
}

private func bassMeter() throws {
    func level(_ frequency: Double, inverted: Bool = false) -> Float {
        var meter = WhitegramPlayerBassMeter()
        for index in 0 ..< 48000 {
            let sample = Int16(sin(2 * .pi * frequency * Double(index) / 44100) * 16000)
            meter.append(left: sample, right: inverted ? -sample : sample)
        }
        return meter.level
    }
    let bass = level(60)
    try check(bass > 0.5 && bass > level(4000) * 10, "Background meter does not isolate low-frequency energy")
    try check(abs(bass - level(60, inverted: true)) < 0.00001, "Opposite stereo phases cancelled the bass meter")
    var meter = WhitegramPlayerBassMeter()
    for _ in 0 ..< 1200 { meter.append(left: .max, right: .min) }
    try check(meter.level.isFinite && (0 ... 1).contains(meter.level), "Full-scale PCM overflowed the meter")
    meter.reset()
    try check(meter.level == 0, "Seeking retained old bass energy")
}

@main
private struct WhitegramPlayerTests {
    static func main() throws {
        try settingsAndOriginalPresets()
        try pitchAndTiming()
        try fadeLifecycle()
        try bassMeter()
        print("PASS: 4 production player-policy groups (original presets, rate/pitch, fade lifecycle, bass meter)")
    }
}
