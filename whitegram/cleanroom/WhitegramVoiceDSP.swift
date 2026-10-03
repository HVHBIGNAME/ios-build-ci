import Foundation

/// Queue-confined mono processor. Every borrowed buffer remains caller-owned.
public final class WhitegramVoiceProcessor {
    public let isActive: Bool
    public let pitchDelayUpperBound: Double
    private let parameters: WhitegramVoiceParameters?
    private let bleepMode: WhitegramVoiceBleepMode?
    private let rate: Double
    private let initialNoiseState: UInt32
    private let pitchRatio: Double
    private let minimumDelay: Double
    private let maximumDelay: Double
    private let echoDelay: Int
    private var pitchSamples: [Float]
    private var echoSamples: [Float]
    private var pitchIndex = 0
    private var echoIndex = 0
    private var pitchDelay: Double
    private var warmupFrames = 0
    private var lowPass: Float = 0
    private var highPass: Float = 0
    private var previousInput: Float = 0
    private var ringPhase = 0.0
    private var noiseState: UInt32
    private var beepPhase = 0.0
    private var beepAttack = 0

    public init(settings: WhitegramVoiceSettings, sampleRate: Double = 48000.0, channel: Int = 0) {
        let valid = sampleRate.isFinite && (8000.0 ... 192000.0).contains(sampleRate)
        self.rate = valid ? sampleRate : 48000
        self.bleepMode = valid ? settings.activeBleepMode : nil
        self.parameters = valid && self.bleepMode == nil ? settings.parameters : nil
        self.isActive = self.parameters != nil || self.bleepMode != nil
        let size = max(1024, Int(self.rate * 0.09))
        self.pitchSamples = Array(repeating: 0, count: self.parameters?.pitch != 0 && self.parameters != nil ? size : 0)
        self.minimumDelay = Double(size) * 0.16
        self.maximumDelay = Double(size) * 0.84
        self.pitchDelay = Double(size) * 0.58
        self.pitchRatio = pow(2, (self.parameters?.pitch ?? 0) / 12)
        self.pitchDelayUpperBound = self.pitchSamples.isEmpty ? 0 : self.maximumDelay / self.rate
        let echo = (self.parameters?.echo ?? 0) / 100
        self.echoSamples = Array(repeating: 0, count: echo > 0.001 ? max(2048, Int(self.rate * 0.72)) : 0)
        self.echoDelay = min(max(1, Int(self.rate * (0.16 + echo * 0.22))), max(1, self.echoSamples.count - 1))
        self.initialNoiseState = 0x4e47564f &+ UInt32(truncatingIfNeeded: channel) &* 0x44f
        self.noiseState = self.initialNoiseState
    }

    public func process(_ samples: UnsafeMutableBufferPointer<Int16>) {
        guard self.isActive else { return }
        for index in samples.indices { samples[index] = self.processInt16(samples[index]) }
    }

