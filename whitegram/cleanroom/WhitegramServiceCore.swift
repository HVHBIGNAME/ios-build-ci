import Foundation
import CoreFoundation

public enum WhitegramServiceError: Error, Equatable, LocalizedError {
    case disabled
    case missingAPIKey
    case invalidAPIKey
    case invalidProvider
    case invalidModel
    case emptyPrompt
    case promptTooLarge
    case invalidConversation
    case conversationStorage
    case conversationChanged
    case conversationFull
    case legacyHistoryFormat
    case originalProxyUnavailable
    case originalProxySessionChanged
    case originalProxyAccessDenied
    case originalProxyAccessUnverified
    case originalProxySigningUnavailable
    case streamingUnavailable
    case unsupportedToolCall
    case invalidHash
    case invalidTarget
    case busy
    case rateLimited(seconds: Int)
    case httpStatus(Int)
    case invalidResponse
    case responseTooLarge
    case requestTooLarge
    case redirectRefused
    case noText
    case outputBlocked
    case cancelled
    case timedOut
    case network(code: Int)
    case keychain(status: Int)
    case preferences
    case notRegularFile
    case fileTooLarge
    case fileUnreadable
    case fileChanged
    case hashingUnavailable
    case uploadUnavailable
    case analysisPending(String)

    public var errorDescription: String? {
        switch self {
        case .disabled: return "Enable this service before making a request."
        case .missingAPIKey: return "Add your API key first."
        case .invalidAPIKey: return "The API key must contain 1–4096 printable ASCII characters without spaces."
        case .invalidProvider: return "Choose Gemini or Groq in AI settings."
        case .invalidModel: return "Enter a valid model ID from your provider. Model IDs may contain letters, numbers, dots, hyphens and underscores; Groq IDs can also contain slashes."
        case .emptyPrompt: return "Enter the text you want to send."
        case .promptTooLarge: return "The prompt exceeds the 32 KiB UTF-8 text limit. Shorten it before sending."
        case .invalidConversation: return "The conversation does not contain a valid sequence of user messages and replies."
        case .conversationStorage: return "Could not read or save this conversation. Reload it or clear its history before sending again."
        case .conversationChanged: return "This conversation changed in another screen. Reload it before sending again."
        case .conversationFull: return "This conversation has reached its local history limit. Clear its history to start a new conversation."
        case .legacyHistoryFormat: return "The original v5 history is not a supported role/text JSON array. It has been preserved without modification."
        case .originalProxyUnavailable: return "Connect this Telegram account to Whitegram before using its signed provider proxy. Account-less calls cannot use that route."
        case .originalProxySessionChanged: return "The Whitegram account session changed. Connect or refresh this account before retrying."
        case .originalProxyAccessDenied: return "This Telegram account does not have access to the Whitegram provider proxy."
        case .originalProxyAccessUnverified: return "Whitegram proxy access has not been verified for this account. Connect or refresh its access status."
        case .originalProxySigningUnavailable: return "The Whitegram application key or device signing identity is unavailable."
        case .streamingUnavailable: return "This transport does not support the provider's streaming protocol. No fallback request was sent."
        case .unsupportedToolCall: return "The model requested a Telegram tool that is not connected in this client. No tool was executed."
        case .invalidHash: return "A SHA-256 hash must contain exactly 64 hexadecimal characters."
        case .invalidTarget: return "Enter an HTTP(S) URL without a username or password, a valid IPv4/IPv6 address, or a SHA-256 hash."
        case .busy: return "A request is already running. Wait for it or cancel it."
        case let .rateLimited(seconds): return "Request limit reached. Try again in \(seconds) seconds. Requests are not retried automatically."
        case let .httpStatus(status):
            switch status {
            case 400, 422: return "The service rejected the request (HTTP \(status)). Check the model ID and supported parameters."
            case 401: return "The service rejected the API key (HTTP 401). Replace it in settings."
            case 403: return "Access denied (HTTP 403). Check the key, API access, plan and regional availability."
            case 404: return "The requested API resource was not found (HTTP 404). Check the model ID or service availability."
            case 413: return "The service rejected the request size (HTTP 413)."
            case 500...599: return "The service is temporarily unavailable (HTTP \(status)). Try again later."
            default: return "The service returned HTTP \(status)."
            }
        case .invalidResponse: return "The service returned an unexpected or incomplete response."
        case .responseTooLarge: return "The response exceeded the local size limit and was cancelled."
        case .requestTooLarge: return "The encoded request exceeded the local size limit."
        case .redirectRefused: return "The API tried to redirect the request. Credentials were not forwarded."
        case .noText: return "The model returned no usable text. It may have exhausted its output budget or returned an unsupported output type."
        case .outputBlocked: return "The provider blocked or filtered the response."
        case .cancelled: return "Cancelled."
        case .timedOut: return "The request timed out. Try again when the connection is available."
        case let .network(code): return "Network request failed (URLSession code \(code)). Check the system network connection."
        case let .keychain(status): return "Secure credential storage is unavailable (Keychain status \(status)). Unlock the device and try again."
        case .preferences: return "Could not update service preferences or clear a legacy credential."
        case .notRegularFile: return "Select one regular file, not a folder, package or symbolic link."
        case .fileTooLarge: return "The file exceeds the 512 MiB local hashing limit. You can enter its SHA-256 hash instead."
        case .fileUnreadable: return "The file provider could not supply a readable local file."
        case .fileChanged: return "The file changed while it was being hashed. Select it again."
        case .hashingUnavailable: return "Local SHA-256 hashing requires iOS 13.4 or later. You can enter a hash instead."
        case .uploadUnavailable: return "File upload is unavailable on this system or transport. No file was submitted."
        case let .analysisPending(id): return "VirusTotal has not completed analysis \(id) within the polling limit. Check its status again; do not upload the file again."
        }
    }
}

