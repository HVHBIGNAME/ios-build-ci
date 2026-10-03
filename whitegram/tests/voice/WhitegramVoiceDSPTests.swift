import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func settings(_ changes: [String: Any] = [:]) -> WhitegramVoiceSettings {
    var values: [String: Any] = ["voiceChangerEnabled": true, "voiceChangerMode": 1, "voiceChangerPreset": 0]
    for (key, value) in changes { values[key] = value }
    return WhitegramVoiceSettings(values: values)
}

private func noise(_ count: Int) -> [Int16] {
    var state: UInt32 = 0x31415926
    return (0 ..< count).map { _ in
        state = state &* 1664525 &+ 1013904223
        return Int16(bitPattern: UInt16(truncatingIfNeeded: state >> 16))
    }
}

private func sine(_ frequency: Double, count: Int, sampleRate: Double = 48000.0) -> [Int16] {
    return (0 ..< count).map { index in
        Int16((16000.0 * sin(2.0 * .pi * frequency * Double(index) / sampleRate)).rounded())
    }
}

private func render(_ input: [Int16], processor: WhitegramVoiceProcessor, chunks: [Int] = [960]) -> [Int16] {
    precondition(chunks.contains(where: { $0 > 0 }) && chunks.allSatisfy({ $0 >= 0 }))
    var output = input
    output.withUnsafeMutableBufferPointer { buffer in
        var offset = 0
        var chunk = 0
        while offset < buffer.count {
            let count = min(chunks[chunk % chunks.count], buffer.count - offset)
            processor.process(UnsafeMutableBufferPointer(start: buffer.baseAddress?.advanced(by: offset), count: count))
            offset += count
            chunk += 1
        }
    }
    return output
}

private func render(_ input: [Int16], settings: WhitegramVoiceSettings) -> [Int16] {
    return render(input, processor: WhitegramVoiceProcessor(settings: settings))
}

// Goertzel measures output frequency; it is not a second implementation of DSP.
private func tonePower(_ samples: [Int16], frequency: Double) -> Double {
    let coefficient = 2.0 * cos(2.0 * .pi * frequency / 48000.0)
    var previous = 0.0
    var previous2 = 0.0
    for sample in samples {
        let current = Double(sample) / 32768.0 + coefficient * previous - previous2
        previous2 = previous
        previous = current
    }
    return max(0.0, previous * previous + previous2 * previous2 - coefficient * previous * previous2) / pow(Double(samples.count), 2.0)
}

private func disabledIdentity() throws {
    let input = (-32768 ... 32767).map { Int16($0) }
    let configurations = [
        settings(["voiceChangerEnabled": false, "voiceChangerPreset": 10, "voiceChangerPitch": 12.0, "voiceChangerEcho": 100.0]),
        settings(),
        settings(["voiceChangerMode": 0, "voiceChangerPreset": 5]),
        settings(["voiceChangerMode": 99, "voiceChangerPreset": 5]),
        settings(["voiceChangerPreset": -1, "voiceChangerPitch": 12.0]),
        settings(["voiceBleepEnabled": true]),
        settings(["voiceChangerInCalls": true]),
    ]
    for configuration in configurations {
        let processor = WhitegramVoiceProcessor(settings: configuration)
        try expect(!processor.isActive, "An inactive/neutral/unsupported configuration became active")
        try expect(render(input, processor: processor, chunks: [0, 1, 959, 960, 961]) == input, "Disabled PCM is not bit-identical")
    }
}

