import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WhitegramServiceHTTPResponse {
    public let statusCode: Int
    public let data: Data
    public let retryAfter: String?

    public init(statusCode: Int, data: Data, retryAfter: String? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.retryAfter = retryAfter
    }

    var cooldownSeconds: Int? {
        if self.statusCode == 429 || (self.statusCode == 503 && self.retryAfter != nil) {
            return whitegramRetryAfter(self.retryAfter)
        }
        return nil
    }
}

/// A transport must call completion exactly once, including after cancellation.
public protocol WhitegramServiceTransport: AnyObject {
    var route: WhitegramServiceRoute { get }
    @discardableResult
    func send(_ request: URLRequest, maximumResponseBytes: Int, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable
}

extension WhitegramServiceTransport {
    public var route: WhitegramServiceRoute { return .direct }
}

public protocol WhitegramServiceUploadTransport: WhitegramServiceTransport {
    /// Validate provider-issued upload destinations for this transport's route.
    func validatedUploadURL(_ value: String) throws -> URL
    /// Complete only after the transport has stopped reading bodyFile, including on cancellation.
    @discardableResult
    func upload(_ request: URLRequest, bodyFile: URL, maximumResponseBytes: Int, progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable
}

extension WhitegramServiceUploadTransport {
    public func validatedUploadURL(_ value: String) throws -> URL {
        return try WhitegramVirusTotalScanWire.uploadURL(value)
    }
}

public protocol WhitegramServiceStreamingTransport: WhitegramServiceTransport {
    /// Invoke received serially, and stop invoking it before delivering completion.
    @discardableResult
    func stream(_ request: URLRequest, maximumResponseBytes: Int, received: @escaping (Data) throws -> Void, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable
}

/// Ephemeral URLSession networking with the system's proxy, VPN and TLS configuration.
public final class WhitegramURLSessionTransport: WhitegramServiceUploadTransport, WhitegramServiceStreamingTransport {
    private let makeConfiguration: () -> URLSessionConfiguration

    public init() {
        self.makeConfiguration = { URLSessionConfiguration.ephemeral }
    }

    init(makeConfiguration: @escaping () -> URLSessionConfiguration) {
        self.makeConfiguration = makeConfiguration
    }

    @discardableResult
    public func send(_ request: URLRequest, maximumResponseBytes: Int, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        let operation = WhitegramURLSessionRequest(maximumResponseBytes: maximumResponseBytes, completion: completion)
        operation.start(request, configuration: self.makeConfiguration())
        return operation
    }

    @discardableResult
    public func upload(_ request: URLRequest, bodyFile: URL, maximumResponseBytes: Int, progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        let operation = WhitegramURLSessionRequest(maximumResponseBytes: maximumResponseBytes, progress: progress, completion: completion)
        operation.start(request, configuration: self.makeConfiguration(), bodyFile: bodyFile)
        return operation
    }

