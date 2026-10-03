import Foundation
import Speech

final class WhitegramVoiceSpeech {
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var timeout: DispatchWorkItem?
    private var completed = false
    private var completion: ((Result<[WhitegramVoiceWord], WhitegramVoiceProcessingError>) -> Void)?

    init(completion: @escaping (Result<[WhitegramVoiceWord], WhitegramVoiceProcessingError>) -> Void) {
        self.completion = completion
    }

    func start(url: URL, locale: String, task: WhitegramVoiceTask) {
        task.onCancel { DispatchQueue.main.async { self.cancel() } }
        DispatchQueue.main.async {
            guard !task.isCancelled else { return }
            #if os(iOS)
            guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
                self.finish(.failure(.speechPermission))
                return
            }
            #endif
            let begin: (SFSpeechRecognizerAuthorizationStatus) -> Void = { authorization in
                DispatchQueue.main.async {
                    guard !self.completed, !task.isCancelled else { return }
                    guard authorization == .authorized else { self.finish(.failure(.speechPermission)); return }
                    self.recognize(url: url, locale: locale)
                }
            }
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                SFSpeechRecognizer.requestAuthorization(begin)
            } else {
                begin(SFSpeechRecognizer.authorizationStatus())
            }
        }
    }

    private func recognize(url: URL, locale: String) {
        let identifier = locale.replacingOccurrences(of: "_", with: "-")
        let common = ["ru": "ru-RU", "en": "en-US", "uk": "uk-UA", "de": "de-DE", "fr": "fr-FR", "es": "es-ES", "it": "it-IT", "pt": "pt-BR", "zh": "zh-CN"]
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: common[identifier] ?? identifier)), recognizer.isAvailable else {
            self.finish(.failure(.speechUnavailable))
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if #available(iOS 13.0, macOS 10.15, *) { request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition }
        let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(.timedOut)) }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
        self.recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.completed else { return }
                if let result, result.isFinal {
                    let words = result.bestTranscription.segments.map { WhitegramVoiceWord(text: $0.substring, timestamp: $0.timestamp, duration: $0.duration) }
                    self.finish(words.isEmpty ? .failure(.transcriptionFailed) : .success(words))
                } else if error != nil {
                    self.finish(.failure(.transcriptionFailed))
                }
            }
        }
    }

    private func finish(_ result: Result<[WhitegramVoiceWord], WhitegramVoiceProcessingError>) {
        guard !self.completed else { return }
        let completion = self.completion
        self.cancel()
        completion?(result)
    }

    private func cancel() {
        self.completed = true
        self.timeout?.cancel()
        self.timeout = nil
        self.recognition?.cancel()
        self.recognition = nil
        self.recognizer = nil
        self.completion = nil
    }
}
