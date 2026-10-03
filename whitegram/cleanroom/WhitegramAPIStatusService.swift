import Foundation

struct WhitegramAPIStatus: Decodable, Equatable, WhitegramBackendValidatable {
    struct Service: Decodable, Equatable { let name: String; let ok: Bool }
    let status: String
    let uptimeSeconds: Int?
    let processingMs: Double?
    let services: [Service]
    enum CodingKeys: String, CodingKey {
        case status, uptimeSeconds = "uptime_seconds", processingMs = "processing_ms", services
    }

    func validateResponse() throws {
        guard !status.isEmpty, status.utf8.count <= 128, services.count <= 256,
              services.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 1024 }),
              uptimeSeconds.map({ $0 >= 0 }) ?? true, processingMs.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw WhitegramBackendError.invalidResponse
        }
    }
}

struct WhitegramAPIConnectionMeasurement: Equatable {
    let pingMilliseconds: Double
    let downloadMbps: Double
    let uploadMbps: Double

    static func rate(bytes: Int, seconds: TimeInterval) throws -> Double {
        guard bytes > 0, seconds.isFinite, seconds > 0 else { throw WhitegramBackendError.invalidResponse }
        return Double(bytes) * 8 / seconds / 1_000_000
    }
}

final class WhitegramAPIUsage {
    static let shared = WhitegramAPIUsage()
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let key = "WhitegramBackend.RequestCounts.v1"
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    private func records() -> [String: [String: Int]] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        do { return try JSONDecoder().decode([String: [String: Int]].self, from: data) }
        catch { NSLog("Whitegram: could not read API usage counts"); return [:] }
    }

    func record(path: String) {
        guard path.hasPrefix("/v1/"), !path.contains("?"), path.utf8.count <= 200 else { return }
        lock.lock()
        defer { lock.unlock() }
        let day = Int(now().timeIntervalSince1970 / 86400)
        var records = records().filter { Int($0.key).map { $0 >= day - 30 && $0 <= day } ?? false }
        let old = records[String(day)]?[path] ?? 0
        records[String(day), default: [:]][path] = old == Int.max ? old : old + 1
        do { defaults.set(try JSONEncoder().encode(records), forKey: key) }
        catch { NSLog("Whitegram: could not save API usage counts") }
    }

    func counts(days: Int) -> [(path: String, count: Int)] {
        lock.lock()
        defer { lock.unlock() }
        let day = Int(now().timeIntervalSince1970 / 86400)
        var counts: [String: Int] = [:]
        for (key, paths) in records() {
            guard let date = Int(key), date <= day, date > day - min(30, max(1, days)) else { continue }
            for (path, count) in paths where count > 0 {
                let (sum, overflow) = (counts[path] ?? 0).addingReportingOverflow(count)
                counts[path] = overflow ? Int.max : sum
            }
        }
        return counts.map { (path: $0.key, count: $0.value) }.sorted { $0.count == $1.count ? $0.path < $1.path : $0.count > $1.count }
    }
}

final class WhitegramAPIStatusService {
    let client: WhitegramBackendClient
    init(client: WhitegramBackendClient) { self.client = client }

    func status(completion: @escaping (Result<WhitegramAPIStatus, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.request(WhitegramAPIStatus.self, path: "/v1/status", authenticated: false, completion: completion)
    }

    func measure(completion: @escaping (Result<WhitegramAPIConnectionMeasurement, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        let cancellation = WhitegramBackendCancellation()
        let ping = client.raw(path: "/v1/status/probe", query: [URLQueryItem(name: "size", value: "1024")], authenticated: false, maximumBytes: 1024) { [self] result in
            if cancellation.isCancelled { completion(.failure(.cancelled)); return }
            switch result {
            case let .failure(error): completion(.failure(error))
            case let .success(ping):
                guard ping.data.count == 1024 else { completion(.failure(.invalidResponse)); return }
                let download = client.raw(path: "/v1/status/probe", query: [URLQueryItem(name: "size", value: "524288")], authenticated: false, maximumBytes: 524288) { [self] result in
                    if cancellation.isCancelled { completion(.failure(.cancelled)); return }
                    switch result {
                    case let .failure(error): completion(.failure(error))
                    case let .success(download):
                        guard download.data.count == 524288 else { completion(.failure(.invalidResponse)); return }
                        var random = SystemRandomNumberGenerator()
                        let bytes = Data((0..<262144).map { _ in UInt8.random(in: .min ... .max, using: &random) })
                        let upload = client.raw(path: "/v1/status/probe", method: "POST", body: bytes, contentType: "application/octet-stream", authenticated: false) { result in
                            if cancellation.isCancelled { completion(.failure(.cancelled)); return }
                            completion(result.flatMap { upload in
                                do {
                                    return .success(WhitegramAPIConnectionMeasurement(pingMilliseconds: ping.duration * 1000,
                                        downloadMbps: try WhitegramAPIConnectionMeasurement.rate(bytes: download.data.count, seconds: download.duration),
                                        uploadMbps: try WhitegramAPIConnectionMeasurement.rate(bytes: bytes.count, seconds: upload.duration)))
                                } catch { return .failure(.invalidResponse) }
                            })
                        }
                        cancellation.bind(upload)
                    }
                }
                cancellation.bind(download)
            }
        }
        cancellation.bind(ping)
        return cancellation
    }
}
