import Foundation

public final class WhitegramSessionDiagnostics {
    public enum Event: String, Codable {
        case authorizationCommitted, authorizedStateLoaded, unauthorizedStateLoaded, missingStateLoaded
        case authorizedAccountAdded, unavailableAccountLoaded, newLoginCreated, staleLoginWriteBlocked
        case networkAuthorizationRequired, networkContextLoggedOut, authorizedUIReady
        case signInResponse, passwordResponse
    }

    private struct Entry: Codable {
        let event: Event
        let timestamp: Int64
        let datacenter: Int?
        let code: Int?
    }

    public static let shared = WhitegramSessionDiagnostics(defaults: .standard)
    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let key = "WhitegramSessionDiagnostics.v1"

    public init(defaults: UserDefaults) { self.defaults = defaults }

    private func entries() -> [Entry] {
        guard let data = defaults.data(forKey: Self.key), data.count <= 65536,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(entries.suffix(64))
    }

    public func record(_ event: Event, datacenter: Int? = nil, code: Int? = nil) {
        guard WhitegramPreferences.bool("automaticErrorReports", default: true) else { return }
        lock.lock()
        defer { lock.unlock() }
        var entries = self.entries()
        entries.append(Entry(event: event, timestamp: Int64(Date().timeIntervalSince1970),
                             datacenter: datacenter.flatMap { (1...5).contains($0) ? $0 : nil }, code: code))
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }

    public func export() throws -> URL {
        struct Report: Encodable {
            let schema = 1
            let build: String
            let revision: String
            let os: String
            let events: [Entry]
        }
        lock.lock()
        let events = self.entries()
        lock.unlock()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("WhiteGram-login-\(UUID().uuidString).json")
        let info = Bundle.main.infoDictionary ?? [:]
        let build = (info["CFBundleVersion"] as? String) ?? "unknown"
        let revision = (info["WhitegramSourceRevision"] as? String) ?? "unknown"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let report = Report(build: build, revision: revision, os: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", events: events)
        try JSONEncoder().encode(report).write(to: destination, options: .atomic)
        return destination
    }
}
