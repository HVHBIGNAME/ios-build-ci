import Foundation

public enum WhitegramVoiceRuntime {
    private static let lock = NSLock()
    private static var proxy: WhitegramVoiceRemoteService.ProxyRequest?
    private static var proxySession: URLSession?

    public static func configureProxyRequest(_ request: WhitegramVoiceRemoteService.ProxyRequest?, session: URLSession? = nil) {
        self.lock.lock()
        self.proxy = request
        self.proxySession = session
        self.lock.unlock()
    }

    public static func remoteService() -> WhitegramVoiceRemoteService {
        self.lock.lock()
        let proxy = self.proxy
        let session = self.proxySession
        self.lock.unlock()
        return WhitegramVoiceRemoteService(proxyRequest: proxy, proxySession: session)
    }

    public static func apiKey() throws -> String {
        let stored = try WhitegramVoiceCredentials.read()
        let legacy = WhitegramPreferences.string("voiceChangerApiKey")
        if !legacy.isEmpty {
            if stored == nil || stored?.isEmpty == true { try WhitegramVoiceCredentials.save(legacy) }
            guard WhitegramPreferences.set("", for: "voiceChangerApiKey") else { throw WhitegramVoiceProcessingError.credentialStore(-1) }
        }
        return stored.flatMap { $0.isEmpty ? nil : $0 } ?? legacy
    }

}

public enum WhitegramVoicePostprocessor {
    @discardableResult
    public static func process(data: Data, fileExtension: String = "ogg", settings: WhitegramVoiceSettings, locale: String, trimRange: Range<Double>? = nil, applyLocalEffects: Bool = false, completion: @escaping (Result<WhitegramVoiceProcessedAudio, WhitegramVoiceProcessingError>) -> Void) -> WhitegramVoiceTask {
        let task = WhitegramVoiceTask()
        self.prepare(data: data, fileExtension: fileExtension, settings: settings, locale: locale, trimRange: trimRange, applyLocalEffects: applyLocalEffects, task: task) { result in
            do {
                let samples = try result.get()
                let encoded = try WhitegramVoiceAudioFile.encode(samples, task: task)
                self.deliver(.success(encoded), task: task, completion: completion)
            } catch {
                self.deliver(.failure(self.error(error)), task: task, completion: completion)
            }
        }
        return task
    }

