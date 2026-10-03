import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WhitegramVoiceProcessingError: Error, LocalizedError {
    case cancelled, invalidAudio, tooLong, invalidCredential, missingVoice, proxyUnavailable
    case speechPermission, speechUnavailable, transcriptionFailed, timedOut, invalidResponse
    case credentialStore(Int32), http(Int), transport(Error), conversion(Error)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Voice processing was cancelled."
        case .invalidAudio: return "The audio could not be decoded."
        case .tooLong: return "This audio exceeds the 20-minute processing limit."
        case .invalidCredential: return "Enter a valid ElevenLabs API key in Voice Effects."
        case .missingVoice: return "Choose an ElevenLabs voice in Voice Effects."
        case .proxyUnavailable: return "The Whitegram voice proxy is not connected. Choose Direct ElevenLabs to use your own API key."
        case .speechPermission: return "Speech recognition permission is required for word bleeping."
        case .speechUnavailable: return "Speech recognition is unavailable for this language or device."
        case .transcriptionFailed: return "Speech recognition could not produce word timings. The recording has not been sent."
        case .timedOut: return "Voice processing timed out. The recording has not been sent."
        case .invalidResponse: return "The voice service returned an invalid response."
        case let .credentialStore(status): return "The voice API key could not be accessed (Keychain \(status))."
        case .http(401): return "ElevenLabs rejected the API key (401)."
        case .http(429): return "ElevenLabs quota or rate limit was reached (429)."
        case let .http(status): return "The voice service returned HTTP \(status)."
        case .transport: return "The voice service could not be reached."
        case .conversion: return "The converted audio could not be encoded."
        }
    }
}

public final class WhitegramVoiceTask {
    private let lock = NSLock()
    private var cancelled = false
    private var cancellation: [() -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }

    public func check() throws {
        if self.isCancelled { throw WhitegramVoiceProcessingError.cancelled }
    }

    public func onCancel(_ action: @escaping () -> Void) {
        self.lock.lock()
        let cancelled = self.cancelled
        if !cancelled { self.cancellation.append(action) }
        self.lock.unlock()
        if cancelled { action() }
    }

    public func cancel() {
        self.lock.lock()
        self.cancelled = true
        let actions = self.cancellation
        self.cancellation.removeAll()
        self.lock.unlock()
        for action in actions { action() }
    }
}

public struct WhitegramVoiceRemoteVoice: Decodable, Equatable {
    public let id: String
    public let name: String
    public let previewURL: String?
    enum CodingKeys: String, CodingKey {
        case id = "voice_id"
        case name
        case previewURL = "preview_url"
    }
}

public final class WhitegramVoiceRemoteService {
    public typealias ProxyRequest = (_ path: String, _ method: String, _ apiKey: String?, _ accept: String) throws -> URLRequest
    private let configuration: URLSessionConfiguration
    private let proxyRequest: ProxyRequest?
    private let proxySession: URLSession?

    public init(configuration: URLSessionConfiguration = .ephemeral, proxyRequest: ProxyRequest? = nil, proxySession: URLSession? = nil) {
        self.configuration = configuration
        self.proxyRequest = proxyRequest
        self.proxySession = proxySession
    }