private func finiteAndConstrainedControls() throws {
    let malformed = settings([
        "voiceChangerPitch": Double.nan,
        "voiceChangerTimbre": Double.infinity,
        "voiceChangerEcho": -Double.infinity,
        "voiceChangerClarity": "loud",
    ])
    for control in WhitegramVoiceControl.allCases {
        try expect(malformed.value(for: control) == 0.0, "Malformed numeric control did not become neutral")
        try expect(control.quantized(Double.nan) == 0.0, "UI quantizer accepts NaN")
    }
    let extreme = settings([
        "voiceChangerPitch": Double.greatestFiniteMagnitude,
        "voiceChangerTimbre": -Double.greatestFiniteMagnitude,
        "voiceChangerEcho": Double.greatestFiniteMagnitude,
        "voiceChangerClarity": Double.greatestFiniteMagnitude,
    ])
    try expect(extreme.pitch == 12.0 && extreme.timbre == -100.0 && extreme.echo == 100.0 && extreme.clarity == 100.0, "Control bounds differ from the documented contract")
    try expect(settings(["voiceChangerPitch": true]).pitch == 0.0, "A boolean was interpreted as numeric pitch")
    try expect(!settings(["voiceChangerEnabled": 1]).enabled, "An integer was interpreted as a boolean")
    let invalidValues: [Any] = [Double.nan, Double.infinity, Double.greatestFiniteMagnitude, 0.5, -1, true, "1"]
    for value in invalidValues {
        let invalid = settings(["voiceChangerMode": value, "voiceChangerPreset": value, "voiceBleepMode": value])
        try expect(invalid.mode == nil && invalid.preset == nil && invalid.bleepMode == nil, "Invalid enum selection was accepted")
    }
    try expect(WhitegramVoiceControl.pitch.quantized(3.24) == 3.0, "Pitch UI steps should be half a semitone")
}

private func fixedCountAndBufferOwnership() throws {
    let processor = WhitegramVoiceProcessor(settings: settings(["voiceChangerPreset": 10]))
    var storage: [Int16] = [12345] + noise(960) + [-23456]
    let count = storage.count
    storage.withUnsafeMutableBufferPointer { buffer in
        processor.process(UnsafeMutableBufferPointer(start: buffer.baseAddress?.advanced(by: 1), count: 960))
    }
    processor.process(UnsafeMutableBufferPointer(start: nil, count: 0))
    try expect(storage.count == count, "Processing changed sample count")
    try expect(storage.first == 12345 && storage.last == -23456, "Processing wrote outside the borrowed sample range")
    // Releasing one input and processing another detects retained input pointers
    // when run under AddressSanitizer using run_native.py --sanitize-address.
    for _ in 0 ..< 100 {
        var temporary = noise(37)
        temporary.withUnsafeMutableBufferPointer { processor.process($0) }
    }
}

private func packetPartitionInvariance() throws {
    let input = noise(42001)
    var configurations = WhitegramVoicePreset.allCases.map { settings(["voiceChangerPreset": $0.rawValue]) }
    configurations += [settings(["voiceChangerPitch": -11.5, "voiceChangerTimbre": 100.0, "voiceChangerEcho": 100.0, "voiceChangerClarity": -100.0])]
    for mode in WhitegramVoiceBleepMode.allCases {
        configurations.append(settings(["voiceBleepEnabled": true, "voiceBleepMode": mode.rawValue, "voiceBleepWholeRecording": true]))
    }
    for configuration in configurations {
        let whole = render(input, processor: WhitegramVoiceProcessor(settings: configuration), chunks: [input.count])
        let partitioned = render(input, processor: WhitegramVoiceProcessor(settings: configuration), chunks: [0, 1, 7, 959, 960, 961, 4096])
        try expect(whole == partitioned, "State was reset/lost at a PCM buffer boundary")
        try expect(partitioned.count == input.count, "Output duration changed")
    }
}

private func echoPersistenceAndReset() throws {
    let delay = 18240 // Original custom echo at 100%: 0.16 + 0.22 seconds.
    var impulse = Array(repeating: Int16(0), count: delay * 3)
    impulse[0] = 24000
    let processor = WhitegramVoiceProcessor(settings: settings(["voiceChangerEcho": 100.0]))
    let output = render(impulse, processor: processor, chunks: [13, 960, 17])
    try expect(output[0] > 0, "Echo lost the dry signal")
    try expect(output[1 ..< delay].allSatisfy({ $0 == 0 }), "Echo arrived earlier than specified")
    try expect(output[delay] > 0 && output[delay * 2] > 0, "Echo did not survive multiple recording packets")
    try expect(output[delay * 2] < output[delay], "Echo feedback is not decaying")
    processor.reset()
    let silence = Array(repeating: Int16(0), count: delay * 3)
    try expect(render(silence, processor: processor) == silence, "Reset leaked audio from an earlier/trimmed segment")
}

