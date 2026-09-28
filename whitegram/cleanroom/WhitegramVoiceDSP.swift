import Foundation

/// A queue-confined, mono signed-Int16 PCM processor. The caller owns every
/// buffer; processing is synchronous, in-place and always N samples in / N out.
public final class WhitegramVoiceProcessor {
    public let isActive: Bool
    public let pitchDelayUpperBound: Double

    private let parameters: WhitegramVoiceParameters?
    private let bleepMode: WhitegramVoiceBleepMode?
    private let pitchShifter: WhitegramVoicePitchShifter?
    private let echoLine: WhitegramVoiceEchoLine?
    private let timbreAlpha: Double
    private let rumbleAlpha: Double
    private let presenceAlpha: Double
    private let smoothingAlpha: Double
    private let radioLowAlpha: Double
    private let radioHighAlpha: Double
    private let envelopeAttack: Double
    private let envelopeRelease: Double
    private let ringStep: Double
    private let beepStep: Double
    private let beepAttackSamples: Int

    private var timbreLow = 0.0
    private var rumbleLow = 0.0
    private var presenceLow = 0.0
    private var smoothingLow = 0.0
    private var radioLow = 0.0
    private var radioHigh = 0.0
    private var envelope = 0.0
    private var ringPhase = 0.0
    private var beepPhase = 0.0
    private var beepAttackPosition = 0
    private var noiseState: UInt32 = 0x57475631

    public init(settings: WhitegramVoiceSettings, sampleRate: Double = 48000.0) {
        let validRate = sampleRate.isFinite && (8000.0 ... 192000.0).contains(sampleRate)
        let rate = validRate ? sampleRate : 48000.0
        let bleepMode = validRate ? settings.activeBleepMode : nil
        let parameters = validRate && bleepMode == nil ? settings.parameters : nil
        self.parameters = parameters
        self.bleepMode = bleepMode
        self.isActive = parameters != nil || bleepMode != nil
        if let parameters, parameters.pitch != 0.0 {
            self.pitchShifter = WhitegramVoicePitchShifter(sampleRate: rate, semitones: parameters.pitch)
            self.pitchDelayUpperBound = 0.04 + 2.0 / rate
        } else {
            self.pitchShifter = nil
            self.pitchDelayUpperBound = 0.0
        }
        if let parameters, parameters.echo > 0.0 {
            self.echoLine = WhitegramVoiceEchoLine(sampleRate: rate, delay: parameters.echoDelay, amount: parameters.echo / 100.0)
        } else {
            self.echoLine = nil
        }
        self.timbreAlpha = Self.lowPassAlpha(900.0, rate: rate)
        self.rumbleAlpha = Self.lowPassAlpha(100.0, rate: rate)
        self.presenceAlpha = Self.lowPassAlpha(2500.0, rate: rate)
        self.smoothingAlpha = Self.lowPassAlpha(1600.0, rate: rate)
        self.radioLowAlpha = Self.lowPassAlpha(300.0, rate: rate)
        self.radioHighAlpha = Self.lowPassAlpha(3400.0, rate: rate)
        self.envelopeAttack = exp(-1.0 / (rate * 0.005))
        self.envelopeRelease = exp(-1.0 / (rate * 0.050))
        self.ringStep = (parameters?.ringFrequency ?? 0.0) / rate
        self.beepStep = 1000.0 / rate
        self.beepAttackSamples = max(1, Int(rate * 0.005))
    }

