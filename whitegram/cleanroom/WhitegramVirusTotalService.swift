import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct WhitegramVirusTotalEngineResult: Equatable {
    public let name: String
    public let category: String
    public let result: String?
    public let version: String?
    public let update: String?
}

public struct WhitegramVirusTotalReport: Equatable {
    public let sha256: String
    public let statistics: [String: Int]?
    public let engines: [WhitegramVirusTotalEngineResult]
    public let analysisDate: Date?
    public let reportURL: URL

    public var summary: String {
        return whitegramVirusTotalSummary(statistics: self.statistics, engines: self.engines, subject: "file")
    }
}

public enum WhitegramVirusTotalLookupResult: Equatable {
    case found(WhitegramVirusTotalReport)
    case notFound(sha256: String)
}

public struct WhitegramVirusTotalTargetReport: Equatable {
    public let target: WhitegramVirusTotalTarget
    public let resourceId: String
    public let statistics: [String: Int]?
    public let engines: [WhitegramVirusTotalEngineResult]
    public let analysisDate: Date?
    public let reportURL: URL

    public var summary: String {
        return whitegramVirusTotalSummary(statistics: self.statistics, engines: self.engines, subject: "target")
    }
}

public enum WhitegramVirusTotalTargetLookupResult: Equatable {
    case found(WhitegramVirusTotalTargetReport)
    case notFound(target: WhitegramVirusTotalTarget)
}

func whitegramVirusTotalSummary(statistics: [String: Int]?, engines: [WhitegramVirusTotalEngineResult], subject: String) -> String {
    if (statistics?["malicious"] ?? 0) > 0 || (statistics?["suspicious"] ?? 0) > 0 || engines.contains(where: { $0.category == "malicious" || $0.category == "suspicious" }) {
        return "One or more engines reported malicious or suspicious findings."
    }
    if let statistics = statistics, statistics["malicious"] == 0, statistics["suspicious"] == 0,
       (statistics["harmless"] ?? 0) + (statistics["undetected"] ?? 0) > 0 {
        return "No detections in the returned statistics. This does not establish that the \(subject) is safe."
    }
    return "Unknown — no conclusive analysis statistics were returned."
}

/// Official API v3 reports and explicitly submitted analyses share one quota gate.
public final class WhitegramVirusTotalService {
    public static let shared = WhitegramVirusTotalService()
    let transport: WhitegramServiceTransport
    let gate: WhitegramServiceRequestGate
    let pollInterval: TimeInterval
    let route: WhitegramServiceRoute

    public init(transport: WhitegramServiceTransport = WhitegramURLSessionTransport(), minimumRequestInterval: TimeInterval = 15, route: WhitegramServiceRoute = .direct) {
        self.transport = transport
        self.gate = WhitegramServiceRequestGate(minimumInterval: minimumRequestInterval)
        self.pollInterval = minimumRequestInterval.isFinite ? max(0, min(604800, minimumRequestInterval)) : 15
        self.route = route
    }