private func resetMatchesNewProcessor() throws {
    let input = noise(25013)
    for preset in WhitegramVoicePreset.allCases {
        let configuration = settings(["voiceChangerPreset": preset.rawValue])
        let processor = WhitegramVoiceProcessor(settings: configuration)
        _ = render(noise(18231), processor: processor)
        processor.reset()
        try expect(render(input, processor: processor) == render(input, settings: configuration), "Reset did not clear all preset state: \(preset)")
    }
}

private func fullScaleSaturation() throws {
    for sign in [1, -1] {
        let input = Array(repeating: Int16(sign * 24000), count: 144000)
        let output = render(input, settings: settings(["voiceChangerEcho": 100.0]))
        try expect(output.allSatisfy({ sign > 0 ? $0 >= 0 : $0 <= 0 }), "Saturation wrapped the Int16 sign")
        try expect(output.allSatisfy({ abs(Int($0)) < 32768 }), "Original soft-knee limiter was replaced by wrapping or hard clipping")
        try expect(output.suffix(960).contains(where: { abs(Int($0)) > 20000 }), "Limiter unexpectedly silenced a sustained input")
    }
    let extremes: [Int16] = (0 ..< 50001).map { $0.isMultiple(of: 2) ? .min : .max }
    for preset in WhitegramVoicePreset.allCases {
        let output = render(extremes, settings: settings(["voiceChangerPreset": preset.rawValue]))
        try expect(output.count == extremes.count, "Extreme PCM changed output length")
    }
}

private func presetsAndSilence() throws {
    let input = sine(500.0, count: 48000)
    let silence = Array(repeating: Int16(0), count: 24000)
    for preset in WhitegramVoicePreset.allCases where preset != .custom {
        let configuration = settings(["voiceChangerPreset": preset.rawValue])
        let output = render(input, settings: configuration)
        try expect(output != input && output.contains(where: { $0 != 0 }), "Preset is an inaudible stub: \(preset)")
        try expect(render(silence, settings: configuration) == silence, "Preset emits audio without any input: \(preset)")
    }
}

private func pitchMovesFrequencyWithoutChangingDuration() throws {
    let input = sine(500.0, count: 72000)
    for semitones in [-12.0, -7.0, 7.0, 12.0] {
        let processor = WhitegramVoiceProcessor(settings: settings(["voiceChangerPitch": semitones]))
        let output = render(input, processor: processor)
        try expect(output.count == input.count, "Pitch changed duration/playback sample rate")
        try expect(abs(processor.pitchDelayUpperBound - 0.0756) < 0.000001, "Pitch delay differs from the recovered 90 ms buffer / 84% read bound")
        let settled = Array(output[9600 ..< 57600])
        let target = 500.0 * pow(2.0, semitones / 12.0)
        let shiftedPower = tonePower(settled, frequency: target)
        let originalPower = tonePower(settled, frequency: 500.0)
        try expect(shiftedPower > 0.005, "No significant energy at the requested pitch (\(semitones) st)")
        try expect(shiftedPower > originalPower * 30.0, "Pitch retained the original fundamental (\(semitones) st)")
    }
}

private func toneControlsChangeSpectralBalance() throws {
    let input = zip(sine(500.0, count: 48000), sine(6000.0, count: 48000)).map { pair in
        Int16((Int(pair.0) + Int(pair.1)) / 4)
    }
    func spectralBalance(_ samples: [Int16]) -> Double {
        let settled = Array(samples[9600 ..< samples.count])
        return tonePower(settled, frequency: 6000.0) / max(1.0e-10, tonePower(settled, frequency: 500.0))
    }
    let originalBalance = spectralBalance(input)
    for key in ["voiceChangerTimbre", "voiceChangerClarity"] {
        let dark = spectralBalance(render(input, settings: settings([key: -100.0])))
        let bright = spectralBalance(render(input, settings: settings([key: 100.0])))
        try expect(dark < originalBalance * 0.5, "Negative \(key) does not smooth the high frequencies")
        try expect(bright > originalBalance * 1.2, "Positive \(key) does not increase presence/brightness")
    }
}