    public static func isValidVoiceId(_ value: String) -> Bool {
        return !value.isEmpty && value.utf8.count <= 256 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 95 || $0 == 45
        }
    }

    public func makeRequest(path: String, method: String, key: String, useProxy: Bool, accept: String) throws -> URLRequest {
        if useProxy {
            guard let proxyRequest = self.proxyRequest else { throw WhitegramVoiceProcessingError.proxyUnavailable }
            return try proxyRequest(path, method, key.isEmpty ? nil : key, accept)
        }
        guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else { throw WhitegramVoiceProcessingError.invalidCredential }
        guard path.hasPrefix("/v1/"), let url = URL(string: "https://api.elevenlabs.io" + path) else { throw WhitegramVoiceProcessingError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return request
    }

    public func conversionRequest(wav: Data, voiceId: String, key: String, useProxy: Bool, boundary: String = "WhitegramBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")) throws -> URLRequest {
        guard !wav.isEmpty else { throw WhitegramVoiceProcessingError.invalidAudio }
        guard Self.isValidVoiceId(voiceId) else { throw WhitegramVoiceProcessingError.missingVoice }
        guard !boundary.isEmpty, boundary.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) }) else { throw WhitegramVoiceProcessingError.invalidResponse }
        var request = try self.makeRequest(path: "/v1/speech-to-speech/\(voiceId)?output_format=mp3_44100_128", method: "POST", key: key, useProxy: useProxy, accept: "audio/mpeg")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for (name, value) in [("model_id", "eleven_multilingual_sts_v2"), ("file_format", "other")] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    public func convert(wav: Data, voiceId: String, key: String, useProxy: Bool, task: WhitegramVoiceTask, completion: @escaping (Result<Data, WhitegramVoiceProcessingError>) -> Void) {
        do {
            let request = try self.conversionRequest(wav: wav, voiceId: voiceId, key: key, useProxy: useProxy)
            self.send(request, useProxy: useProxy, task: task) { result in
                completion(result.flatMap { data in
                    let mp3 = data.starts(with: [0x49, 0x44, 0x33]) || (data.count > 1 && data[0] == 0xff && data[1] & 0xe0 == 0xe0)
                    return mp3 ? .success(data) : .failure(.invalidResponse)
                })
            }
        } catch let error as WhitegramVoiceProcessingError {
            completion(.failure(error))
        } catch {
            completion(.failure(.transport(error)))
        }
    }

    public func voices(key: String, useProxy: Bool, task: WhitegramVoiceTask, completion: @escaping (Result<[WhitegramVoiceRemoteVoice], WhitegramVoiceProcessingError>) -> Void) {
        struct Response: Decodable { let voices: [WhitegramVoiceRemoteVoice] }
        do {
            let request = try self.makeRequest(path: "/v1/voices", method: "GET", key: key, useProxy: useProxy, accept: "application/json")
            self.send(request, useProxy: useProxy, task: task) { result in
                completion(result.flatMap { data in
                    do {
                        let voices = try JSONDecoder().decode(Response.self, from: data).voices
                        guard voices.count <= 10000, voices.allSatisfy({ Self.isValidVoiceId($0.id) && !$0.name.isEmpty }), Set(voices.map(\.id)).count == voices.count else { return .failure(.invalidResponse) }
                        return .success(voices)
                    }
                    catch { return .failure(.invalidResponse) }
                })
            }
        } catch let error as WhitegramVoiceProcessingError {
            completion(.failure(error))
        } catch {
            completion(.failure(.transport(error)))
        }
    }

    private func send(_ request: URLRequest, useProxy: Bool, task: WhitegramVoiceTask, completion: @escaping (Result<Data, WhitegramVoiceProcessingError>) -> Void) {
        guard !task.isCancelled else { return }
        if !useProxy {
            _ = WhitegramVoiceHTTP(request: request, configuration: self.configuration, task: task, completion: completion)
            return
        }
        guard let session = self.proxySession else { completion(.failure(.proxyUnavailable)); return }
        let requestTask = session.dataTask(with: request) { data, response, error in
            guard !task.isCancelled else { return }
            if let error { completion(.failure(.transport(error))); return }
            guard let response = response as? HTTPURLResponse else { completion(.failure(.invalidResponse)); return }
            guard (200 ... 299).contains(response.statusCode) else { completion(.failure(.http(response.statusCode))); return }
            guard let data, !data.isEmpty, data.count <= WhitegramVoiceHTTP.maximumBytes else { completion(.failure(.invalidResponse)); return }
            completion(.success(data))
        }
        task.onCancel { requestTask.cancel() }
        requestTask.resume()
    }
}
