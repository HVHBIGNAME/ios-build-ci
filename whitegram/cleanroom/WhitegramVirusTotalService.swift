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
        if (self.statistics?["malicious"] ?? 0) > 0 || (self.statistics?["suspicious"] ?? 0) > 0 || self.engines.contains(where: { $0.category == "malicious" || $0.category == "suspicious" }) {
            return "One or more engines reported malicious or suspicious findings."
        }
        if let statistics = self.statistics, statistics["malicious"] == 0, statistics["suspicious"] == 0,
           (statistics["harmless"] ?? 0) + (statistics["undetected"] ?? 0) > 0 {
            return "No detections in the returned statistics. This does not establish that the file is safe."
        }
        return "Unknown — no conclusive analysis statistics were returned."
    }
}

public enum WhitegramVirusTotalLookupResult: Equatable {
    case found(WhitegramVirusTotalReport)
    case notFound(sha256: String)
}

/// Looks up an existing report. This service has no file-upload or scan-submission endpoint.
public final class WhitegramVirusTotalService {
    public static let shared = WhitegramVirusTotalService()
    private let transport: WhitegramServiceTransport
    private let gate: WhitegramServiceRequestGate

    public init(transport: WhitegramServiceTransport = WhitegramURLSessionTransport(), minimumRequestInterval: TimeInterval = 15) {
        self.transport = transport
        self.gate = WhitegramServiceRequestGate(minimumInterval: minimumRequestInterval)
    }

    @discardableResult
    public func lookup(sha256: String, apiKey: String, completion: @escaping (Result<WhitegramVirusTotalLookupResult, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
        let operation = WhitegramServiceOperation(completion: completion)
        let prepared = whitegramServiceResult { () -> URLRequest in
            let request = try WhitegramVirusTotalWire.request(sha256: sha256, apiKey: apiKey)
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
                    whitegramServiceResult { try WhitegramVirusTotalWire.response(response, sha256: sha256) }
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
        let hash = try self.validatedHash(sha256)
        let key = try whitegramValidatedAPIKey(apiKey)
        guard let url = URL(string: "https://www.virustotal.com/api/v3/files/" + hash) else { throw WhitegramServiceError.invalidHash }
        return try whitegramServiceRequest(url: url, method: "GET", apiKey: key, header: "x-apikey")
    }

    static func response(_ response: WhitegramServiceHTTPResponse, sha256: String) throws -> WhitegramVirusTotalLookupResult {
        let hash = try self.validatedHash(sha256)
        guard response.data.count <= WhitegramServiceLimits.maximumVirusTotalResponseBytes else { throw WhitegramServiceError.responseTooLarge }
        if response.statusCode == 404 {
            // A generic HTML 404 is not evidence that VirusTotal recognized this hash lookup.
            if let error = try? JSONDecoder().decode(ErrorResponse.self, from: response.data), error.error.code == "NotFoundError" {
                return .notFound(sha256: hash)
            }
            throw WhitegramServiceError.httpStatus(404)
        }
        if let error = whitegramHTTPError(status: response.statusCode, retryAfter: response.retryAfter) { throw error }
        let file = try JSONDecoder().decode(FileResponse.self, from: response.data).data
        guard file.type == "file", file.id.lowercased() == hash else { throw WhitegramServiceError.invalidResponse }
        if let reportedHash = file.attributes.sha256, reportedHash.lowercased() != hash { throw WhitegramServiceError.invalidResponse }
        let statistics = file.attributes.lastAnalysisStats
        guard (statistics?.count ?? 0) <= 128, statistics?.values.allSatisfy({ $0 >= 0 && $0 <= 100000 }) != false,
              (file.attributes.lastAnalysisResults?.count ?? 0) <= 2000 else { throw WhitegramServiceError.invalidResponse }
        let engines = (file.attributes.lastAnalysisResults ?? [:]).map { name, engine in
            WhitegramVirusTotalEngineResult(name: engine.engineName ?? name, category: engine.category ?? "unknown", result: engine.result, version: engine.engineVersion, update: engine.engineUpdate)
        }.sorted { lhs, rhs in
            let lhsFlagged = lhs.category == "malicious" || lhs.category == "suspicious"
            let rhsFlagged = rhs.category == "malicious" || rhs.category == "suspicious"
            return lhsFlagged == rhsFlagged ? lhs.name < rhs.name : lhsFlagged
        }
        guard let reportURL = URL(string: "https://www.virustotal.com/gui/file/" + hash + "/detection") else { throw WhitegramServiceError.invalidResponse }
        let timestamp = file.attributes.lastAnalysisDate
        if let timestamp = timestamp, timestamp < 0 || timestamp > 253402300799 { throw WhitegramServiceError.invalidResponse }
        return .found(WhitegramVirusTotalReport(sha256: hash, statistics: statistics, engines: engines,
            analysisDate: timestamp.map { Date(timeIntervalSince1970: Double($0)) }, reportURL: reportURL))
    }

    private struct ErrorResponse: Decodable {
        struct APIError: Decodable { let code: String }
        let error: APIError
    }

    private struct FileResponse: Decodable {
        struct File: Decodable {
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
                let lastAnalysisStats: [String: Int]?
                let lastAnalysisResults: [String: Engine]?
                let lastAnalysisDate: Int64?
                enum CodingKeys: String, CodingKey {
                    case sha256
                    case lastAnalysisStats = "last_analysis_stats"
                    case lastAnalysisResults = "last_analysis_results"
                    case lastAnalysisDate = "last_analysis_date"
                }
            }
            let id: String
            let type: String
            let attributes: Attributes
        }
        let data: File
    }
}