    @discardableResult
    public func lookup(sha256: String, apiKey: String, completion: @escaping (Result<WhitegramVirusTotalLookupResult, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        return self.perform(request: { try WhitegramVirusTotalWire.request(sha256: sha256, apiKey: apiKey) }, response: { try WhitegramVirusTotalWire.response($0, sha256: sha256) }, completion: completion)
    }

    @discardableResult
    public func lookup(target: WhitegramVirusTotalTarget, apiKey: String, completion: @escaping (Result<WhitegramVirusTotalTargetLookupResult, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        return self.perform(request: { try WhitegramVirusTotalWire.request(target: target, apiKey: apiKey) }, response: { try WhitegramVirusTotalWire.response($0, target: target) }, completion: completion)
    }

    func perform<Value>(request: () throws -> URLRequest, response decode: @escaping (WhitegramServiceHTTPResponse) throws -> Value, completion: @escaping (Result<Value, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        let operation = WhitegramServiceOperation(completion: completion)
        let prepared = whitegramServiceResult { () -> URLRequest in
            try self.route.requireAvailable()
            let request = try request()
            try self.gate.begin()
            return request
        }
        switch prepared {
        case let .failure(error): operation.finish(.failure(error))
        case let .success(request):
            let gate = self.gate
            let child = self.transport.send(request, maximumResponseBytes: WhitegramServiceLimits.maximumVirusTotalResponseBytes) { result in
                if case let .success(response) = result {
                    gate.end(retryAfter: response.cooldownSeconds)
                } else {
                    gate.end()
                }
                operation.finish(result.flatMap { response in
                    whitegramServiceResult { try decode(response) }
                })
            }
            operation.attach(child)
        }
        return operation.task
    }
}

enum WhitegramVirusTotalWire {
    static func validatedHash(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw WhitegramServiceError.invalidHash
        }
        return value
    }

    static func request(sha256: String, apiKey: String) throws -> URLRequest {
        return try self.request(target: .file(sha256: sha256), apiKey: apiKey)
    }

    static func request(target: WhitegramVirusTotalTarget, apiKey: String) throws -> URLRequest {
        let target = try target.validated()
        let key = try whitegramValidatedAPIKey(apiKey)
        guard let url = URL(string: "https://www.virustotal.com/api/v3/" + target.resourcePath) else { throw WhitegramServiceError.invalidTarget }
        return try whitegramServiceRequest(url: url, method: "GET", apiKey: key, header: "x-apikey")
    }

    static func response(_ response: WhitegramServiceHTTPResponse, sha256: String) throws -> WhitegramVirusTotalLookupResult {
        switch try self.response(response, target: .file(sha256: sha256)) {
        case let .notFound(target): return .notFound(sha256: target.value)
        case let .found(report):
            return .found(WhitegramVirusTotalReport(sha256: report.target.value, statistics: report.statistics, engines: report.engines, analysisDate: report.analysisDate, reportURL: report.reportURL))
        }
    }

    static func response(_ response: WhitegramServiceHTTPResponse, target: WhitegramVirusTotalTarget) throws -> WhitegramVirusTotalTargetLookupResult {
        let target = try target.validated()
        guard response.data.count <= WhitegramServiceLimits.maximumVirusTotalResponseBytes else { throw WhitegramServiceError.responseTooLarge }
        if response.statusCode == 404 {
            // A generic HTML 404 is not evidence that VirusTotal recognized the lookup.
            if let error = try? JSONDecoder().decode(ErrorResponse.self, from: response.data), error.error.code == "NotFoundError" {
                return .notFound(target: target)
            }
            throw WhitegramServiceError.httpStatus(404)
        }
        if let error = whitegramHTTPError(status: response.statusCode, retryAfter: response.retryAfter) { throw error }
        let resource = try JSONDecoder().decode(ResourceResponse.self, from: response.data).data
        let reportPath: String
        let resourceId: String
        switch target {
        case let .file(hash):
            guard resource.type == "file", resource.id.lowercased() == hash else { throw WhitegramServiceError.invalidResponse }
            if let reportedHash = resource.attributes.sha256, reportedHash.lowercased() != hash { throw WhitegramServiceError.invalidResponse }
            resourceId = hash
            reportPath = "file/" + hash
        case let .ipAddress(ip):
            guard resource.type == "ip_address", (try? WhitegramVirusTotalTarget.ipAddress(resource.id).validated()) == target else { throw WhitegramServiceError.invalidResponse }
            resourceId = ip
            reportPath = "ip-address/" + ip
        case .url:
            guard resource.type == "url", let id = try? self.validatedHash(resource.id), let url = resource.attributes.url,
                  (try? WhitegramVirusTotalTarget.url(url).validated()) == target else { throw WhitegramServiceError.invalidResponse }
            resourceId = id
            reportPath = "url/" + id
        }
        let statistics = resource.attributes.lastAnalysisStats
        guard (statistics?.count ?? 0) <= 128, statistics?.values.allSatisfy({ $0 >= 0 && $0 <= 100000 }) != false,
              (resource.attributes.lastAnalysisResults?.count ?? 0) <= 2000 else { throw WhitegramServiceError.invalidResponse }
        let engines = (resource.attributes.lastAnalysisResults ?? [:]).map { name, engine in
            WhitegramVirusTotalEngineResult(name: engine.engineName ?? name, category: engine.category ?? "unknown", result: engine.result, version: engine.engineVersion, update: engine.engineUpdate)
        }.sorted { lhs, rhs in
            let lhsFlagged = lhs.category == "malicious" || lhs.category == "suspicious"
            let rhsFlagged = rhs.category == "malicious" || rhs.category == "suspicious"
            return lhsFlagged == rhsFlagged ? lhs.name < rhs.name : lhsFlagged
        }
        guard let reportURL = URL(string: "https://www.virustotal.com/gui/" + reportPath + "/detection") else { throw WhitegramServiceError.invalidResponse }
        let timestamp = resource.attributes.lastAnalysisDate
        if let timestamp = timestamp, timestamp < 0 || timestamp > 253402300799 { throw WhitegramServiceError.invalidResponse }
        return .found(WhitegramVirusTotalTargetReport(target: target, resourceId: resourceId, statistics: statistics, engines: engines,
            analysisDate: timestamp.map { Date(timeIntervalSince1970: Double($0)) }, reportURL: reportURL))
    }

    private struct ErrorResponse: Decodable {
        struct APIError: Decodable { let code: String }
        let error: APIError
    }

    private struct ResourceResponse: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable {
                struct Engine: Decodable {
                    let category: String?
                    let result: String?
                    let engineName: String?
                    let engineVersion: String?
                    let engineUpdate: String?
                    enum CodingKeys: String, CodingKey {
                        case category, result
                        case engineName = "engine_name"
                        case engineVersion = "engine_version"
                        case engineUpdate = "engine_update"
                    }
                }
                let sha256: String?
                let url: String?
                let lastAnalysisStats: [String: Int]?
                let lastAnalysisResults: [String: Engine]?
                let lastAnalysisDate: Int64?
                enum CodingKeys: String, CodingKey {
                    case sha256, url
                    case lastAnalysisStats = "last_analysis_stats"
                    case lastAnalysisResults = "last_analysis_results"
                    case lastAnalysisDate = "last_analysis_date"
                }
            }
            let id: String
            let type: String
            let attributes: Attributes
        }
        let data: Resource
    }
}