    static func prepare(data: Data, fileExtension: String, settings: WhitegramVoiceSettings, locale: String, trimRange: Range<Double>?, applyLocalEffects: Bool, task: WhitegramVoiceTask, completion: @escaping (Result<[Int16], WhitegramVoiceProcessingError>) -> Void) {
        let service = WhitegramVoiceRuntime.remoteService()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try task.check()
                let directory = try WhitegramVoiceTemporaryDirectory()
                let allowed = ["ogg", "opus", "wav", "mp3", "m4a", "mp4", "mov", "caf", "aiff", "aac"]
                guard allowed.contains(fileExtension.lowercased()) else { throw WhitegramVoiceProcessingError.invalidAudio }
                let input = try directory.write(data, name: "input." + fileExtension.lowercased())
                var samples = try WhitegramVoiceAudioFile.decode(input, task: task)
                if let trimRange {
                    guard trimRange.lowerBound.isFinite, trimRange.upperBound.isFinite, trimRange.lowerBound >= 0, trimRange.upperBound > trimRange.lowerBound else { throw WhitegramVoiceProcessingError.invalidAudio }
                    let duration = Double(samples.count) / 48000
                    let lower = Int(min(duration, trimRange.lowerBound) * 48000)
                    let upper = Int(min(duration, trimRange.upperBound) * 48000)
                    guard lower < upper else { throw WhitegramVoiceProcessingError.invalidAudio }
                    samples = Array(samples[lower ..< upper])
                }
                try self.transform(samples: samples, directory: directory, settings: settings, locale: locale, applyLocalEffects: applyLocalEffects, service: service, task: task, completion: completion)
            } catch {
                completion(.failure(self.error(error)))
            }
        }
    }

    static func transform(samples: [Int16], directory: WhitegramVoiceTemporaryDirectory, settings: WhitegramVoiceSettings, locale: String, applyLocalEffects: Bool, service: WhitegramVoiceRemoteService, task: WhitegramVoiceTask, completion: @escaping (Result<[Int16], WhitegramVoiceProcessingError>) -> Void) throws {
        var samples = samples
        if applyLocalEffects {
            let processor = WhitegramVoiceProcessor(settings: settings)
            let sampleCount = samples.count
            try samples.withUnsafeMutableBufferPointer { buffer in
                for offset in stride(from: 0, to: sampleCount, by: 960) {
                    try task.check()
                    processor.process(UnsafeMutableBufferPointer(start: buffer.baseAddress!.advanced(by: offset), count: min(960, sampleCount - offset)))
                }
            }
        }
        self.bleep(samples: samples, directory: directory, settings: settings, locale: locale, task: task) { result in
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(samples):
                self.convert(samples: samples, directory: directory, settings: settings, service: service, task: task, completion: completion)
            }
        }
    }

    private static func bleep(samples: [Int16], directory: WhitegramVoiceTemporaryDirectory, settings: WhitegramVoiceSettings, locale: String, task: WhitegramVoiceTask, completion: @escaping (Result<[Int16], WhitegramVoiceProcessingError>) -> Void) {
        guard settings.bleepEnabled, !settings.bleepWholeRecording, let mode = settings.bleepMode else { completion(.success(samples)); return }
        do {
            let url = try directory.write(WhitegramVoiceAudioFile.wav(samples), name: "transcribe.wav")
            WhitegramVoiceProfanityStore.shared.ensureLoaded(task: task) { matcher in
            let speech = WhitegramVoiceSpeech { result in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !task.isCancelled else { return }
                    switch result {
                    case let .failure(error): completion(.failure(error))
                    case let .success(words):
                        var output = samples
                        let ranges = WhitegramVoiceSelectiveBleep.ranges(words: words, sampleRate: 48000, sampleCount: samples.count, matcher: matcher)
                        WhitegramVoiceSelectiveBleep.apply(&output, sampleRate: 48000, ranges: ranges, mode: mode)
                        completion(.success(output))
                    }
                    withExtendedLifetime(directory) {}
                }
            }
            speech.start(url: url, locale: locale, task: task)
            }
        } catch {
            completion(.failure(self.error(error)))
        }
    }

    private static func convert(samples: [Int16], directory: WhitegramVoiceTemporaryDirectory, settings: WhitegramVoiceSettings, service: WhitegramVoiceRemoteService, task: WhitegramVoiceTask, completion: @escaping (Result<[Int16], WhitegramVoiceProcessingError>) -> Void) {
        do {
            try task.check()
            guard settings.enabled && settings.mode == .remote else { completion(.success(samples)); return }
            let key = try WhitegramVoiceRuntime.apiKey()
            service.convert(wav: WhitegramVoiceAudioFile.wav(samples), voiceId: settings.voiceId, key: key, useProxy: settings.useProxy, task: task) { result in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try result.get()
                        try task.check()
                        let url = try directory.write(data, name: "converted.mp3")
                        completion(.success(try WhitegramVoiceAudioFile.decode(url, task: task)))
                    } catch {
                        completion(.failure(self.error(error)))
                    }
                }
            }
        } catch {
            completion(.failure(self.error(error)))
        }
    }

    static func error(_ error: Error) -> WhitegramVoiceProcessingError {
        return (error as? WhitegramVoiceProcessingError) ?? .conversion(error)
    }

    static func deliver<T>(_ result: Result<T, WhitegramVoiceProcessingError>, task: WhitegramVoiceTask, completion: @escaping (Result<T, WhitegramVoiceProcessingError>) -> Void) {
        DispatchQueue.main.async {
            guard !task.isCancelled else { return }
            completion(result)
            task.cancel()
        }
    }
}
