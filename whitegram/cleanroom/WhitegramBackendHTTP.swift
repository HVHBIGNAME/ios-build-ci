import Foundation
import Security
import CryptoKit

public protocol WhitegramBackendTask: AnyObject { func cancel() }

final class WhitegramBackendCancellation: WhitegramBackendTask {
    private let lock = NSLock()
    private var task: WhitegramBackendTask?
    private var cancellationError: WhitegramBackendError?
    private var completed = false
    private var observers: [NSObjectProtocol] = []

    static func failure<T>(_ error: WhitegramBackendError, completion: @escaping (Result<T, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        let cancellation = WhitegramBackendCancellation()
        DispatchQueue.main.async {
            guard cancellation.claimCompletion() else { return }
            completion(.failure(cancellation.isCancelled ? .cancelled : error))
        }
        return cancellation
    }

    var isCancelled: Bool {
        return error != nil
    }

    var error: WhitegramBackendError? {
        lock.lock()
        defer { lock.unlock() }
        return cancellationError
    }

    func bind(_ task: WhitegramBackendTask) {
        lock.lock()
        let cancelled = cancellationError != nil
        if !cancelled && !completed { self.task = task }
        lock.unlock()
        if cancelled { task.cancel() }
    }

    func claimCompletion() -> Bool {
        lock.lock()
        guard !completed else { lock.unlock(); return false }
        completed = true
        task = nil
        let observers = self.observers
        self.observers.removeAll()
        lock.unlock()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        return true
    }

    func observe(_ observer: NSObjectProtocol) {
        lock.lock()
        let completed = self.completed
        if !completed { observers.append(observer) }
        lock.unlock()
        if completed { NotificationCenter.default.removeObserver(observer) }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func cancel() { cancel(reason: .cancelled) }

    func cancel(reason: WhitegramBackendError) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        if cancellationError == nil { cancellationError = reason }
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

public struct WhitegramBackendHTTPResponse {
    public let data: Data
    public let response: HTTPURLResponse
    public let duration: TimeInterval

    public init(data: Data, response: HTTPURLResponse, duration: TimeInterval) {
        self.data = data
        self.response = response
        self.duration = duration
    }
}

struct WhitegramBackendTransfer {
    var bodyFile: URL?
    var received: ((Data) throws -> Void)?
    var progress: ((Int64, Int64) -> Void)?
    var validateSession: () throws -> Void = {}
}

protocol WhitegramBackendHTTP {
    func execute(_ request: URLRequest, maximumBytes: Int, transfer: WhitegramBackendTransfer,
                 completion: @escaping (Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) -> Void) -> WhitegramBackendTask
}

struct WhitegramBackendPinnedHTTP: WhitegramBackendHTTP {
    private let configuration: () -> URLSessionConfiguration

    init(configuration: @escaping () -> URLSessionConfiguration = { .ephemeral }) { self.configuration = configuration }

    func execute(_ request: URLRequest, maximumBytes: Int, transfer: WhitegramBackendTransfer,
                 completion: @escaping (Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        let task = WhitegramBackendURLTask(maximumBytes: maximumBytes, transfer: transfer, completion: completion)
        task.start(request, configuration: configuration())
        return task
    }

    static func subjectPublicKeyInfo(_ key: Data) -> Data {
        let prefix: [UInt8]
        switch key.count {
        case 65: prefix = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        case 97: prefix = [0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00]
        default: return key
        }
        return Data(prefix) + key
    }

    static func accepts(_ trust: SecTrust) -> Bool {
        guard SecTrustEvaluateWithError(trust, nil) else { return false }
        for index in 0..<SecTrustGetCertificateCount(trust) {
            guard let certificate = SecTrustGetCertificateAtIndex(trust, index), let key = SecCertificateCopyKey(certificate),
                  let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data? else { continue }
            let digest = Data(SHA256.hash(data: subjectPublicKeyInfo(bytes))).base64EncodedString()
            if WhitegramBackendProtocol.spkiPins.contains(digest) { return true }
        }
        return false
    }
}

private final class WhitegramBackendURLTask: NSObject, WhitegramBackendTask, URLSessionDataDelegate {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let transfer: WhitegramBackendTransfer
    private var completion: ((Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var terminalError: WhitegramBackendError?
    private let startedAt = ProcessInfo.processInfo.systemUptime

    init(maximumBytes: Int, transfer: WhitegramBackendTransfer, completion: @escaping (Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) -> Void) {
        self.maximumBytes = maximumBytes
        self.transfer = transfer
        self.completion = completion
    }

    func start(_ request: URLRequest, configuration: URLSessionConfiguration) {
        guard let url = request.url, url.scheme == "https", url.host == WhitegramBackendProtocol.baseURL.host,
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              request.httpBodyStream == nil, maximumBytes > 0, maximumBytes <= WhitegramBackendProtocol.maximumResponseBytes else {
            finish(.failure(.invalidRequest)); return
        }
        if let file = transfer.bodyFile {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard file.isFileURL, request.httpBody == nil, values.isRegularFile == true, values.isSymbolicLink == false,
                      let size = values.fileSize, size > 0, Int64(size) <= WhitegramBackendProtocol.maximumUploadBytes else {
                    throw WhitegramBackendError.invalidRequest
                }
            } catch { finish(.failure(.invalidRequest)); return }
        }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = transfer.bodyFile == nil ? 60 : 600
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        let task: URLSessionDataTask
        if let file = transfer.bodyFile { task = session.uploadTask(with: request, fromFile: file) }
        else { task = session.dataTask(with: request) }
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() { abort(.cancelled) }

    private func abort(_ error: WhitegramBackendError) {
        lock.lock()
        if terminalError == nil { terminalError = error }
        let task = self.task
        lock.unlock()
        // Completion waits for URLSession to stop reading an upload file.
        if let task { task.cancel() }
        else { finish(.failure(error)) }
    }

    private var failure: WhitegramBackendError? {
        lock.lock()
        defer { lock.unlock() }
        return terminalError
    }

    private func finish(_ result: Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        if let completion { DispatchQueue.main.async { completion(result) } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.protectionSpace.host == WhitegramBackendProtocol.baseURL.host,
              let trust = challenge.protectionSpace.serverTrust, WhitegramBackendPinnedHTTP.accepts(trust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            abort(.invalidResponse)
            return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            abort(.responseTooLarge)
            return
        }
        self.response = response
        do {
            if let failure { throw failure }
            try transfer.validateSession()
        } catch {
            completionHandler(.cancel)
            abort(error as? WhitegramBackendError ?? .invalidResponse)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil else { return }
        guard chunk.count <= maximumBytes - data.count else { abort(.responseTooLarge); return }
        data.append(chunk)
        do {
            try transfer.validateSession()
            if let response, (200..<300).contains(response.statusCode) { try transfer.received?(chunk) }
        } catch { abort(error as? WhitegramBackendError ?? .invalidResponse) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard failure == nil else { return }
        do {
            try transfer.validateSession()
            transfer.progress?(totalBytesSent, totalBytesExpectedToSend)
        } catch { abort(error as? WhitegramBackendError ?? .invalidResponse) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure { finish(.failure(failure)) }
        else if let error = error as NSError? {
            finish(.failure(error.code == NSURLErrorCancelled ? .cancelled : .transport(error.code)))
        } else if let response {
            finish(.success(WhitegramBackendHTTPResponse(data: data, response: response, duration: ProcessInfo.processInfo.systemUptime - startedAt)))
        } else { finish(.failure(.invalidResponse)) }
    }
}
