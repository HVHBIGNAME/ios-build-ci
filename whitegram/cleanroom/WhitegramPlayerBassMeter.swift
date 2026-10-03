import Foundation

/// 44.1 kHz stereo renderer meter. Observes PCM without altering it.
public struct WhitegramPlayerBassMeter {
    private var lowLeft: Float = 0
    private var lowRight: Float = 0
    private var energy: Float = 0
    private var frames = 0
    public private(set) var level: Float = 0
    private let alpha = Float(1 - exp(-2 * Double.pi * 180 / 44100))

    public init() {}

    public mutating func append(left: Int16, right: Int16) {
        self.lowLeft += self.alpha * (Float(left) / 32768 - self.lowLeft)
        self.lowRight += self.alpha * (Float(right) / 32768 - self.lowRight)
        self.energy += (self.lowLeft * self.lowLeft + self.lowRight * self.lowRight) * 0.5
        self.frames += 1
        if self.frames == 1200 {
            self.level = min(1, sqrt(self.energy / 1200) * 3)
            self.energy = 0
            self.frames = 0
        }
    }

    public mutating func reset() { self = WhitegramPlayerBassMeter() }
}
