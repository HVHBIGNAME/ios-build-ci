import Foundation

final class WhitegramPluginHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Request {
        let task: URLSessionDataTask
        let started = Date()
        let completion: (Result<Any, WhitegramPluginError>) -> Void
        var response: HTTPURLResponse?
        var data = Data()

        init(task: URLSessionDataTask, completion: @escaping (Result<Any, WhitegramPluginError>) -> Void) {
            self.task = task
            self.completion = completion
        }
    }

    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var invalidated = false
    private var session: URLSession!

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.name = "WhitegramPlugin.HTTP"
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    private static func validatedURL(_ text: String) throws -> URL {
        guard text.utf8.count <= 8192, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw WhitegramPluginError("INVALID_URL", "HTTP requests require an http(s) URL without embedded credentials")
        }
        return url
    }

    static func makeRequest(_ options: [String: Any]) throws -> URLRequest {
        guard let urlText = options["url"] as? String else { throw WhitegramPluginError("INVALID_ARGUMENT", "HTTP request requires url") }
        let url = try Self.validatedURL(urlText)
        let method = try whitegramPluginString([options["method"] ?? "GET"], 0).uppercased()
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else {
            throw WhitegramPluginError("INVALID_ARGUMENT", "Unsupported HTTP method")
        }
        let timeout = try whitegramPluginNumber([options["timeout"] ?? 30], 0)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: min(60, max(1, timeout)))
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        if let headers = options["headers"] {
            guard let headers = headers as? [String: String], headers.count <= 64 else { throw WhitegramPluginError("INVALID_ARGUMENT", "headers must be a string dictionary") }
            for (name, value) in headers {
                guard !name.isEmpty, name.utf8.count <= 128, value.utf8.count <= 8192,
                      name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~").contains($0) }),
                      !value.contains("\r"), !value.contains("\n"), !value.contains("\0"),
                      !["host", "content-length", "connection", "transfer-encoding", "proxy-authorization"].contains(name.lowercased()) else {
                    throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid or transport-owned HTTP header: \(name)")
                }
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        if let encoded = options["bodyBase64"] {
            guard options["body"] == nil else { throw WhitegramPluginError("INVALID_ARGUMENT", "Choose body or bodyBase64, not both") }
            let encoded = try whitegramPluginString([encoded], 0)
            guard let data = Data(base64Encoded: encoded) else { throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid bodyBase64") }
            request.httpBody = data
        } else if let body = options["body"], !(body is NSNull) {
            if let text = body as? String {
                request.httpBody = Data(text.utf8)
            } else if let object = body as? [String: String], let encoded = object["__wgBase64"] {
                guard let data = Data(base64Encoded: encoded) else { throw WhitegramPluginError("INVALID_ARGUMENT", "Invalid byte body") }
                request.httpBody = data
            } else {
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
                if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
            }
        }
        guard (request.httpBody?.count ?? 0) <= WhitegramPluginStorage.maximumFileBytes else { throw WhitegramPluginError("QUOTA_EXCEEDED", "HTTP body is too large") }
        return request
    }

    @discardableResult
    func request(_ options: [String: Any], completion: @escaping (Result<Any, WhitegramPluginError>) -> Void) throws -> Int {
        let request = try Self.makeRequest(options)
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.invalidated else { throw WhitegramPluginError("PLUGIN_STOPPED", "HTTP client is closed") }
        guard self.requests.count < 16 else { throw WhitegramPluginError("QUOTA_EXCEEDED", "Too many HTTP requests") }
        let task = self.session.dataTask(with: request)
        self.requests[task.taskIdentifier] = Request(task: task, completion: completion)
        task.resume()
        return task.taskIdentifier
    }

    func cancel(_ id: Int) {
        self.lock.lock()
        let request = self.requests.removeValue(forKey: id)
        self.lock.unlock()
        request?.task.cancel()
    }

    func invalidate() {
        self.lock.lock()
        self.invalidated = true
        let requests = Array(self.requests.values)
        self.requests.removeAll()
        self.lock.unlock()
        for request in requests { request.task.cancel() }
        self.session.invalidateAndCancel()
    }

    private func fail(_ task: URLSessionTask, _ error: WhitegramPluginError) {
        self.lock.lock()
        let request = self.requests.removeValue(forKey: task.taskIdentifier)
        self.lock.unlock()
        task.cancel()
        request?.completion(.failure(error))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            self.fail(dataTask, WhitegramPluginError("HTTP_ERROR", "Expected an HTTP response"))
            return
        }
        guard response.expectedContentLength <= Int64(WhitegramPluginStorage.maximumFileBytes) else {
            completionHandler(.cancel)
            self.fail(dataTask, WhitegramPluginError("QUOTA_EXCEEDED", "HTTP response is too large"))
            return
        }
        self.lock.lock()
        let request = self.requests[dataTask.taskIdentifier]
        request?.response = response
        self.lock.unlock()
        completionHandler(request == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.lock.lock()
        guard let request = self.requests[dataTask.taskIdentifier] else { self.lock.unlock(); return }
        if request.data.count + data.count > WhitegramPluginStorage.maximumFileBytes {
            self.lock.unlock()
            self.fail(dataTask, WhitegramPluginError("QUOTA_EXCEEDED", "HTTP response is too large"))
        } else {
            request.data.append(data)
            self.lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.lock.lock()
        let request = self.requests.removeValue(forKey: task.taskIdentifier)
        self.lock.unlock()
        guard let request = request else { return }
        if let error = error {
            request.completion(.failure(WhitegramPluginError("HTTP_ERROR", error.localizedDescription)))
            return
        }
        guard let response = request.response else {
            request.completion(.failure(WhitegramPluginError("HTTP_ERROR", "No HTTP response received")))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        request.completion(.success([
            "ok": (200 ..< 300).contains(response.statusCode), "status": response.statusCode,
            "url": response.url?.absoluteString ?? "", "headers": headers,
            "body": String(data: request.data, encoding: .utf8) as Any? ?? NSNull(),
            "base64": request.data.base64EncodedString(), "elapsedMs": Date().timeIntervalSince(request.started) * 1000
        ]))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? Self.validatedURL(url.absoluteString)) != nil else {
            completionHandler(nil)
            self.fail(task, WhitegramPluginError("INVALID_URL", "Redirect left HTTP(S)"))
            return
        }
        completionHandler(Self.redirectRequest(request, from: response.url))
    }

    static func redirectRequest(_ request: URLRequest, from old: URL?) -> URLRequest {
        var request = request
        request.httpShouldHandleCookies = false
        let url = request.url
        if old?.host?.lowercased() != url?.host?.lowercased() || old?.scheme?.lowercased() != url?.scheme?.lowercased() || old?.port != url?.port {
            for header in ["Authorization", "Cookie", "Proxy-Authorization"] { request.setValue(nil, forHTTPHeaderField: header) }
        }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Self.handleChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Self.handleChallenge(challenge, completionHandler: completionHandler)
    }

    private static func handleChallenge(_ challenge: URLAuthenticationChallenge, completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