private func simultaneousProcessorsAreIndependent() throws {
    let inputA = noise(19937)
    let inputB = sine(700.0, count: inputA.count)
    let settingsA = settings(["voiceChangerPreset": 10])
    let settingsB = settings(["voiceChangerPreset": 5])
    let expectedA = render(inputA, settings: settingsA)
    let expectedB = render(inputB, settings: settingsB)
    let processorA = WhitegramVoiceProcessor(settings: settingsA)
    let processorB = WhitegramVoiceProcessor(settings: settingsB)
    var actualA: [Int16] = []
    var actualB: [Int16] = []
    for lower in stride(from: 0, to: inputA.count, by: 961) {
        let upper = min(inputA.count, lower + 961)
        actualA += render(Array(inputA[lower ..< upper]), processor: processorA)
        actualB += render(Array(inputB[lower ..< upper]), processor: processorB)
    }
    try expect(actualA == expectedA && actualB == expectedB, "Processors share mutable recording state")
}

private func bleepRequiresExplicitOptInAndReplacesInput() throws {
    let input = noise(30000)
    try expect(render(input, settings: settings(["voiceBleepEnabled": true])) == input, "Imported automatic-bleep setting masked the whole recording")
    for mode in WhitegramVoiceBleepMode.allCases {
        let configuration = settings(["voiceChangerPreset": 10, "voiceBleepEnabled": true, "voiceBleepMode": mode.rawValue, "voiceBleepWholeRecording": true])
        let processor = WhitegramVoiceProcessor(settings: configuration)
        let output = render(input, processor: processor)
        let zeros = Array(repeating: Int16(0), count: input.count)
        try expect(output == render(zeros, settings: configuration), "Whole-message masking leaked microphone input or preset audio")
        if mode == .silence {
            try expect(output == zeros, "Silence mode is not exactly zero")
        } else {
            try expect(tonePower(Array(output[960 ..< 24960]), frequency: 1000.0) > 0.005, "Beep does not contain the specified 1 kHz tone")
            try expect(output.allSatisfy({ abs(Int($0)) <= 5243 }), "Beep amplitude is too high")
        }
        processor.reset()
        try expect(render(input, processor: processor) == output, "Bleep phase/attack did not reset")
    }
}

private func invalidSampleRatesAndImmutableSnapshot() throws {
    let input = noise(10000)
    for rate in [Double.nan, Double.infinity, -48000.0, 0.0, 7999.0, 192001.0] {
        let processor = WhitegramVoiceProcessor(settings: settings(["voiceChangerPreset": 5]), sampleRate: rate)
        try expect(!processor.isActive && render(input, processor: processor) == input, "Invalid sample rate activated DSP")
    }
    var values: [String: Any] = ["voiceChangerEnabled": true, "voiceChangerMode": 1, "voiceChangerPitch": 0.0]
    let processor = WhitegramVoiceProcessor(settings: WhitegramVoiceSettings(values: values))
    values["voiceChangerPitch"] = 12.0
    try expect(render(input, processor: processor) == input, "An existing recorder's immutable snapshot changed")
    try expect(render(input, settings: WhitegramVoiceSettings(values: values)) != input, "A new recorder did not take updated settings")
}

private func originalPresetParameters() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let presets = fixture["voice_presets"] as! [[Double]]
    try expect(presets.count == WhitegramVoicePreset.allCases.count, "Original preset count drift")
    for preset in WhitegramVoicePreset.allCases {
        let value = settings(["voiceChangerPreset": preset.rawValue]).parameters ?? WhitegramVoiceParameters()
        let actual = [value.pitch, value.timbre, value.echo, value.clarity, value.ringFrequency, value.distortion, value.noiseMix]
        for (actual, expected) in zip(actual, presets[preset.rawValue]) {
            try expect(abs(actual - expected) < 0.000001, "Preset coefficients differ from the original IPA table: \(preset)")
        }
    }
}