    @discardableResult
    public func stream(_ request: URLRequest, maximumResponseBytes: Int, received: @escaping (Data) throws -> Void, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        let operation = WhitegramURLSessionRequest(maximumResponseBytes: maximumResponseBytes, received: received, completion: completion)
        operation.start(request, configuration: self.makeConfiguration())
        return operation
    }
}

private final class WhitegramURLSessionRequest: NSObject, URLSessionDataDelegate, WhitegramServiceCancellable, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private var completion: ((Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void)?
    private var session: URLSession?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var terminalResult: Result<WhitegramServiceHTTPResponse, WhitegramServiceError>?
    private let progress: ((Int64, Int64) -> Void)?
    private let received: ((Data) throws -> Void)?

    init(maximumResponseBytes: Int, progress: ((Int64, Int64) -> Void)? = nil, received: ((Data) throws -> Void)? = nil, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) {
        self.maximumResponseBytes = maximumResponseBytes
        self.progress = progress
        self.received = received
        self.completion = completion
        super.init()
    }

    func start(_ request: URLRequest, configuration: URLSessionConfiguration, bodyFile: URL? = nil) {
        guard let url = request.url, url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, (whitegramServiceAllowsQuery(url) || bodyFile != nil) else {
            self.finish(.failure(.invalidResponse))
            return
        }
        guard self.maximumResponseBytes > 0, request.httpBodyStream == nil, (request.httpBody?.count ?? 0) <= WhitegramServiceLimits.maximumRequestBytes else {
            self.finish(.failure(.requestTooLarge))
            return
        }
        if let bodyFile {
            guard bodyFile.isFileURL, request.httpBody == nil,
                  let values = try? bodyFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, Int64(size) <= WhitegramServiceLimits.maximumUploadBodyBytes else {
                self.finish(.failure(.fileUnreadable))
                return
            }
        }
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = WhitegramServiceLimits.requestTimeout
        configuration.timeoutIntervalForResource = bodyFile == nil ? WhitegramServiceLimits.resourceTimeout : 600
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        self.lock.lock()
        guard self.completion != nil, self.terminalResult == nil else { self.lock.unlock(); return }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        let task: URLSessionTask
        if let bodyFile {
            task = session.uploadTask(with: request, fromFile: bodyFile)
        } else {
            task = session.dataTask(with: request)
        }
        self.lock.unlock()
        task.resume()
    }

    func cancel() {
        self.finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) {
        self.lock.lock()
        guard self.completion != nil, self.terminalResult == nil else { self.lock.unlock(); return }
        self.terminalResult = result
        let session = self.session
        self.session = nil
        self.buffer = Data()
        self.response = nil
        self.lock.unlock()
        if let session {
            // The completion closure owns the upload snapshot. Keep it until URLSession is quiescent.
            session.invalidateAndCancel()
        } else {
            self.completeAfterInvalidation()
        }
    }

    private func completeAfterInvalidation() {
        self.lock.lock()
        let completion = self.completion
        let result = self.terminalResult ?? .failure(.invalidResponse)
        self.completion = nil
        self.terminalResult = nil
        self.lock.unlock()
        completion?(result)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        self.completeAfterInvalidation()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        self.finish(.failure(.redirectRefused))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        self.lock.lock()
        let active = self.completion != nil && self.terminalResult == nil
        self.lock.unlock()
        if active, totalBytesExpectedToSend >= 0, totalBytesSent <= totalBytesExpectedToSend {
            self.progress?(totalBytesSent, totalBytesExpectedToSend)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            self.finish(.failure(.invalidResponse))
            return
        }
        guard response.expectedContentLength <= Int64(self.maximumResponseBytes) else {
            completionHandler(.cancel)
            self.finish(.failure(.responseTooLarge))
            return
        }
        self.lock.lock()
        let active = self.completion != nil && self.terminalResult == nil
        if active { self.response = response }
        self.lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.lock.lock()
        guard self.completion != nil, self.terminalResult == nil else { self.lock.unlock(); return }
        guard data.count <= self.maximumResponseBytes - self.buffer.count else {
            self.lock.unlock()
            self.finish(.failure(.responseTooLarge))
            return
        }
        self.buffer.append(data)
        let deliver = self.response.map { (200..<300).contains($0.statusCode) } == true
        self.lock.unlock()
        if deliver, let received = self.received {
            do { try received(data) }
            catch { self.finish(.failure(error as? WhitegramServiceError ?? .invalidResponse)) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            let serviceError: WhitegramServiceError
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
                serviceError = .cancelled
            } else if error.domain == NSURLErrorDomain && error.code == NSURLErrorTimedOut {
                serviceError = .timedOut
            } else {
                serviceError = .network(code: error.code)
            }
            self.finish(.failure(serviceError))
            return
        }
        self.lock.lock()
        let response = self.response
        let data = self.buffer
        self.lock.unlock()
        guard let response = response else {
            self.finish(.failure(.invalidResponse))
            return
        }
        self.finish(.success(WhitegramServiceHTTPResponse(statusCode: response.statusCode, data: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))))
    }
}

private func whitegramServiceAllowsQuery(_ url: URL) -> Bool {
    if url.query == nil { return true }
    guard url.host == "generativelanguage.googleapis.com", url.path == "/v1beta/models",
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          !items.isEmpty, Set(items.map { $0.name }).count == items.count else { return false }
    return items.allSatisfy { item in
        guard let value = item.value, value.utf8.count <= 2048 else { return false }
        return (item.name == "pageSize" && value == "20") || (item.name == "pageToken" && !value.isEmpty)
    }
}

func whitegramServiceRequest(url: URL, method: String, apiKey: String, header: String, body: Data? = nil) throws -> URLRequest {
    guard (body?.count ?? 0) <= WhitegramServiceLimits.maximumRequestBytes else { throw WhitegramServiceError.requestTooLarge }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: WhitegramServiceLimits.requestTimeout)
    request.httpMethod = method
    request.httpBody = body
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
    request.setValue(apiKey, forHTTPHeaderField: header)
    return request
}