    /// No preference reads, locks, allocations or audio-session operations occur
    /// here. Disabled and neutral configurations return before touching PCM.
    public func process(_ samples: UnsafeMutableBufferPointer<Int16>) {
        guard self.isActive, !samples.isEmpty else { return }
        if let bleepMode = self.bleepMode {
            self.replaceRecording(samples, mode: bleepMode)
            return
        }
        guard let parameters = self.parameters else { return }

        for index in samples.indices {
            var sample = Double(samples[index]) / 32768.0
            if let pitchShifter = self.pitchShifter {
                sample = pitchShifter.process(sample)
            }
            sample = self.filter(sample, parameters: parameters)
            if parameters.ringMix > 0.0 {
                sample *= 1.0 - parameters.ringMix + parameters.ringMix * cos(2.0 * .pi * self.ringPhase)
                self.ringPhase += self.ringStep
                if self.ringPhase >= 1.0 { self.ringPhase -= 1.0 }
            }
            if parameters.noiseMix > 0.0 {
                let magnitude = abs(sample)
                let coefficient = magnitude > self.envelope ? self.envelopeAttack : self.envelopeRelease
                self.envelope = coefficient * self.envelope + (1.0 - coefficient) * magnitude
                self.noiseState ^= self.noiseState << 13
                self.noiseState ^= self.noiseState >> 17
                self.noiseState ^= self.noiseState << 5
                let noise = Double(self.noiseState) / Double(UInt32.max) * 2.0 - 1.0
                sample = sample * (1.0 - parameters.noiseMix) + noise * self.envelope * parameters.noiseMix
            }
            if let echoLine = self.echoLine {
                sample = echoLine.process(sample)
            }
            samples[index] = Self.quantize(sample)
        }
    }

    /// Start a new uninterrupted segment without retaining echoes or delayed
    /// samples from a discarded/trimmed segment. Call on the recording queue.
    public func reset() {
        self.pitchShifter?.reset()
        self.echoLine?.reset()
        self.timbreLow = 0.0
        self.rumbleLow = 0.0
        self.presenceLow = 0.0
        self.smoothingLow = 0.0
        self.radioLow = 0.0
        self.radioHigh = 0.0
        self.envelope = 0.0
        self.ringPhase = 0.0
        self.beepPhase = 0.0
        self.beepAttackPosition = 0
        self.noiseState = 0x57475631
    }

    private static func lowPassAlpha(_ frequency: Double, rate: Double) -> Double {
        return 1.0 - exp(-2.0 * .pi * min(frequency, rate * 0.45) / rate)
    }

    private func filter(_ input: Double, parameters: WhitegramVoiceParameters) -> Double {
        var sample = input
        let timbre = parameters.timbre / 100.0
        if timbre != 0.0 {
            self.timbreLow += self.timbreAlpha * (sample - self.timbreLow)
            let high = sample - self.timbreLow
            if timbre < 0.0 {
                sample = self.timbreLow + high * (1.0 + 0.85 * timbre)
            } else {
                sample += high * (0.75 * timbre)
            }
        }
        let clarity = parameters.clarity / 100.0
        if clarity > 0.0 {
            self.rumbleLow += self.rumbleAlpha * (sample - self.rumbleLow)
            self.presenceLow += self.presenceAlpha * (sample - self.presenceLow)
            sample = sample - clarity * self.rumbleLow + clarity * 0.4 * (sample - self.presenceLow)
        } else if clarity < 0.0 {
            self.smoothingLow += self.smoothingAlpha * (sample - self.smoothingLow)
            sample = sample * (1.0 + clarity) - self.smoothingLow * clarity
        }
        if parameters.radio {
            self.radioLow += self.radioLowAlpha * (sample - self.radioLow)
            let high = sample - self.radioLow
            self.radioHigh += self.radioHighAlpha * (high - self.radioHigh)
            sample = 0.8 * tanh(2.0 * self.radioHigh)
        }
        return sample
    }

    private func replaceRecording(_ samples: UnsafeMutableBufferPointer<Int16>, mode: WhitegramVoiceBleepMode) {
        for index in samples.indices {
            switch mode {
            case .silence:
                samples[index] = 0
            case .beep:
                let attack = Double(self.beepAttackPosition) / Double(self.beepAttackSamples)
                samples[index] = Self.quantize(0.16 * attack * sin(2.0 * .pi * self.beepPhase))
                self.beepAttackPosition = min(self.beepAttackSamples, self.beepAttackPosition + 1)
                self.beepPhase += self.beepStep
                if self.beepPhase >= 1.0 { self.beepPhase -= 1.0 }
            }
        }
    }

