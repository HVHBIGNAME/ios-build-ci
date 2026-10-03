import Foundation

final class WhitegramBackendClient {
    static let sessionUpdated = Notification.Name("WhitegramBackendSessionUpdated")
    let userId: Int64
    let sessions: WhitegramBackendSessionStorage
    let access: WhitegramBackendAccessStore
    private let http: WhitegramBackendHTTP
    let now: () -> Date
    private let deviceSignature: (String) throws -> String?
    private let applicationKey: () throws -> Data
    private let recordUsage: (String) -> Void
    private let lock = NSRecursiveLock()
    private var limitedUntil: [String: Date] = [:]

    init(userId: Int64, sessions: WhitegramBackendSessionStorage = WhitegramBackendKeychain.shared,
         http: WhitegramBackendHTTP = WhitegramBackendPinnedHTTP(), now: @escaping () -> Date = Date.init,
         access: WhitegramBackendAccessStore = .shared,
         recordUsage: @escaping (String) -> Void = WhitegramAPIUsage.shared.record,
         applicationKey: @escaping () throws -> Data = { try WhitegramBackendProtocol.configuredApplicationKey() },
         deviceSignature: @escaping (String) throws -> String? = WhitegramBackendIdentity.shared.sign) {
        self.userId = userId
        self.sessions = sessions
        self.access = access
        self.http = http
        self.now = now
        self.deviceSignature = deviceSignature
        self.applicationKey = applicationKey
        self.recordUsage = recordUsage
    }

    func hasSession() throws -> Bool {
        guard let session = try sessions.load(userId: userId) else { return false }
        do { try session.validate(userId: userId, now: now()); return true }
        catch WhitegramBackendError.missingSession { return false }
    }

    func makeRequest(path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                     contentType: String? = nil, accept: String = "application/json", providerKey: String? = nil,
                     authenticated: Bool = true) throws -> (URLRequest, WhitegramBackendSession?) {
        lock.lock()
        defer { lock.unlock() }
        if let until = limitedUntil[path], until > now() { throw WhitegramBackendError.http(429, retryAfter: until.timeIntervalSince(now())) }
        let session = authenticated ? try sessions.load(userId: userId) : nil
        if authenticated {
            guard let session else { throw WhitegramBackendError.missingSession }
            try session.validate(userId: userId, now: now())
        }
        try access.require(userId: userId, path: path, now: now())
        guard ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method), body.map({ $0.count <= WhitegramBackendProtocol.maximumResponseBytes }) ?? true else {
            throw WhitegramBackendError.invalidRequest
        }
        for value in [contentType, accept, providerKey].compactMap({ $0 }) {
            guard !value.isEmpty, value.utf8.count <= 16384, value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 && $0.value < 127 }) else {
                throw WhitegramBackendError.invalidRequest
            }
        }
        if providerKey != nil, !authenticated || !path.hasPrefix("/v1/proxy/") { throw WhitegramBackendError.invalidRequest }
        var request = URLRequest(url: try WhitegramBackendProtocol.url(path: path, query: query), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if body != nil || contentType != nil { request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(providerKey, forHTTPHeaderField: "X-Provider-Key")
        try WhitegramBackendProtocol.sign(&request, date: now(), session: session, applicationKey: try applicationKey(), deviceSignature: deviceSignature)
        return (request, session)
    }

    @discardableResult
    func raw(path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, contentType: String? = nil,
             authenticated: Bool = true, maximumBytes: Int = WhitegramBackendProtocol.maximumResponseBytes,
             accept: String = "application/json", providerKey: String? = nil, preserveHTTPStatus: Bool = false,
             bodyFile: URL? = nil, received: ((Data) throws -> Void)? = nil, progress: ((Int64, Int64) -> Void)? = nil,
             completion: @escaping (Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        let cancellation = WhitegramBackendCancellation()
        do {
            guard maximumBytes > 0, maximumBytes <= WhitegramBackendProtocol.maximumResponseBytes else { throw WhitegramBackendError.invalidRequest }
            guard bodyFile == nil || body == nil else { throw WhitegramBackendError.invalidRequest }
            let (request, session) = try makeRequest(path: path, query: query, method: method, body: body,
                contentType: contentType, accept: accept, providerKey: providerKey, authenticated: authenticated)
            let validateSession = { [self] in
                if let error = cancellation.error { throw error }
                if let session {
                    guard try sessions.load(userId: userId) == session else { throw WhitegramBackendError.sessionChanged }
                    try session.validate(userId: userId, now: now())
                }
                try access.require(userId: userId, path: path, now: now())
            }
            let transfer = WhitegramBackendTransfer(bodyFile: bodyFile, received: received, progress: progress, validateSession: validateSession)
            if authenticated {
                for name in [Self.sessionUpdated, WhitegramBackendAccessStore.updated] {
                    cancellation.observe(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [self, weak cancellation] notification in
                        guard notification.userInfo?["userId"] as? Int64 == userId else { return }
                        do { try validateSession() }
                        catch { cancellation?.cancel(reason: error as? WhitegramBackendError ?? .invalidResponse) }
                    })
                }
            }
            try validateSession()
            recordUsage(path)
            let task = http.execute(request, maximumBytes: maximumBytes, transfer: transfer) { [self] result in
                DispatchQueue.main.async { [self] in
                    guard cancellation.claimCompletion() else { return }
                    let checked: Result<WhitegramBackendHTTPResponse, WhitegramBackendError>
                    do {
                        try validateSession()
                        let response = try result.get()
                        guard response.data.count <= maximumBytes else { throw WhitegramBackendError.responseTooLarge }
                        let status = response.response.statusCode
                        if !(200..<300).contains(status) {
                            let retry = WhitegramBackendProtocol.retryAfter(response.response, now: now())
                            if status == 429 {
                                lock.lock()
                                limitedUntil[path] = now().addingTimeInterval(retry ?? 60)
                                lock.unlock()
                            }
                            if status == 401, !path.hasPrefix("/v1/proxy/"), let session, try sessions.remove(userId: userId, matching: session) {
                                access.reset(userId: userId)
                                NotificationCenter.default.post(name: Self.sessionUpdated, object: nil, userInfo: ["userId": userId])
                            }
                            if !preserveHTTPStatus { throw WhitegramBackendError.http(status, retryAfter: retry) }
                        }
                        checked = .success(response)
                    } catch let error as WhitegramBackendError { checked = .failure(error) }
                    catch { checked = .failure(.invalidResponse) }
                    completion(checked)
                }
            }
            cancellation.bind(task)
        } catch let error as WhitegramBackendError {
            DispatchQueue.main.async {
                guard cancellation.claimCompletion() else { return }
                completion(.failure(cancellation.error ?? error))
            }
        } catch {
            DispatchQueue.main.async {
                guard cancellation.claimCompletion() else { return }
                completion(.failure(cancellation.error ?? .invalidRequest))
            }
        }
        return cancellation
    }

    @discardableResult
    func request<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil,
                               authenticated: Bool = true, completion: @escaping (Result<T, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return raw(path: path, query: query, method: method, body: body, authenticated: authenticated) { result in
            completion(result.flatMap { response in
                do { return .success(try WhitegramBackendDecoding.decode(T.self, from: response.data)) }
                catch { return .failure(.invalidResponse) }
            })
        }
    }
}
