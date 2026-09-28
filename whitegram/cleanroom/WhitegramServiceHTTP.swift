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
    @discardableResult
    func send(_ request: URLRequest, maximumResponseBytes: Int, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable
}

/// Ephemeral URLSession networking with the system's proxy, VPN and TLS configuration.
public final class WhitegramURLSessionTransport: WhitegramServiceTransport {
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
}

private final class WhitegramURLSessionRequest: NSObject, URLSessionDataDelegate, WhitegramServiceCancellable, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumResponseBytes: Int
    private var completion: ((Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void)?
    private var session: URLSession?
    private var buffer = Data()
    private var response: HTTPURLResponse?

    init(maximumResponseBytes: Int, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) {
        self.maximumResponseBytes = maximumResponseBytes
        self.completion = completion
        super.init()
    }

    func start(_ request: URLRequest, configuration: URLSessionConfiguration) {
        guard let url = request.url, url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else {
            self.finish(.failure(.invalidResponse))
            return
        }
        guard self.maximumResponseBytes > 0, request.httpBodyStream == nil, (request.httpBody?.count ?? 0) <= WhitegramServiceLimits.maximumRequestBytes else {
            self.finish(.failure(.requestTooLarge))
            return
        }
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = WhitegramServiceLimits.requestTimeout
        configuration.timeoutIntervalForResource = WhitegramServiceLimits.resourceTimeout
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .userInitiated
        self.lock.lock()
        guard self.completion != nil else { self.lock.unlock(); return }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        let task = session.dataTask(with: request)
        self.lock.unlock()
        task.resume()
    }

    func cancel() {
        self.finish(.failure(.cancelled))
    }

    private func finish(_ result: Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) {
        self.lock.lock()
        guard let completion = self.completion else { self.lock.unlock(); return }
        self.completion = nil
        let session = self.session
        self.session = nil
        self.buffer = Data()
        self.response = nil
        self.lock.unlock()
        session?.invalidateAndCancel()
        completion(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        self.finish(.failure(.redirectRefused))
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
        let active = self.completion != nil
        if active { self.response = response }
        self.lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.lock.lock()
        guard self.completion != nil else { self.lock.unlock(); return }
        guard data.count <= self.maximumResponseBytes - self.buffer.count else {
            self.lock.unlock()
            self.finish(.failure(.responseTooLarge))
            return
        }
        self.buffer.append(data)
        self.lock.unlock()
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
