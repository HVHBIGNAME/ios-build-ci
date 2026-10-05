import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WhitegramVirusTotalScanProgress: Equatable {
    case preparing(Int64, Int64)
    case prepared(WhitegramVirusTotalFileHash)
    case uploading(Int64, Int64)
    case submitted(String)
    case analysing(String, Int)
}

public struct WhitegramVirusTotalAnalysis: Equatable {
    public enum Status: String, Decodable { case queued, inProgress = "in-progress", completed }
    public let id: String
    public let status: Status
    public let statistics: [String: Int]?
    public let engines: [WhitegramVirusTotalEngineResult]
    public let date: Date?

    public var summary: String {
        guard self.status == .completed else { return "Analysis is still " + self.status.rawValue + ". No verdict is available." }
        return whitegramVirusTotalSummary(statistics: self.statistics, engines: self.engines, subject: "target")
    }
}

protocol WhitegramServiceScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> WhitegramServiceCancellable
}

struct WhitegramServiceMainScheduler: WhitegramServiceScheduler {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> WhitegramServiceCancellable {
        let task = WhitegramServiceTask()
        let work = DispatchWorkItem { if !task.isCancelled { action() } }
        task.onCancel { work.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
        return task
    }
}

extension WhitegramVirusTotalService {
    /// Uses the original fixed https://vk.com probe. No selected message, URL or file is included.
    @discardableResult
    public func testConnection(apiKey: String, completion: @escaping (Result<Bool, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        return self.perform(request: {
            let url = URL(string: "https://www.virustotal.com/api/v3/" + WhitegramVirusTotalTarget.url("https://vk.com").resourcePath)!
            return try whitegramServiceRequest(url: url, method: "GET", apiKey: whitegramValidatedAPIKey(apiKey), header: "x-apikey")
        }, response: { response in
            switch try WhitegramVirusTotalWire.response(response, target: .url("https://vk.com")) {
            case .found: return true
            case .notFound: return false
            }
        }, completion: completion)
    }

    @discardableResult
    public func scan(target: WhitegramVirusTotalTarget, progress: @escaping (WhitegramVirusTotalScanProgress) -> Void, apiKey: String, completion: @escaping (Result<WhitegramVirusTotalAnalysis, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        return self.startScan(target: target, analysisId: nil, scheduler: WhitegramServiceMainScheduler(), progress: progress, apiKey: apiKey, completion: completion)
    }

    @discardableResult
    public func resumeAnalysis(id: String, progress: @escaping (WhitegramVirusTotalScanProgress) -> Void, apiKey: String, completion: @escaping (Result<WhitegramVirusTotalAnalysis, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        return self.startScan(target: nil, analysisId: id, scheduler: WhitegramServiceMainScheduler(), progress: progress, apiKey: apiKey, completion: completion)
    }

    func startScan(target: WhitegramVirusTotalTarget?, analysisId: String?, scheduler: WhitegramServiceScheduler, progress: @escaping (WhitegramVirusTotalScanProgress) -> Void, apiKey: String, completion: @escaping (Result<WhitegramVirusTotalAnalysis, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        let scan = WhitegramVirusTotalScanOperation(service: self, apiKey: apiKey, scheduler: scheduler, progress: progress, completion: completion)
        scan.start(target: target, analysisId: analysisId)
        return scan.task
    }

    /// Snapshots and hashes the chosen file once, then uploads those exact bytes. Never retries POST.
    @discardableResult
    public func uploadAndScan(fileURL: URL, fileName: String? = nil, expectedHash: String? = nil, progress: @escaping (WhitegramVirusTotalScanProgress) -> Void, apiKey: String, completion: @escaping (Result<WhitegramVirusTotalAnalysis, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        return self.startUpload(fileURL: fileURL, fileName: fileName, expectedHash: expectedHash, scheduler: WhitegramServiceMainScheduler(), progress: progress, apiKey: apiKey, completion: completion)
    }

    func startUpload(fileURL: URL, fileName: String?, expectedHash: String?, scheduler: WhitegramServiceScheduler, progress: @escaping (WhitegramVirusTotalScanProgress) -> Void, apiKey: String, completion: @escaping (Result<WhitegramVirusTotalAnalysis, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        let scan = WhitegramVirusTotalScanOperation(service: self, apiKey: apiKey, scheduler: scheduler, progress: progress, completion: completion)
        scan.prepareFile(url: fileURL, fileName: fileName, expectedHash: expectedHash)
        return scan.task
    }

    func upload(_ upload: WhitegramVirusTotalUpload, to url: URL, apiKey: String, progress: @escaping (Int64, Int64) -> Void, completion: @escaping (Result<String, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        let operation = WhitegramServiceOperation(completion: completion)
        do {
            try self.route.requireAvailable(using: self.transport)
            guard let transport = self.transport as? WhitegramServiceUploadTransport else { throw WhitegramServiceError.uploadUnavailable }
            var request = try whitegramServiceRequest(url: transport.validatedUploadURL(url.absoluteString), method: "POST", apiKey: whitegramValidatedAPIKey(apiKey), header: "x-apikey")
            request.setValue("multipart/form-data; boundary=" + upload.boundary, forHTTPHeaderField: "Content-Type")
            request.setValue(String(upload.bodyBytes), forHTTPHeaderField: "Content-Length")
            try self.gate.begin()
            let child = transport.upload(request, bodyFile: upload.bodyFile, maximumResponseBytes: WhitegramServiceLimits.maximumVirusTotalResponseBytes, progress: progress) { result in
                // The snapshot must outlive a cancelled URLSession upload as well as a successful one.
                withExtendedLifetime(upload) {
                    if case let .success(response) = result { self.gate.end(retryAfter: response.cooldownSeconds) } else { self.gate.end() }
                    operation.finish(result.flatMap { response in whitegramServiceResult { try WhitegramVirusTotalScanWire.submission(response) } })
                }
            }
            operation.attach(child)
        } catch {
            operation.finish(.failure(error as? WhitegramServiceError ?? .invalidResponse))
        }
        return operation.task
    }
}

private final class WhitegramVirusTotalScanOperation {
    private let service: WhitegramVirusTotalService
    private let apiKey: String
    private let scheduler: WhitegramServiceScheduler
    private let progress: (WhitegramVirusTotalScanProgress) -> Void
    private let operation: WhitegramServiceOperation<WhitegramVirusTotalAnalysis>
    private var polls = 0
    var task: WhitegramServiceTask { return self.operation.task }

    init(service: WhitegramVirusTotalService, apiKey: String, scheduler: WhitegramServiceScheduler, progress: @escaping (WhitegramVirusTotalScanProgress) -> Void, completion: @escaping (Result<WhitegramVirusTotalAnalysis, WhitegramServiceError>) -> Void) {
        self.service = service
        self.apiKey = apiKey
        self.scheduler = scheduler
        self.progress = progress
        self.operation = WhitegramServiceOperation(completion: completion)
    }

    func start(target: WhitegramVirusTotalTarget?, analysisId: String?) {
        DispatchQueue.main.async {
            guard !self.task.isCancelled else { return }
            if let analysisId {
                do { self.poll(try WhitegramVirusTotalScanWire.analysisId(analysisId)) }
                catch { self.operation.finish(.failure(.invalidResponse)) }
                return
            }
            guard let target else { self.operation.finish(.failure(.invalidTarget)); return }
            let child = self.service.perform(request: { try WhitegramVirusTotalScanWire.submit(target: target, apiKey: self.apiKey) }, response: WhitegramVirusTotalScanWire.submission) { result in
                self.submitted(result)
            }
            self.operation.attach(child)
        }
    }

    func prepareFile(url: URL, fileName: String?, expectedHash: String?) {
        // Validate before materializing any file-provider data.
        do {
            try self.service.route.requireAvailable(using: self.service.transport)
            _ = try whitegramValidatedAPIKey(self.apiKey)
            guard self.service.transport is WhitegramServiceUploadTransport else { throw WhitegramServiceError.uploadUnavailable }
            if let expectedHash { _ = try WhitegramVirusTotalWire.validatedHash(expectedHash) }
        } catch {
            self.operation.finish(.failure(error as? WhitegramServiceError ?? .invalidResponse))
            return
        }
        let child = WhitegramVirusTotalUpload.prepare(url: url, expectedHash: expectedHash, fileName: fileName, progress: { count, total in
            self.emit(.preparing(count, total))
        }) { result in
            guard !self.task.isCancelled else { return }
            switch result {
            case let .failure(error): self.operation.finish(.failure(error))
            case let .success(upload):
                self.emit(.prepared(upload.file))
                if upload.file.byteCount > WhitegramServiceLimits.directUploadFileBytes {
                    let child = self.service.perform(request: {
                        try WhitegramVirusTotalScanWire.request(path: "files/upload_url", method: "GET", apiKey: self.apiKey)
                    }, response: { response in
                        guard let transport = self.service.transport as? WhitegramServiceUploadTransport else { throw WhitegramServiceError.uploadUnavailable }
                        return try WhitegramVirusTotalScanWire.uploadAddress(response, validate: transport.validatedUploadURL)
                    }) { result in
                        guard !self.task.isCancelled else { return }
                        switch result {
                        case let .failure(error): self.operation.finish(.failure(error))
                        case let .success(url): self.wait { self.upload(upload, to: url) }
                        }
                    }
                    self.operation.attach(child)
                } else {
                    self.upload(upload, to: URL(string: "https://www.virustotal.com/api/v3/files")!)
                }
            }
        }
        self.operation.attach(child)
    }

    private func upload(_ upload: WhitegramVirusTotalUpload, to url: URL) {
        guard !self.task.isCancelled else { return }
        let child = self.service.upload(upload, to: url, apiKey: self.apiKey, progress: { count, total in
            self.emit(.uploading(count, total))
        }) { self.submitted($0) }
        self.operation.attach(child)
    }

    private func submitted(_ result: Result<String, WhitegramServiceError>) {
        guard !self.task.isCancelled else { return }
        switch result {
        case let .failure(error): self.operation.finish(.failure(error))
        case let .success(id):
            self.emit(.submitted(id))
            self.wait { self.poll(id) }
        }
    }

    private func wait(seconds: TimeInterval? = nil, _ action: @escaping () -> Void) {
        let child = self.scheduler.schedule(after: seconds ?? max(15, self.service.pollInterval)) {
            if !self.task.isCancelled { action() }
        }
        self.operation.attach(child)
    }

    private func poll(_ id: String) {
        guard !self.task.isCancelled else { return }
        guard self.polls < WhitegramServiceLimits.maximumAnalysisPolls else { self.operation.finish(.failure(.analysisPending(id))); return }
        self.polls += 1
        let child = self.service.perform(request: {
            try WhitegramVirusTotalScanWire.request(path: "analyses/" + id, method: "GET", apiKey: self.apiKey)
        }, response: { try WhitegramVirusTotalScanWire.analysis($0, expectedId: id) }) { result in
            guard !self.task.isCancelled else { return }
            switch result {
            case let .failure(error):
                if case let .rateLimited(seconds) = error, seconds <= 300 {
                    self.wait(seconds: Double(seconds)) { self.poll(id) }
                } else {
                    self.operation.finish(.failure(error))
                }
            case let .success(analysis):
                if analysis.status == .completed {
                    self.operation.finish(.success(analysis))
                } else {
                    self.emit(.analysing(analysis.status.rawValue, self.polls))
                    self.wait { self.poll(id) }
                }
            }
        }
        self.operation.attach(child)
    }

    private func emit(_ progress: WhitegramVirusTotalScanProgress) {
        DispatchQueue.main.async { if !self.task.isCancelled { self.progress(progress) } }
    }
}

enum WhitegramVirusTotalScanWire {
    static func request(path: String, method: String, apiKey: String, body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: "https://www.virustotal.com/api/v3/" + path) else { throw WhitegramServiceError.invalidTarget }
        return try whitegramServiceRequest(url: url, method: method, apiKey: whitegramValidatedAPIKey(apiKey), header: "x-apikey", body: body)
    }

    static func submit(target: WhitegramVirusTotalTarget, apiKey: String) throws -> URLRequest {
        let target = try target.validated()
        switch target {
        case let .url(value):
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            guard let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) else { throw WhitegramServiceError.invalidTarget }
            var request = try self.request(path: "urls", method: "POST", apiKey: apiKey, body: Data(("url=" + escaped).utf8))
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            return request
        case .file:
            return try self.request(path: target.resourcePath + "/analyse", method: "POST", apiKey: apiKey)
        case .ipAddress:
            // The original IP workflow is a report lookup, not an analysis-queue submission.
            throw WhitegramServiceError.invalidTarget
        }
    }

    static func analysisId(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 512, value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 || $0 == 61 }) else {
            throw WhitegramServiceError.invalidResponse
        }
        return value
    }

    private static func checked(_ response: WhitegramServiceHTTPResponse) throws -> Data {
        if let error = whitegramHTTPError(status: response.statusCode, retryAfter: response.retryAfter) { throw error }
        guard response.data.count <= WhitegramServiceLimits.maximumVirusTotalResponseBytes else { throw WhitegramServiceError.responseTooLarge }
        return response.data
    }

    static func submission(_ response: WhitegramServiceHTTPResponse) throws -> String {
        struct Envelope: Decodable {
            struct Resource: Decodable { let type: String; let id: String }
            let data: Resource
        }
        let resource = try JSONDecoder().decode(Envelope.self, from: self.checked(response)).data
        guard resource.type == "analysis" else { throw WhitegramServiceError.invalidResponse }
        return try self.analysisId(resource.id)
    }

    static func uploadURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", url.host?.lowercased() == "www.virustotal.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil,
              (url.path == "/api/v3/files" && url.query == nil) || url.path.hasPrefix("/_ah/upload/") else { throw WhitegramServiceError.invalidResponse }
        return url
    }

    static func uploadAddress(_ response: WhitegramServiceHTTPResponse, validate: (String) throws -> URL = WhitegramVirusTotalScanWire.uploadURL) throws -> URL {
        struct Envelope: Decodable { let data: String }
        return try validate(JSONDecoder().decode(Envelope.self, from: self.checked(response)).data)
    }

    static func analysis(_ response: WhitegramServiceHTTPResponse, expectedId: String) throws -> WhitegramVirusTotalAnalysis {
        let resource = try JSONDecoder().decode(AnalysisEnvelope.self, from: self.checked(response)).data
        guard resource.type == "analysis", resource.id == expectedId, try self.analysisId(resource.id) == expectedId else { throw WhitegramServiceError.invalidResponse }
        let value = resource.attributes
        guard (value.stats?.count ?? 0) <= 128, value.stats?.values.allSatisfy({ $0 >= 0 && $0 <= 100000 }) != false,
              (value.results?.count ?? 0) <= 2000, value.date.map({ $0 >= 0 && $0 <= 253402300799 }) != false else { throw WhitegramServiceError.invalidResponse }
        let engines = (value.results ?? [:]).map { name, result in
            WhitegramVirusTotalEngineResult(name: result.engineName ?? name, category: result.category ?? "unknown", result: result.result, version: result.engineVersion, update: result.engineUpdate)
        }.sorted { $0.name < $1.name }
        return WhitegramVirusTotalAnalysis(id: resource.id, status: value.status, statistics: value.stats, engines: engines, date: value.date.map { Date(timeIntervalSince1970: Double($0)) })
    }

    private struct AnalysisEnvelope: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable {
                struct Engine: Decodable {
                    let engineName: String?
                    let engineVersion: String?
                    let engineUpdate: String?
                    let category: String?
                    let result: String?
                    enum CodingKeys: String, CodingKey {
                        case category, result
                        case engineName = "engine_name", engineVersion = "engine_version", engineUpdate = "engine_update"
                    }
                }
                let status: WhitegramVirusTotalAnalysis.Status
                let stats: [String: Int]?
                let results: [String: Engine]?
                let date: Int64?
            }
            let id: String
            let type: String
            let attributes: Attributes
        }
        let data: Resource
    }
}
