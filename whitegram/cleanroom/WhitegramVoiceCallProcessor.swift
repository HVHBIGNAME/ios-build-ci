import Foundation
import TelegramCore

/// One instance per shared call audio device. Only outgoing PCM enters this adapter.
final class WhitegramVoiceCallProcessor {
    private struct Format: Hashable {
        let rate: Int
        let channels: Int
    }
    private let lock = NSLock()
    private var processors: [Format: WhitegramVoicePCMProcessor] = [:]
    private var activeFormat: Format?
    private var observer: NSObjectProtocol?
    private var settings: WhitegramVoiceSettings?

    init() {
        self.reload()
        self.observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main, using: { [weak self] _ in self?.reload() })
    }

    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func reload() {
        var values = WhitegramPreferences.values()
        values["voiceBleepEnabled"] = false
        let settings = WhitegramVoiceSettings(values: values)
        guard settings != self.settings else { return }
        self.settings = settings
        var processors: [Format: WhitegramVoicePCMProcessor] = [:]
        if settings.callsRequested && settings.hasLocalEffect {
            for rate in [8000, 16000, 32000, 44100, 48000, 96000] {
                for channels in [1, 2] {
                    processors[Format(rate: rate, channels: channels)] = WhitegramVoicePCMProcessor(settings: settings, sampleRate: Double(rate), channelCount: channels)
                }
            }
        }
        self.lock.lock()
        let previous = self.processors
        self.processors = processors
        self.activeFormat = nil
        self.lock.unlock()
        withExtendedLifetime(previous) {}
    }

    func reset() {
        self.lock.lock()
        for processor in self.processors.values { processor.reset() }
        self.activeFormat = nil
        self.lock.unlock()
    }

    func process(_ samples: UnsafeMutablePointer<Int16>, frames: Int32, channels: Int32, sampleRate: Int32) {
        guard frames > 0, frames <= 3840, (1 ... 2).contains(channels) else { return }
        self.lock.lock()
        defer { self.lock.unlock() }
        let format = Format(rate: Int(sampleRate), channels: Int(channels))
        if self.activeFormat != format {
            self.processors[format]?.reset()
            self.activeFormat = format
        }
        self.processors[format]?.processInterleaved(UnsafeMutableBufferPointer(start: samples, count: Int(frames) * Int(channels)), frameCount: Int(frames))
    }
}