public enum WhitegramServiceLimits {
    public static let maximumPromptBytes = 32 * 1024
    public static let maximumRequestBytes = 256 * 1024
    public static let maximumAIResponseBytes = 2 * 1024 * 1024
    public static let maximumAIConversationTurns = 100
    public static let maximumAIHistoryBytes = 8 * 1024 * 1024
    public static let maximumVirusTotalTargetBytes = 8192
    public static let maximumVirusTotalResponseBytes = 4 * 1024 * 1024
    public static let maximumOutputTokens = 4096
    public static let maximumFileBytes: Int64 = 512 * 1024 * 1024
    public static let directUploadFileBytes: Int64 = 32 * 1024 * 1024
    public static let maximumUploadBodyBytes: Int64 = maximumFileBytes + 4096
    public static let maximumAnalysisPolls = 20
    public static let fileChunkBytes = 1024 * 1024
    public static let requestTimeout: TimeInterval = 45
    public static let resourceTimeout: TimeInterval = 90
}

public enum WhitegramServiceRoute: String, Equatable {
    case direct
    case originalProxy

    static func fromProxyFlag(_ value: Any?) -> WhitegramServiceRoute {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return .originalProxy }
        return number.boolValue ? .originalProxy : .direct
    }

    func requireAvailable(using transport: WhitegramServiceTransport? = nil) throws {
        guard self == (transport?.route ?? .direct) else { throw WhitegramServiceError.originalProxyUnavailable }
    }
}

public protocol WhitegramServiceCancellable: AnyObject {
    func cancel()
}

/// Cancellation is thread-safe. Service callbacks are delivered exactly once on the main queue.
/// Discarding a task does not cancel it; the owner should cancel when its UI or operation ends.
public final class WhitegramServiceTask: WhitegramServiceCancellable, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var cancellationHandlers: [() -> Void] = []

    public init() {
    }

    public var isCancelled: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.cancelled
    }

    public func cancel() {
        self.lock.lock()
        guard !self.completed, !self.cancelled else {
            self.lock.unlock()
            return
        }
        self.cancelled = true
        let handlers = self.cancellationHandlers
        self.cancellationHandlers.removeAll()
        self.lock.unlock()
        for handler in handlers {
            handler()
        }
    }

    func onCancel(_ handler: @escaping () -> Void) {
        self.lock.lock()
        if self.cancelled {
            self.lock.unlock()
            handler()
        } else if self.completed {
            self.lock.unlock()
        } else {
            self.cancellationHandlers.append(handler)
            self.lock.unlock()
        }
    }

    // A nil result means another completion already won the race.
    func claimCompletion() -> Bool? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.completed else { return nil }
        self.completed = true
        self.cancellationHandlers.removeAll()
        return self.cancelled
    }
}

final class WhitegramServiceOperation<Value>: @unchecked Sendable {
    let task = WhitegramServiceTask()
    private let completion: (Result<Value, WhitegramServiceError>) -> Void

    init(completion: @escaping (Result<Value, WhitegramServiceError>) -> Void) {
        self.completion = completion
        self.task.onCancel { [weak self] in
            self?.finish(.failure(.cancelled))
        }
    }

    func attach(_ child: WhitegramServiceCancellable) {
        self.task.onCancel { child.cancel() }
    }

    func finish(_ result: Result<Value, WhitegramServiceError>) {
        DispatchQueue.main.async {
            guard let cancelled = self.task.claimCompletion() else { return }
            self.completion(cancelled ? .failure(.cancelled) : result)
        }
    }
}

final class WhitegramServiceRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private let now: () -> TimeInterval
    private var active = false
    private var nextAllowed: TimeInterval = 0

    init(minimumInterval: TimeInterval, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.minimumInterval = minimumInterval.isFinite ? min(604800, max(0, minimumInterval)) : 0
        self.now = now
    }

    func begin() throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.active else { throw WhitegramServiceError.busy }
        let time = self.now()
        let delay = self.nextAllowed - time
        guard delay <= 0 else { throw WhitegramServiceError.rateLimited(seconds: Int(ceil(delay))) }
        self.active = true
        self.nextAllowed = time + self.minimumInterval
    }

    func end(retryAfter: Int? = nil) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.active = false
        if let retryAfter = retryAfter {
            self.nextAllowed = max(self.nextAllowed, self.now() + Double(retryAfter))
        }
    }
}

func whitegramValidatedAPIKey(_ value: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw WhitegramServiceError.missingAPIKey }
    guard value.utf8.count <= 4096, value.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
        throw WhitegramServiceError.invalidAPIKey
    }
    return value
}

func whitegramRetryAfter(_ value: String?, now: Date = Date()) -> Int {
    guard let value = value, value.utf8.count <= 128 else { return 60 }
    if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
        return max(1, Int(ceil(min(seconds, 604800))))
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    guard let date = formatter.date(from: value) else { return 60 }
    return max(1, Int(ceil(min(max(0, date.timeIntervalSince(now)), 604800))))
}

func whitegramHTTPError(status: Int, retryAfter: String?) -> WhitegramServiceError? {
    if status == 429 {
        return .rateLimited(seconds: whitegramRetryAfter(retryAfter))
    }
    if (300..<400).contains(status) {
        return .redirectRefused
    }
    return (200..<300).contains(status) ? nil : .httpStatus(status)
}

func whitegramServiceResult<Value>(_ action: () throws -> Value) -> Result<Value, WhitegramServiceError> {
    do {
        return .success(try action())
    } catch let error as WhitegramServiceError {
        return .failure(error)
    } catch {
        // Decoder and transport descriptions can contain response data; expose only a fixed error.
        return .failure(.invalidResponse)
    }
}
