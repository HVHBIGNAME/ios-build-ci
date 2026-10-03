import Foundation
import CryptoKit

public enum WhitegramBackendError: Error, LocalizedError, Equatable {
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case missingSession
    case missingApplicationKey
    case sessionChanged
    case accountMismatch
    case cancelled
    case transport(Int)
    case http(Int, retryAfter: TimeInterval?)
    case keychain(Int32)
    case deviceIdentity
    case telegramAuthentication
    case queueFull
    case betaAccessUnknown
    case betaAccessDenied
    case invalidBetaVerdict
    case staleResponse
    case localStorage

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The Whitegram request is invalid."
        case .invalidResponse: return "The Whitegram server returned an invalid response."
        case .responseTooLarge: return "The Whitegram response exceeded the size limit."
        case .missingSession: return "Connect this Telegram account to Whitegram first."
        case .missingApplicationKey: return "This build has no valid Whitegram application signing key configured."
        case .sessionChanged: return "The Whitegram session changed. Please refresh."
        case .accountMismatch: return "The server session belongs to a different Telegram account."
        case .cancelled: return "Cancelled."
        case let .transport(code): return "Whitegram connection failed (network error \(code))."
        case let .http(code, retryAfter):
            if code == 401 { return "The Whitegram session has expired. Connect again." }
            if code == 403 { return "The Whitegram server denied access to this feature." }
            if code == 429, let retryAfter, retryAfter.isFinite { return "Too many requests. Try again in " + String(format: "%.0f", ceil(max(0, retryAfter))) + " seconds." }
            return "Whitegram server returned HTTP \(code)."
        case let .keychain(code): return "Whitegram credentials could not be accessed (Keychain \(code))."
        case .deviceIdentity: return "The Whitegram device identity could not be loaded or signed."
        case .telegramAuthentication: return "Telegram could not authorize the Whitegram authentication mini app."
        case .queueFull: return "The pending Whitegram activity queue is full. Connect this account and retry."
        case .betaAccessUnknown: return "Whitegram Beta access has not been verified for this account. Refresh its access status."
        case .betaAccessDenied: return "This account does not have access to Whitegram Beta."
        case .invalidBetaVerdict: return "The Whitegram Beta access response could not be verified."
        case .staleResponse: return "The profile changed while this request was running. Refresh to load its current state."
        case .localStorage: return "The saved Whitegram profile wallpaper could not be read or written."
        }
    }
}

enum WhitegramBackendProtocol {
    static let baseURL = URL(string: "https://api.whitegram.heypainservice.online")!
    static let maximumResponseBytes = 8 * 1024 * 1024
    static let maximumUploadBytes: Int64 = 512 * 1024 * 1024 + 4096
    static let spkiPins: Set<String> = [
        "brzvtCELCIZUo4sD/qPX0ccRtPsd3DY6RfmxpOU9oB4=",
        "sCkq5UWXjg+7mKu9lMhhYF5bGLsy7VI/UNW3tccdR7w=",
        "diGVwiVYbubAI3RW4hB9xU8e/CH2GnkuvVFZE8zmgzI=",
        "C5+lpZ7tcVwmwQIMcRtPbsQtWLABXhQzejna0wHFr8M="
    ]

    static func configuredApplicationKey(encoded: Any? = Bundle.main.object(forInfoDictionaryKey: "WhitegramBackendApplicationKey")) throws -> Data {
        guard let encoded = encoded as? String, encoded.utf8.count == 44,
              let data = Data(base64Encoded: encoded), data.count == 32,
              data.base64EncodedString() == encoded else {
            throw WhitegramBackendError.missingApplicationKey
        }
        return data
    }