private func stereoAndFloatAdapters() throws {
    let configuration = settings(["voiceChangerPreset": 4])
    let left = sine(330, count: 48001)
    let right = sine(700, count: left.count)
    let expectedLeft = render(left, processor: WhitegramVoiceProcessor(settings: configuration, channel: 0))
    let expectedRight = render(right, processor: WhitegramVoiceProcessor(settings: configuration, channel: 1))
    var interleaved = zip(left, right).flatMap { [$0.0, $0.1] }
    interleaved += [1234, -1234]
    let processor = WhitegramVoicePCMProcessor(settings: configuration, sampleRate: 48000, channelCount: 2)
    interleaved.withUnsafeMutableBufferPointer { buffer in
        for offset in stride(from: 0, to: left.count, by: 337) {
            let count = min(337, left.count - offset)
            processor.processInterleaved(UnsafeMutableBufferPointer(start: buffer.baseAddress!.advanced(by: offset * 2), count: count * 2), frameCount: count)
        }
    }
    for index in left.indices {
        try expect(interleaved[index * 2] == expectedLeft[index] && interleaved[index * 2 + 1] == expectedRight[index], "Interleaved adapter mixed channel state")
    }
    try expect(interleaved.suffix(2) == [1234, -1234], "Stereo adapter wrote past the frame count")
    processor.reset()
    var planar = left
    planar.withUnsafeMutableBufferPointer { processor.processPlanar($0, channel: 0) }
    try expect(planar == expectedLeft, "Planar and interleaved adapters disagree")
    let untouched = interleaved
    interleaved.withUnsafeMutableBufferPointer { processor.processInterleaved($0, frameCount: Int.max) }
    try expect(interleaved == untouched, "Invalid frame count wrote memory")
    var floats: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] + Array(repeating: 0.2, count: 4800)
    let floatProcessor = WhitegramVoiceProcessor(settings: configuration)
    floats.withUnsafeMutableBufferPointer { floatProcessor.process($0) }
    try expect(floats.allSatisfy { $0.isFinite && abs($0) <= 1 }, "Float PCM was not finite and bounded")
    try expect(floats.suffix(960).contains(where: { $0 != 0 }), "Malformed input poisoned subsequent Float PCM")
}

@main
private struct WhitegramVoiceDSPTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("disabled/neutral/unsupported bit identity", disabledIdentity),
            ("finite controls, enum validation and UI bounds", finiteAndConstrainedControls),
            ("sample count, buffer boundaries and ownership", fixedCountAndBufferOwnership),
            ("arbitrary packet partition invariance", packetPartitionInvariance),
            ("echo persistence, decay and reset", echoPersistenceAndReset),
            ("reset is equivalent to a fresh processor", resetMatchesNewProcessor),
            ("full-scale saturation without sign overflow", fullScaleSaturation),
            ("every preset is audible and silence stays silent", presetsAndSilence),
            ("pitch shifts frequency at fixed duration", pitchMovesFrequencyWithoutChangingDuration),
            ("timbre and clarity change spectral balance", toneControlsChangeSpectralBalance),
            ("simultaneous recorders have independent state", simultaneousProcessorsAreIndependent),
            ("bleep opt-in, masking, frequency and reset", bleepRequiresExplicitOptInAndReplacesInput),
            ("invalid rates and immutable per-recorder settings", invalidSampleRatesAndImmutableSnapshot),
            ("original IPA preset coefficients", originalPresetParameters),
            ("stereo, planar, Float and invalid frame adapters", stereoAndFloatAdapters),
        ]
        for (name, run) in tests {
            try run()
            print("PASS: \(name)")
        }
        print("PASS: \(tests.count) native DSP test groups (production Swift implementation)")
    }
}