    private static func quantize(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let scaled = (min(1.0, max(-1.0, value)) * 32768.0).rounded()
        return Int16(min(32767.0, max(-32768.0, scaled)))
    }
}

/// Two fractional-delay read heads with complementary Hann windows. Moving
/// delay at 1-ratio reads at ratio speed without changing the output clock.
private final class WhitegramVoicePitchShifter {
    private let window: Double
    private let phaseStep: Double
    private let inputAlpha: Double
    private let filterInput: Bool
    private var samples: [Double]
    private var writeIndex = 0
    private var phase = 0.0
    private var inputLow1 = 0.0
    private var inputLow2 = 0.0

    init(sampleRate: Double, semitones: Double) {
        let ratio = pow(2.0, semitones / 12.0)
        self.window = sampleRate * 0.04
        self.phaseStep = (1.0 - ratio) / self.window
        self.samples = Array(repeating: 0.0, count: Int(ceil(self.window)) + 4)
        self.filterInput = ratio > 1.0
        self.inputAlpha = 1.0 - exp(-2.0 * .pi * (0.40 / max(1.0, ratio)))
    }

    func process(_ input: Double) -> Double {
        var sample = input
        if self.filterInput {
            self.inputLow1 += self.inputAlpha * (sample - self.inputLow1)
            self.inputLow2 += self.inputAlpha * (self.inputLow1 - self.inputLow2)
            sample = self.inputLow2
        }
        self.samples[self.writeIndex] = sample
        let secondPhase = self.phase < 0.5 ? self.phase + 0.5 : self.phase - 0.5
        let weight = 0.5 - 0.5 * cos(2.0 * .pi * self.phase)
        let first = self.read(delay: 2.0 + self.phase * self.window)
        let second = self.read(delay: 2.0 + secondPhase * self.window)
        let output = first * weight + second * (1.0 - weight)
        self.writeIndex += 1
        if self.writeIndex == self.samples.count { self.writeIndex = 0 }
        self.phase += self.phaseStep
        if self.phase < 0.0 { self.phase += 1.0 }
        if self.phase >= 1.0 { self.phase -= 1.0 }
        return output
    }

    private func read(delay: Double) -> Double {
        var position = Double(self.writeIndex) - delay
        if position < 0.0 { position += Double(self.samples.count) }
        let lower = Int(position)
        let upper = lower + 1 == self.samples.count ? 0 : lower + 1
        let fraction = position - Double(lower)
        return self.samples[lower] * (1.0 - fraction) + self.samples[upper] * fraction
    }

    func reset() {
        for index in self.samples.indices { self.samples[index] = 0.0 }
        self.writeIndex = 0
        self.phase = 0.0
        self.inputLow1 = 0.0
        self.inputLow2 = 0.0
    }
}

private final class WhitegramVoiceEchoLine {
    private let wet: Double
    private let feedback: Double
    private var samples: [Double]
    private var writeIndex = 0

    init(sampleRate: Double, delay: Double, amount: Double) {
        self.samples = Array(repeating: 0.0, count: max(1, Int((sampleRate * delay).rounded())))
        self.wet = 0.6 * amount
        self.feedback = 0.5 * amount
    }

    func process(_ input: Double) -> Double {
        let delayed = self.samples[self.writeIndex]
        self.samples[self.writeIndex] = min(4.0, max(-4.0, input + delayed * self.feedback))
        self.writeIndex += 1
        if self.writeIndex == self.samples.count { self.writeIndex = 0 }
        return (input + delayed * self.wet) / (1.0 + self.wet)
    }

    func reset() {
        for index in self.samples.indices { self.samples[index] = 0.0 }
        self.writeIndex = 0
    }
}