    public func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        guard self.isActive else { return }
        for index in samples.indices { samples[index] = self.processFloat(samples[index]) }
    }

    fileprivate func processInt16(_ input: Int16) -> Int16 {
        guard self.isActive else { return input }
        if let bleepMode = self.bleepMode {
            return Int16(min(32767, max(-32768, (self.bleep(bleepMode) * 32768).rounded())))
        }
        let output = self.effect(Float(input) / 32768) * 36000
        return output.isFinite ? Int16(min(32767, max(-32768, output))) : 0
    }

    fileprivate func processFloat(_ input: Float) -> Float {
        guard self.isActive else { return input }
        if let bleepMode = self.bleepMode { return Float(self.bleep(bleepMode)) }
        let output = self.effect(input.isFinite ? min(1, max(-1, input)) : 0) * 1.1
        return output.isFinite ? min(1, max(-1, output)) : 0
    }

    private func effect(_ input: Float) -> Float {
        guard let p = self.parameters else { return input }
        var sample = self.pitch(input)
        let blend = Float(min(1, Double(self.warmupFrames) / (self.rate * 0.055)))
        if blend < 1 { self.warmupFrames += 1 }
        sample = input * (1 - blend) + sample * blend
        sample = self.tone(sample, timbre: p.timbre / 100, clarity: p.clarity / 100)
        if p.ringFrequency > 0 {
            sample *= Float(sin(self.ringPhase)) * 0.72 + 0.28
            self.ringPhase += 2 * .pi * p.ringFrequency / self.rate
            if self.ringPhase >= 2 * .pi { self.ringPhase -= 2 * .pi }
        }
        if p.noiseMix > 0 {
            self.noiseState = self.noiseState &* 1664525 &+ 1013904223
            let noise = Float(Int32(bitPattern: self.noiseState)) / 2147483648
            let envelope = min(1, abs(sample) * 4.5)
            sample = sample * Float(1 - p.noiseMix) + noise * envelope * Float(p.noiseMix * 0.72)
        }
        if p.distortion > 0 {
            let drive = Float(1 + p.distortion * 10)
            sample = min(1, max(-1, sample * drive)) / max(1, drive * 0.42)
        }
        if !self.echoSamples.isEmpty {
            let amount = p.echo / 100
            let index = (self.echoIndex - self.echoDelay + self.echoSamples.count) % self.echoSamples.count
            let delayed = self.echoSamples[index]
            self.echoSamples[self.echoIndex] = sample + delayed * Float(0.18 + amount * 0.48)
            self.echoIndex = (self.echoIndex + 1) % self.echoSamples.count
            sample = sample * Float(1 - amount * 0.28) + delayed * Float(amount * 0.78)
        }
        return sample / (1 + abs(sample))
    }

    private func tone(_ input: Float, timbre: Double, clarity: Double) -> Float {
        let lowAlpha: Float = timbre < 0 ? Float(0.025 + (timbre + 1) * 0.19) : 0.24
        self.lowPass += lowAlpha * (input - self.lowPass)
        self.highPass = Float(0.82 + max(0, timbre) * 0.14) * (self.highPass + input - self.previousInput)
        self.previousInput = input
        var result = input
        if timbre < 0 {
            result = input * Float(1 + timbre) - self.lowPass * Float(timbre)
        } else if timbre > 0 {
            result = input * Float(1 - timbre * 0.48) + self.highPass * Float(timbre * 0.9)
        }
        if clarity < 0 {
            result = result * Float(1 + clarity * 0.55) + self.lowPass * Float(clarity * -0.55)
        } else {
            result += (input - self.lowPass) * Float(clarity * 0.7)
        }
        return result
    }

    private func pitch(_ input: Float) -> Float {
        guard !self.pitchSamples.isEmpty, abs((self.parameters?.pitch) ?? 0) > 0.01 else { return input }
        self.pitchSamples[self.pitchIndex] = input
        let width = self.maximumDelay - self.minimumDelay
        let secondDelay = self.minimumDelay + (self.pitchDelay - self.minimumDelay + width * 0.5).truncatingRemainder(dividingBy: width)
        let weight = Float(1 - abs(2 * (self.pitchDelay - self.minimumDelay) / width - 1))
        let secondWeight = Float(1 - abs(2 * (secondDelay - self.minimumDelay) / width - 1))
        let output = (self.readPitch(self.pitchDelay) * weight + self.readPitch(secondDelay) * secondWeight) / max(0.001, weight + secondWeight)
        self.pitchDelay += 1 - self.pitchRatio
        if self.pitchDelay < self.minimumDelay { self.pitchDelay += width }
        if self.pitchDelay >= self.maximumDelay { self.pitchDelay -= width }
        self.pitchIndex = (self.pitchIndex + 1) % self.pitchSamples.count
        return output
    }

    private func readPitch(_ delay: Double) -> Float {
        var position = Double(self.pitchIndex) - delay
        if position < 0 { position += Double(self.pitchSamples.count) }
        let lower = Int(position)
        let fraction = Float(position - floor(position))
        return self.pitchSamples[lower] * (1 - fraction) + self.pitchSamples[(lower + 1) % self.pitchSamples.count] * fraction
    }

    private func bleep(_ mode: WhitegramVoiceBleepMode) -> Double {
        if mode == .silence { return 0 }
        let attackCount = max(1, Int(self.rate * 0.005))
        let output = 0.16 * Double(self.beepAttack) / Double(attackCount) * sin(2 * .pi * self.beepPhase)
        self.beepAttack = min(attackCount, self.beepAttack + 1)
        self.beepPhase += 1000 / self.rate
        if self.beepPhase >= 1 { self.beepPhase -= 1 }
        return output
    }

    public func reset() {
        for index in self.pitchSamples.indices { self.pitchSamples[index] = 0 }
        for index in self.echoSamples.indices { self.echoSamples[index] = 0 }
        self.pitchIndex = 0
        self.echoIndex = 0
        self.pitchDelay = Double(max(1024, Int(self.rate * 0.09))) * 0.58
        self.warmupFrames = 0
        self.lowPass = 0
        self.highPass = 0
        self.previousInput = 0
        self.ringPhase = 0
        self.noiseState = self.initialNoiseState
        self.beepPhase = 0
        self.beepAttack = 0
    }
}

public final class WhitegramVoicePCMProcessor {
    private let channels: [WhitegramVoiceProcessor]
    public let channelCount: Int

    public init(settings: WhitegramVoiceSettings, sampleRate: Double, channelCount: Int) {
        self.channelCount = (1 ... 8).contains(channelCount) ? channelCount : 0
        self.channels = (0 ..< self.channelCount).map { WhitegramVoiceProcessor(settings: settings, sampleRate: sampleRate, channel: $0) }
    }

    public func processInterleaved(_ samples: UnsafeMutableBufferPointer<Int16>, frameCount: Int) {
        guard self.channelCount > 0, frameCount >= 0, frameCount <= samples.count / self.channelCount else { return }
        for frame in 0 ..< frameCount {
            for channel in self.channels.indices {
                let index = frame * self.channelCount + channel
                samples[index] = self.channels[channel].processInt16(samples[index])
            }
        }
    }

    public func processInterleaved(_ samples: UnsafeMutableBufferPointer<Float>, frameCount: Int) {
        guard self.channelCount > 0, frameCount >= 0, frameCount <= samples.count / self.channelCount else { return }
        for frame in 0 ..< frameCount {
            for channel in self.channels.indices {
                let index = frame * self.channelCount + channel
                samples[index] = self.channels[channel].processFloat(samples[index])
            }
        }
    }

    public func processPlanar(_ samples: UnsafeMutableBufferPointer<Int16>, channel: Int) {
        guard self.channels.indices.contains(channel) else { return }
        self.channels[channel].process(samples)
    }

    public func processPlanar(_ samples: UnsafeMutableBufferPointer<Float>, channel: Int) {
        guard self.channels.indices.contains(channel) else { return }
        self.channels[channel].process(samples)
    }

    public func reset() { for channel in self.channels { channel.reset() } }
}
