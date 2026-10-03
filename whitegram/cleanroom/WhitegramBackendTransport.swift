import Foundation

/// Authorized, pinned transport to the historical Whitegram API, bound to one Telegram user.
public final class WhitegramBackendAuthorizedTransport {
    public static var baseURL: URL { return WhitegramBackendProtocol.baseURL }
    public let userId: Int64
    private let client: WhitegramBackendClient

    public init(userId: Int64) {
        self.userId = userId
        self.client = WhitegramBackendClient(userId: userId)
    }

    init(client: WhitegramBackendClient) {
        self.userId = client.userId
        self.client = client
    }

    public func hasSession() throws -> Bool { return try client.hasSession() }

    public var accessState: WhitegramBackendAccessState { return client.access.state(userId: userId, now: client.now()) }

    @discardableResult
    public func refreshAccess(completion: @escaping (Result<WhitegramBackendAccessState, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.refreshAccess(completion: completion)
    }

    public func disconnect() throws {
        try client.sessions.remove(userId: userId)
        client.access.reset(userId: userId)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: WhitegramBackendClient.sessionUpdated, object: nil, userInfo: ["userId": self.userId])
        }
    }

    /// All callbacks are serial on the main queue. Non-2xx responses retain their status, headers and body.
    /// Streaming chunks are delivered only for 2xx responses; throwing stops the transfer with invalidResponse.
    /// The caller owns bodyFile and must keep it unchanged until completion, including after cancel().
    /// No direct-provider fallback or implicit account selection is performed.
    @discardableResult
    public func execute(path: String, query: [URLQueryItem] = [], method: String = "GET",
                        providerKey: String? = nil, body: Data? = nil, bodyFile: URL? = nil,
                        contentType: String? = nil, accept: String = "application/json",
                        maximumResponseBytes: Int = 8 * 1024 * 1024,
                        received: ((Data) throws -> Void)? = nil,
                        progress: ((Int64, Int64) -> Void)? = nil,
                        completion: @escaping (Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.raw(path: path, query: query, method: method, body: body, contentType: contentType,
            maximumBytes: maximumResponseBytes, accept: accept, providerKey: providerKey, preserveHTTPStatus: true,
            bodyFile: bodyFile, received: received, progress: progress, completion: completion)
    }
}

public let whitegramBackendSessionUpdated = WhitegramBackendClient.sessionUpdated