    static func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard path.hasPrefix("/v1/"), !path.contains("?"), !path.contains("#"), !path.contains("%"),
              !path.contains("\\"), !path.contains("//"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              path.utf8.count <= 4096, query.count <= 64,
              path.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else {
            throw WhitegramBackendError.invalidRequest
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url, url.absoluteString.utf8.count <= 16384 else { throw WhitegramBackendError.invalidRequest }
        return url
    }

    static func canonicalMessage(url: URL, method: String, timestamp: Int64) -> String {
        let target = url.path + (url.query.map { "?" + $0 } ?? "")
        return "\(timestamp):\(method.uppercased()):\(target)"
    }

    static func signature(message: String, key: Data) -> String {
        return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)).map { String(format: "%02x", $0) }.joined()
    }

    static func sign(_ request: inout URLRequest, date: Date, session: WhitegramBackendSession?, applicationKey: Data, deviceSignature: (String) throws -> String?) throws {
        guard applicationKey.count == 32 else { throw WhitegramBackendError.missingApplicationKey }
        guard let url = request.url, url.scheme == baseURL.scheme, url.host == baseURL.host,
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              let timestamp = Int64(exactly: date.timeIntervalSince1970.rounded(.towardZero)) else {
            throw WhitegramBackendError.invalidRequest
        }
        let message = canonicalMessage(url: url, method: request.httpMethod ?? "GET", timestamp: timestamp)
        request.setValue(String(timestamp), forHTTPHeaderField: "X-WG-Timestamp")
        request.setValue(signature(message: message, key: applicationKey), forHTTPHeaderField: "X-WG-Sig")
        request.setValue(try deviceSignature(message), forHTTPHeaderField: "X-WG-Device-Sig")
        request.setValue(session?.sessionKey.map { signature(message: message, key: $0) }, forHTTPHeaderField: "X-WG-Session-Sig")
        request.setValue(session.map { "Whitegram " + $0.token }, forHTTPHeaderField: "Authorization")
    }

    static func retryAfter(_ response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard let text = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(text), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: text).map { max(0, $0.timeIntervalSince(now)) }
    }

    static func webAppInitData(from urlString: String) throws -> String {
        guard let components = URLComponents(string: urlString) else { throw WhitegramBackendError.telegramAuthentication }
        let query = components.queryItems ?? []
        let fragment = components.percentEncodedFragment.flatMap { URLComponents(string: "https://whitegram.invalid/?" + $0)?.queryItems } ?? []
        let matches = (query + fragment).filter { $0.name == "tgWebAppData" }
        guard matches.count == 1, let data = matches[0].value, !data.isEmpty, data.utf8.count <= 64 * 1024 else {
            throw WhitegramBackendError.telegramAuthentication
        }
        return data
    }
}

struct WhitegramBackendSession: Codable, Equatable {
    let userId: Int64
    let token: String
    let expiresAt: Date
    let sessionKey: Data?

    func validate(userId: Int64, now: Date) throws {
        guard self.userId == userId, userId > 0 else { throw WhitegramBackendError.accountMismatch }
        guard !token.isEmpty, token.utf8.count <= 16384, !token.utf8.contains(13), !token.utf8.contains(10),
              expiresAt.timeIntervalSince1970.isFinite, expiresAt > now,
              sessionKey.map({ !$0.isEmpty && $0.count <= 128 }) ?? true else { throw WhitegramBackendError.missingSession }
    }
}

struct WhitegramBackendSessionResponse: Decodable {
    struct User: Decodable { let id: Int64 }
    let accessToken: String
    let expiresIn: TimeInterval
    let user: User
    let sessionKey: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", expiresIn = "expires_in", user, sessionKey = "session_key"
    }

    func session(for userId: Int64, now: Date) throws -> WhitegramBackendSession {
        guard user.id == userId else { throw WhitegramBackendError.accountMismatch }
        guard expiresIn.isFinite, expiresIn > 0, expiresIn <= 365 * 86400 else { throw WhitegramBackendError.invalidResponse }
        let key: Data?
        if let value = sessionKey {
            guard let data = Data(base64Encoded: value), !data.isEmpty, data.count <= 128 else { throw WhitegramBackendError.invalidResponse }
            key = data
        } else { key = nil }
        let result = WhitegramBackendSession(userId: userId, token: accessToken, expiresAt: now.addingTimeInterval(expiresIn), sessionKey: key)
        try result.validate(userId: userId, now: now)
        return result
    }
}
