import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Bounded, opt-out diagnostic delivery. No Telegram log files or account data enter this queue.
public final class WhitegramErrorReporter: @unchecked Sendable {
    public static let shared = WhitegramErrorReporter()
    public static let changed = Notification.Name("WhitegramDiagnostics.statusChanged")
    private let queue = DispatchQueue(label: "WhitegramDiagnostics", qos: .utility)
    private var pending: [WhitegramErrorReport] = []
    private var recent: [String: Date] = [:]
    private var upload: WhitegramDiagnosticsUpload?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var generation = 0
    private var retry: DispatchWorkItem?
    private var attempts = 0
    private var state = "not started"
    private var store: URL?

    public var enabled: Bool { WhitegramPreferences.bool("automaticErrorReports", default: true) }
    public var status: String { queue.sync { "\(state); queued: \(pending.count)" } }

    private var configuration: (URL, String)? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WhitegramDiagnosticsURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "WhitegramDiagnosticsUploadKey") as? String,
              key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        return (url, key)
    }

    public func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            do {
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("WhitegramDiagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var excludedRoot = root
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try excludedRoot.setResourceValues(values)
                self.store = root.appendingPathComponent("pending-v1.json")
                if let store = self.store, FileManager.default.fileExists(atPath: store.path) {
                    let size = try store.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                    self.pending = Array(try JSONDecoder().decode([WhitegramErrorReport].self, from: Data(contentsOf: store)).suffix(32))
                }
            } catch { self.setState("storage error"); return }
            self.observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("WhitegramDiagnostics.runtimeError"), object: nil, queue: nil) { [weak self] event in
                guard let kind = (event.userInfo?["kind"] as? String).flatMap(WhitegramErrorReport.Kind.init(rawValue:)),
                      let component = (event.userInfo?["component"] as? String).flatMap(WhitegramErrorReport.Component.init(rawValue:)),
                      let code = event.userInfo?["code"] as? Int else { return }
                self?.record(kind: kind, component: component, code: code)
            })
            self.observers.append(NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { [weak self] _ in self?.flush() })
            self.flushLocked()
        }
    }

    public func record(kind: WhitegramErrorReport.Kind, component: WhitegramErrorReport.Component, code: Int, frames: [WhitegramErrorReport.Frame] = [], diagnosticBuild: String? = nil) {
        queue.async {
            guard self.started, self.enabled, self.configuration != nil, self.store != nil else { return }
            let now = Date()
            let report = WhitegramErrorReport(kind: kind, component: component, code: code, frames: frames, now: now, diagnosticBuild: diagnosticBuild)
            self.recent = self.recent.filter { now.timeIntervalSince($0.value) < 300 }
            if self.recent[report.fingerprint] != nil { return }
            if self.recent.count >= 64 { return }
            self.recent[report.fingerprint] = now
            self.pending.append(report)
            if self.pending.count > 32 { self.pending.removeFirst(self.pending.count - 32) }
            guard self.persist() else { return }
            self.flushLocked()
        }
    }

    public func flush() { queue.async { self.flushLocked() } }

    private func setState(_ value: String) {
        self.state = value
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    @discardableResult private func persist() -> Bool {
        guard let store else { return false }
        do { try JSONEncoder().encode(self.pending).write(to: store, options: .atomic); return true }
        catch { self.setState("storage error"); return false }
    }

    private func flushLocked() {
        guard self.started else { return }
        guard self.enabled else {
            self.generation += 1
            self.retry?.cancel(); self.retry = nil
            self.upload?.cancel(); self.upload = nil
            self.pending.removeAll(); self.recent.removeAll()
            if self.persist() { self.setState("disabled") }
            return
        }
        guard let (url, key) = self.configuration else { self.setState("not configured"); return }
        guard self.upload == nil, self.retry == nil else { return }
        let cutoff = Int64(Date().timeIntervalSince1970) - 7 * 86400
        self.pending.removeAll { $0.timestamp < cutoff }
        guard let report = self.pending.first else { self.setState("ready"); return }
        guard let body = try? JSONEncoder().encode(report), body.count <= 65536 else { self.setState("invalid report"); return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let generation = self.generation
        self.setState("sending")
        self.upload = WhitegramDiagnosticsUpload(request: request, reportId: report.id) { [weak self] accepted, code in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation else { return }
                self.upload = nil
                if accepted {
                    self.pending.removeAll { $0.id == report.id }
                    self.attempts = 0
                    if self.persist() { self.setState("sent"); self.flushLocked() }
                } else {
                    self.attempts = min(6, self.attempts + 1)
                    self.setState("delivery failed (\(code)); retry pending")
                    let retry = DispatchWorkItem { [weak self] in
                        guard let self, generation == self.generation else { return }
                        self.retry = nil
                        self.flushLocked()
                    }
                    self.retry = retry
                    self.queue.asyncAfter(deadline: .now() + min(900.0, 15.0 * pow(2.0, Double(self.attempts))), execute: retry)
                }
            }
        }
    }
}
