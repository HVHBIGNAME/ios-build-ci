import Foundation

/// Reuse this account-bound client set across a screen's requests, uploads and polling.
public final class WhitegramAccountServices {
    public let backend: WhitegramBackendAuthorizedTransport
    private let proxyAI: WhitegramAIService
    private let proxyVirusTotal: WhitegramVirusTotalService

    public convenience init(userId: Int64) {
        self.init(backend: WhitegramBackendAuthorizedTransport(userId: userId))
    }

    init(backend: WhitegramBackendAuthorizedTransport) {
        self.backend = backend
        let transport = WhitegramServiceProxyTransport(backend: backend)
        self.proxyAI = WhitegramAIService(transport: transport)
        self.proxyVirusTotal = WhitegramVirusTotalService(transport: transport, route: .originalProxy)
    }

    public func ai(route: WhitegramServiceRoute) -> WhitegramAIService {
        return route == .direct ? .shared : self.proxyAI
    }

    public func virusTotal(route: WhitegramServiceRoute) -> WhitegramVirusTotalService {
        return route == .direct ? .shared : self.proxyVirusTotal
    }
}

extension WhitegramServiceRoute {
    func aiService(account: WhitegramAccountServices?) throws -> WhitegramAIService {
        if let account { return account.ai(route: self) }
        try self.requireAvailable()
        return .shared
    }

    func virusTotalService(account: WhitegramAccountServices?) throws -> WhitegramVirusTotalService {
        if let account { return account.virusTotal(route: self) }
        try self.requireAvailable()
        return .shared
    }
}

/// Converts provider requests to the recovered proxy paths. It never sends to a provider origin.
public final class WhitegramServiceProxyTransport: WhitegramServiceStreamingTransport, WhitegramServiceUploadTransport {
    public var route: WhitegramServiceRoute { return .originalProxy }
    private let backend: WhitegramBackendAuthorizedTransport

    public init(backend: WhitegramBackendAuthorizedTransport) { self.backend = backend }

    public func send(_ request: URLRequest, maximumResponseBytes: Int, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        return self.execute(request, maximumResponseBytes: maximumResponseBytes, completion: completion)
    }

    public func stream(_ request: URLRequest, maximumResponseBytes: Int, received: @escaping (Data) throws -> Void, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        return self.execute(request, maximumResponseBytes: maximumResponseBytes, received: received, completion: completion)
    }

    public func upload(_ request: URLRequest, bodyFile: URL, maximumResponseBytes: Int, progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        return self.execute(request, maximumResponseBytes: maximumResponseBytes, bodyFile: bodyFile, progress: progress, completion: completion)
    }

