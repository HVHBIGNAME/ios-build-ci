import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WhitegramTranslationGoogleError: Error, Equatable {
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case httpStatus(Int)
    case cancelled
    case timedOut
    case network
}

/// The original Local Translation provider is Google's client-side HTTPS API.
public enum WhitegramTranslationGoogle {
    public static let maximumResponseBytes = 1024 * 1024

    @discardableResult
    public static func translate(text: String, fromLang: String?, toLang: String, configuration: URLSessionConfiguration = .ephemeral, completion: @escaping (Result<String, WhitegramTranslationGoogleError>) -> Void) -> WhitegramTranslationGoogleRequest {
        let operation = WhitegramTranslationGoogleRequest(completion: completion)
        do {
            operation.start(try self.request(text: text, fromLang: fromLang, toLang: toLang), configuration: configuration)
        } catch {
            operation.finish(.failure(error as? WhitegramTranslationGoogleError ?? .invalidRequest))
        }
        return operation
    }

    static func request(text: String, fromLang: String?, toLang: String) throws -> URLRequest {
        func language(_ value: String) throws -> String {
            let code = value.replacingOccurrences(of: "_", with: "-")
            guard !code.isEmpty, code.utf8.count <= 32,
                  code.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                throw WhitegramTranslationGoogleError.invalidRequest
            }
            return code
        }
        guard WhitegramTranslationTextRules.hasText(text), text.utf16.count <= WhitegramTranslationTextRules.maximumSourceUTF16Length else {
            throw WhitegramTranslationGoogleError.invalidRequest
        }
        let source = try language(fromLang.flatMap { $0.isEmpty ? nil : $0 } ?? "auto")
        let target = try language(toLang)
        guard target.lowercased() != "auto" else { throw WhitegramTranslationGoogleError.invalidRequest }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "translate.googleapis.com"
        components.path = "/translate_a/single"
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "oe", value: "UTF-8"),
            URLQueryItem(name: "otf", value: "1"),
            URLQueryItem(name: "ssel", value: "0"),
            URLQueryItem(name: "tsel", value: "0"),
            URLQueryItem(name: "kc", value: "7"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components.url else { throw WhitegramTranslationGoogleError.invalidRequest }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func response(status: Int, data: Data) throws -> String {
        guard status == 200 else { throw WhitegramTranslationGoogleError.httpStatus(status) }
        guard data.count <= self.maximumResponseBytes else { throw WhitegramTranslationGoogleError.responseTooLarge }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
                  let blocks = root.first as? [[Any]], !blocks.isEmpty else { throw WhitegramTranslationGoogleError.invalidResponse }
            var result = ""
            for block in blocks {
                guard let text = block.first as? String else { throw WhitegramTranslationGoogleError.invalidResponse }
                result += text
                guard result.utf16.count <= WhitegramTranslationTextRules.maximumResultUTF16Length else { throw WhitegramTranslationGoogleError.responseTooLarge }
            }
            guard WhitegramTranslationTextRules.hasText(result) else { throw WhitegramTranslationGoogleError.invalidResponse }
            return result
        } catch let error as WhitegramTranslationGoogleError {
            throw error
        } catch {
            throw WhitegramTranslationGoogleError.invalidResponse
        }
    }
}

/// Completion is asynchronous on the main queue. Cancelling before delivery wins over a queued result.
public final class WhitegramTranslationGoogleRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Result<String, WhitegramTranslationGoogleError>) -> Void)?
    private var session: URLSession?
    private var status: Int?
    private var buffer = Data()
    private var finishing = false
    private var cancelled = false

    init(completion: @escaping (Result<String, WhitegramTranslationGoogleError>) -> Void) {
        self.completion = completion
        super.init()
    }

    func start(_ request: URLRequest, configuration: URLSessionConfiguration) {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.lock.lock()
        guard !self.finishing, !self.cancelled else { self.lock.unlock(); return }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.lock.unlock()
        task.resume()
    }

    public func cancel() {
        self.lock.lock()
        if self.completion != nil { self.cancelled = true }
        self.lock.unlock()
        self.finish(.failure(.cancelled))
    }

    func finish(_ result: Result<String, WhitegramTranslationGoogleError>) {
        self.lock.lock()
        guard !self.finishing else { self.lock.unlock(); return }
        self.finishing = true
        let session = self.session
        self.session = nil
        self.buffer = Data()
        self.lock.unlock()
        session?.invalidateAndCancel()
        DispatchQueue.main.async {
            self.lock.lock()
            let completion = self.completion
            self.completion = nil
            let cancelled = self.cancelled
            self.lock.unlock()
            completion?(cancelled ? .failure(.cancelled) : result)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        self.finish(.failure(.httpStatus(response.statusCode)))
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            self.finish(.failure(.invalidResponse))
            return
        }
        guard response.statusCode == 200 else {
            completionHandler(.cancel)
            self.finish(.failure(.httpStatus(response.statusCode)))
            return
        }
        guard response.expectedContentLength <= Int64(WhitegramTranslationGoogle.maximumResponseBytes) else {
            completionHandler(.cancel)
            self.finish(.failure(.responseTooLarge))
            return
        }
        self.lock.lock()
        let active = !self.finishing
        if active { self.status = response.statusCode }
        self.lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.lock.lock()
        guard !self.finishing else { self.lock.unlock(); return }
        guard data.count <= WhitegramTranslationGoogle.maximumResponseBytes - self.buffer.count else {
            self.lock.unlock()
            self.finish(.failure(.responseTooLarge))
            return
        }
        self.buffer.append(data)
        self.lock.unlock()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as NSError? {
            let code: WhitegramTranslationGoogleError
            switch (error.domain, error.code) {
            case (NSURLErrorDomain, NSURLErrorCancelled): code = .cancelled
            case (NSURLErrorDomain, NSURLErrorTimedOut): code = .timedOut
            default: code = .network
            }
            self.finish(.failure(code))
            return
        }
        self.lock.lock()
        let status = self.status
        let data = self.buffer
        self.lock.unlock()
        do {
            guard let status else { throw WhitegramTranslationGoogleError.invalidResponse }
            self.finish(.success(try WhitegramTranslationGoogle.response(status: status, data: data)))
        } catch {
            self.finish(.failure(error as? WhitegramTranslationGoogleError ?? .invalidResponse))
        }
    }
}