    public func validatedUploadURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else { throw WhitegramServiceError.invalidResponse }
        let components = try Self.components(url)
        let path = try Self.virusTotalPath(components)
        guard path.hasPrefix("/v1/proxy/virustotal/v3/") else { throw WhitegramServiceError.invalidResponse }
        return try WhitegramBackendProtocol.url(path: path, query: components.queryItems ?? [])
    }

    private func execute(_ request: URLRequest, maximumResponseBytes: Int, bodyFile: URL? = nil,
                         received: ((Data) throws -> Void)? = nil, progress: ((Int64, Int64) -> Void)? = nil,
                         completion: @escaping (Result<WhitegramServiceHTTPResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceCancellable {
        do {
            guard let url = request.url, request.httpBodyStream == nil,
                  (request.httpBody?.count ?? 0) <= WhitegramServiceLimits.maximumRequestBytes,
                  bodyFile == nil || request.httpBody == nil else { throw WhitegramServiceError.requestTooLarge }
            let components = try Self.components(url)
            let target = try Self.target(components, request: request, uploading: bodyFile != nil)
            var consumerError: WhitegramServiceError?
            let receive: ((Data) throws -> Void)? = received.map { callback in
                return { data in
                    do { try callback(data) }
                    catch {
                        consumerError = error as? WhitegramServiceError ?? .invalidResponse
                        throw error
                    }
                }
            }
            let task = self.backend.execute(path: target.path, query: components.queryItems ?? [], method: request.httpMethod ?? "GET",
                providerKey: target.key, body: request.httpBody, bodyFile: bodyFile,
                contentType: request.value(forHTTPHeaderField: "Content-Type"), accept: request.value(forHTTPHeaderField: "Accept") ?? "application/json",
                maximumResponseBytes: maximumResponseBytes, received: receive, progress: progress) { result in
                completion(result.map { response in
                    WhitegramServiceHTTPResponse(statusCode: response.response.statusCode, data: response.data,
                        retryAfter: response.response.value(forHTTPHeaderField: "Retry-After"))
                }.mapError { error in
                    if error == .invalidResponse, let consumerError { return consumerError }
                    return Self.serviceError(error)
                })
            }
            return WhitegramServiceBackendTask(task)
        } catch {
            let operation = WhitegramServiceOperation(completion: completion)
            operation.finish(.failure(error as? WhitegramServiceError ?? .invalidResponse))
            return operation.task
        }
    }

    private static func components(_ url: URL) throws -> URLComponents {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false), value.scheme == "https",
              value.port == nil || value.port == 443, value.user == nil, value.password == nil, value.fragment == nil,
              !value.path.contains("\\"), !value.path.contains("//"), value.percentEncodedPath == value.path,
              !value.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw WhitegramServiceError.invalidResponse }
        return value
    }

    private static func virusTotalPath(_ value: URLComponents) throws -> String {
        if value.host?.lowercased() == "www.virustotal.com", value.path.hasPrefix("/api/v3/") {
            return "/v1/proxy/virustotal" + value.path.dropFirst(4)
        }
        if value.host?.lowercased() == WhitegramBackendAuthorizedTransport.baseURL.host,
           value.path.hasPrefix("/v1/proxy/virustotal/v3/") { return value.path }
        throw WhitegramServiceError.invalidResponse
    }

    private static func target(_ value: URLComponents, request: URLRequest, uploading: Bool) throws -> (path: String, key: String) {
        let method = request.httpMethod ?? "GET"
        guard method == "GET" || method == "POST" else { throw WhitegramServiceError.invalidResponse }
        switch value.host?.lowercased() {
        case "generativelanguage.googleapis.com":
            guard !uploading else { throw WhitegramServiceError.uploadUnavailable }
            if method == "GET", value.path == "/v1beta/models" {
                let items = value.queryItems ?? []
                guard Set(items.map(\.name)).count == items.count, items.allSatisfy({ item in
                    guard let text = item.value, !text.isEmpty, text.utf8.count <= 2048 else { return false }
                    return (item.name == "pageSize" && text == "20") || item.name == "pageToken"
                }) else { throw WhitegramServiceError.invalidResponse }
            } else {
                let prefix = "/v1beta/models/"
                let suffix = ":generateContent"
                guard method == "POST", value.query == nil, value.path.hasPrefix(prefix), value.path.hasSuffix(suffix) else { throw WhitegramServiceError.invalidResponse }
                _ = try WhitegramAIProvider.gemini.validatedModel(String(value.path.dropFirst(prefix.count).dropLast(suffix.count)))
            }
            return ("/v1/proxy/gemini" + value.path, try whitegramValidatedAPIKey(request.value(forHTTPHeaderField: "x-goog-api-key") ?? ""))
        case "api.groq.com":
            guard !uploading, value.query == nil,
                  (method == "GET" && value.path == "/openai/v1/models") || (method == "POST" && value.path == "/openai/v1/chat/completions"),
                  let authorization = request.value(forHTTPHeaderField: "Authorization"), authorization.hasPrefix("Bearer ") else { throw WhitegramServiceError.invalidResponse }
            return ("/v1/proxy/groq" + value.path, try whitegramValidatedAPIKey(String(authorization.dropFirst(7))))
        default:
            let path = try self.virusTotalPath(value)
            guard (uploading && method == "POST") || value.query == nil else { throw WhitegramServiceError.invalidResponse }
            return (path, try whitegramValidatedAPIKey(request.value(forHTTPHeaderField: "x-apikey") ?? ""))
        }
    }

    static func serviceError(_ error: WhitegramBackendError) -> WhitegramServiceError {
        switch error {
        case .cancelled: return .cancelled
        case .missingSession, .accountMismatch: return .originalProxyUnavailable
        case .sessionChanged, .staleResponse: return .originalProxySessionChanged
        case .betaAccessDenied: return .originalProxyAccessDenied
        case .betaAccessUnknown, .invalidBetaVerdict: return .originalProxyAccessUnverified
        case .missingApplicationKey, .deviceIdentity: return .originalProxySigningUnavailable
        case .responseTooLarge: return .responseTooLarge
        case let .keychain(status): return .keychain(status: Int(status))
        case let .transport(code):
            if code == NSURLErrorTimedOut { return .timedOut }
            if code == NSURLErrorCancelled { return .cancelled }
            return .network(code: code)
        case let .http(status, retryAfter):
            if status == 429 {
                let seconds = retryAfter.flatMap { $0.isFinite ? $0 : nil } ?? 60
                return .rateLimited(seconds: Int(ceil(min(604800, max(1, seconds)))))
            }
            return .httpStatus(status)
        case .invalidRequest, .invalidResponse, .telegramAuthentication, .queueFull, .localStorage: return .invalidResponse
        }
    }
}

private final class WhitegramServiceBackendTask: WhitegramServiceCancellable {
    private let task: WhitegramBackendTask
    init(_ task: WhitegramBackendTask) { self.task = task }
    func cancel() { self.task.cancel() }
}
